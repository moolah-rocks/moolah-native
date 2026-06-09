import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileIndexSyncHandler")
@MainActor
struct ProfileIndexSyncHandlerTests {

  private func makeHandler() throws -> (ProfileIndexSyncHandler, GRDBProfileIndexRepository) {
    let database = try ProfileIndexDatabase.openInMemory()
    let repository = GRDBProfileIndexRepository(database: database)
    let handler = ProfileIndexSyncHandler(repository: repository)
    return (handler, repository)
  }

  // MARK: - Remote Insert

  @Test
  func applyRemoteInsertCreatesProfileRow() throws {
    let (handler, repository) = try makeHandler()

    let profileId = UUID()
    let ckRecord = CKRecord(
      recordType: ProfileRow.recordType,
      recordID: CKRecord.ID(
        recordType: ProfileRow.recordType, uuid: profileId, zoneID: handler.zoneID)
    )
    ckRecord["label"] = "My Profile" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 7 as CKRecordValue
    ckRecord["createdAt"] = Date() as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let row = try #require(try repository.fetchRowSync(id: profileId))
    #expect(row.label == "My Profile")
    #expect(row.currencyCode == "AUD")
    #expect(row.financialYearStartMonth == 7)
    #expect(row.encodedSystemFields != nil)
  }

  // MARK: - Remote Update

  @Test
  func applyRemoteUpdateModifiesExistingRow() throws {
    let (handler, repository) = try makeHandler()

    let profileId = UUID()
    let initial = Profile(
      id: profileId,
      label: "Old Label",
      currencyCode: "USD",
      financialYearStartMonth: 7
    )
    try repository.applyRemoteChangesSync(
      saved: [ProfileRow(domain: initial)], deleted: [])

    let ckRecord = CKRecord(
      recordType: ProfileRow.recordType,
      recordID: CKRecord.ID(
        recordType: ProfileRow.recordType, uuid: profileId, zoneID: handler.zoneID)
    )
    ckRecord["label"] = "New Label" as CKRecordValue
    ckRecord["currencyCode"] = "EUR" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 1 as CKRecordValue
    ckRecord["createdAt"] = Date() as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    let row = try #require(try repository.fetchRowSync(id: profileId))
    #expect(row.label == "New Label")
    #expect(row.currencyCode == "EUR")
    #expect(row.financialYearStartMonth == 1)
  }

  // MARK: - Remote Deletion

  @Test
  func applyRemoteDeletionRemovesProfileRow() throws {
    let (handler, repository) = try makeHandler()

    let profileId = UUID()
    let initial = Profile(
      id: profileId,
      label: "To Delete",
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    try repository.applyRemoteChangesSync(
      saved: [ProfileRow(domain: initial)], deleted: [])

    let recordID = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: profileId, zoneID: handler.zoneID)
    _ = handler.applyRemoteChanges(saved: [], deleted: [recordID])

    let row = try repository.fetchRowSync(id: profileId)
    #expect(row == nil)
  }

  // MARK: - needs_push Apply Guard (issue #1081)

  @Test("a needs_push profile row's label survives a stale echo")
  func dirtyProfileEchoPreservesRename() throws {
    let (handler, repository) = try makeHandler()
    let profileId = UUID()
    let local = Profile(
      id: profileId, label: "LOCAL RENAME", currencyCode: "AUD",
      financialYearStartMonth: 7)
    try repository.applyRemoteChangesSync(saved: [ProfileRow(domain: local)], deleted: [])
    try repository.markNeedsPushSync(id: profileId)  // simulate a pending local edit

    let staleEcho = CKRecord(
      recordType: ProfileRow.recordType,
      recordID: CKRecord.ID(
        recordType: ProfileRow.recordType, uuid: profileId, zoneID: handler.zoneID))
    staleEcho["label"] = "STALE OLD LABEL" as CKRecordValue
    staleEcho["currencyCode"] = "AUD" as CKRecordValue
    staleEcho["financialYearStartMonth"] = 7 as CKRecordValue
    staleEcho["createdAt"] = Date() as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [staleEcho], deleted: [])

