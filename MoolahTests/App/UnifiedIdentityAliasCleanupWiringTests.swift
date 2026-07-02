// MoolahTests/App/UnifiedIdentityAliasCleanupWiringTests.swift

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
}
