import Foundation
import OSLog

/// Shared daily-price-series orchestration for the stock and crypto price
/// services. Default-implemented on an `Actor`-constrained protocol so the
/// shared code runs each conforming actor's own isolation and mutates
/// `caches[instrumentKey]` PER KEY — never a whole-dict snapshot — which is
/// what preserves the actors' concurrent-different-instrument re-entrancy
/// contract (a snapshot/defer-writeback design would clobber a concurrent
/// call's committed cache entry). The three genuine differences (provider
/// fetch, quote denomination, optional first-trade floor) are plugs.
protocol PriceSeriesOrchestrating: Actor {
  associatedtype Cache: PriceSeriesCache

  /// Per-instrument caches, keyed ticker / tokenId. Mutated per key by the
  /// shared defaults on `self`; satisfied by each actor's stored property.
  var caches: [String: Cache] { get set }
  /// Keys hydrated from SQL (so a genuinely empty cache is not re-queried).
  var hydrated: Set<String> { get set }

  var now: @Sendable () -> Date { get }
  var timeZone: TimeZone { get }
  var dateFormatter: ISO8601DateFormatter { get }
  var plannerConfig: ContiguousFetchPlanner.Config { get }

  /// Plug 1 — fetch the window, merge into `caches[instrumentKey]`, persist.
  /// Owns the single-client (stock) vs fallback-chain + coalescing (crypto)
  /// difference. Throws on genuine provider failure; rethrows `CancellationError`.
  func fetchAndMerge(instrumentKey: String, window: ClosedRange<Date>) async throws
  /// Plug 2 — the instrument's quote denomination (stock: listing currency;
  /// crypto: `.USD`). `nil` when unknown (cold cache).
  func quote(for instrumentKey: String) -> Instrument?
  /// Plug 3a — confirmed first-trade floor (`YYYY-MM-DD`); `nil` for stock.
  func firstTradeFloor(for instrumentKey: String) -> String?
  /// Plug 3b — confirm+persist the floor on a no-error backward exhaustion;
  /// no-op for stock.
  func confirmFirstTradeOnBackwardExhaustion(
    instrumentKey: String, lastFetchError: (any Error)?) async throws

  /// Hydrate `caches[instrumentKey]` + insert into `hydrated` from SQL.
  func hydrate(instrumentKey: String) async throws

  func belowFloorError(instrumentKey: String, date: String) -> any Error
  func noPriceError(instrumentKey: String, date: String) -> any Error
}

extension PriceSeriesOrchestrating {
  // MARK: - Public orchestration

  /// Single price: cap → exact → hydrate-once → exact → floor-short-circuit →
  /// in-range → extend-contiguously → resolve. Mutates `caches[key]` per key.
  func price(instrumentKey key: String, on date: Date) async throws -> Decimal {
    let capped = cappedToYesterday(date, now: now, timeZone: timeZone)
    let dateString = dateFormatter.string(from: capped)

    if let hit = exact(key: key, dateString: dateString) { return hit }
    if !hydrated.contains(key) { try await hydrate(instrumentKey: key) }
    if let hit = exact(key: key, dateString: dateString) { return hit }

    if let floor = firstTradeFloor(for: key), dateString < floor {
      throw belowFloorError(instrumentKey: key, date: dateString)
    }

    if let inRange = try inRangeResolution(key: key, dateString: dateString) {
      return inRange
    }

    return try await extendAndResolve(key: key, date: capped, dateString: dateString)
  }

  /// Range: hydrate-once → cap upper → cover forward+backward → carry-forward
  /// series over the caller's range using `Calendar.utc` day stepping.
  func prices(
    instrumentKey key: String, in range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    if !hydrated.contains(key) { try await hydrate(instrumentKey: key) }
    let fetchUpper = cappedToYesterday(range.upperBound, now: now, timeZone: timeZone)
    if range.lowerBound <= fetchUpper,
      let lowerKey = DateKey.from(isoString: dateFormatter.string(from: range.lowerBound)),
      let upperKey = DateKey.from(isoString: dateFormatter.string(from: fetchUpper))
    {
      try await coverRange(key: key, lowerKey: lowerKey, upperKey: upperKey)
    }
    return buildResultSeries(key: key, in: range)
  }

  // MARK: - Shared internals (lifted verbatim, operating on self.caches[key])

  private func exact(key: String, dateString: String) -> Decimal? {
    guard let dateKey = DateKey.from(isoString: dateString) else { return nil }
    return caches[key]?.prices.exact(dateKey)
  }

  private func floorPrice(key: String, dateString: String) -> Decimal? {
    guard let dateKey = DateKey.from(isoString: dateString), let cache = caches[key] else {
      return nil
    }
    return cache.prices.floor(dateKey)
  }

  /// In-range short-circuit (mirrors crypto `inRangeFallback`): when the date
  /// sits inside `[earliest, latest]`, return the floor if present, else throw
  /// `noPriceError` rather than re-fetch. `nil` ⇒ out of range, caller extends.
  private func inRangeResolution(key: String, dateString: String) throws -> Decimal? {
    guard let cache = caches[key],
      dateString >= cache.earliestDate, dateString <= cache.latestDate
    else { return nil }
    if let floor = floorPrice(key: key, dateString: dateString) { return floor }
    throw noPriceError(instrumentKey: key, date: dateString)
  }

