import Foundation
import GRDB
import OSLog

actor CryptoPriceService {
  // `clients` is accessed by the live-prices extension in
  // `CryptoPriceService+Live.swift` so it must be at least internal.
  let clients: [CryptoPriceClient]

  // MARK: - Cross-extension internals
  // `caches`, `hydrated`, `database`, and `logger` are accessed
  // by the SQL persistence extension in
  // `CryptoPriceService+Persistence.swift` and the merge extension in
  // `CryptoPriceService+Merge.swift`. The methods
  // `loadCache(tokenId:)` / `persistDelta(tokenId:deltaRecords:)`
  // (persistence) and `mergeReturningDelta(tokenId:symbol:newPrices:)`
  // (merge) are defined there and called from this file, which is why
  // both they and these properties are `internal` rather than `private`.
  // They remain actor-isolated; the access modifier is internal so the
  // sibling-file extensions can see them.
  //
  // The price-series orchestration (cap → exact → hydrate → window loop →
  // carry-forward → resolution) is shared with `StockPriceService` via the
  // `PriceSeriesOrchestrating` default methods; `caches`, `hydrated`, `now`,
  // `timeZone`, `dateFormatter`, and `plannerConfig` satisfy that protocol's
  // requirements directly. See `CryptoPriceService+PriceSeriesOrchestrating`.
  var caches: [String: CryptoPriceCache] = [:]
  /// Loaded token ids — set on first hydration so we don't re-read SQL when
  /// the cache is genuinely empty. Satisfies the `PriceSeriesOrchestrating`
  /// `hydrated` requirement.
  var hydrated: Set<String> = []
  /// In-flight cache-extension fetches, keyed by token id, so concurrent
  /// `price(...)` requests for the same token share one provider round-trip
  /// instead of each issuing its own. The `id` tags the owning request so a
  /// completing fetch only clears its own entry, never a successor's.
  /// `internal` (not `private`) so `fetchWindowCoalesced` in
  /// `CryptoPriceService+FetchRange.swift` can read and mutate it from the
  /// sibling-file extension. It remains actor-isolated.
  var extensionTasks: [String: (id: UUID, task: Task<Void, Error>)] = [:]
  /// Bounded-window planner config used by the shared `PriceSeriesOrchestrating`
  /// window loop. Same 30-day window / 2-day forward buffer the per-service
  /// `warmRange` loop uses.
  let plannerConfig = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)
  /// In-flight `(instrument, mapping)` context for the current price/prices
  /// call, keyed by instrument id, so the window-only `fetchAndMerge` plug can
  /// recover the provider mapping the crypto fetch needs. Set in the thin
  /// `price(for:mapping:on:)`/`prices(for:mapping:in:)` call-throughs and
  /// cleared with a keyed `defer`. KEYED (never a single slot) so concurrent
  /// fetches for different tokens don't clobber each other — race-safe for the
  /// same reason `caches[key]` is. A concurrent call for the *same* id writes
  /// the identical context, so last-writer-wins is harmless.
  ///
  /// `internal` (not `private`) so the `fetchAndMerge` plug in the sibling
  /// `CryptoPriceService+PriceSeriesOrchestrating.swift` extension can read it.
  var pendingFetchContext: [String: (instrument: Instrument, mapping: CryptoProviderMapping)] = [:]
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
    hydrated.remove(instrumentId)
    metadataCache.removeValue(forKey: instrumentId)
    // `registration(for:)` co-stores a wrapped-native token's registration
    // under BOTH the wrapper's id and the resolved native lookup id, so a
    // purge must evict both directions or a stale co-stored entry survives:
    //  • purging a NATIVE id must also drop the wrapper entry resolved to it
    //    (e.g. ETH purge → drop WETH), and
    //  • purging a WRAPPER id must also drop the native entry it was stored
    //    under (e.g. WETH purge → drop ETH).
    // Without both, a subsequent lookup of the un-evicted side returns the
    // stale cached mapping instead of re-resolving via the lookup closure.
    if let wrapperId = WrappedNativeContracts.canonicalWrappedInstrumentId(
      forChainId: chainId(fromCryptoId: instrumentId))
    {
      metadataCache.removeValue(forKey: wrapperId)
    }
    if let nativeId = WrappedNativeContracts.nativePricingInstrumentId(
      chainId: chainId(fromCryptoId: instrumentId),
      contractAddress: contractAddress(fromCryptoId: instrumentId))
    {
      metadataCache.removeValue(forKey: nativeId)
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

  /// Extracts the contract-address segment from a crypto instrument id of the
  /// form `"<chainId>:<contractAddress>"`. Returns `nil` for a native id
  /// (`"<chainId>:native"`) or an id without a `:` separator — matching the
  /// `contractAddress == nil` shape of a native `Instrument`, so the value
  /// round-trips through `WrappedNativeContracts.nativePricingInstrumentId`.
  private func contractAddress(fromCryptoId id: String) -> String? {
    guard let colon = id.firstIndex(of: ":") else { return nil }
    let suffix = String(id[id.index(after: colon)...])
    return suffix == "native" ? nil : suffix
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
  ///
  /// No request coalescing: concurrent cache-miss callers for the same id may
  /// each run the (idempotent) lookup once before the first stores its result.
  /// An accepted trade-off — the lookup is cheap and side-effect-free, so the
  /// duplicate work isn't worth a per-id in-flight task table.
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

  /// Thin call-through: stashes the in-flight `(instrument, mapping)` so the
  /// window-only `fetchAndMerge` plug can recover the mapping, then delegates
  /// to the shared `PriceSeriesOrchestrating.price(instrumentKey:on:)` default.
  ///
  /// The `defer` clears the keyed context on return. Because the shared default
  /// only fetches while this call is on the stack for `instrument.id`, and a
  /// concurrent call for a *different* id uses a different dict key, the
  /// per-key stash is race-safe for the same reason `caches[key]` is. A
  /// concurrent call for the *same* id sets the same context value (identical
  /// instrument/mapping), so last-writer-wins is harmless.
  func price(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    on date: Date
  ) async throws -> Decimal {
    pendingFetchContext[instrument.id] = (instrument, mapping)
    defer { pendingFetchContext[instrument.id] = nil }
    return try await price(instrumentKey: instrument.id, on: date)
  }

  // MARK: - Date range

  /// Thin call-through to the shared `PriceSeriesOrchestrating` range default.
  /// See `price(for:mapping:on:)` for the `pendingFetchContext` race contract.
  func prices(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    in range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    pendingFetchContext[instrument.id] = (instrument, mapping)
    defer { pendingFetchContext[instrument.id] = nil }
    return try await prices(instrumentKey: instrument.id, in: range)
  }

  // `currentPrices(for:)` (the live / spot endpoint) and
  // `prefetchLatest(for:)` (the live-tick writer) live in
  // `CryptoPriceService+Live.swift`.

}

// The price-series orchestration (cache lookup, carry-forward series, and the
// contiguous window loop) lives in the shared `PriceSeriesOrchestrating`
// default methods — see `CryptoPriceService+PriceSeriesOrchestrating.swift` for
// the conformance and the plug methods that route the 4-provider fallback chain
// + first-trade floor back through per-service code.
//
// `boundsKeys(tokenId:)`, `parseInterval(_:)`, `fetchWindowCoalesced(...)`,
// `fetchRange(instrument:mapping:from:to:)`, and `confirmFirstTradedOnIfExhausted`
// live in `CryptoPriceService+FetchRange.swift`; `mergeReturningDelta` lives in
// `CryptoPriceService+Merge.swift`; and `NoOpTokenResolutionClient` lives in its
// own sibling file.
