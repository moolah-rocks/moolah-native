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
  /// Per-base serialization gate for cache-extending work (hydrate + fetch
  /// + merge). The actor only guarantees mutual exclusion *between*
  /// suspension points; a cache extension spans several `await`s
  /// (`loadCache`, `client.fetchRates`, `persistDelta`), so two `rate()` /
  /// `rates()` / `prefetchLatest` calls for the same base can interleave
  /// and merge **non-adjacent** fetch windows. That unions `[earliest,
  /// latest]` over an interior region neither window fetched, breaking the
  /// contiguity invariant `fallbackRate`'s in-range short-circuit relies on
  /// — the requester then carries forward an earlier day's rate. This gate
  /// serialises extension per base so windows are always merged
  /// contiguously; a waiter re-checks the cache on acquire, so the second
  /// caller usually finds its date already covered and skips the fetch.
  /// See `withCacheExtension(base:)`.
  private var cacheExtensionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  private var cacheExtensionHeld: Set<String> = []
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

    // Hydration + fetch + merge all extend the cache, so they run under the
    // per-base extension gate: concurrent `rate()` calls for the same base
    // must not interleave and union non-adjacent windows (see
    // `cacheExtensionWaiters`). A caller that waited re-checks the cache
    // first — another extender may have already covered this date.
    return try await withCacheExtension(base: base) {
      // Hydrate from SQL on first access.
      if !hydratedBases.contains(base) {
        try await loadCache(base: base)
      }

      // Check again after disk load (or after a prior waiter's fetch).
      if let cached = lookupRate(base: base, quote: quote, dateString: dateString) {
        return cached
      }

      // In-range short-circuit: if the requested date is within the cached
      // `[earliestDate, latestDate]` window, the exact miss is a weekend /
      // holiday / Frankfurter-not-yet-posted gap. `fallbackRate` resolves it
      // from the most-recent prior cached rate without going to the network.
      // Skipping the fetch here is what keeps repeat chart renders cheap —
      // see `guides/INSTRUMENT_CONVERSION_GUIDE.md` and the perf rationale
      // in `Shared/ExchangeRateService+Persistence.swift`. Safe under the
      // gate: the bounds now reflect only contiguously-merged windows.
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

    // Hydrate + cover both extend the cache, so they run under the per-base
    // extension gate to stay contiguous with any concurrent `rate()` /
    // `rates()` / `prefetchLatest` call for the same base (see
    // `cacheExtensionWaiters`).
    try await withCacheExtension(base: base) {
      // Hydrate cache if not already in memory.
      if !hydratedBases.contains(base) {
        try await loadCache(base: base)
      }

      // Cap the *fetch* upper bound at yesterday — same rationale as
      // `rate()`. The result series below still walks the caller-supplied
      // range; today's slot fills via `lastKnownRate` carry-forward.
      let fetchUpperBound = cappedDate(range.upperBound)

      // Cover the requested range contiguously using bounded 30-day windows
      // driven by `ContiguousFetchPlanner`. Unlike a precomputed chunk list,
      // the loop anchors each window at the live cache bounds and stops as
      // soon as a window yields no progress — preventing a horizon-restricted
      // provider from jumping `latest` over un-fetched interior days.
      // `coverRangeContiguously` lives in `ExchangeRateService+FetchRange.swift`.
      if range.lowerBound <= fetchUpperBound,
        let lowerKey = DateKey.from(isoString: dateFormatter.string(from: range.lowerBound)),
        let upperKey = DateKey.from(isoString: dateFormatter.string(from: fetchUpperBound))
      {
        try await coverRangeContiguously(base: base, lowerKey: lowerKey, upperKey: upperKey)
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

  // MARK: - Cache-extension serialization

  /// Runs `body` (a hydrate / fetch / merge sequence that extends the cache
  /// for `base`) with at most one extension in flight per base. Concurrent
  /// callers for the same base queue and resume one at a time, so fetch
  /// windows are always merged contiguously rather than unioned across an
  /// unfetched interior gap. The lock is always released — including when
  /// `body` throws — so a fetch failure (or cancellation) never strands the
  /// next waiter. `body` runs after the lock is acquired, so callers should
  /// re-check the cache inside it (another extender may have already covered
  /// the requested date while this caller waited).
  func withCacheExtension<T>(
    base: String, _ body: () async throws -> T
  ) async rethrows -> T {
    if cacheExtensionHeld.contains(base) {
      await withCheckedContinuation { continuation in
        cacheExtensionWaiters[base, default: []].append(continuation)
      }
    } else {
      cacheExtensionHeld.insert(base)
    }
    defer { releaseCacheExtension(base: base) }
    return try await body()
  }

  /// Hands the per-base extension lock to the next queued waiter, or marks
  /// the base free when none remain.
  private func releaseCacheExtension(base: String) {
    guard var waiters = cacheExtensionWaiters[base], !waiters.isEmpty else {
      // No one queued — the base is free again.
      cacheExtensionWaiters[base] = nil
      cacheExtensionHeld.remove(base)
      return
    }
    // Hand the lock straight to the next waiter (it stays "held").
    let next = waiters.removeFirst()
    cacheExtensionWaiters[base] = waiters.isEmpty ? nil : waiters
    next.resume()
  }

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