  private func boundsKeys(key: String) -> (earliest: Int32?, latest: Int32?) {
    guard let cache = caches[key] else { return (nil, nil) }
    return (DateKey.from(isoString: cache.earliestDate), DateKey.from(isoString: cache.latestDate))
  }

  private func windowDates(_ window: ClosedRange<Int32>, fallback: Date) -> ClosedRange<Date> {
    let lower = dateFormatter.date(from: DateKey.isoString(window.lowerBound)) ?? fallback
    let upper = dateFormatter.date(from: DateKey.isoString(window.upperBound)) ?? fallback
    return lower...max(lower, upper)
  }

  /// Extend toward a single requested date, then resolve. Mirrors crypto
  /// `extendContiguously` + `resolveAfterExtension`.
  private func extendAndResolve(
    key: String, date: Date, dateString: String
  ) async throws -> Decimal {
    let requestedKey = DateKey.from(isoString: dateString) ?? Int32.max
    let lastError = try await runWindowLoop(
      key: key,
      requestedKey: requestedKey,
      fallback: date,
      midLoopHit: { [self] in
        if let hit = exact(key: key, dateString: dateString) { return hit }
        return try inRangeResolution(key: key, dateString: dateString)
      })
    if let hit = exact(key: key, dateString: dateString) { return hit }
    if let floorHit = floorPrice(key: key, dateString: dateString) { return floorHit }
    if let inRange = try inRangeResolution(key: key, dateString: dateString) { return inRange }
    if let floor = firstTradeFloor(for: key), dateString < floor {
      throw belowFloorError(instrumentKey: key, date: dateString)
    }
    if let lastError { throw lastError }
    throw noPriceError(instrumentKey: key, date: dateString)
  }

  /// Cover `[lowerKey, upperKey]` forward-then-backward, then surface the last
  /// provider error if an endpoint is still uncovered. Mirrors crypto
  /// `coverRangeContiguously`.
  private func coverRange(key: String, lowerKey: Int32, upperKey: Int32) async throws {
    var lastError: (any Error)?
    for requestedKey in [upperKey, lowerKey] {
      let err = try await runWindowLoop(
        key: key,
        requestedKey: requestedKey,
        fallback: now(),
        midLoopHit: { nil })
      if let err { lastError = err }
    }
    if let lastError {
      let todayKey = DateKey.from(isoString: dateFormatter.string(from: now())) ?? upperKey
      let bounds = boundsKeys(key: key)
      let stillUncovered = [upperKey, lowerKey].contains { dateKey in
        ContiguousFetchPlanner.nextWindow(
          earliest: bounds.earliest,
          latest: bounds.latest,
          requested: dateKey,
          today: todayKey,
          config: plannerConfig) != nil
      }
      if stillUncovered { throw lastError }
    }
  }

  /// The bounded planner loop toward `requestedKey`. Returns the captured
  /// provider error (if the chain failed) or `nil`. `midLoopHit` lets the
  /// single-price path early-exit on a cache hit between windows; the range
  /// path passes `{ nil }`. Rethrows `CancellationError` unchanged.
  private func runWindowLoop(
    key: String,
    requestedKey: Int32,
    fallback: Date,
    midLoopHit: () throws -> Decimal?
  ) async throws -> (any Error)? {
    let todayKey = DateKey.from(isoString: dateFormatter.string(from: now())) ?? requestedKey
    var lastError: (any Error)?
    var guardSteps = 0
    while guardSteps < 250 {
      guardSteps += 1
      let bounds = boundsKeys(key: key)
      guard
        let window = ContiguousFetchPlanner.nextWindow(
          earliest: bounds.earliest,
          latest: bounds.latest,
          requested: requestedKey,
          today: todayKey,
          config: plannerConfig)
      else { break }
      let before = bounds
      do {
        try await fetchAndMerge(
          instrumentKey: key, window: windowDates(window, fallback: fallback))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastError = error
        break
      }
      if try midLoopHit() != nil { break }
      if boundsKeys(key: key) == before {
        let wasBackward = before.earliest.map { requestedKey < $0 } ?? false
        if wasBackward {
          try await confirmFirstTradeOnBackwardExhaustion(
            instrumentKey: key, lastFetchError: lastError)
        }
        break
      }
    }
    if guardSteps >= 250 {
      Logger(subsystem: "com.moolah.app", category: "PriceSeriesOrchestrating")
        .warning("window loop guard limit reached for \(key, privacy: .public)")
    }
    return lastError
  }

  /// Carry-forward daily series over `range`, stepping with `Calendar.utc`
  /// (the intentional stock fix). Non-trading gaps carry the last known close;
  /// nothing is emitted before the first known close.
  private func buildResultSeries(
    key: String, in range: ClosedRange<Date>
  ) -> [(date: Date, price: Decimal)] {
    var results: [(date: Date, price: Decimal)] = []
    var lastKnownPrice: Decimal?
    var current = range.lowerBound
    while current <= range.upperBound {
      let dateString = dateFormatter.string(from: current)
      if let dateKey = DateKey.from(isoString: dateString),
        let price = caches[key]?.prices.exact(dateKey)
      {
        lastKnownPrice = price
        results.append((current, price))
      } else if let fallback = lastKnownPrice {
        results.append((current, fallback))
      }
      guard let next = Calendar.utc.date(byAdding: .day, value: 1, to: current) else { break }
      current = next
    }
    return results
  }
}
