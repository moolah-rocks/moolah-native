// MoolahTests/Backends/GRDB/SystemFieldsBatchTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies the batch system-fields writers added to the GRDB repos
/// land every update inside a single GRDB transaction so
/// `databaseDidCommit` (the trigger for `ValueObservation` re-fetches)
/// fires exactly once for the batch — not once per row. This is the
/// load-bearing change that lets the post-`sendChanges` write-back
/// path scale: a 400-record CKSyncEngine batch upload now produces at
/// most one observation per affected recordType, instead of one per
/// row.
///
/// Coverage focuses on `GRDBTransactionRepository` (the highest-volume
/// table in the sync flow). The other eight repos use the same shape;
/// `ProfileDataSyncHandler.systemFieldsBatchSetter(for:)` exercises
/// each via the dispatch table at the call site.
@Suite("System-fields batch writes")
struct SystemFieldsBatchTests {

  // MARK: - Helpers

  private final class CommitCounter: TransactionObserver, @unchecked Sendable {
    var commits: Int = 0

    func observes(eventsOfKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws {}
    func databaseDidCommit(_ database: Database) { commits += 1 }
    func databaseDidRollback(_ database: Database) {}
  }

  /// Inserts `count` transaction rows with a placeholder system-fields
  /// blob and returns their ids. The placeholder is non-nil so the
  /// later batch update produces a real change to observe.
  private static func seedRows(_ count: Int, into database: any DatabaseWriter) throws -> [UUID] {
    let ids = (0..<count).map { _ in UUID() }
    try database.write { database in
      for id in ids {
        let row = TransactionRow(
          id: id,
          recordName: TransactionRow.recordName(for: id),
          date: Date(timeIntervalSince1970: 1_700_000_000),
          payee: "seed-\(id.uuidString.prefix(4))",
          notes: nil,
          recurPeriod: nil,
          recurEvery: nil,
          importOriginRawDescription: nil,
          importOriginBankReference: nil,
          importOriginRawAmount: nil,
          importOriginRawBalance: nil,
          importOriginImportedAt: nil,
          importOriginImportSessionId: nil,
          importOriginSourceFilename: nil,
          importOriginParserIdentifier: nil,
          encodedSystemFields: Data([0xFF]))
        try row.upsert(database)
      }
    }
    return ids
  }

  private static func makeRepository() throws -> (GRDBTransactionRepository, DatabaseQueue) {
    let database = try ProfileDatabase.openInMemory()
    let conversionService = FakeConversionService.fixedRates([:])
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let repo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    return (repo, database)
  }

  // MARK: - Single-commit guarantee

  @Test("Batch writer commits exactly once for many updates")
  func batchWriterCommitsOnce() async throws {
    let (repo, database) = try Self.makeRepository()
    let ids = try Self.seedRows(50, into: database)

    let counter = CommitCounter()
    try await database.write { database in
      database.add(transactionObserver: counter, extent: .observerLifetime)
    }
    counter.commits = 0  // reset to ignore the registration write

    let updates = ids.map { (id: $0, data: Data([0xAB, 0xCD]) as Data?) }
    let updatedCount = try repo.setEncodedSystemFieldsBatchSync(updates)

    #expect(updatedCount == 50)
    #expect(counter.commits == 1, "Expected one commit; got \(counter.commits)")
  }

  @Test("Per-row writer commits once per call (control)")
  func perRowWriterCommitsPerCall() async throws {
    let (repo, database) = try Self.makeRepository()
    let ids = try Self.seedRows(5, into: database)

    let counter = CommitCounter()
    try await database.write { database in
      database.add(transactionObserver: counter, extent: .observerLifetime)
    }
    counter.commits = 0

    let blob = Data([0x12, 0x34])
    for id in ids {
      _ = try repo.setEncodedSystemFieldsSync(id: id, data: blob)
    }

    #expect(counter.commits == 5, "Per-row path should fire one commit per call")
  }

  // MARK: - Functional correctness

  @Test("Batch writer updates every row to the supplied blob")
  func batchWriterUpdatesEveryRow() async throws {
    let (repo, database) = try Self.makeRepository()
    let ids = try Self.seedRows(3, into: database)
    let blob = Data([0x42, 0x99])

    let updatedCount = try repo.setEncodedSystemFieldsBatchSync(
      ids.map { (id: $0, data: blob as Data?) })

    #expect(updatedCount == 3)
    let rows = try await database.read { database in
      try TransactionRow.fetchAll(database)
    }
    #expect(rows.count == 3)
    for row in rows {
      #expect(row.encodedSystemFields == blob)
    }
  }

  @Test("Batch writer accepts nil to clear")
  func batchWriterAcceptsNilToClear() async throws {
    let (repo, database) = try Self.makeRepository()
    let ids = try Self.seedRows(2, into: database)

    let updatedCount = try repo.setEncodedSystemFieldsBatchSync(
      ids.map { (id: $0, data: nil as Data?) })

    #expect(updatedCount == 2)
    let rows = try await database.read { database in
      try TransactionRow.fetchAll(database)
    }
    for row in rows {
      #expect(row.encodedSystemFields == nil)
    }
  }

  @Test("Empty input is a no-op (no transaction, returns zero)")
  func emptyInputIsNoOp() async throws {
    let (repo, database) = try Self.makeRepository()
    _ = try Self.seedRows(0, into: database)

    let counter = CommitCounter()
    try await database.write { database in
      database.add(transactionObserver: counter, extent: .observerLifetime)
    }
    counter.commits = 0

    let updatedCount = try repo.setEncodedSystemFieldsBatchSync([])

    #expect(updatedCount == 0)
    #expect(counter.commits == 0, "Empty input should skip the transaction entirely")
  }

  @Test("Missing rows count toward updated == 0 without throwing")
  func missingRowsAreSilent() async throws {
    let (repo, _) = try Self.makeRepository()
    let strangerId = UUID()
    let blob = Data([0x55])

    let updatedCount = try repo.setEncodedSystemFieldsBatchSync(
      [(id: strangerId, data: blob)])

    #expect(updatedCount == 0)
  }
}
