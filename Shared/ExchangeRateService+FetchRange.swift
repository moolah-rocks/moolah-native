// Shared/ExchangeRateService+FetchRange.swift

import Foundation

// MARK: - Contiguous bounded extension (single rate)

extension ExchangeRateService {
  /// Extends the cache contiguously toward `dateString` using bounded
  /// 30-day windows driven by `ContiguousFetchPlanner`. Each iteration
  /// fetches one window anchored at the current cache boundary, so the
  /// cache never jumps its bounds over un-fetched interior days (the
  /// interior-gap bug fixed here). The loop exits when the date is covered,
  /// when no progress was made (provider genuinely has no data for this
  /// window), or when a fetch error occurs.
  ///
  /// Unlike the old unbounded year-chunk approach, a horizon-restricted
  /// provider (e.g. Frankfurter with a rolling window) causes the loop to
  /// stop at the edge of its coverage window rather than jumping `latest`
  /// all the way to the requested date and leaving a void.
  ///
  /// Errors are swallowed (FX falls back to cached on failure), mirroring
  /// the original `fetchToCoverDate` contract. `date` is already capped at
  /// yesterday by `rate()`.
  func fetchToCoverDate(base: String, date: Date, dateString: String) async {
    let requestedKey = DateKey.from(isoString: dateString) ?? Int32.max
    let todayKey =
      DateKey.from(isoString: dateFormatter.string(from: now())) ?? requestedKey
    let config = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)
    var guardSteps = 0
    while guardSteps < 64 {
      guardSteps += 1
      let bounds = boundsKeys(base: base)
      guard
        let window = ContiguousFetchPlanner.nextWindow(
          earliest: bounds.earliest,
          latest: bounds.latest,
          requested: requestedKey,
          today: todayKey,
          config: config)
      else { break }  // requested date now in range
      let before = bounds
      let fetchStart =
        dateFormatter.date(from: DateKey.isoString(window.lowerBound)) ?? date
      let fetchEnd =
        dateFormatter.date(from: DateKey.isoString(window.upperBound)) ?? date
      do {
        try await fetchAndMerge(base: base, from: fetchStart, to: fetchEnd)
      } catch {
        // Fetch failed — errors are swallowed; caller falls back to cached.
        logger.warning(
          "fetchToCoverDate window failed for base \(base, privacy: .public) on \(dateString, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        break
      }
      // No progress (bounds unchanged) means genuine no-more-data; stop and
      // let a later call re-query the boundary (recent data may publish later).
      if boundsKeys(base: base) == before { break }
    }
  }

  /// Returns the current cache bounds for `base` as `DateKey` (`Int32`
  /// yyyymmdd) values. Returns `(nil, nil)` when the cache is cold.
  func boundsKeys(base: String) -> (earliest: Int32?, latest: Int32?) {
    guard let cache = caches[base] else { return (nil, nil) }
    return (
      DateKey.from(isoString: cache.earliestDate),
      DateKey.from(isoString: cache.latestDate)
    )
  }
}

// MARK: - Sub-range chunking for rates(from:to:in:)

extension ExchangeRateService {
  /// Returns the uncovered sub-ranges of `[fetchStart, fetchEnd]` not
  /// already in the cache, split into at most 30-day windows. No single
  /// fetch can span an un-served interior, keeping the cache bounds
  /// contiguous and preventing a horizon-restricted provider from jumping
  /// `latest` over un-fetched days.
  func uncoveredSubRanges(
    base: String, fetchStart: Date, fetchEnd: Date
  ) -> [ClosedRange<Date>] {
    let rangeStart = dateFormatter.string(from: fetchStart)
    let rangeEnd = dateFormatter.string(from: fetchEnd)
    let cal = Calendar.utc
    guard let cache = caches[base] else {
      return Self.chunked(fetchStart...fetchEnd, days: 30)
    }
    var result: [ClosedRange<Date>] = []
    if rangeStart < cache.earliestDate,
      let earliest = dateFormatter.date(from: cache.earliestDate),
      let backEnd = cal.date(byAdding: .day, value: -1, to: earliest),
      fetchStart <= backEnd
    {
      result += Self.chunked(fetchStart...backEnd, days: 30)
    }
    if rangeEnd > cache.latestDate,
      let forwardStart = dateFormatter.date(from: cache.latestDate),
      forwardStart <= fetchEnd
    {
      result += Self.chunked(forwardStart...fetchEnd, days: 30)
    }
    return result
  }

  /// Splits `range` into consecutive sub-ranges of at most `days` calendar
  /// days (UTC). Used by `uncoveredSubRanges` to cap individual fetches so
  /// a horizon-restricted provider cannot jump the cache bounds over a void.
  static func chunked(_ range: ClosedRange<Date>, days: Int) -> [ClosedRange<Date>] {
    let cal = Calendar.utc
    var result: [ClosedRange<Date>] = []
    var start = range.lowerBound
    while start <= range.upperBound {
      let end: Date
      if let candidate = cal.date(byAdding: .day, value: days, to: start) {
        end = min(candidate, range.upperBound)
      } else {
        end = range.upperBound
      }
      result.append(start...end)
      guard let next = cal.date(byAdding: .day, value: 1, to: end) else { break }
      if next > range.upperBound { break }
      start = next
    }
    return result
  }
}
