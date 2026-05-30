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
  let database: any DatabaseWriter
  let logger = Logger(
    subsystem: "com.moolah.app", category: "CryptoPriceService")

  private let dateFormatter: ISO8601DateFormatter
  private let resolutionClient: TokenResolutionClient
  /// Injected clock so tests can pin "today" deterministically.
  private let now: @Sendable () -> Date
  /// Injected zone used by `cappedToYesterday` to compute "yesterday".
  /// Production defaults to `TimeZone.current`; tests asserting on a
  /// specific `YYYY-MM-DD` label pin to `UTC`.
  private let timeZone: TimeZone

  init(
    clients: [CryptoPriceClient],
    database: any DatabaseWriter,
    resolutionClient: (any TokenResolutionClient)? = nil,
    now: @Sendable @escaping () -> Date = { Date() },
    timeZone: TimeZone = .current
  ) {
    self.clients = clients
    self.database = database
    self.resolutionClient = resolutionClient ?? NoOpTokenResolutionClient()
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

  // MARK: - Single price

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

    if let inRange = try inRangeFallback(tokenId: tokenId, dateString: dateString) {
      return inRange
    }

    // Out of cached range — extend toward the requested date and try
    // each provider in order. Continues past providers that return
    // empty so a fallback chain (CoinGecko → CryptoCompare → Binance)
    // can collectively fill in the dates one of them has.
    let fetchInterval = extensionWindow(
      for: tokenId, requestedDate: date, dateString: dateString)
    return try await fetchAndExtendCache(
      instrument: instrument,
      mapping: mapping,
      fetchInterval: fetchInterval,
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
  private func inRangeFallback(tokenId: String, dateString: String) throws -> Decimal? {
    guard let cache = caches[tokenId],
      dateString >= cache.earliestDate, dateString <= cache.latestDate
    else { return nil }
    if let fallback = fallbackPrice(tokenId: tokenId, dateString: dateString) {
      return fallback
    }
    throw CryptoPriceError.noPriceAvailable(tokenId: tokenId, date: dateString)
  }

  /// Returns the date range a fetch should cover when the cache cannot
  /// satisfy the request directly. Mirrors the extension shape used by
  /// `StockPriceService.fetchToCoverDate` and `ExchangeRateService`:
  ///
  /// - **Cache exists, requested date past `latestDate`:** forward
  ///   extension *including* `latestDate` so a stale value (e.g. an
  ///   intraday tick persisted by an older build) is overwritten by
  ///   the next finalised close.
  /// - **Cache exists, requested date before `earliestDate`:** backward
  ///   extension from the requested date to the day before
  ///   `earliestDate`.
  /// - **Cold cache (no entry for token):** 30-day surrounding window so
  ///   a first-ever request on a non-trading day can still fall back
  ///   to a recent prior price.
  ///
  /// The in-range case is unreachable here — `price(...)` short-circuits
  /// before calling this — but a defensive single-day window is returned
  /// just in case.
  ///
  /// `requestedDate` is already capped at yesterday by `price(...)`.
  private func extensionWindow(
    for tokenId: String, requestedDate: Date, dateString: String
  ) -> ClosedRange<Date> {
    let calendar = Calendar(identifier: .gregorian)
    if let cache = caches[tokenId] {
      if dateString > cache.latestDate,
        let fetchStart = dateFormatter.date(from: cache.latestDate),
        fetchStart <= requestedDate
      {
        return fetchStart...requestedDate
      }
      if dateString < cache.earliestDate,
        let earliestDate = dateFormatter.date(from: cache.earliestDate),
        let fetchEnd = calendar.date(byAdding: .day, value: -1, to: earliestDate)
      {
        return requestedDate...fetchEnd
      }
      return requestedDate...requestedDate
    }
    let fetchStart = calendar.date(byAdding: .day, value: -30, to: requestedDate) ?? requestedDate
    return fetchStart...requestedDate
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
    let rangeStart = dateFormatter.string(from: range.lowerBound)
    let fetchEndString = dateFormatter.string(from: fetchUpperBound)

    let gregorian = Calendar(identifier: .gregorian)
    if let cache = caches[tokenId] {
      if rangeStart < cache.earliestDate,
        let earliestDate = dateFormatter.date(from: cache.earliestDate),
        let fetchEnd = gregorian.date(byAdding: .day, value: -1, to: earliestDate)
      {
        try await fetchRange(
          instrument: instrument, mapping: mapping, from: range.lowerBound, to: fetchEnd)
      }
      // Forward extension overlaps the existing latest entry — same
      // rationale as `extensionWindow`.
      if fetchEndString > cache.latestDate,
        let fetchStart = dateFormatter.date(from: cache.latestDate),
        fetchStart <= fetchUpperBound
      {
        try await fetchRange(
          instrument: instrument, mapping: mapping, from: fetchStart, to: fetchUpperBound)
      }
    } else if range.lowerBound <= fetchUpperBound {
      try await fetchRange(
        instrument: instrument, mapping: mapping, from: range.lowerBound, to: fetchUpperBound)
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

  // `currentPrices(for:)` (the live / spot endpoint) lives in
  // `CryptoPriceService+Live.swift`.

  // MARK: - Prefetch

  func prefetchLatest(for registrations: [CryptoRegistration]) async {
    let mappings = registrations.map(\.mapping)
    let prices: [String: Decimal]
    do {
      prices = try await currentPrices(for: mappings)
    } catch {
      logger.warning(
        "Prefetch failed (best-effort): \(error.localizedDescription, privacy: .public)"
      )
      return
    }
    // Tag the live tick as the local-yesterday calendar day; see
    // `Shared/PriceCacheCap.swift`. The next forward `dailyPrices`
    // extension overwrites this best-effort value with the finalised
    // close.
    let dateString = dateFormatter.string(
      from: cappedToYesterday(now(), now: now, timeZone: timeZone))
    for (tokenId, price) in prices {
      let registration = registrations.first { $0.id == tokenId }
      let symbol = registration?.instrument.ticker ?? registration?.instrument.name ?? ""
      let delta = mergeReturningDelta(
        tokenId: tokenId, symbol: symbol, newPrices: [dateString: price])
      // Skip the disk write when the latest price is identical to the
      // already-cached value — periodic "no change" polling would
      // otherwise rewrite the partition on every tick.
      guard !delta.isEmpty else { continue }
      do {
        try await persistDelta(tokenId: tokenId, deltaRecords: delta)
      } catch {
        logger.warning(
          // Best-effort: continue the loop so a single bad token doesn't
          // poison the rest of the prefetch.
          "prefetchLatest: persistDelta failed for \(tokenId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }
}

// MARK: - Cache lookup & merge

extension CryptoPriceService {
  /// Internal (not private) so `fetchAndExtendCache` in
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
    let calendar = Calendar(identifier: .gregorian)
    var dates: [Date] = []
    var current = range.lowerBound
    while current <= range.upperBound {
      dates.append(current)
      guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
      current = next
    }
    return dates
  }

  // `fetchAndExtendCache(instrument:mapping:fetchInterval:dateString:)`
  // and `fetchRange(instrument:mapping:from:to:)` live in
  // `CryptoPriceService+FetchRange.swift`, `mergeReturningDelta` lives
  // in `CryptoPriceService+Merge.swift`, and `NoOpTokenResolutionClient`
  // lives in its own sibling file.
}
