import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Suite is intentionally NOT `@MainActor`. The remote-changes tests
/// drive `applyRemoteChanges` (which is `nonisolated` and must run off
/// the main actor in production) and verify GRDB state via async
/// `database.read`/`write` overloads — exercising those from
/// `@MainActor` would block the main thread on a synchronous DB write.
/// Harness construction (`makeHandler` / `makeHandlerAndDatabase`) is
/// `@MainActor`-isolated and goes through `try await MainActor.run`.
/// `buildCKRecord` is `@MainActor`; the tests that invoke it carry
/// per-method `@MainActor` annotations.
@Suite("ProfileDataSyncHandler — remote changes & record building")
struct ProfileDataSyncHandlerTests {

  // MARK: - Remote Insert

  @Test
  func applyRemoteInsertCreatesLocalRecord() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase()
    }
    let handler = harness.handler

    let accountId = UUID()
    let ckRecord = CKRecord(
      recordType: "AccountRecord",
      recordID: CKRecord.ID(
        recordType: AccountRow.recordType, uuid: accountId, zoneID: handler.zoneID)
    )
    ckRecord["name"] = "Remote Account" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 1 as CKRecordValue
    ckRecord["isHidden"] = 0 as CKRecordValue

    let result = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let rows = try await harness.database.read { database in
      try AccountRow.filter(AccountRow.Columns.id == accountId).fetchAll(database)
    }
    #expect(rows.count == 1)
    #expect(rows.first?.name == "Remote Account")
    guard case .success(let changedTypes) = result else {
      Issue.record("Expected .success but got \(result)")
      return
    }
    #expect(changedTypes.contains("AccountRecord"))
  }

  // MARK: - Remote Update

  @Test
  func applyRemoteUpdateModifiesExistingRecord() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase()
    }
    let handler = harness.handler
    let database = harness.database

    let accountId = UUID()
    let stub = Account(
      id: accountId, name: "Old Name", type: .bank,
      instrument: .defaultTestInstrument, position: 0, isHidden: false)
    try await database.write { database in
      try AccountRow(domain: stub).insert(database)
    }

    let ckRecord = CKRecord(
      recordType: "AccountRecord",
      recordID: CKRecord.ID(
        recordType: AccountRow.recordType, uuid: accountId, zoneID: handler.zoneID)
    )
    ckRecord["name"] = "Updated Name" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["position"] = 5 as CKRecordValue
    ckRecord["isHidden"] = 1 as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let rows = try await database.read { database in
      try AccountRow.filter(AccountRow.Columns.id == accountId).fetchAll(database)
    }
    #expect(rows.count == 1)
    #expect(rows.first?.name == "Updated Name")
    #expect(rows.first?.position == 5)
    #expect(rows.first?.isHidden == true)
  }

  // MARK: - Remote Deletion

  @Test
  func applyRemoteDeletionRemovesLocalRecord() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase()
    }
    let handler = harness.handler
    let database = harness.database

    let accountId = UUID()
    let stub = Account(
      id: accountId, name: "To Delete", type: .bank,
      instrument: .defaultTestInstrument, position: 0, isHidden: false)
    try await database.write { database in
      try AccountRow(domain: stub).insert(database)
    }

    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: accountId, zoneID: handler.zoneID)
    let result = handler.applyRemoteChanges(
      saved: [], deleted: [(recordID, "AccountRecord")])

    let rows = try await database.read { database in
      try AccountRow.filter(AccountRow.Columns.id == accountId).fetchAll(database)
    }
    #expect(rows.isEmpty)
    guard case .success(let changedTypes) = result else {
      Issue.record("Expected .success but got \(result)")
      return
    }
    #expect(changedTypes.contains("AccountRecord"))
  }

  // MARK: - buildCKRecord

  @Test
  @MainActor
  func buildCKRecordProducesCorrectRecord() throws {
    let handler = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase().handler

    let id = UUID()
    let row = AccountRow(
      id: id,
      recordName: AccountRow.recordName(for: id),
      name: "Savings",
      type: "bank",
      instrumentId: "AUD",
      position: 0,
      isHidden: false,
      encodedSystemFields: nil,
      valuationMode: "recordedValue")

    let ckRecord = handler.buildCKRecord(from: row, encodedSystemFields: nil)

    #expect(ckRecord.recordType == "AccountRecord")
    #expect(
      ckRecord.recordID.recordName
        == "\(AccountRow.recordType)|\(id.uuidString)")
    #expect(ckRecord.recordID.zoneID == handler.zoneID)
    #expect(ckRecord["name"] as? String == "Savings")
  }

  @Test("buildCKRecord drops cached system fields when they point to a different zone")
  @MainActor
  func buildCKRecordDropsCachedFieldsOnZoneMismatch() throws {
    let handler = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase().handler

    // Simulate legacy corruption: a local AccountRow whose cached
    // encodedSystemFields blob references a DIFFERENT profile's zone.
    // Historically this happened pre-April-15 when per-profile sync engines
    // received fetch events for every zone in the database and upserted
    // records by UUID into the wrong container. buildCKRecord must NOT reuse
    // those system fields — doing so ships the record with a stale change
    // tag that lives in another zone and triggers an unbreakable
    // `serverRecordChanged` loop on every send.
    let foreignZone = CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)",
      ownerName: CKCurrentUserDefaultName
    )
    let accountId = UUID()
    let foreignCK = CKRecord(
      recordType: "AccountRecord",
      recordID: CKRecord.ID(
        recordType: AccountRow.recordType, uuid: accountId, zoneID: foreignZone)
    )
    let foreignSystemFields = foreignCK.encodedSystemFields

    let row = AccountRow(
      id: accountId,
      recordName: AccountRow.recordName(for: accountId),
      name: "Corrupt",
      type: "bank",
      instrumentId: "AUD",
      position: 0,
      isHidden: false,
      encodedSystemFields: foreignSystemFields,
      valuationMode: "recordedValue")

    let built = handler.buildCKRecord(from: row, encodedSystemFields: foreignSystemFields)

    #expect(built.recordID.zoneID == handler.zoneID)
    // A fresh (unsent) CKRecord has no change tag. Sending with the foreign
    // tag would be rejected with serverRecordChanged forever.
    #expect(built.recordChangeTag == nil)
    #expect(
      built.recordID.recordName
        == "\(AccountRow.recordType)|\(accountId.uuidString)")
    #expect(built["name"] as? String == "Corrupt")
  }

  @Test
  @MainActor
  func buildCKRecordPreservesCachedSystemFields() throws {
    let handler = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase().handler

    let accountId = UUID()
    // Create a CKRecord to extract its encoded system fields. We capture
    // the bytes off this synthetic CKRecord and feed them straight into
    // `buildCKRecord(from:encodedSystemFields:)` to assert reuse.
    let originalCK = CKRecord(
      recordType: "AccountRecord",
      recordID: CKRecord.ID(
        recordType: AccountRow.recordType, uuid: accountId, zoneID: handler.zoneID)
    )
    originalCK["name"] = "Test" as CKRecordValue
    originalCK["type"] = "bank" as CKRecordValue
    originalCK["position"] = 0 as CKRecordValue
    originalCK["isHidden"] = 0 as CKRecordValue
    let cachedSystemFields = originalCK.encodedSystemFields

    let row = AccountRow(
      id: accountId,
      recordName: AccountRow.recordName(for: accountId),
      name: "Test",
      type: "bank",
      instrumentId: "AUD",
      position: 0,
      isHidden: false,
      encodedSystemFields: cachedSystemFields,
      valuationMode: "recordedValue")

    // Build a CKRecord — should reuse cached system fields, which carry a
    // prefixed recordID by construction. The `buildCKRecord` contract is
    // that field values from `row.toCKRecord` are merged onto the cached
    // record.
    let built = handler.buildCKRecord(from: row, encodedSystemFields: cachedSystemFields)
    #expect(
      built.recordID.recordName
        == "\(AccountRow.recordType)|\(accountId.uuidString)")
    #expect(built.recordID.zoneID == handler.zoneID)
    #expect(built["name"] as? String == "Test")
  }

  @Test("buildCKRecord clears optional user fields removed locally")
  @MainActor
  func buildCKRecordClearsRemovedOptionalUserFields() throws {
    let handler = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase().handler
    let accountId = UUID()
    let cachedCK = CKRecord(
      recordType: "AccountRecord",
      recordID: CKRecord.ID(
        recordType: AccountRow.recordType, uuid: accountId, zoneID: handler.zoneID)
    )
    cachedCK["name"] = "Joint" as CKRecordValue
    cachedCK["taxOwnerIdsEncoded"] = UUID().uuidString as CKRecordValue
    let cachedSystemFields = cachedCK.encodedSystemFields

    let row = AccountRow(
      id: accountId,
      recordName: AccountRow.recordName(for: accountId),
      name: "Joint",
      type: "bank",
      instrumentId: "AUD",
      position: 0,
      isHidden: false,
      encodedSystemFields: cachedSystemFields,
      valuationMode: "recordedValue")

    let built = handler.buildCKRecord(from: row, encodedSystemFields: cachedSystemFields)

    #expect(built["name"] as? String == "Joint")
    #expect(built["taxOwnerIdsEncoded"] == nil)
  }

  @Test("TaxOwnerRow normalises unknown CloudKit kind values")
  func taxOwnerRowNormalisesUnknownCloudKitKindValues() throws {
    let ownerId = UUID()
    let record = CKRecord(
      recordType: TaxOwnerRow.recordType,
      recordID: CKRecord.ID(
        recordType: TaxOwnerRow.recordType,
        uuid: ownerId,
        zoneID: CKRecordZone.ID(zoneName: "profile-\(UUID().uuidString)")))
    record["name"] = "Alex" as CKRecordValue
    record["kind"] = "company" as CKRecordValue

    let row = try #require(TaxOwnerRow.fieldValues(from: record))

    #expect(row.kind == TaxOwnerKind.individual.rawValue)
  }
}
