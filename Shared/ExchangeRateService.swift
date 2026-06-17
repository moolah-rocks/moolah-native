// Shared/ExchangeRateService.swift

import Foundation
import GRDB
import OSLog

enum ExchangeRateError: Error, Equatable {
  case noRateAvailable(base: String, quote: String, date: String)
}

actor ExchangeRateService {
  private let client: ExchangeRateClient

  // MARK: - Cross-extension internals
  // `caches`, `hydratedBases`, `database`, and `logger` are accessed by
  // the SQL persistence extension in `ExchangeRateService+Persistence.swift`.
  // They remain actor-isolated; the access modifier is internal so the
  // sibling-file extension can see them.
  var caches: [String: ExchangeRateCache] = [:]
  /// Loaded bases — set on first hydration so we don't re-read SQL when the
  /// cache is genuinely empty.
  var hydratedBases: Set<String> = []
  let database: any DatabaseWriter
  let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeRateService")

  // `dateFormatter`, `now`, and `timeZone` are accessed by
  // `prefetchLatest` in `ExchangeRateService+Prefetch.swift`, so they
  // must be at least internal.
  let dateFormatter: ISO8601DateFormatter
  /// Injected clock so tests can pin "today" deterministically.
  let now: @Sendable () -> Date
  /// Injected zone used by `cappedToYesterday` to compute "yesterday".
  /// Production defaults to `TimeZone.current`; tests asserting on a
  /// specific `YYYY-MM-DD` label pin to `UTC`.
  let timeZone: TimeZone

  init(
    client: ExchangeRateClient,
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

  func rate(from: Instrument, to: Instrument, on date: Date) async throws -> Decimal {
    if from.id == to.id { return Decimal(1) }

    let date = cappedDate(date)
    let dateString = dateFormatter.string(from: date)
    let base = from.id
    let quote = to.id

    // Check in-memory cache
    if let cached = lookupRate(base: base, quote: quote, dateString: dateString) {
      return cached
    }

    // Hydrate from SQL on first access
    if !hydratedBases.contains(base) {
      try await loadCache(base: base)
    }

    // Check again after disk load
    if let cached = lookupRate(base: base, quote: quote, dateString: dateString) {
      return cached
    }

    // In-range short-circuit: if the requested date is within the cached
    // `[earliestDate, latestDate]` window, the exact miss is a weekend /
    // holiday / Frankfurter-not-yet-posted gap. `fallbackRate` resolves it
    // from the most-recent prior cached rate without going to the network.
    // Skipping the fetch here is what keeps repeat chart renders cheap —
    // see `guides/INSTRUMENT_CONVERSION_GUIDE.md` and the perf rationale
    // in `Shared/ExchangeRateService+Persistence.swift`.
    if let cache = caches[base],
      dateString >= cache.earliestDate, dateString <= cache.latestDate
    {
      if let fallback = fallbackRate(base: base, quote: quote, dateString: dateString) {
        return fallback
      }
      // In-range with no fallback only happens when this quote currency
      // has never been seen for this base — surface as missing rather
      // than triggering a fetch + full cache rewrite.
      throw ExchangeRateError.noRateAvailable(base: base, quote: quote, date: dateString)
    }

    // Out of cached range — extend toward the requested date.
    try await fetchToCoverDate(base: base, date: date, dateString: dateString)

    // Exact hit after fetch?
    if let cached = lookupRate(base: base, quote: quote, dateString: dateString) {
      return cached
    }

    // Fall back to the most-recent cached rate on or before the requested date.
    if let fallback = fallbackRate(base: base, quote: quote, dateString: dateString) {
      return fallback
    }

    throw ExchangeRateError.noRateAvailable(base: base, quote: quote, date: dateString)
  }

  // `fetchToCoverDate(base:date:dateString:)` lives in
  // `ExchangeRateService+FetchRange.swift`.

  /// See `Shared/PriceCacheCap.swift` for the rationale.
  private func cappedDate(_ date: Date) -> Date {
    cappedToYesterday(date, now: now, timeZone: timeZone)
  }

  func rates(
    from: Instrument, to: Instrument, in range: ClosedRange<Date>
  ) async throws -> [(date: Date, rate: Decimal)] {
    if from.id == to.id {
      return generateDateSeries(in: range).map { ($0, Decimal(1)) }
    }

    let base = from.id
    let quote = to.id

    // Hydrate cache if not already in memory
    if !hydratedBases.contains(base) {
      try await loadCache(base: base)
    }

    // Cap the *fetch* upper bound at yesterday — same rationale as
    // `rate()`. The result series below still walks the caller-supplied
    // range; today's slot fills via `lastKnownRate` carry-forward.
    let fetchUpperBound = cappedDate(range.upperBound)

    // Fetch only the uncovered sub-ranges, chunked into ≤30-day windows so
    // a horizon-restricted provider cannot jump `latest` over un-fetched days.
    // `uncoveredSubRanges` lives in `ExchangeRateService+FetchRange.swift`.
    if range.lowerBound <= fetchUpperBound {
      let subRanges = uncoveredSubRanges(
        base: base, fetchStart: range.lowerBound, fetchEnd: fetchUpperBound)
      for sub in subRanges {
        try await fetchAndMerge(base: base, from: sub.lowerBound, to: sub.upperBound)
      }
    }

    // Build result series
    let dates = generateDateSeries(in: range)
    var results: [(date: Date, rate: Decimal)] = []
    var lastKnownRate: Decimal?

    for date in dates {
      let dateString = dateFormatter.string(from: date)
      if let key = DateKey.from(isoString: dateString),
        let rate = caches[base]?.rates.exact(key)?[quote]
      {
        lastKnownRate = rate
        results.append((date, rate))
      } else if let fallback = lastKnownRate {
        results.append((date, fallback))
      }
    }

    return results
  }

  func convert(_ amount: InstrumentAmount, to instrument: Instrument, on date: Date) async throws
    -> InstrumentAmount
  {
    if amount.instrument.id == instrument.id { return amount }

    let exchangeRate = try await rate(from: amount.instrument, to: instrument, on: date)
    let converted = amount.quantity * exchangeRate
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }

  // `prefetchLatest(base:)` lives in `ExchangeRateService+Prefetch.swift`.

  // MARK: - Private helpers

  private func lookupRate(base: String, quote: String, dateString: String) -> Decimal? {
    guard let key = DateKey.from(isoString: dateString) else { return nil }
    return caches[base]?.rates.exact(key)?[quote]
  }

  private func fallbackRate(base: String, quote: String, dateString: String) -> Decimal? {
    guard let key = DateKey.from(isoString: dateString),
      let cache = caches[base]
    else { return nil }
    // Finds the newest day on or before `target` carrying `quote`, skipping
    // day maps that lack it (a day map may exist without this quote) and
    // probing older days. `floorKey` makes each hop O(log n).
    var probe = key
    while let dayKey = cache.rates.floorKey(probe) {
      if let rate = cache.rates.exact(dayKey)?[quote] { return rate }
      probe = dayKey - 1
    }
    return nil
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

  // `fetchAndMerge` is internal: called from `ExchangeRateService+Prefetch.swift`,
  // `ExchangeRateService+FetchRange.swift`, and tests.
  func fetchAndMerge(base: String, from: Date, to: Date) async throws {
    let fetched = try await client.fetchRates(base: base, from: from, to: to)
    // Frankfurter (and the chunked extension call sites in this service)
    // legitimately return an empty payload for weekend / holiday / future
    // single-day probes. Skip the disk write entirely — there is nothing
    // new to persist.
    guard !fetched.isEmpty else { return }
    let delta = mergeReturningDelta(base: base, newRates: fetched)
    // The fetch may also return rates we already have (e.g. an extension
    // chunk that overlaps the cached range due to rounding). When merge
    // observes no change we have nothing to write.
    guard !delta.isEmpty else { return }
    try await persistDelta(base: base, deltaRecords: delta)
  }

  /// Merges `newRates` into `caches[base]` and returns the rows that
  /// actually changed so the persistence layer can `INSERT OR REPLACE`
  /// only those (rather than rewriting every cached row for the base on
  /// every fetch).
  ///
  /// The comparison is per-(date, quote) so a fetch that returns the
  /// same rates already in cache produces an empty delta. This is what
  /// lets `fetchAndMerge` skip the disk write on a no-op extension probe.
  private func mergeReturningDelta(
    base: String, newRates: [String: [String: Decimal]]
  ) -> [ExchangeRateRecord] {
    guard !newRates.isEmpty else { return [] }
    guard let earliest = newRates.keys.min(), let latest = newRates.keys.max() else { return [] }

    if var existing = caches[base] {
      let deltaRecords = mergeIntoExisting(&existing, base: base, newRates: newRates)
      if earliest < existing.earliestDate {
        existing.earliestDate = earliest
      }
      if latest > existing.latestDate {
        existing.latestDate = latest
      }
      caches[base] = existing
      return deltaRecords
    }

    let (series, deltaRecords) = buildFreshSeries(base: base, newRates: newRates)
    caches[base] = ExchangeRateCache(
      base: base,
      earliestDate: earliest,
      latestDate: latest,
      rates: series
    )
    return deltaRecords
  }

  /// Whole-day merge of `newRates` into an existing cache entry, returning
  /// only the per-(date, quote) rows that actually changed. Replaces the
  /// entire day map (no per-quote merge into the existing day).
  private func mergeIntoExisting(
    _ existing: inout ExchangeRateCache,
    base: String,
    newRates: [String: [String: Decimal]]
  ) -> [ExchangeRateRecord] {
    var deltaRecords: [ExchangeRateRecord] = []
    for (dateKey, dayRates) in newRates {
      guard let key = DateKey.from(isoString: dateKey) else { continue }  // malformed wire date — unusable as a sorted key; skip
      let existingDayRates = existing.rates.exact(key) ?? [:]
      for (quote, rate) in dayRates where existingDayRates[quote] != rate {
        deltaRecords.append(rateRecord(base: base, quote: quote, date: dateKey, rate: rate))
      }
      existing.rates.upsert(dayRates, forKey: key)
    }
    return deltaRecords
  }

  /// Builds a fresh `SortedDateSeries` for a base with no existing cache
  /// entry; every fetched (date, quote) rate is a delta row.
  private func buildFreshSeries(
    base: String, newRates: [String: [String: Decimal]]
  ) -> (SortedDateSeries<[String: Decimal]>, [ExchangeRateRecord]) {
    var series = SortedDateSeries<[String: Decimal]>()
    var deltaRecords: [ExchangeRateRecord] = []
    for (dateKey, dayRates) in newRates {
      guard let key = DateKey.from(isoString: dateKey) else { continue }  // malformed wire date — unusable as a sorted key; skip
      series.upsert(dayRates, forKey: key)
      for (quote, rate) in dayRates {
        deltaRecords.append(rateRecord(base: base, quote: quote, date: dateKey, rate: rate))
      }
    }
    return (series, deltaRecords)
  }

  /// Marshalls a `(date, quote, rate)` triple into the GRDB record shape.
  /// `Decimal → Double` round-trips via `NSDecimalNumber` (the same path
  /// GRDB itself takes), keeping the precision-preservation contract in
  /// sync with `loadCache`'s decode.
  private func rateRecord(
    base: String, quote: String, date: String, rate: Decimal
  ) -> ExchangeRateRecord {
    ExchangeRateRecord(
      base: base,
      quote: quote,
      date: date,
      rate: NSDecimalNumber(decimal: rate).doubleValue
    )
  }

  // SQL persistence (`loadCache` / `persistDelta`) lives in
  // `ExchangeRateService+Persistence.swift`.
}
