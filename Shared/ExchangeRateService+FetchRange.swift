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
  func fetchToCoverDate(base: String, date: Date, dateString: String) async throws {
    let requestedKey = DateKey.from(isoString: dateString) ?? Int32.max
    let todayKey =
      DateKey.from(isoString: dateFormatter.string(from: now())) ?? requestedKey
    let config = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)
    var guardSteps = 0
    while guardSteps < 250 {
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
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Fetch failed — provider errors are swallowed; caller falls back to cached.
        logger.warning(
          "fetchToCoverDate window failed for base \(base, privacy: .public) on \(dateString, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        break
      }
      // No progress (bounds unchanged) means genuine no-more-data; stop and
      // let a later call re-query the boundary (recent data may publish later).
      if boundsKeys(base: base) == before { break }
    }
    if guardSteps >= 250 {
      logger.warning(
        "fetchToCoverDate: guard limit reached for base \(base, privacy: .public) on \(dateString, privacy: .public)"
      )
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

// MARK: - Contiguous range extension for rates(from:to:in:)

extension ExchangeRateService {
  /// Covers `[lowerKey, upperKey]` contiguously by running the bounded
  /// planner loop toward each endpoint with a no-progress guard. Unlike a
  /// precomputed chunk list (which fetches every window upfront and so can
  /// leave an interior gap when a horizon-restricted provider serves only a
  /// recent subset), this stops a direction the moment a window yields no
  /// boundary progress — keeping `[earliest, latest]` contiguous exactly as
  /// the single-rate `fetchToCoverDate` does. Used by
  /// `rates(from:to:in:)`.
  ///
  /// Errors are swallowed (FX falls back to cached on failure), mirroring
  /// the existing `fetchToCoverDate` contract. `CancellationError` is
  /// re-thrown to preserve cooperative-cancellation semantics.
  func coverRangeContiguously(
    base: String,
    lowerKey: Int32,
    upperKey: Int32
  ) async throws {
    let todayKey =
      DateKey.from(isoString: dateFormatter.string(from: now())) ?? upperKey
    let config = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)
    // Cover the forward endpoint first, then the backward one. Each call
    // anchors at the live cache bounds, so order does not create a gap.
    for requestedKey in [upperKey, lowerKey] {
      var guardSteps = 0
      while guardSteps < 250 {
        guardSteps += 1
        let bounds = boundsKeys(base: base)
        guard
          let window = ContiguousFetchPlanner.nextWindow(
            earliest: bounds.earliest,
            latest: bounds.latest,
            requested: requestedKey,
            today: todayKey,
            config: config)
        else { break }  // endpoint now in range
        let before = bounds
        let fetchStart =
          dateFormatter.date(from: DateKey.isoString(window.lowerBound))
          ?? dateFormatter.date(from: DateKey.isoString(requestedKey))
          ?? now()
        let fetchEnd =
          dateFormatter.date(from: DateKey.isoString(window.upperBound))
          ?? dateFormatter.date(from: DateKey.isoString(requestedKey))
          ?? now()
        do {
          try await fetchAndMerge(base: base, from: fetchStart, to: fetchEnd)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // Fetch failed — provider errors are swallowed; caller falls back to cached.
          logger.warning(
            "coverRangeContiguously window failed for base \(base, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
          break
        }
        // No progress (bounds unchanged) means genuine no-more-data; stop and
        // let a later call re-query the boundary (data may publish later).
        if boundsKeys(base: base) == before { break }
      }
      if guardSteps >= 250 {
        logger.warning(
          "coverRangeContiguously: guard limit reached for base \(base, privacy: .public)"
        )
      }
    }
  }
}
