@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Shared fixtures for the bloated-state recovery suites (issue #1090 / #12).
/// Split across two `@Suite` files to stay within the test-file length budget;
/// the helpers live here so both share one definition.
@MainActor
enum BloatRecoveryTestSupport {
  static let threshold = SyncCoordinator.bloatRecoveryByteThreshold

  static func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "bloat-recovery-test-\(UUID().uuidString)"))
  }

  static func makeCoordinator(
    iCloud: ICloudAvailability = .available,
    isCloudKitAvailable: Bool = true
  ) throws -> (coordinator: SyncCoordinator, manager: ProfileContainerManager) {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: try makeDefaults(),
      isCloudKitAvailable: isCloudKitAvailable)
    coordinator.iCloudAvailability = iCloud
    return (coordinator, manager)
  }

  /// A coordinator + a profile with one locally-deleted-but-un-propagated
  /// category whose tombstone is journaled, plus the resolved `CKRecord.ID`.
  struct ShieldFixture {
    let coordinator: SyncCoordinator
    let doomedID: CKRecord.ID
  }

  static func makeShieldFixture() async throws -> ShieldFixture {
    let (coordinator, manager) = try makeCoordinator()
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(id: profileId, label: "Recover", currencyCode: "AUD"))
    let categories = GRDBCategoryRepository(database: try manager.database(for: profileId))
    let doomed = try await categories.create(Moolah.Category(name: "Doomed"))
    try await categories.delete(id: doomed.id, withReplacement: nil)
    let doomedID = CKRecord.ID(
      recordType: CategoryRow.recordType,
      uuid: doomed.id,
      zoneID: CKRecordZone.ID(
        zoneName: DeletionJournal.dataZoneName(for: profileId),
        ownerName: CKCurrentUserDefaultName))
    return ShieldFixture(coordinator: coordinator, doomedID: doomedID)
  }

  /// Drives a complete fetch session (begin → end) so the forced post-recovery
  /// refetch is considered "settled".
  static func settleFetchSession(_ coordinator: SyncCoordinator) {
    coordinator.beginFetchingChanges()
    coordinator.endFetchingChanges()
  }

  /// Whether the recovery shield suppresses a fetched save for `id`.
  static func suppresses(_ id: CKRecord.ID, _ coordinator: SyncCoordinator) async -> Bool {
    let record = CKRecord(recordType: CategoryRow.recordType, recordID: id)
    return await coordinator.recoveryShieldedSaves([record]).toApply.isEmpty
  }
}
