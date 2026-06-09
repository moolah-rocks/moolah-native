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

    await MainActor.run {
      _ = harness.handler.handleSentRecordZoneChanges(
        savedRecords: [sent], failedSaves: [], failedDeletes: [])
    }

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

    await MainActor.run {
      _ = harness.handler.handleSentRecordZoneChanges(
        savedRecords: [sent], failedSaves: [], failedDeletes: [])
    }

    #expect(try await needsPushFlag(in: harness.database, id: id))  // newer edit must remain pending
  }
}
