import GRDB
import XCTest

@testable import Moolah

/// Benchmarks for AnalysisRepository — measures loadAll and fetchCategoryBalances
/// on a realistic x2-scale dataset (37k transactions and 62 accounts).
final class AnalysisBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _backend: CloudKitBackend?
  nonisolated(unsafe) private static var _database: DatabaseQueue?

  override static func setUp() {
    super.setUp()
    let result = expecting("benchmark TestBackend.create failed") {
      try TestBackend.create()
    }
    _backend = result.backend
    _database = result.database
    BenchmarkFixtures.seed(scale: .twoX, in: result.database)
  }

  override static func tearDown() {
    _backend = nil
    _database = nil
    super.tearDown()
  }

  private var backend: CloudKitBackend {
    guard let backend = Self._backend else {
      fatalError("setUp must initialise _backend before tests run")
    }
    return backend
  }

  private var repo: GRDBAnalysisRepository {
    guard let repo = backend.analysis as? GRDBAnalysisRepository else {
      fatalError(
        "AnalysisBenchmarks requires GRDBAnalysisRepository; "
          + "got \(type(of: backend.analysis))")
    }
    return repo
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  /// loadAll with 12 months of history and 3 months of forecast.
  /// Exercises the full concurrent pipeline: daily balances, expense breakdown,
  /// income/expense — all computed off the main thread.
  func testLoadAll_12months() throws {
    let repo = self.repo
    let historyAfter = try XCTUnwrap(
      Calendar.current.date(byAdding: .month, value: -12, to: Date()))
    let forecastUntil = try XCTUnwrap(
      Calendar.current.date(byAdding: .month, value: 3, to: Date()))
    measure(metrics: metrics, options: options) {
      _ = awaitSyncExpecting {
        try await repo.loadAll(
          historyAfter: historyAfter, forecastUntil: forecastUntil, monthEnd: 31)
      }
    }
  }

  /// loadAll with nil historyAfter — loads all 5 years of history.
  /// Measures the worst-case full-dataset analysis path.
  func testLoadAll_allHistory() throws {
    let repo = self.repo
    let forecastUntil = try XCTUnwrap(
      Calendar.current.date(byAdding: .month, value: 3, to: Date()))
    measure(metrics: metrics, options: options) {
      _ = awaitSyncExpecting {
        try await repo.loadAll(historyAfter: nil, forecastUntil: forecastUntil, monthEnd: 31)
      }
    }
  }

  /// fetchCategoryBalances for a 12-month expense window with no additional filters.
  /// Measures the filter + group-by aggregation over the full transaction set.
  func testFetchCategoryBalances() throws {
    let repo = self.repo
    let end = Date()
    let start = try XCTUnwrap(Calendar.current.date(byAdding: .month, value: -12, to: end))
    let dateRange = start...end
    measure(metrics: metrics, options: options) {
      _ = awaitSyncExpecting {
        try await repo.fetchCategoryBalances(
          dateRange: dateRange, transactionType: .expense, filters: nil,
          targetInstrument: .defaultTestInstrument)
      }
    }
  }

  /// fetchCategoryBalancesByType — combined income+expense in a single pass.
  /// Should be faster than two separate fetchCategoryBalances calls.
  func testFetchCategoryBalancesByType() throws {
    let repo = self.repo
    let end = Date()
    let start = try XCTUnwrap(Calendar.current.date(byAdding: .month, value: -12, to: end))
    let dateRange = start...end
    measure(metrics: metrics, options: options) {
      _ = awaitSyncExpecting {
        try await repo.fetchCategoryBalancesByType(
          dateRange: dateRange, filters: nil,
          targetInstrument: .defaultTestInstrument)
      }
    }
  }
}
