// Shared/CryptoPriceService.swift

import Foundation
import GRDB
import OSLog

actor CryptoPriceService {
  // `clients` is accessed by the live-prices extension in
  // `CryptoPriceService+Live.swift` so it must be at least internal.
  let clients: [CryptoPriceClient]

  // MARK: - Cross-extension internals
  // `caches`, `hydratedTokenIds`, `database`, and `logger` are accessed
  // by the SQL persistence extension in
  // `CryptoPriceService+Persistence.swift` and the merge extension in
  // `CryptoPriceService+Merge.swift`. The methods
  // `loadCache(tokenId:)` / `persistDelta(tokenId:deltaRecords:)`
  // (persistence) and `mergeReturningDelta(tokenId:symbol:newPrices:)`
  // (merge) are defined there and called from this file, which is why
  // both they and these properties are `internal` rather than `private`.
  // They remain actor-isolated; the access modifier is internal so the
  // sibling-file extensions can see them.
  var caches: [String: CryptoPriceCache] = [:]
  /// Loaded token ids — set on first hydration so we don't re-read SQL when
  /// the cache is genuinely empty.
  var hydratedTokenIds: Set<String> = []
  /// In-flight cache-extension fetches, keyed by token id, so concurrent
  /// `price(...)` requests for the same token share one provider round-trip
  /// instead of each issuing its own. The `id` tags the owning request so a
  /// completing fetch only clears its own entry, never a successor's.
  /// `internal` (not `private`) so `fetchWindowCoalesced` in
  /// `CryptoPriceService+FetchRange.swift` can read and mutate it from the
  /// sibling-file extension. It remains actor-isolated.
  var extensionTasks: [String: (id: UUID, task: Task<Void, Error>)] = [:]
  let database: any DatabaseWriter
  let logger = Logger(
    subsystem: "com.moolah.app", category: "CryptoPriceService")

  // `dateFormatter`, `now`, and `timeZone` are `internal` (not `private`)
  // because the warm path in `CryptoPriceService+FetchRange.swift`
  // (`warmRange` and its bounded-window loop) reuses the same ISO day
  // formatting, injected clock, and zone the in-file cache-extension
  // decision uses, so the sibling-file extension must see them. They
  // remain actor-isolated; the access modifier is internal so the
  // sibling-file extension can read them.
  let dateFormatter: ISO8601DateFormatter
  private let resolutionClient: TokenResolutionClient
  /// In-memory cache of resolved `CryptoRegistration` values, keyed by
  /// instrument id. Populated lazily on first call to `registration(for:)`
  /// and evicted by `purgeCache(instrumentId:)`. Keyed under both the
  /// original instrument id and the resolved lookup id (native id for
  /// wrapped-native tokens) so a second call for the wrapper hits the
  /// cache without re-running the lookup. Private — used only within this
  /// file, no sibling-file extension reads it.
  private var metadataCache: [String: CryptoRegistration] = [:]
  private let metadataLookup: @Sendable (String) async throws -> CryptoRegistration?
  /// Injected clock so tests can pin "today" deterministically.
  let now: @Sendable () -> Date
  /// Injected zone used by `cappedToYesterday` to compute "yesterday".
  /// Production defaults to `TimeZone.current`; tests asserting on a
  /// specific `YYYY-MM-DD` label pin to `UTC`.
  let timeZone: TimeZone

  init(
    clients: [CryptoPriceClient],
    database: any DatabaseWriter,
    resolutionClient: (any TokenResolutionClient)? = nil,
    metadataLookup: @Sendable @escaping (String) async throws -> CryptoRegistration? = { _ in nil },
    now: @Sendable @escaping () -> Date = { Date() },
    timeZone: TimeZone = .current
  ) {
    self.clients = clients
    self.database = database
    self.resolutionClient = resolutionClient ?? NoOpTokenResolutionClient()
    self.metadataLookup = metadataLookup
    self.now = now
    self.timeZone = timeZone
    self.dateFormatter = ISO8601DateFormatter()
    self.dateFormatter.formatOptions = [.withFullDate]
  }

  // MARK: - Token resolution

  func resolveRegistration(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> CryptoRegistration {
    let result = try await resolutionClient.resolve(
      chainId: chainId,
      contractAddress: contractAddress,
      symbol: symbol,
      isNative: isNative
    )
    let resolvedSymbol = result.resolvedSymbol ?? symbol ?? "???"
    let resolvedName = result.resolvedName ?? symbol ?? "Unknown Token"
    let resolvedDecimals = result.resolvedDecimals ?? 18

    let instrument = Instrument.crypto(
      chainId: chainId,
      contractAddress: isNative ? nil : contractAddress,
      symbol: resolvedSymbol,
      name: resolvedName,
      decimals: resolvedDecimals
    )
    let mapping = CryptoProviderMapping(
      instrumentId: instrument.id,
      coingeckoId: result.coingeckoId,
      cryptocompareSymbol: result.cryptocompareSymbol,
      binanceSymbol: result.binanceSymbol
    )
    return CryptoRegistration(instrument: instrument, mapping: mapping)
  }

  /// Drops any cached price data for the given instrument id — removes both
  /// the in-memory cache entry and the on-disk rows. Called when an
  /// instrument is un-registered so we don't retain stale prices for a
  /// deregistered instrument.
  func purgeCache(instrumentId: String) async {
    caches.removeValue(forKey: instrumentId)
    hydratedTokenIds.remove(instrumentId)
    metadataCache.removeValue(forKey: instrumentId)
    // When a native-asset registration is purged, also evict any cached
    // wrapped-native entry that was resolved to it (e.g. WETH→ETH). Without
    // this, a subsequent WETH price lookup would return the stale cached
    // mapping instead of re-resolving via the lookup closure.
    if let wrapperId = WrappedNativeContracts.canonicalWrappedInstrumentId(
      forChainId: chainId(fromCryptoId: instrumentId))
    {
      metadataCache.removeValue(forKey: wrapperId)
    }
    do {
      try await database.write { database in
        try CryptoPriceRecord
          .filter(CryptoPriceRecord.Columns.tokenId == instrumentId)
          .deleteAll(database)
        try CryptoTokenMetaRecord
          .filter(CryptoTokenMetaRecord.Columns.tokenId == instrumentId)
          .deleteAll(database)
        // `crypto_price` is `WITHOUT ROWID`; SQLite's update hook does
        // not fire for these tables, so `ValueObservation` over the
        // rate-cache region needs an explicit notify to see this delete.
        // See `Backends/GRDB/Observation/RateCacheTable.swift`
        // and `guides/DATABASE_CODE_GUIDE.md` §2 convention 1.
        try database.notifyRateCacheChange(.cryptoPrice)
      }
    } catch {
      logger.warning(
        "purgeCache failed for \(instrumentId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// Extracts the chain id from a crypto instrument id of the form
  /// `"<chainId>:native"` or `"<chainId>:<contractAddress>"`. Returns
  /// `nil` when the id does not match the expected format.
  private func chainId(fromCryptoId id: String) -> Int? {
    Int(id.prefix(while: { $0 != ":" }))
  }

  // MARK: - Single price

  /// Resolves the `CryptoRegistration` for `instrument` via the injected
  /// `metadataLookup` closure, with an in-memory cache to avoid redundant
  /// point lookups. Wrapped-native tokens (WETH, WMATIC, …) are redirected
  /// to their chain's native registration via `WrappedNativeContracts`.
  ///
  /// Throws `ConversionError.noProviderMapping` when the lookup returns
  /// `nil` for the resolved id — matching the error the caller expects when
  /// no provider mapping is registered for the instrument.
  func registration(for instrument: Instrument) async throws -> CryptoRegistration {
    if let cached = metadataCache[instrument.id] { return cached }
    let lookupId =
      WrappedNativeContracts.nativePricingInstrumentId(
        chainId: instrument.chainId, contractAddress: instrument.contractAddress)
      ?? instrument.id
    guard let resolved = try await metadataLookup(lookupId) else {
      throw ConversionError.noProviderMapping(instrumentId: instrument.id)
    }
    metadataCache[instrument.id] = resolved
    metadataCache[lookupId] = resolved
    return resolved
  }

  /// Prices `instrument` on `date` by first resolving its `CryptoRegistration`
  /// (via the in-memory metadata cache + injected lookup), then delegating to
  /// the internal `price(for:mapping:on:)`. Wrapped-native tokens are priced
  /// via their chain's native registration so price fetch/cache uses the
  /// native instrument's id, matching the pre-existing behaviour.
  func price(for instrument: Instrument, on date: Date) async throws -> Decimal {
    let reg = try await registration(for: instrument)
    return try await price(for: reg.instrument, mapping: reg.mapping, on: date)
  }

  func price(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    on date: Date
  ) async throws -> Decimal {
    let date = cappedToYesterday(date, now: now, timeZone: timeZone)
    let tokenId = instrument.id
    let dateString = dateFormatter.string(from: date)

    if let cached = lookupPrice(tokenId: tokenId, dateString: dateString) {
      return cached
    }

    if !hydratedTokenIds.contains(tokenId) {
      try await loadCache(tokenId: tokenId)
    }

    if let cached = lookupPrice(tokenId: tokenId, dateString: dateString) {
      return cached
    }

    // Fast-path: if the confirmed first-trade date is known and the requested
    // date is strictly before it, the token had no market price on this date.
    // Throw `.beforeFirstTrade` so the priceLookup seam can map it to .knownZero.
    if let floor = caches[tokenId]?.firstTradedOn, dateString < floor {
      throw CryptoPriceError.beforeFirstTrade(tokenId: tokenId, date: dateString)
    }

    if let inRange = try inRangeFallback(tokenId: tokenId, dateString: dateString) {
      return inRange
    }

    // Out of cached range: extend contiguously toward the requested date.
    return try await extendContiguously(
      instrument: instrument,
      mapping: mapping,
      tokenId: tokenId,
      dateString: dateString)
  }

  /// Resolves the request from the in-memory cache when the requested
  /// date sits inside the `[earliestDate, latestDate]` window. Returns
  /// the prior-trading-day fallback price if available and `nil` if the
  /// date is out of range (the caller then triggers an extension fetch).
  ///
  /// Throws `noPriceAvailable` for the rare in-range case where the
  /// cache has bounds set but no row on or before the requested date —
  /// surfacing as missing rather than re-fetching is intentional.
  /// Without this short-circuit every weekend / non-trading-day in a
  /// chart's visible range dispatched a network probe and a `saveCache`
  /// rewrite, saturating the GRDB queue. Mirrors
  /// `ExchangeRateService.rate(...)`'s in-range branch.
  ///
  /// `internal` (not `private`) because `extendContiguously` in
  /// `CryptoPriceService+FetchRange.swift` calls it from a sibling
  /// extension on the same actor.
  func inRangeFallback(tokenId: String, dateString: String) throws -> Decimal? {
    guard let cache = caches[tokenId],
      dateString >= cache.earliestDate, dateString <= cache.latestDate
    else { return nil }
    if let fallback = fallbackPrice(tokenId: tokenId, dateString: dateString) {
      return fallback
    }
    throw CryptoPriceError.noPriceAvailable(tokenId: tokenId, date: dateString)
  }

  // MARK: - Date range

  func prices(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    in range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    let tokenId = instrument.id

    if !hydratedTokenIds.contains(tokenId) {
      try await loadCache(tokenId: tokenId)
    }

    // Cap the *fetch* upper bound at yesterday — same rationale as
    // `price(for:mapping:on:)`. The result series below still walks the
    // caller-supplied range; today's slot fills via `lastKnownPrice`.
    let fetchUpperBound = cappedToYesterday(range.upperBound, now: now, timeZone: timeZone)

    // Extend the cache contiguously toward both endpoints using the bounded
    // planner loop (no-progress guard), so a horizon-restricted provider
    // cannot jump `earliest`/`latest` over un-fetched days (the interior-gap
    // bug). `coverRangeContiguously` lives in
    // `CryptoPriceService+FetchRange.swift`.
    if range.lowerBound <= fetchUpperBound,
      let lowerKey = DateKey.from(isoString: dateFormatter.string(from: range.lowerBound)),
      let upperKey = DateKey.from(isoString: dateFormatter.string(from: fetchUpperBound))
    {
      try await coverRangeContiguously(
        instrument: instrument,
        mapping: mapping,
        tokenId: tokenId,
        lowerKey: lowerKey,
        upperKey: upperKey)
    }

    let dates = generateDateSeries(in: range)
    var results: [(date: Date, price: Decimal)] = []
    var lastKnownPrice: Decimal?

    for date in dates {
      let dateString = dateFormatter.string(from: date)
      if let key = DateKey.from(isoString: dateString),
        let price = caches[tokenId]?.prices.exact(key)
      {
        lastKnownPrice = price
        results.append((date, price))
      } else if let fallback = lastKnownPrice {
        results.append((date, fallback))
      }
    }

    return results
  }

  // `currentPrices(for:)` (the live / spot endpoint) and
  // `prefetchLatest(for:)` (the live-tick writer) live in
  // `CryptoPriceService+Live.swift`.

}

// MARK: - Cache lookup & merge

extension CryptoPriceService {
  /// Internal (not private) so `extendContiguously` in
  /// `CryptoPriceService+FetchRange.swift` can call it from the sibling
  /// extension — same actor isolation, just different file.
  func lookupPrice(tokenId: String, dateString: String) -> Decimal? {
    guard let key = DateKey.from(isoString: dateString) else { return nil }
    return caches[tokenId]?.prices.exact(key)
  }

  func fallbackPrice(tokenId: String, dateString: String) -> Decimal? {
    guard let key = DateKey.from(isoString: dateString),
      let cache = caches[tokenId]
    else { return nil }
    return cache.prices.floor(key)
  }

  private func generateDateSeries(in range: ClosedRange<Date>) -> [Date] {
    let calendar = Calendar.utc
    var dates: [Date] = []
    var current = range.lowerBound
    while current <= range.upperBound {
      dates.append(current)
      guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
      current = next
    }
    return dates
  }

  // `extendContiguously(instrument:mapping:tokenId:dateString:)`,
  // `boundsKeys(tokenId:)`, `parseInterval(_:)`, `fetchWindowCoalesced(...)`,
  // and `fetchRange(instrument:mapping:from:to:)` live in
  // `CryptoPriceService+FetchRange.swift`, `mergeReturningDelta` lives
  // in `CryptoPriceService+Merge.swift`, and `NoOpTokenResolutionClient`
  // lives in its own sibling file.
}
