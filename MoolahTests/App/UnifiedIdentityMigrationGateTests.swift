// MoolahTests/App/UnifiedIdentityMigrationGateTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("UnifiedIdentityMigration: SyncCoordinator wiring")
@MainActor
struct UnifiedIdentityMigrationGateTests {

  // MARK: - Helpers

  private func makeIsolatedDefaults(tag: String) throws -> UserDefaults {
    let suiteName = "gate-test-\(tag)-\(UUID().uuidString)"
    return try #require(UserDefaults(suiteName: suiteName))
  }

  // MARK: - Tests

  /// Verifies that `runUnifiedIdentityMigrationForTesting()` — which delegates
  /// to the same construction path as the lifecycle — runs the migration
  /// end-to-end against the shared registry and a seeded profile database,
  /// sets the completion flag, and aliases the retired id onto its canonical.
  ///
  /// This exercises the wiring (dep construction + invocation) that
  /// `runZoneSetup` performs between `replayDeletionJournal()` and the
  /// first-launch / backfill scan, without dispatching a real `CKSyncEngine`.
  @Test("coordinator runs the identity migration against the shared + profile DBs")
  func coordinatorRunsMigration() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let registry = GRDBInstrumentRegistryRepository(database: manager.profileIndexDatabase)
    let resolver = CanonicalInstrumentResolver()
    let defaults = try makeIsolatedDefaults(tag: "run")
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: defaults,
      sharedInstrumentRegistry: registry,
      sharedCanonicalResolver: resolver)

    // Seed: canonical (1:native) + retired (10:native) in the shared registry.
    try await registry.registerCrypto(
      CryptoRegistration.ethMainnet.instrument,
      mapping: CryptoRegistration.ethMainnet.mapping)
    try await registry.registerCrypto(
      CryptoRegistration.ethOptimism.instrument,
      mapping: CryptoRegistration.ethOptimism.mapping)

    // Seed: one profile with retired-id rows in all FK tables.
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(
        id: profileId, label: "Test Profile", currencyCode: "AUD",
        financialYearStartMonth: 7))
    let profileDb = try manager.database(for: profileId)
    try await profileDb.write { database in try seedRetiredRows(database) }

    // Act: invoke the lifecycle migration path via the test hook.
    await coordinator.runUnifiedIdentityMigrationForTesting()

    // Assert: completion flag is set.
    #expect(UnifiedInstrumentIdentityMigration.isComplete(in: defaults))

    // Assert: the retired id is aliased onto the canonical in the shared registry.
    let aliasOf = try await manager.profileIndexDatabase.read { database in
      try String?.fetchOne(
        database,
        sql: "SELECT alias_of FROM instrument WHERE id = ?",
        arguments: ["10:native"])
    }
    #expect(aliasOf == "1:native")
  }

  /// Verifies that `runUnifiedIdentityMigrationForTesting()` is a no-op (does
  /// not crash, does not clear the flag) when the completion flag is already set.
  /// Production launches gate on the same flag.
  @Test("coordinator migration is a no-op when already complete (gate flag set)")
  func coordinatorSkipsMigrationWhenAlreadyComplete() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let registry = GRDBInstrumentRegistryRepository(database: manager.profileIndexDatabase)
    let resolver = CanonicalInstrumentResolver()
    let defaults = try makeIsolatedDefaults(tag: "noop")
    defaults.set(true, forKey: UnifiedInstrumentIdentityMigration.gateKey)
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: defaults,
      sharedInstrumentRegistry: registry,
      sharedCanonicalResolver: resolver)

    // Act: should short-circuit immediately.
    await coordinator.runUnifiedIdentityMigrationForTesting()

    // Assert: flag remains set; nothing was cleared or reset.
    #expect(UnifiedInstrumentIdentityMigration.isComplete(in: defaults))
  }

  /// Verifies that `runUnifiedIdentityMigrationForTesting()` silently skips
  /// when the coordinator has no shared registry (preview / test contexts that
  /// omit that dep). The completion flag must NOT be set — the migration was
  /// not run, not finished.
  @Test("coordinator skips migration when shared registry is absent")
  func coordinatorSkipsMigrationWithoutRegistry() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = try makeIsolatedDefaults(tag: "nodeps")
    // Coordinator constructed without sharedInstrumentRegistry.
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: defaults)

    await coordinator.runUnifiedIdentityMigrationForTesting()

    // Flag must NOT be set — migration was skipped, not completed.
    #expect(!UnifiedInstrumentIdentityMigration.isComplete(in: defaults))
  }

  /// Verifies that `resetGateFlag(in:)` clears a completion flag that was
  /// previously set — the behaviour relied upon by the `--ui-testing` reset
  /// path in `MoolahApp+Setup.swift` to prevent stale `UserDefaults` from
  /// short-circuiting the migration for fresh in-memory UI-test profiles.
  @Test("resetGateFlag clears a previously-set completion flag")
  func resetGateFlagClearsFlag() throws {
    let defaults = try makeIsolatedDefaults(tag: "reset")
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)
    #expect(UnifiedInstrumentIdentityMigration.isComplete(in: defaults))
    UnifiedInstrumentIdentityMigration.resetGateFlag(in: defaults)
    #expect(!UnifiedInstrumentIdentityMigration.isComplete(in: defaults))
  }
}
