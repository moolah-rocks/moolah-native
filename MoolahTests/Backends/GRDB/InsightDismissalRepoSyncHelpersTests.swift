import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("GRDBInsightDismissalRepository sync helpers")
struct InsightDismissalRepoSyncHelpersTests {
  private func makeRepo() throws -> (GRDBInsightDismissalRepository, DatabaseQueue) {
    let queue = try ProfileDatabase.openInMemory()
    return (GRDBInsightDismissalRepository(database: queue), queue)
  }

  @Test
  func recordDismissalIncrementsAtomically() async throws {
    let (repo, _) = try makeRepo()
    _ = try await repo.recordDismissal(of: .newRecurringDetected)
    _ = try await repo.recordDismissal(of: .newRecurringDetected)
    let third = try await repo.recordDismissal(of: .newRecurringDetected)
    #expect(third.count == 3)
    let all = try await repo.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.count == 3)
  }

  @Test
  func distinctKindsAreIndependent() async throws {
    let (repo, _) = try makeRepo()
    _ = try await repo.recordDismissal(of: .newRecurringDetected)
    _ = try await repo.recordDismissal(of: .subscriptionPriceHike)
    _ = try await repo.recordDismissal(of: .subscriptionPriceHike)
    let byKind = Dictionary(
      uniqueKeysWithValues: try await repo.fetchAll().map { ($0.kind, $0.count) })
    #expect(byKind[.newRecurringDetected] == 1)
    #expect(byKind[.subscriptionPriceHike] == 2)
  }

  @Test
  func applyRemoteChangesUpsertsAndDeletes() throws {
    let (repo, _) = try makeRepo()
    let row = InsightDismissalRow(kind: .feeSpend, count: 5)
    try repo.applyRemoteChangesSync(saved: [row], deleted: [])
    #expect(try repo.fetchRowSync(id: row.id)?.count == 5)
    try repo.applyRemoteChangesSync(saved: [], deleted: [row.id])
    #expect(try repo.fetchRowSync(id: row.id) == nil)
  }

  @Test
  func unsyncedRowIdsReportsRowsMissingSystemFields() throws {
    let (repo, _) = try makeRepo()
    let row = InsightDismissalRow(kind: .feeSpend, count: 1)
    try repo.applyRemoteChangesSync(saved: [row], deleted: [])
    #expect(try repo.unsyncedRowIdsSync() == [row.id])
    _ = try repo.setEncodedSystemFieldsSync(id: row.id, data: Data([0x01]))
    #expect(try repo.unsyncedRowIdsSync().isEmpty)
  }

  // MARK: - In-transaction variant

  @Test
  func applyRemoteChangesInTransactionVariantSucceeds() async throws {
    let (repo, queue) = try makeRepo()
    let row = InsightDismissalRow(kind: .feeSpend, count: 7)
    try await queue.write { database in
      try repo.applyRemoteChangesSync(saved: [row], deleted: [], in: database)
    }
    #expect(try repo.fetchRowSync(id: row.id)?.count == 7)
  }

  // MARK: - setEncodedSystemFieldsBatchSync

  @Test
  func setEncodedSystemFieldsBatchSyncUpdatesEveryRow() throws {
    let (repo, _) = try makeRepo()
    let first = InsightDismissalRow(kind: .feeSpend, count: 1)
    let second = InsightDismissalRow(kind: .idleCashAlert, count: 2)
    try repo.applyRemoteChangesSync(saved: [first, second], deleted: [])

    let payloadA = Data([0x01])
    let payloadB = Data([0x02])
    let updatedCount = try repo.setEncodedSystemFieldsBatchSync(
      [(id: first.id, data: payloadA), (id: second.id, data: payloadB)])
    #expect(updatedCount == 2)

    #expect(try repo.fetchRowSync(id: first.id)?.encodedSystemFields == payloadA)
    #expect(try repo.fetchRowSync(id: second.id)?.encodedSystemFields == payloadB)
  }

  @Test
  func setEncodedSystemFieldsBatchSyncReturnsZeroForEmptyInput() throws {
    let (repo, _) = try makeRepo()
    #expect(try repo.setEncodedSystemFieldsBatchSync([]) == 0)
  }

  // MARK: - clearAllSystemFieldsSync

  @Test
  func clearAllSystemFieldsSyncNullsEveryBlob() throws {
    let (repo, _) = try makeRepo()
    let first = InsightDismissalRow(kind: .feeSpend, count: 1)
    let second = InsightDismissalRow(kind: .idleCashAlert, count: 2)
    try repo.applyRemoteChangesSync(saved: [first, second], deleted: [])
    _ = try repo.setEncodedSystemFieldsSync(id: first.id, data: Data([0x99]))
    _ = try repo.setEncodedSystemFieldsSync(id: second.id, data: Data([0x88]))

    try repo.clearAllSystemFieldsSync()

    #expect(try repo.fetchRowSync(id: first.id)?.encodedSystemFields == nil)
    #expect(try repo.fetchRowSync(id: second.id)?.encodedSystemFields == nil)
  }

  // MARK: - deleteAllSync

  @Test
  func deleteAllSyncRemovesEveryRow() async throws {
    let (repo, _) = try makeRepo()
    try repo.applyRemoteChangesSync(
      saved: [
        InsightDismissalRow(kind: .feeSpend, count: 1),
        InsightDismissalRow(kind: .idleCashAlert, count: 2),
      ], deleted: [])

    try repo.deleteAllSync()

    #expect(try await repo.fetchAll().isEmpty)
  }

  // MARK: - allRowIdsSync

  @Test
  func allRowIdsSyncReturnsEveryId() throws {
    let (repo, _) = try makeRepo()
    let first = InsightDismissalRow(kind: .feeSpend, count: 1)
    let second = InsightDismissalRow(kind: .idleCashAlert, count: 2)
    try repo.applyRemoteChangesSync(saved: [first, second], deleted: [])

    #expect(try Set(repo.allRowIdsSync()) == Set([first.id, second.id]))
  }

  // MARK: - fetchRowSync / fetchRowsSync

  @Test
  func fetchRowSyncReturnsRowOrNil() throws {
    let (repo, _) = try makeRepo()
    let row = InsightDismissalRow(kind: .feeSpend, count: 3)
    try repo.applyRemoteChangesSync(saved: [row], deleted: [])

    #expect(try repo.fetchRowSync(id: row.id)?.id == row.id)
    #expect(try repo.fetchRowSync(id: UUID()) == nil)
  }

  @Test
  func fetchRowsSyncReturnsMatchingSubset() throws {
    let (repo, _) = try makeRepo()
    let first = InsightDismissalRow(kind: .feeSpend, count: 1)
    let second = InsightDismissalRow(kind: .idleCashAlert, count: 2)
    let third = InsightDismissalRow(kind: .newRecurringDetected, count: 3)
    try repo.applyRemoteChangesSync(saved: [first, second, third], deleted: [])

    let rows = try repo.fetchRowsSync(ids: [first.id, second.id])
    #expect(Set(rows.map(\.id)) == Set([first.id, second.id]))
  }

  // MARK: - Rollback (transaction boundary)

  @Test
  func applyRemoteChangesRollsBackOnMidBatchFailure() throws {
    let (repo, queue) = try makeRepo()
    let existing = InsightDismissalRow(kind: .feeSpend, count: 4)
    try repo.applyRemoteChangesSync(saved: [existing], deleted: [])

    // Abort the second upsert in the batch. The two rows upsert in a single
    // `database.write`, so the failure must roll back BOTH — the pre-existing
    // row's echoed upsert and the new row's insert.
    try queue.write { database in
      try database.execute(
        sql: """
          CREATE TEMP TRIGGER fail_second_insight_insert
          BEFORE INSERT ON insight_dismissal
          WHEN NEW.count = -42
          BEGIN
              SELECT RAISE(ABORT, 'forced mid-batch failure');
          END;
          """)
    }

    let newRow = InsightDismissalRow(kind: .idleCashAlert, count: -42)
    #expect(throws: (any Error).self) {
      try repo.applyRemoteChangesSync(saved: [existing, newRow], deleted: [])
    }

    // Pre-existing row survives unchanged; the new row never persisted.
    #expect(try repo.fetchRowSync(id: existing.id)?.count == 4)
    #expect(try repo.fetchRowSync(id: newRow.id) == nil)
  }

  @Test
  func recordDismissalRollsBackOnFailure() async throws {
    let (repo, queue) = try makeRepo()
    _ = try await repo.recordDismissal(of: .feeSpend)  // count == 1

    // Abort any UPDATE to the table, so the read-modify-write increment
    // (which upserts → UPDATE on the existing row) fails and rolls back.
    try await queue.write { database in
      try database.execute(
        sql: """
          CREATE TEMP TRIGGER fail_insight_update
          BEFORE UPDATE ON insight_dismissal
          BEGIN
              SELECT RAISE(ABORT, 'forced update failure');
          END;
          """)
    }

    await #expect(throws: (any Error).self) {
      _ = try await repo.recordDismissal(of: .feeSpend)
    }

    let id = InsightDismissalRow.id(for: .feeSpend)
    #expect(try repo.fetchRowSync(id: id)?.count == 1)
  }
}
