import Foundation
import GRDB
import XCTest

@testable import Moolah

/// Benchmarks the chart-render hot path for `ExchangeRateService.rate(...)`.
///
/// Reproduces the load that an investment-account view places on the
/// service: a year-long visible range (~365 days) × a handful of held
/// instruments is realised by ~365 × N `rate(...)` calls per render.
/// Frankfurter posts no rates on weekends or public holidays, so a
/// non-trivial fraction of those days are exact-match cache misses that
/// must be served from the most-recent prior rate via fallback.
///
/// `setUp` seeds an `ExchangeRateService` with one calendar year of
/// weekday-only AUD→USD rates (260 dates). The benchmark body issues
/// 365 in-range `rate(...)` calls — one per day — covering both weekday
/// hits and weekend gaps. With the in-range short-circuit + delta-write
/// fix the entire loop is served from the in-memory cache (no GRDB
/// writes, no client calls). Without it, every weekend-day call
/// dispatches an extension fetch and a full-base `saveCache` rewrite
/// that saturates the GRDB serial queue — the timing delta between
/// "before" and "after" runs of this benchmark on the same machine
/// directly quantifies the chart-render bottleneck.
///
/// The benchmark uses a non-trapping client so the same code can be run
/// on the pre-fix branch for comparison. A regression to the buggy
/// behaviour shows up as a 50–500× wall-clock blowup, not as a crash.
final class ExchangeRateCacheBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _service: ExchangeRateService?
  nonisolated(unsafe) private static var _database: DatabaseQueue?
  nonisolated(unsafe) private static var _datesToQuery: [Date] = []

  override static func setUp() {
    super.setUp()
    let database = expecting("benchmark ProfileIndexDatabase.openInMemory failed") {
      try ProfileIndexDatabase.openInMemory()
    }
    _database = database

    let calendar = Calendar(identifier: .gregorian)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let yearStart = parseDate("2024-01-01", formatter: formatter)
    let yearEnd = parseDate("2024-12-31", formatter: formatter)

    var primingRates: [String: [String: Decimal]] = [:]
    var queryDates: [Date] = []
    var day = yearStart
    while day <= yearEnd {
      queryDates.append(day)
      let weekday = calendar.component(.weekday, from: day)
      // 1 = Sunday, 7 = Saturday — skip weekend dates so the cache mirrors
      // Frankfurter's "weekday-only" posting cadence and the in-range gaps
      // are the realistic ones the chart-render loop hits.
      if weekday != 1 && weekday != 7 {
        let key = formatter.string(from: day)
        primingRates[key] = ["USD": Decimal(0.65)]
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    _datesToQuery = queryDates

    let client = SeedingRateClient(rates: primingRates)
    let service = ExchangeRateService(client: client, database: database)
    // Prime the cache by hitting the first and last weekdays so the
    // earliest/latest meta bounds span the whole year. Subsequent
    // `rate(...)` calls in the measure block therefore land *in-range*
    // for every weekend day in the loop. The same client is reused for
    // the measure block so the buggy code path (which goes to network
    // on weekend gaps) returns the empty payload Frankfurter would —
    // letting the benchmark run on either branch without crashing.
    let firstWeekday = parseDate("2024-01-02", formatter: formatter)
    let lastDay = parseDate("2024-12-31", formatter: formatter)
    _ = awaitSyncExpecting {
      try await service.rate(from: .AUD, to: .USD, on: firstWeekday)
    }
    _ = awaitSyncExpecting {
      try await service.rate(from: .AUD, to: .USD, on: lastDay)
    }
    _service = service
  }

  /// Parses an ISO-8601 date or traps with a clear benchmark-setup
  /// failure. Wraps the force-unwrap so the call sites stay compliant
  /// with SwiftLint's `force_unwrapping` policy.
  private static func parseDate(_ string: String, formatter: ISO8601DateFormatter) -> Date {
    expecting("benchmark setUp could not parse date \(string)") {
      guard let date = formatter.date(from: string) else {
        throw BenchmarkSetupError.invalidDate(string)
      }
      return date
    }
  }

  override static func tearDown() {
    _service = nil
    _database = nil
    _datesToQuery = []
    super.tearDown()
  }

  private var service: ExchangeRateService {
    guard let service = Self._service else {
      preconditionFailure("setUp must initialise _service before tests run")
    }
    return service
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  /// 365 in-range `rate(...)` calls — one per day in a calendar year,
  /// against a cache primed with the 260 weekday rates for that year.
  /// Approximates the work an investment-account chart does on a single
  /// render against a one-year visible range with a single converted
  /// instrument.
  func testYearOfInRangeLookups() {
    let service = self.service
    let dates = Self._datesToQuery
    measure(metrics: metrics, options: options) {
      autoreleasepool {
        _ = awaitSyncExpecting {
          var sum: Decimal = 0
          for date in dates {
            sum += try await service.rate(from: .AUD, to: .USD, on: date)
          }
          return sum
        }
      }
    }
  }
}

private enum BenchmarkSetupError: Error {
  case invalidDate(String)
}

// MARK: - Benchmark-local rate-client stubs

/// Returns the rates passed in at construction, scoped per-date.
/// Used only during `setUp` to prime the cache.
private struct SeedingRateClient: ExchangeRateClient, Sendable {
  let rates: [String: [String: Decimal]]

  func fetchRates(
    base: String, from: Date, to: Date
  ) async throws -> [String: [String: Decimal]] {
    let calendar = Calendar(identifier: .gregorian)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    var result: [String: [String: Decimal]] = [:]
    var day = from
    while day <= to {
      let key = formatter.string(from: day)
      if let dayRates = rates[key] {
        result[key] = dayRates
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return result
  }
}
