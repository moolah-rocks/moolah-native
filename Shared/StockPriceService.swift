// Shared/StockPriceService.swift

import Foundation
import GRDB
import OSLog

enum StockPriceError: Error, Equatable {
  case noPriceAvailable(ticker: String, date: String)
  case unknownTicker(String)
}

actor StockPriceService {
  private let client: StockPriceClient
  private var hydratedTickers: Set<String> = []
  private let database: any DatabaseWriter

  // MARK: - Cross-extension internals
  // `caches`, `dateFormatter`, `now`, `timeZone`, and `logger` are accessed
  // by the merge extension in `StockPriceService+Merge.swift` (which defines
  // `mergeReturningDelta(ticker:instrument:newPrices:)`, called from this
  // file) and by the bounded-extension / chunking extension in
  // `StockPriceService+FetchRange.swift`, so they are `internal` rather than
  // `private`. They remain actor-isolated; the access modifier is internal
  // only so the sibling-file extensions can see them.
  var caches: [String: StockPriceCache] = [:]
  let dateFormatter: ISO8601DateFormatter
  /// Injected clock so tests can pin "today" deterministically.
  let now: @Sendable () -> Date
  /// Injected zone used by `cappedToYesterday` to compute "yesterday".
  /// Production defaults to `TimeZone.current`; tests asserting on a
  /// specific `YYYY-MM-DD` label pin to `UTC`.
  let timeZone: TimeZone
  let logger = Logger(
    subsystem: "com.moolah.app", category: "StockPriceService")

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

  func price(ticker: String, on date: Date) async throws -> Decimal {
    let date = cappedDate(date)
    let dateString = dateFormatter.string(from: date)

    // Check in-memory cache
    if let cached = lookupPrice(ticker: ticker, dateString: dateString) {
      return cached
    }

    // Hydrate from SQL on first access
    if !hydratedTickers.contains(ticker) {
      try await loadCache(ticker: ticker)
    }

    // Check again after disk load
    if let cached = lookupPrice(ticker: ticker, dateString: dateString) {
      return cached
    }

    // Fetch from client — expand range to fill gap between cache and requested date
    do {
      try await fetchToCoverDate(ticker: ticker, date: date, dateString: dateString)
      if let cached = lookupPrice(ticker: ticker, dateString: dateString) {
        return cached
      }
    } catch {
      // Network failure — try fallback to most recent prior date
      if let fallback = fallbackPrice(ticker: ticker, dateString: dateString) {
        return fallback
      }
      throw error
    }

    // Fetch succeeded but no price for this date — try fallback
    if let fallback = fallbackPrice(ticker: ticker, dateString: dateString) {
      return fallback
    }

    throw StockPriceError.noPriceAvailable(ticker: ticker, date: dateString)
  }

  func prices(
    ticker: String, in range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    // Hydrate cache if not already in memory
    if !hydratedTickers.contains(ticker) {
      try await loadCache(ticker: ticker)
    }

    // Cap the *fetch* upper bound at yesterday — never ask Yahoo for
    // today's still-running bar. The result series below still walks the
    // caller-supplied range; today's slot fills via `lastKnownPrice`
    // carry-forward (which lands on yesterday's close).
    let fetchUpperBound = cappedDate(range.upperBound)

    guard range.lowerBound <= fetchUpperBound else {
      return buildResultSeries(ticker: ticker, in: range)
    }

    // Fetch uncovered sub-ranges using bounded 30-day windows so a
    // horizon-restricted provider cannot advance bounds over un-fetched days.
    let subRanges = uncoveredSubRanges(
      ticker: ticker,
      fetchStart: range.lowerBound,
      fetchEnd: fetchUpperBound)
    for sub in subRanges {
      try await fetchAndMerge(ticker: ticker, from: sub.lowerBound, to: sub.upperBound)
    }

    return buildResultSeries(ticker: ticker, in: range)
  }

  func instrument(for ticker: String) async throws -> Instrument {
    if let cache = caches[ticker] {
      return cache.instrument
    }
    if !hydratedTickers.contains(ticker) {
      try await loadCache(ticker: ticker)
    }
    if let cache = caches[ticker] {
      return cache.instrument
    }
    throw StockPriceError.unknownTicker(ticker)
  }

  // MARK: - Private helpers

  func cappedDate(_ date: Date) -> Date {
    cappedToYesterday(date, now: now, timeZone: timeZone)
  }

  func lookupPrice(ticker: String, dateString: String) -> Decimal? {
    guard let key = DateKey.from(isoString: dateString) else { return nil }
    return caches[ticker]?.prices.exact(key)
  }

  func fallbackPrice(ticker: String, dateString: String) -> Decimal? {
    guard let key = DateKey.from(isoString: dateString),
      let cache = caches[ticker]
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

  /// Builds the carry-forward daily price series for `ticker` over `range`
  /// from the in-memory cache. Weekend/holiday gaps carry the last known close.
  func buildResultSeries(
    ticker: String, in range: ClosedRange<Date>
  ) -> [(date: Date, price: Decimal)] {
    let dates = generateDateSeries(in: range)
    var results: [(date: Date, price: Decimal)] = []
    var lastKnownPrice: Decimal?

    for date in dates {
      let dateString = dateFormatter.string(from: date)
      if let key = DateKey.from(isoString: dateString),
        let price = caches[ticker]?.prices.exact(key)
      {
        lastKnownPrice = price
        results.append((date, price))
      } else if let fallback = lastKnownPrice {
        results.append((date, fallback))
      }
    }

    return results
  }

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
  private func loadCache(ticker: String) async throws {
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
    hydratedTickers.insert(ticker)
  }

  /// Persists the rows produced by `mergeReturningDelta` for `ticker`
  /// plus the latest meta-bounds, all in a single transaction.
  ///
  /// Each delta row is written `INSERT OR REPLACE` so a re-fetched date
  /// updates in place; the meta row is `INSERT OR REPLACE`d via
  /// `StockTickerMetaRecord`'s `.replace` conflict policy. There is no
  /// `deleteAll` — once a date is finalised its close is stable, and the
  /// forward-extension overlap (see `fetchToCoverDate`) re-fetches the
  /// latest cached date on every extension so a stale intraday tick
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
