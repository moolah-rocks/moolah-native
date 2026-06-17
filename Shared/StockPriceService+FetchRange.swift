// Shared/StockPriceService+FetchRange.swift

import Foundation

// MARK: - Contiguous bounded extension (single price)

extension StockPriceService {
  /// Extends the cache contiguously toward `dateString` using bounded
  /// 30-day windows driven by `ContiguousFetchPlanner`. Each iteration
  /// fetches one window anchored at the current cache boundary, so the
  /// cache never jumps its bounds over un-fetched interior days (the
  /// interior-gap bug fixed here). The loop exits when the date is covered,
  /// when no progress was made (provider genuinely has no data for this
  /// window), or when a fetch error occurs.
  ///
  /// Unlike the old unbounded year-chunk approach, a horizon-restricted
  /// provider (e.g. Yahoo Finance with a rolling window) causes the loop to
  /// stop at the edge of its coverage window rather than jumping `latest`
  /// all the way to the requested date and leaving a void.
  ///
  /// `date` is already capped at yesterday by `price(ticker:on:)`.
  func fetchToCoverDate(ticker: String, date: Date, dateString: String) async throws {
    let requestedKey = DateKey.from(isoString: dateString) ?? Int32.max
    let todayKey =
      DateKey.from(isoString: dateFormatter.string(from: now())) ?? requestedKey
    let config = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)
    var guardSteps = 0
    while guardSteps < 250 {
      guardSteps += 1
      let bounds = boundsKeys(ticker: ticker)
      guard
        let window = ContiguousFetchPlanner.nextWindow(
          earliest: bounds.earliest,
          latest: bounds.latest,
          requested: requestedKey,
          today: todayKey,
          config: config)
      else { break }  // requested date now in range
      let before = bounds
      let fetchStart = dateFormatter.date(from: DateKey.isoString(window.lowerBound)) ?? date
      let fetchEnd = dateFormatter.date(from: DateKey.isoString(window.upperBound)) ?? date
      try await fetchAndMerge(ticker: ticker, from: fetchStart, to: fetchEnd)
      if lookupPrice(ticker: ticker, dateString: dateString) != nil { break }
      if fallbackPrice(ticker: ticker, dateString: dateString) != nil { break }
      // No progress (bounds unchanged) means genuine no-more-data; stop and
      // let a later call re-query the boundary (recent data may publish later).
      if boundsKeys(ticker: ticker) == before { break }
    }
    if guardSteps >= 250 {
      logger.warning(
        "fetchToCoverDate: guard limit reached for ticker \(ticker, privacy: .public) on \(dateString, privacy: .public)"
      )
    }
  }

  /// Returns the current cache bounds for `ticker` as `DateKey` (`Int32`
  /// yyyymmdd) values. Returns `(nil, nil)` when the cache is cold.
  func boundsKeys(ticker: String) -> (earliest: Int32?, latest: Int32?) {
    guard let cache = caches[ticker] else { return (nil, nil) }
    return (
      DateKey.from(isoString: cache.earliestDate),
      DateKey.from(isoString: cache.latestDate)
    )
  }
}

// MARK: - Sub-range chunking for prices(ticker:in:)

extension StockPriceService {
  /// Returns the uncovered sub-ranges of `[fetchStart, fetchEnd]` not
  /// already in the cache, split into at most 30-day windows. No single
  /// fetch can span an un-served interior, keeping the cache bounds
  /// contiguous and preventing a horizon-restricted provider from jumping
  /// `latest` over un-fetched days.
  func uncoveredSubRanges(
    ticker: String, fetchStart: Date, fetchEnd: Date
  ) -> [ClosedRange<Date>] {
    let rangeStart = dateFormatter.string(from: fetchStart)
    let rangeEnd = dateFormatter.string(from: fetchEnd)
    let cal = Calendar.utc
    guard let cache = caches[ticker] else {
      return ContiguousFetchPlanner.chunked(fetchStart...fetchEnd, days: 30)
    }
    var result: [ClosedRange<Date>] = []
    if rangeStart < cache.earliestDate,
      let earliest = dateFormatter.date(from: cache.earliestDate),
      let backEnd = cal.date(byAdding: .day, value: -1, to: earliest),
      fetchStart <= backEnd
    {
      result += ContiguousFetchPlanner.chunked(fetchStart...backEnd, days: 30)
    }
    if rangeEnd > cache.latestDate,
      let forwardStart = dateFormatter.date(from: cache.latestDate),
      forwardStart <= fetchEnd
    {
      result += ContiguousFetchPlanner.chunked(forwardStart...fetchEnd, days: 30)
    }
    return result
  }
}