    let row = try #require(try repository.fetchRowSync(id: profileId))
    // The in-flight rename wins; only system fields were updated.
    #expect(row.label == "LOCAL RENAME")
    #expect(row.encodedSystemFields == staleEcho.encodedSystemFields)
  }

  // MARK: - needs_push Conditional Clear on Ack (issue #1081)

  @Test("profile ack clears needs_push only when unchanged since send")
  func profileAckConditionalClear() throws {
    let (handler, repository) = try makeHandler()
    let profileId = UUID()
    let row = ProfileRow(
      domain: Profile(
        id: profileId, label: "Sent", currencyCode: "AUD", financialYearStartMonth: 7))
    try repository.applyRemoteChangesSync(saved: [row], deleted: [])
    try repository.markNeedsPushSync(id: profileId)
    // The uploaded record is built from the persisted row (production
    // builds it via `recordToSave` → `fetchRowSync`), so it carries the
    // same SQLite-round-tripped `createdAt` the ack path re-reads.
    let persisted = try #require(try repository.fetchRowSync(id: profileId))
    let sent = handler.buildCKRecord(for: persisted)

    _ = handler.handleSentRecordZoneChanges(
      savedRecords: [sent], failedSaves: [], failedDeletes: [])

    let dirty = try repository.dirtyIdsSync(from: [profileId])
    #expect(dirty.isEmpty)  // unchanged → cleared
  }

  @Test
  func applyRemoteChangesSkipsNonProfileRecordTypes() throws {
    let (handler, repository) = try makeHandler()

    let ckRecord = CKRecord(
      recordType: "CD_SomeOtherType",
      recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: handler.zoneID)
    )
    ckRecord["label"] = "Ignored" as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    #expect(try repository.allRowIdsSync().isEmpty)
  }

  // MARK: - deleteLocalData

  @Test
  func deleteLocalDataRemovesAllProfiles() throws {
    let (handler, repository) = try makeHandler()

    let profiles = [
      Profile(label: "Profile 1", currencyCode: "AUD"),
      Profile(label: "Profile 2", currencyCode: "USD"),
      Profile(label: "Profile 3", currencyCode: "EUR"),
    ]
    try repository.applyRemoteChangesSync(
      saved: profiles.map { ProfileRow(domain: $0) }, deleted: [])

    handler.deleteLocalData()

    #expect(try repository.allRowIdsSync().isEmpty)
  }

  // MARK: - queueAllExistingRecords

  @Test
  func queueAllExistingRecordsReturnsCorrectIDs() throws {
    let (handler, repository) = try makeHandler()

    let id1 = UUID()
    let id2 = UUID()
    let profile1 = Profile(id: id1, label: "P1", currencyCode: "AUD")
    let profile2 = Profile(id: id2, label: "P2", currencyCode: "USD")
    try repository.applyRemoteChangesSync(
      saved: [ProfileRow(domain: profile1), ProfileRow(domain: profile2)], deleted: [])

    let recordIDs = handler.queueAllExistingRecords()

    #expect(recordIDs.count == 2)
    let recordNames = Set(recordIDs.map(\.recordName))
    #expect(
      recordNames.contains(
        "\(ProfileRow.recordType)|\(id1.uuidString)"))
    #expect(
      recordNames.contains(
        "\(ProfileRow.recordType)|\(id2.uuidString)"))
    for recordID in recordIDs {
      #expect(recordID.zoneID == handler.zoneID)
    }
  }

  @Test
  func queueAllExistingRecordsReturnsEmptyWhenNoRecords() throws {
    let (handler, _) = try makeHandler()
    let recordIDs = handler.queueAllExistingRecords()
    #expect(recordIDs.isEmpty)
  }

  // MARK: - buildCKRecord

  @Test
  func buildCKRecordProducesCorrectRecord() throws {
    let (handler, _) = try makeHandler()

    let profileId = UUID()
    let row = ProfileRow(
      id: profileId,
      recordName: ProfileRow.recordName(for: profileId),
      label: "Test Profile",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(),
      encodedSystemFields: nil
    )

    let ckRecord = handler.buildCKRecord(for: row)

    #expect(ckRecord.recordType == ProfileRow.recordType)
    #expect(
      ckRecord.recordID.recordName
        == "\(ProfileRow.recordType)|\(profileId.uuidString)")
    #expect(ckRecord.recordID.zoneID == handler.zoneID)
    #expect(ckRecord["label"] as? String == "Test Profile")
    #expect(ckRecord["currencyCode"] as? String == "AUD")
    #expect(ckRecord["financialYearStartMonth"] as? Int == 7)
  }
}
