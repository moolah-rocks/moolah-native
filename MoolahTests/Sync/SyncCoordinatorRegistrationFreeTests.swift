import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Regression tests for issue #619: a sync event for a profile whose
/// `ProfileSession` is not open must apply successfully. Before the fix,
/// `SyncCoordinator.handlerForProfileZone` threw
/// `SyncCoordinatorError.profileNotRegistered` and the apply path
/// trapped via `preconditionFailure`. After the fix, the coordinator
/// constructs the per-profile GRDB repositories on demand from
/// `containerManager.database(for:)`.
@Suite("SyncCoordinator — registration-free apply")
@MainActor
struct SyncCoordinatorRegistrationFreeTests {
  @Test("handlerForProfileZone constructs a handler when no bundle is registered")
  func handlerConstructedWithoutRegistration() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    let handler = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)

    #expect(handler.profileId == profileId)
    #expect(handler.zoneID == zoneID)
  }

  @Test("a second call returns the cached handler")
  func handlerCachedAcrossCalls() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    let first = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)
    let second = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)

    #expect(first === second)
  }

  @Test("missing sent handler recovers unless teardown was intentional")
  func missingSentHandlerRecoveryDistinguishesIntentionalTeardown() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let transientId = UUID()
    let tornDownId = UUID()

    #expect(coordinator.missingSentHandlerAction(for: transientId) == .recover)
    coordinator.evictCachedState(for: tornDownId)
    #expect(
      coordinator.missingSentHandlerAction(for: tornDownId)
        == .ignoreIntentionalTeardown)
  }

  @Test("remote profile default owner update refreshes cached data handler")
  func remoteProfileDefaultOwnerUpdateRefreshesCachedDataHandler() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    let oldDefaultOwnerId = UUID()
    let newDefaultOwnerId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    try manager.profileIndexRepository.applyRemoteChangesSync(
      saved: [
        ProfileRow(
          domain: Profile(
            id: profileId,
            label: "Family",
            defaultTaxOwnerId: oldDefaultOwnerId))
      ],
      deleted: [])

    let handler = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)
    #expect(handler.grdbRepositories.taxOwners.defaultTaxOwnerId == oldDefaultOwnerId)

    let record = CKRecord(
      recordType: ProfileRow.recordType,
      recordID: CKRecord.ID(
        recordType: ProfileRow.recordType,
        uuid: profileId,
        zoneID: coordinator.profileIndexHandler.zoneID))
    record["label"] = "Family" as CKRecordValue
    record["currencyCode"] = "AUD" as CKRecordValue
    record["financialYearStartMonth"] = 7 as CKRecordValue
    record["createdAt"] = Date() as CKRecordValue
    record["defaultTaxOwnerId"] = newDefaultOwnerId.uuidString as CKRecordValue

    await coordinator.applyFetchedIndexChanges(saved: [record], deleted: [])

    #expect(handler.grdbRepositories.taxOwners.defaultTaxOwnerId == newDefaultOwnerId)
  }

  @Test("applyFetchedRecordZoneChanges writes rows for an un-sessionized profile")
  func applyWritesRowsWithoutSession() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(
        id: profileId, label: "Background", currencyCode: "AUD",
        financialYearStartMonth: 7))
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    let accountId = UUID()
    let record = CKRecord(
      recordType: AccountRow.recordType,
      recordID: CKRecord.ID(
        recordName: AccountRow.recordName(for: accountId),
        zoneID: zoneID))
    record["name"] = "Synced from another device" as CKRecordValue
    record["instrumentId"] = "AUD" as CKRecordValue
    record["position"] = Int64(0) as CKRecordValue
    record["isHidden"] = Int64(0) as CKRecordValue
    record["type"] = "bank" as CKRecordValue

    // Drive the apply path directly — no ProfileSession has been
    // constructed, so this would have trapped before the fix.
    let handler = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)
    let result = handler.applyRemoteChanges(
      saved: [record], deleted: [], preExtractedSystemFields: [])

    if case .saveFailed(let description) = result {
      Issue.record("apply failed: \(description)")
    }
    let database = try manager.database(for: profileId)
    let stored = try await database.read { reader in
      try AccountRow.filter(AccountRow.Columns.id == accountId).fetchOne(reader)
    }
    #expect(stored?.name == "Synced from another device")
  }

  @Test("encrypted-data-reset clears system fields and re-queues records without session")
  func encryptedResetWithoutSession() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(
        id: profileId, label: "Reset", currencyCode: "AUD",
        financialYearStartMonth: 7))
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    // Seed a row directly in GRDB with a non-nil encodedSystemFields.
    let database = try manager.database(for: profileId)
    let categoryId = UUID()
    try await database.write { writer in
      try CategoryRow(
        id: categoryId,
        recordName: CategoryRow.recordName(for: categoryId),
        name: "Reset me",
        parentId: nil,
        encodedSystemFields: Data([0xDE, 0xAD, 0xBE, 0xEF])
      ).insert(writer)
    }

    coordinator.handleEncryptedDataReset(zoneID, zoneType: .profileData(profileId))

    let stored = try await database.read { reader in
      try CategoryRow.filter(CategoryRow.Columns.id == categoryId).fetchOne(reader)
    }
    #expect(stored?.encodedSystemFields == nil)
  }
}
