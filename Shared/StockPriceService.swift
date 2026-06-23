import Foundation
import GRDB
import OSLog

enum StockPriceError: Error, Equatable {
  case noPriceAvailable(ticker: String, date: String)
  case unknownTicker(String)
}

actor StockPriceService {
  private let client: StockPriceClient
  private let database: any DatabaseWriter

  // MARK: - Cross-extension internals
  // `caches`, `hydrated`, `dateFormatter`, `now`, `timeZone`, and `logger` are
  // accessed by the merge extension in `StockPriceService+Merge.swift` (which
  // defines `mergeReturningDelta(ticker:instrument:newPrices:)`, called from
  // this file), so they are `internal` rather than `private`. They remain
  // actor-isolated; the access modifier is internal only so the sibling-file
  // extensions can see them.
  //
  // The price-series orchestration (cap → exact → hydrate → window loop →
  // carry-forward → resolution) is shared with `CryptoPriceService` via the
  // `PriceSeriesOrchestrating` default methods; `caches`, `hydrated`, `now`,
  // `timeZone`, `dateFormatter`, and `plannerConfig` satisfy that protocol's
  // requirements directly. See `StockPriceService+PriceSeriesOrchestrating`.
  var caches: [String: StockPriceCache] = [:]
  /// Tickers hydrated from SQL — set on first hydration so we don't re-read
  /// SQL when the cache is genuinely empty. Satisfies the
  /// `PriceSeriesOrchestrating` `hydrated` requirement.
  var hydrated: Set<String> = []
  let dateFormatter: ISO8601DateFormatter
  /// Injected clock so tests can pin "today" deterministically.
  let now: @Sendable () -> Date
  /// Injected zone used by `cappedToYesterday` to compute "yesterday".
  /// Production defaults to `TimeZone.current`; tests asserting on a
  /// specific `YYYY-MM-DD` label pin to `UTC`.
  let timeZone: TimeZone
  let logger = Logger(
    subsystem: "com.moolah.app", category: "StockPriceService")
  /// Bounded-window planner config used by the shared `PriceSeriesOrchestrating`
  /// window loop (30-day window / 2-day forward buffer).
  let plannerConfig = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)

  init(
    client: StockPriceClient,
    database: any DatabaseWriter,
    now: @Sendable @escaping () -> Date = { Date() },
    timeZone: TimeZone = .current
  ) {
    self.client = client
    self.database = database
    self.now = now
    self.timeZone = timeZone
    self.dateFormatter = ISO8601DateFormatter()
    self.dateFormatter.formatOptions = [.withFullDate]
  }

  // MARK: - Public API

  /// Thin call-through to the shared `PriceSeriesOrchestrating` default.
  func price(ticker: String, on date: Date) async throws -> Decimal {
    try await price(instrumentKey: ticker, on: date)
  }

  /// Thin call-through to the shared `PriceSeriesOrchestrating` default.
  func prices(
    ticker: String, in range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    try await prices(instrumentKey: ticker, in: range)
  }

  func instrument(for ticker: String) async throws -> Instrument {
    if let cache = caches[ticker] {
      return cache.instrument
    }
    if !hydrated.contains(ticker) {
      try await loadCache(ticker: ticker)
    }
    if let cache = caches[ticker] {
      return cache.instrument
    }
    throw StockPriceError.unknownTicker(ticker)
  }

  // MARK: - Fetch + persistence

  func fetchAndMerge(ticker: String, from: Date, to: Date) async throws {
    let response = try await client.fetchDailyPrices(ticker: ticker, from: from, to: to)
    // Yahoo Finance (and the chunked extension call sites) legitimately
    // return an empty payload for weekend / holiday / future probes.
    // Skip the disk write entirely — there is nothing new to persist.
    guard !response.prices.isEmpty else { return }
    let delta = mergeReturningDelta(
      ticker: ticker, instrument: response.instrument, newPrices: response.prices
    )
    // The fetch may also return prices we already have (e.g. an extension
    // chunk that overlaps the cached range due to rounding). When merge
    // observes no change there is nothing to write.
    guard !delta.isEmpty else { return }
    try await persistDelta(ticker: ticker, deltaRecords: delta)
  }

  // MARK: - SQL persistence

  /// Hydrates `caches[ticker]` from `stock_price` + `stock_ticker_meta`.
  /// The meta row records the price denomination (`instrument_id`, e.g.
  /// `"AUD"` for `BHP.AX`); on load we reconstruct a fiat `Instrument` from
  /// the stored code, mirroring the `Instrument.fiat(code:)` factory used
  /// when the price API first responds.
  ///
  /// Marks the ticker as hydrated even when no rows exist so we don't
  /// re-query on every miss.
  func loadCache(ticker: String) async throws {
    let snapshot: StockPriceCache? = try await database.read { database in
      let metaRecord =
        try StockTickerMetaRecord
        .filter(StockTickerMetaRecord.Columns.ticker == ticker)
        .fetchOne(database)
      guard let metaRecord else { return nil }
      let priceRecords =
        try StockPriceRecord
        .filter(StockPriceRecord.Columns.ticker == ticker)
        .order(StockPriceRecord.Columns.date)
        .fetchAll(database)
      // See `ExchangeRateService.loadCache` for the rationale on the
      // String-via-Decimal round-trip; preserves source precision instead
      // of inheriting the binary `Decimal(_: Double)` tail.
      // `.order(date)` ascending satisfies `init(sortedEntries:)`.
      var entries: [SortedDateSeries<Decimal>.Entry] = []
      entries.reserveCapacity(priceRecords.count)
      for record in priceRecords {
        guard let key = DateKey.from(isoString: record.date) else { continue }
        let value = Decimal(string: String(record.price)) ?? Decimal(record.price)
        entries.append(.init(key: key, value: value))
      }
      return StockPriceCache(
        ticker: ticker,
        instrument: Instrument.fiat(code: metaRecord.instrumentId),
        earliestDate: metaRecord.earliestDate,
        latestDate: metaRecord.latestDate,
        prices: SortedDateSeries(sortedEntries: entries)
      )
    }
    if let snapshot { caches[ticker] = snapshot }
    hydrated.insert(ticker)
  }

  /// Persists the rows produced by `mergeReturningDelta` for `ticker`
  /// plus the latest meta-bounds, all in a single transaction.
  ///
  /// Each delta row is written `INSERT OR REPLACE` so a re-fetched date
  /// updates in place; the meta row is `INSERT OR REPLACE`d via
  /// `StockTickerMetaRecord`'s `.replace` conflict policy. There is no
  /// `deleteAll` — once a date is finalised its close is stable, and the
  /// forward-extension overlap (the shared window loop re-fetches the
  /// latest cached date on every extension) so a stale intraday tick
  /// persisted by an older build gets overwritten the next time the
  /// range moves forward. The rollback contract still holds because
  /// every statement runs inside one `database.write` closure and any
  /// failure rolls them back together.
  ///
  /// The price denomination in `StockPriceCache` is the API-reported
  /// fiat currency the ticker trades in (see
  /// `YahooFinanceClient.parseResponse`). The meta row carries that code
  /// so `loadCache` can reconstruct via `Instrument.fiat(code:)`.
  ///
  /// Captures `caches[ticker]` before suspending on `database.write`.
  /// Actor re-entrancy is acceptable here: a concurrent merge will
  /// produce its own delta with its own `persistDelta` afterwards, so
  /// the disk converges to the latest in-memory state. A crash between
  /// two writes leaves the disk at an intermediate-but-consistent
  /// snapshot — acceptable for a best-effort persistent cache.
  func persistDelta(ticker: String, deltaRecords: [StockPriceRecord]) async throws {
    guard let cache = caches[ticker] else { return }
    let meta = StockTickerMetaRecord(
      ticker: ticker,
      instrumentId: cache.instrument.id,
      earliestDate: cache.earliestDate,
      latestDate: cache.latestDate
    )
    try await database.write { database in
      // GRDB caches the insert statement internally; no explicit cachedStatement needed.
      for record in deltaRecords {
        try record.insert(database, onConflict: .replace)
      }
      try meta.insert(database, onConflict: .replace)
      // `stock_price` is `WITHOUT ROWID`; SQLite's update hook does
      // not fire for these tables, so `ValueObservation` over the
      // rate-cache region needs an explicit notify to see this write.
      // See `Backends/GRDB/Observation/RateCacheTable.swift`
      // and `guides/DATABASE_CODE_GUIDE.md` §2 convention 1.
      try database.notifyRateCacheChange(.stockPrice)
    }
  }
}
