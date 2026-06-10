import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Record-name collision fix — issue #416")
@MainActor
struct RecordNameCollisionTests {

  // MARK: - 1. UUID collision between types (regression test)

  @Test("Account and Transaction sharing a UUID both upload as distinct CKRecords")
  func collidingUUIDsYieldDistinctPrefixedRecordNames() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler

    let sharedId = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: sharedId, name: "Shares"
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.transactionRow(
        id: sharedId, payee: "Opening balance"
      ).upsert(database)
    }

    // The lookup is keyed by recordType and then by UUID, so two record
    // types sharing a UUID produce two independent entries — preventing
    // the same `CKRecord` from being appended to a batch twice.
    let lookup = handler.buildBatchRecordLookup(byRecordType: [
      AccountRow.recordType: [sharedId],
      TransactionRow.recordType: [sharedId],
    ])

    let accountRecord = try #require(lookup[AccountRow.recordType]?.succeededHits[sharedId])
    let transactionRecord = try #require(
      lookup[TransactionRow.recordType]?.succeededHits[sharedId])
    #expect(
      accountRecord.recordID.recordName
        == "\(AccountRow.recordType)|\(sharedId.uuidString)")
    #expect(
      transactionRecord.recordID.recordName
        == "\(TransactionRow.recordType)|\(sharedId.uuidString)")
  }

  @Test("queueUnsyncedRecords produces prefixed recordNames per type")
  func queueUnsyncedProducesPrefixedRecordNamesPerType() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler

    let sharedId = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: sharedId, name: "Shares"
      ).upsert(database)
      try ProfileDataSyncHandlerTestSupport.transactionRow(
        id: sharedId, payee: "Opening balance"
      ).upsert(database)
    }

    let recordIDs = handler.queueUnsyncedRecords()
    let names = Set(recordIDs.map(\.recordName))
    #expect(
      names.contains("\(AccountRow.recordType)|\(sharedId.uuidString)"))
    #expect(
      names.contains(
        "\(TransactionRow.recordType)|\(sharedId.uuidString)"))
  }

  // MARK: - 2. Uplink uses prefixed name for new records

  @Test("buildCKRecord for a brand-new AccountRow emits a prefixed recordName")
  func buildCKRecordEmitsPrefixedRecordNameForNewRecords() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler

    let accountId = UUID()
    let row = AccountRow(
      id: accountId,
      recordName: AccountRow.recordName(for: accountId),
      name: "New",
      type: "bank",
      instrumentId: "AUD",
      position: 0,
      isHidden: false,
      encodedSystemFields: nil,
      valuationMode: ValuationMode.recordedValue.rawValue)

    let built = handler.buildCKRecord(from: row, encodedSystemFields: nil)
    #expect(
      built.recordID.recordName
        == "\(AccountRow.recordType)|\(accountId.uuidString)")
  }

  // MARK: - 3. Uplink ignores stale bare-UUID cached system fields

  @Test("buildCKRecord ignores legacy bare-UUID recordName in cached system fields")
  func buildCKRecordIgnoresLegacyBareUUIDCachedSystemFields() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler

    let accountId = UUID()
    // Seed an encodedSystemFields blob whose recordID uses the legacy
    // bare-UUID recordName. Reusing this would re-upload the record under
    // the legacy form and round-trip nowhere (the downlink path drops it),
    // so `buildCKRecord` must ignore the stale cache and emit a fresh
    // prefixed recordID.
    let legacyRecord = CKRecord(
      recordType: "AccountRecord",
      recordID: CKRecord.ID(
        recordName: accountId.uuidString, zoneID: handler.zoneID))
    let legacySystemFields = legacyRecord.encodedSystemFields

    let row = AccountRow(
      id: accountId,
      recordName: AccountRow.recordName(for: accountId),
      name: "Updated",
      type: "bank",
      instrumentId: "AUD",
      position: 0,
      isHidden: false,
      encodedSystemFields: legacySystemFields,
      valuationMode: ValuationMode.recordedValue.rawValue)

    let built = handler.buildCKRecord(from: row, encodedSystemFields: legacySystemFields)
    #expect(
      built.recordID.recordName
        == "\(AccountRow.recordType)|\(accountId.uuidString)")
    #expect(built["name"] as? String == "Updated")
  }

  // MARK: - 4. Downlink rejects bare-UUID CKRecords

  @Test("applyRemoteChanges drops bare-UUID CKRecords and ingests prefixed ones")
  func applyRemoteChangesRejectsBareUUIDAcceptsPrefixed() async throws {
    let harness =
      try ProfileDataSyncHandlerTestSupport
      .makeHandlerAndDatabase()
    let handler = harness.handler

    let legacyId = UUID()
    let legacyCK = CKRecord(
      recordType: "AccountRecord",
      recordID: CKRecord.ID(
        recordName: legacyId.uuidString, zoneID: handler.zoneID))
    legacyCK["name"] = "Legacy" as CKRecordValue
    legacyCK["type"] = "bank" as CKRecordValue
    legacyCK["position"] = 0 as CKRecordValue
    legacyCK["isHidden"] = 0 as CKRecordValue

    let newId = UUID()
    let newCK = CKRecord(
      recordType: "AccountRecord",
      recordID: CKRecord.ID(
        recordType: "AccountRecord",
        uuid: newId,
        zoneID: handler.zoneID))
    newCK["name"] = "Prefixed" as CKRecordValue
    newCK["type"] = "bank" as CKRecordValue
    newCK["position"] = 1 as CKRecordValue
    newCK["isHidden"] = 0 as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [legacyCK, newCK], deleted: [])

    let rows = try await harness.database.read { database in
      try AccountRow.fetchAll(database)
    }
    let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    #expect(byId[legacyId] == nil, "bare-UUID record should not be ingested")
    #expect(byId[newId]?.name == "Prefixed")
    #expect(byId[newId]?.encodedSystemFields != nil)
  }

  // MARK: - 5. System-fields round-trip for prefixed records

  @Test("handleSentRecordZoneChanges writes system fields back using recordType")
  func handleSentRecordZoneChangesAppliesSystemFieldsForPrefixedRecords() async throws {
    let harness =
      try ProfileDataSyncHandlerTestSupport
      .makeHandlerAndDatabase()
    let handler = harness.handler

    let accountId = UUID()
    let stub = Account(
      id: accountId, name: "Test", type: .bank,
      instrument: .defaultTestInstrument, position: 0, isHidden: false)
    try await harness.database.write { database in
      try AccountRow(domain: stub).insert(database)
    }

    // Simulate a CK round-trip where the server returns a prefixed
    // CKRecord as "saved".
    let savedCK = CKRecord(
      recordType: "AccountRecord",
      recordID: CKRecord.ID(
        recordType: "AccountRecord",
        uuid: accountId,
        zoneID: handler.zoneID))
    savedCK["name"] = "Test" as CKRecordValue

    _ = handler.handleSentRecordZoneChanges(
      savedRecords: [savedCK], failedSaves: [], failedDeletes: [])

    let reloaded = try await harness.database.read { database in
      try AccountRow.filter(AccountRow.Columns.id == accountId).fetchOne(database)
    }
    #expect(reloaded?.encodedSystemFields != nil)
  }

  // MARK: - 6. ProfileIndexSyncHandler dual-format

  private func makeProfileIndexHandler() throws -> (
    ProfileIndexSyncHandler, GRDBProfileIndexRepository
  ) {
    let database = try ProfileIndexDatabase.openInMemory()
    let repository = GRDBProfileIndexRepository(database: database)
    let handler = ProfileIndexSyncHandler(repository: repository)
    return (handler, repository)
  }

  @Test("ProfileIndexSyncHandler.recordToSave accepts prefixed recordID")
  func profileIndexRecordToSaveAcceptsPrefixedRecordID() async throws {
    let (handler, repository) = try makeProfileIndexHandler()

    let profileId = UUID()
    let profile = Profile(
      id: profileId, label: "Test", currencyCode: "AUD",
      financialYearStartMonth: 7)
    try repository.applyRemoteChangesSync(
      saved: [ProfileRow(domain: profile)], deleted: [])

    let prefixedID = CKRecord.ID(
      recordType: ProfileRow.recordType,
      uuid: profileId,
      zoneID: handler.zoneID)

    let result = try #require(handler.recordToSave(for: prefixedID).foundRecord)
    #expect(result.recordType == ProfileRow.recordType)
    #expect(
      result.recordID.recordName
        == "\(ProfileRow.recordType)|\(profileId.uuidString)")
  }

  @Test("ProfileIndexSyncHandler.applyRemoteChanges accepts prefixed ProfileRecord")
  func profileIndexApplyRemoteChangesAcceptsPrefixedProfileRecord() async throws {
    let (handler, repository) = try makeProfileIndexHandler()

    let profileId = UUID()
    let prefixedCK = CKRecord(
      recordType: ProfileRow.recordType,
      recordID: CKRecord.ID(
        recordType: ProfileRow.recordType,
        uuid: profileId,
        zoneID: handler.zoneID))
    prefixedCK["label"] = "Prefixed" as CKRecordValue
    prefixedCK["currencyCode"] = "AUD" as CKRecordValue
    prefixedCK["financialYearStartMonth"] = 7 as CKRecordValue
    prefixedCK["createdAt"] = Date() as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [prefixedCK], deleted: [])

    let row = try #require(try repository.fetchRowSync(id: profileId))
    #expect(row.label == "Prefixed")
    #expect(row.encodedSystemFields != nil)
  }

  @Test(
    "ProfileIndexSyncHandler.handleSentRecordZoneChanges caches system fields for prefixed records"
  )
  func profileIndexHandleSentCachesSystemFieldsForPrefixedRecord() async throws {
    let (handler, repository) = try makeProfileIndexHandler()

    let profileId = UUID()
    let profile = Profile(
      id: profileId, label: "Test", currencyCode: "AUD",
      financialYearStartMonth: 7)
    try repository.applyRemoteChangesSync(
      saved: [ProfileRow(domain: profile)], deleted: [])
    let preRow = try #require(try repository.fetchRowSync(id: profileId))
    #expect(preRow.encodedSystemFields == nil)

    let savedCK = CKRecord(
      recordType: ProfileRow.recordType,
      recordID: CKRecord.ID(
        recordType: ProfileRow.recordType,
        uuid: profileId,
        zoneID: handler.zoneID))
    savedCK["label"] = "Test" as CKRecordValue

    _ = handler.handleSentRecordZoneChanges(
      savedRecords: [savedCK], failedSaves: [], failedDeletes: [])

    let row = try #require(try repository.fetchRowSync(id: profileId))
    #expect(row.encodedSystemFields != nil)
  }
}
