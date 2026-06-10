import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileIndexSyncHandler")
@MainActor
struct ProfileIndexSyncHandlerTestsMore {

  private func makeHandler() throws -> (ProfileIndexSyncHandler, GRDBProfileIndexRepository) {
    let database = try ProfileIndexDatabase.openInMemory()
    let repository = GRDBProfileIndexRepository(database: database)
    let handler = ProfileIndexSyncHandler(repository: repository)
    return (handler, repository)
  }

  @Test
  func buildCKRecordPreservesCachedSystemFields() throws {
    let (handler, repository) = try makeHandler()

    let profileId = UUID()
    let originalCK = CKRecord(
      recordType: ProfileRow.recordType,
      recordID: CKRecord.ID(
        recordType: ProfileRow.recordType, uuid: profileId, zoneID: handler.zoneID)
    )
    originalCK["label"] = "Test" as CKRecordValue
    originalCK["currencyCode"] = "AUD" as CKRecordValue
    originalCK["financialYearStartMonth"] = 7 as CKRecordValue
    originalCK["createdAt"] = Date() as CKRecordValue

    // Apply remote changes to store system fields
    _ = handler.applyRemoteChanges(saved: [originalCK], deleted: [])

    let row = try #require(try repository.fetchRowSync(id: profileId))
    #expect(row.encodedSystemFields != nil)

    let built = handler.buildCKRecord(for: row)
    #expect(
      built.recordID.recordName
        == "\(ProfileRow.recordType)|\(profileId.uuidString)")
    #expect(built.recordID.zoneID == handler.zoneID)
    #expect(built["label"] as? String == "Test")
  }

  // MARK: - recordToSave

  @Test
  func recordToSaveFindsProfileByUUID() throws {
    let (handler, repository) = try makeHandler()

    let profileId = UUID()
    let profile = Profile(id: profileId, label: "Found", currencyCode: "AUD")
    try repository.applyRemoteChangesSync(
      saved: [ProfileRow(domain: profile)], deleted: [])

    let recordID = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: profileId, zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID).foundRecord
    #expect(result != nil)
    #expect(result?.recordType == ProfileRow.recordType)
    #expect(result?["label"] as? String == "Found")
  }

  @Test
  func recordToSaveReturnsNilForMissingProfile() throws {
    let (handler, _) = try makeHandler()

    let recordID = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: UUID(), zoneID: handler.zoneID)
    // Missing row, query succeeded → `.absent` (issue #1087 tri-state).
    guard case .absent = handler.recordToSave(for: recordID) else {
      Issue.record("expected .absent for a missing profile")
      return
    }
  }

  // MARK: - clearAllSystemFields

  @Test
  func clearAllSystemFieldsClearsOnAllProfiles() throws {
    let (handler, repository) = try makeHandler()

    let profileId = UUID()
    let ckRecord = CKRecord(
      recordType: ProfileRow.recordType,
      recordID: CKRecord.ID(
        recordType: ProfileRow.recordType, uuid: profileId, zoneID: handler.zoneID)
    )
    ckRecord["label"] = "Test" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 7 as CKRecordValue
    ckRecord["createdAt"] = Date() as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let preRow = try #require(try repository.fetchRowSync(id: profileId))
    #expect(preRow.encodedSystemFields != nil)

    handler.clearAllSystemFields()

    let postRow = try #require(try repository.fetchRowSync(id: profileId))
    #expect(postRow.encodedSystemFields == nil)
  }

  // MARK: - updateEncodedSystemFields / clearEncodedSystemFields

  @Test
  func updateEncodedSystemFieldsSetsDataOnMatchingProfile() throws {
    let (handler, repository) = try makeHandler()

    let profileId = UUID()
    let profile = Profile(id: profileId, label: "Test", currencyCode: "AUD")
    try repository.applyRemoteChangesSync(
      saved: [ProfileRow(domain: profile)], deleted: [])

    let testData = Data([0x01, 0x02, 0x03])
    let recordID = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: profileId, zoneID: handler.zoneID)
    handler.updateEncodedSystemFields(recordID, data: testData)

    let row = try #require(try repository.fetchRowSync(id: profileId))
    #expect(row.encodedSystemFields == testData)
  }

  @Test
  func clearEncodedSystemFieldsClearsDataOnMatchingProfile() throws {
    let (handler, repository) = try makeHandler()

    let profileId = UUID()
    var row = ProfileRow(
      domain: Profile(id: profileId, label: "Test", currencyCode: "AUD"))
    row.encodedSystemFields = Data([0x01, 0x02])
    try repository.applyRemoteChangesSync(saved: [row], deleted: [])

    let recordID = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: profileId, zoneID: handler.zoneID)
    handler.clearEncodedSystemFields(recordID)

    let updated = try #require(try repository.fetchRowSync(id: profileId))
    #expect(updated.encodedSystemFields == nil)
  }

  // MARK: - handleSentRecordZoneChanges

  @Test
  func handleSentRecordZoneChangesUpdatesSystemFieldsFromSavedRecords() throws {
    let (handler, repository) = try makeHandler()

    let profileId = UUID()
    let profile = Profile(id: profileId, label: "Test", currencyCode: "AUD")
    try repository.applyRemoteChangesSync(
      saved: [ProfileRow(domain: profile)], deleted: [])

    // Build a CKRecord with encoded system fields produced from a real
    // record so the system fields blob is valid.
    let ckRecord = CKRecord(
      recordType: ProfileRow.recordType,
      recordID: CKRecord.ID(
        recordType: ProfileRow.recordType, uuid: profileId, zoneID: handler.zoneID)
    )
    ckRecord["label"] = "Test" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 7 as CKRecordValue
    ckRecord["createdAt"] = Date() as CKRecordValue
    let expectedSystemFields = ckRecord.encodedSystemFields

    let failures = handler.handleSentRecordZoneChanges(
      savedRecords: [ckRecord],
      failedSaves: [],
      failedDeletes: []
    )

    #expect(failures.conflicts.isEmpty)
    #expect(failures.unknownItems.isEmpty)
    #expect(failures.requeue.isEmpty)
    #expect(failures.requeueDeletes.isEmpty)

    let row = try #require(try repository.fetchRowSync(id: profileId))
    #expect(row.encodedSystemFields == expectedSystemFields)
  }

  @Test
  func handleSentRecordZoneChangesWithNoRecordsReturnsEmptyFailures() throws {
    let (handler, _) = try makeHandler()

    let failures = handler.handleSentRecordZoneChanges(
      savedRecords: [],
      failedSaves: [],
      failedDeletes: []
    )

    #expect(failures.conflicts.isEmpty)
    #expect(failures.unknownItems.isEmpty)
    #expect(failures.requeue.isEmpty)
    #expect(failures.requeueDeletes.isEmpty)
  }
}
