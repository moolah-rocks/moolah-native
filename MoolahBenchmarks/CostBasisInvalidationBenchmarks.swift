import GRDB
import XCTest

@testable import Moolah

/// Guards the invalidation-only cost-basis observation against accidentally
/// materialising a profile-wide transaction projection. Delivery after a
/// relevant write should remain effectively constant as the transaction count
/// doubles.
final class CostBasisInvalidationBenchmarks: XCTestCase {
  nonisolated(unsafe) private static var oneXBackend: CloudKitBackend?
  nonisolated(unsafe) private static var oneXDatabase: DatabaseQueue?
  nonisolated(unsafe) private static var twoXBackend: CloudKitBackend?
  nonisolated(unsafe) private static var twoXDatabase: DatabaseQueue?

  override static func setUp() {
    super.setUp()
    let oneX = expecting("1x benchmark TestBackend.create failed") { try TestBackend.create() }
    let twoX = expecting("2x benchmark TestBackend.create failed") { try TestBackend.create() }
    oneXBackend = oneX.backend
    oneXDatabase = oneX.database
    twoXBackend = twoX.backend
    twoXDatabase = twoX.database
    BenchmarkFixtures.seed(scale: .oneX, in: oneX.database)
    BenchmarkFixtures.seed(scale: .twoX, in: twoX.database)
  }

  override static func tearDown() {
    oneXBackend = nil
    oneXDatabase = nil
    twoXBackend = nil
    twoXDatabase = nil
    super.tearDown()
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }

  private var options: XCTMeasureOptions {
    let options = XCTMeasureOptions()
    options.iterationCount = 10
    return options
  }

  func testLegWriteInvalidation_1x() {
    measureLegWriteInvalidation(
      backend: requireBackend(Self.oneXBackend, scale: "1x"),
      database: requireDatabase(Self.oneXDatabase, scale: "1x"))
  }

  func testLegWriteInvalidation_2x() {
    measureLegWriteInvalidation(
      backend: requireBackend(Self.twoXBackend, scale: "2x"),
      database: requireDatabase(Self.twoXDatabase, scale: "2x"))
  }

  private func measureLegWriteInvalidation(
    backend: CloudKitBackend,
    database: DatabaseQueue
  ) {
    measure(metrics: metrics, options: options) {
      awaitSyncExpecting {
        // Batch 100 edit-to-invalidation cycles per measurement so the clock
        // metric is long enough to avoid sub-millisecond scheduler noise.
        for _ in 0..<100 {
          var iterator =
            backend.transactions.observeCostBasisRelevantChanges().makeAsyncIterator()
          _ = await iterator.next()
          try await database.write { database in
            try database.execute(
              sql: """
                UPDATE transaction_leg
                SET quantity = quantity + 1
                WHERE id = (SELECT id FROM transaction_leg LIMIT 1)
                """)
          }
          _ = await iterator.next()
        }
      }
    }
  }

  private func requireBackend(_ backend: CloudKitBackend?, scale: String) -> CloudKitBackend {
    guard let backend else { fatalError("\(scale) setUp did not initialise backend") }
    return backend
  }

  private func requireDatabase(_ database: DatabaseQueue?, scale: String) -> DatabaseQueue {
    guard let database else { fatalError("\(scale) setUp did not initialise database") }
    return database
  }
}
