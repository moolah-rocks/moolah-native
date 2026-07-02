// MoolahTests/App/UnifiedIdentityAliasCleanupWiringTests.swift

@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("UnifiedIdentityAliasCleanup: SyncCoordinator wiring")
@MainActor
struct UnifiedIdentityAliasCleanupWiringTests {

  private func makeIsolatedDefaults(tag: String) throws -> UserDefaults {
    let suiteName = "alias-wiring-test-\(tag)-\(UUID().uuidString)"
    return try #require(UserDefaults(suiteName: suiteName))
  }

  /// Verifies that `runUnifiedIdentityAliasCleanupForTesting()` — which
  /// delegates to the same construction path as the lifecycle — deletes
  /// aliased rows, writes journal entries, and sets the alias-cleanup
  /// completion flag.
  ///
  /// This exercises the wiring (dep construction + invocation) that
  /// `runZoneSetup` performs after `runUnifiedIdentityMigration()`, without
  /// dispatching a real `CKSyncEngine`.
  @Test("coordinator deletes aliased rows, writes journal, and sets alias-cleanup completion flag")
  func coordinatorRunsAliasCleanup() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let registry = GRDBInstrumentRegistryRepository(database: manager.profileIndexDatabase)
    let resolver = CanonicalInstrumentResolver()
    let defaults = try makeIsolatedDefaults(tag: "run")
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: defaults,
      sharedInstrumentRegistry: registry,
      sharedCanonicalResolver: resolver)

    // Seed: canonical (1:native) + two retired rows with alias_of set.
    try await registry.registerCrypto(
      CryptoRegistration.ethMainnet.instrument,
      mapping: CryptoRegistration.ethMainnet.mapping)
    try await registry.registerCrypto(
      CryptoRegistration.ethOptimism.instrument,
      mapping: CryptoRegistration.ethOptimism.mapping)
    try await registry.registerCrypto(
      CryptoRegistration.ethBase.instrument,
      mapping: CryptoRegistration.ethBase.mapping)
    try await manager.profileIndexDatabase.write { database in
      try database.execute(
        sql: "UPDATE instrument SET alias_of = '1:native' WHERE id = '10:native'")
      try database.execute(
        sql: "UPDATE instrument SET alias_of = '1:native' WHERE id = '8453:native'")
    }
    // Set the identity-migration completion flag so the cleanup does not defer.
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)

    // Act: invoke the lifecycle cleanup path via the test hook.
    await coordinator.runUnifiedIdentityAliasCleanupForTesting()

    // Assert: alias-cleanup completion flag is set.
    #expect(UnifiedInstrumentIdentityAliasCleanup.isComplete(in: defaults))

    // Assert: retired rows are gone.
    let aliasedCount = try await manager.profileIndexDatabase.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM instrument WHERE alias_of IS NOT NULL") ?? 0
    }
    #expect(aliasedCount == 0)

    // Assert: journal rows were written for the two retired ids.
    let journalCount = try await manager.profileIndexDatabase.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM deletion_journal WHERE zone_name = 'profile-index'") ?? 0
    }
    #expect(journalCount == 2)
  }

  /// Verifies that `runUnifiedIdentityAliasCleanupForTesting()` is a no-op
  /// when the alias-cleanup completion flag is already set.
  @Test("coordinator alias cleanup is a no-op when alias-cleanup completion flag is already set")
  func coordinatorSkipsCleanupWhenAlreadyComplete() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = try makeIsolatedDefaults(tag: "noop")
    defaults.set(true, forKey: UnifiedInstrumentIdentityAliasCleanup.gateKey)
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: defaults)

    await coordinator.runUnifiedIdentityAliasCleanupForTesting()

    #expect(UnifiedInstrumentIdentityAliasCleanup.isComplete(in: defaults))
  }

  // MARK: - Same-launch tombstone ordering regression

  /// Pins the ordering contract in `runZoneSetup`: the alias cleanup writes
  /// deletion_journal entries AFTER the first `replayDeletionJournal` has
  /// already run, so a second replay must follow the cleanup to enqueue those
  /// tombstones as `.deleteRecord`s THIS launch and close the resurrection
  /// window.
  ///
  /// A refactor that drops or reorders the second replay would silence every
  /// other test while reopening the window — this test specifically asserts
  /// that tombstones written by the cleanup are visible to a subsequent
  /// `replayDeletionJournal(into:)` call.
  @Test(
    "tombstones written by alias cleanup are enqueued by a subsequent replayDeletionJournal (same-launch ordering)"
  )
  func aliasCleanupTombstonesReplayedSameLaunch() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let registry = GRDBInstrumentRegistryRepository(database: manager.profileIndexDatabase)
    let defaults = try makeIsolatedDefaults(tag: "ordering")
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: defaults,
      sharedInstrumentRegistry: registry)

    // Seed: one canonical + two retired aliased rows — identical to the
    // coordinatorRunsAliasCleanup fixture so the cleanup deletes them both.
    try await registry.registerCrypto(
      CryptoRegistration.ethMainnet.instrument,
      mapping: CryptoRegistration.ethMainnet.mapping)
    try await registry.registerCrypto(
      CryptoRegistration.ethOptimism.instrument,
      mapping: CryptoRegistration.ethOptimism.mapping)
    try await registry.registerCrypto(
      CryptoRegistration.ethBase.instrument,
      mapping: CryptoRegistration.ethBase.mapping)
    try await manager.profileIndexDatabase.write { database in
      try database.execute(
        sql: "UPDATE instrument SET alias_of = '1:native' WHERE id = '10:native'")
      try database.execute(
        sql: "UPDATE instrument SET alias_of = '1:native' WHERE id = '8453:native'")
    }
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)

    // Simulate the FIRST replayDeletionJournal() pass (journal is empty at
    // this point — cleanup has not run yet).  This mirrors runZoneSetup order
    // and proves the cleanup's tombstones are NOT yet in the journal here.
    let firstStore = InMemoryPendingChangeStore()
    await coordinator.replayDeletionJournal(into: firstStore)
    #expect(firstStore.pendingRecordZoneChanges.isEmpty, "journal must be empty before cleanup")

    // Run the alias cleanup — this is the step that writes the two journal
    // entries for '10:native' and '8453:native'.
    let deletedCount = await coordinator.runUnifiedIdentityAliasCleanupForTesting()
    #expect(deletedCount == 2, "cleanup must delete both retired rows")

    // Now run the SECOND replayDeletionJournal() that runZoneSetup performs
    // after the cleanup.  This is the step under test: it must pick up the
    // tombstones the cleanup just wrote and enqueue them as .deleteRecord.
    let secondStore = InMemoryPendingChangeStore()
    await coordinator.replayDeletionJournal(into: secondStore)

    let indexZoneID = coordinator.profileIndexHandler.zoneID
    let deleteIDs = Set(
      secondStore.pendingRecordZoneChanges.compactMap { change -> CKRecord.ID? in
        if case .deleteRecord(let id) = change { return id }
        return nil
      })
    #expect(
      deleteIDs.contains(CKRecord.ID(recordName: "10:native", zoneID: indexZoneID)),
      "10:native tombstone must be enqueued by the post-cleanup replay")
    #expect(
      deleteIDs.contains(CKRecord.ID(recordName: "8453:native", zoneID: indexZoneID)),
      "8453:native tombstone must be enqueued by the post-cleanup replay")
    #expect(deleteIDs.allSatisfy { $0.zoneID == indexZoneID })
  }
}
