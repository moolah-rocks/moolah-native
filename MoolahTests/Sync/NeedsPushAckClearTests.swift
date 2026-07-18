@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Upload ack clears needs_push only when unchanged")
struct NeedsPushAckClearTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  /// Reads the raw `needs_push` flag for an account id. Uses raw SQL
  /// because the flag is a local-only column absent from `AccountRow`'s
  /// `CodingKeys`, so it is not visible on the decoded row.
  private func needsPushFlag(
    in database: DatabaseQueue, id: UUID
  ) async throws -> Bool {
    try await database.read { database -> Bool in
      try Bool.fetchOne(
        database, sql: "SELECT needs_push FROM account WHERE id = ?", arguments: [id]) ?? false
    }
  }

  private func encodedSystemFields(
    in database: DatabaseQueue, id: UUID
  ) async throws -> Data? {
    try await database.read { database in
      try Data.fetchOne(
        database,
        sql: "SELECT encoded_system_fields FROM account WHERE id = ?",
        arguments: [id])
    }
  }

  @Test("ack clears the flag when the row matches what was sent")
  func clearsWhenUnchanged() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    let row = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "Sent")
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try row.insert(database)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
    }
    // Build the sent record from the SAME row state that was persisted so
    // the user fields match exactly (no sub-ms Date round-trip drift).
    let sent = row.toCKRecord(in: Self.zoneID)

    _ = await harness.handler.handleSentRecordZoneChanges(
      savedRecords: [sent], failedSaves: [], failedDeletes: [])

    #expect(try await needsPushFlag(in: harness.database, id: id) == false)
  }

  @Test("ack leaves the flag set when the row changed since send")
  func keepsWhenChanged() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "EDIT 2").insert(database)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
    }
    // The record that was actually sent carried the OLD value "EDIT 1".
    let sent = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "EDIT 1")
      .toCKRecord(in: Self.zoneID)

    _ = await harness.handler.handleSentRecordZoneChanges(
      savedRecords: [sent], failedSaves: [], failedDeletes: [])

    #expect(try await needsPushFlag(in: harness.database, id: id))  // newer edit must remain pending
  }

  @Test("ack persistence rolls back and requeues when any record type fails")
  func rollsBackWholeAcknowledgementBatch() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let accountId = UUID()
    let account = ProfileDataSyncHandlerTestSupport.accountRow(id: accountId, name: "Sent")
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try account.insert(database)
      try AccountRow.filter(AccountRow.Columns.id == accountId)
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
      try database.execute(sql: "DROP TABLE category")
    }
    let category = ProfileDataSyncHandlerTestSupport.categoryRow(id: UUID(), name: "Broken")
    let saved = [account.toCKRecord(in: Self.zoneID), category.toCKRecord(in: Self.zoneID)]

    let failures = await harness.handler.handleSentRecordZoneChanges(
      savedRecords: saved, failedSaves: [], failedDeletes: [])

    #expect(Set(failures.requeue) == Set(saved.map(\.recordID)))
    #expect(try await needsPushFlag(in: harness.database, id: accountId))
    #expect(try await encodedSystemFields(in: harness.database, id: accountId) == nil)
  }
}
