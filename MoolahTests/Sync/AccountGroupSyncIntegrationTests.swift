@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// End-to-end dispatch test for `AccountGroupRecord`: drives
/// `ProfileDataSyncHandler.applyRemoteChanges` with a synthetic CKRecord
/// representing an insert, then a delete, and verifies the local GRDB
/// state matches at each step. Mirrors `ApplyRemoteChangesOutOfOrderTests`'
/// harness construction.
@Suite("AccountGroup sync integration")
struct AccountGroupSyncIntegrationTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test
  func applyRemoteChangesInsertThenDeleteAccountGroup() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }

    let groupId = UUID()
    let recordID = CKRecord.ID(
      recordType: AccountGroupRow.recordType, uuid: groupId, zoneID: Self.zoneID)
    let ckRecord = CKRecord(recordType: "AccountGroupRecord", recordID: recordID)
    ckRecord["name"] = "Trust Fund Crypto" as CKRecordValue
    ckRecord["bucket"] = AccountBucket.investments.rawValue as CKRecordValue
    ckRecord["instrumentId"] = "AUD" as CKRecordValue
    ckRecord["position"] = Int64(0) as CKRecordValue

    // Apply incoming save — must NOT throw, must NOT report .saveFailed.
    let saveResult = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = saveResult {
      Issue.record("Expected success, got .saveFailed(\(message))")
    }

    var presentCount = try await harness.database.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM account_group WHERE id = ?",
        arguments: [groupId]) ?? -1
    }
    #expect(presentCount == 1, "AccountGroup row should land in GRDB after save dispatch")

    let storedName = try await harness.database.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT name FROM account_group WHERE id = ?",
        arguments: [groupId])
    }
    #expect(storedName == "Trust Fund Crypto")

    // Apply incoming delete — must remove the row.
    let deleteResult = harness.handler.applyRemoteChanges(
      saved: [], deleted: [(recordID, "AccountGroupRecord")])
    if case .saveFailed(let message) = deleteResult {
      Issue.record("Expected success, got .saveFailed(\(message))")
    }

    presentCount = try await harness.database.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM account_group WHERE id = ?",
        arguments: [groupId]) ?? -1
    }
    #expect(presentCount == 0, "AccountGroup row should be removed after delete dispatch")
  }

  /// A second AccountGroup save targeting the same id (e.g. a remote
  /// rename) must upsert in place rather than fail on the PK collision.
  @Test
  func applyRemoteChangesAccountGroupUpsertReplacesExistingRow() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }

    let groupId = UUID()
    let recordID = CKRecord.ID(
      recordType: AccountGroupRow.recordType, uuid: groupId, zoneID: Self.zoneID)

    let first = CKRecord(recordType: "AccountGroupRecord", recordID: recordID)
    first["name"] = "Before Rename" as CKRecordValue
    first["bucket"] = AccountBucket.investments.rawValue as CKRecordValue
    first["instrumentId"] = "AUD" as CKRecordValue
    first["position"] = Int64(0) as CKRecordValue
    _ = harness.handler.applyRemoteChanges(saved: [first], deleted: [])

    let second = CKRecord(recordType: "AccountGroupRecord", recordID: recordID)
    second["name"] = "After Rename" as CKRecordValue
    second["bucket"] = AccountBucket.investments.rawValue as CKRecordValue
    second["instrumentId"] = "AUD" as CKRecordValue
    second["position"] = Int64(2) as CKRecordValue
    _ = harness.handler.applyRemoteChanges(saved: [second], deleted: [])

    let row = try await harness.database.read { database in
      try AccountGroupRow
        .filter(AccountGroupRow.Columns.id == groupId)
        .fetchOne(database)
    }
    let fetched = try #require(row)
    #expect(fetched.name == "After Rename")
    #expect(fetched.position == 2)
  }
}
