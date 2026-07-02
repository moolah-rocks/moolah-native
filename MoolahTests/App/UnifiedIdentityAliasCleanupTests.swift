// MoolahTests/App/UnifiedIdentityAliasCleanupTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

// MARK: - Helpers

private func makeIsolatedDefaults(tag: String) throws -> UserDefaults {
  let suiteName = "alias-cleanup-test-\(tag)-\(UUID().uuidString)"
  return try #require(UserDefaults(suiteName: suiteName))
}

/// Seeds the shared registry with:
///   - `1:native`  (canonical, `alias_of IS NULL`)
///   - `10:native` (retired,   `alias_of = "1:native"`)
///   - `8453:native` (retired, `alias_of = "1:native"`)
private func seedAliasedRegistry(queue: DatabaseQueue) async throws {
  let registry = GRDBInstrumentRegistryRepository(database: queue)
  try await registry.registerCrypto(
    CryptoRegistration.ethMainnet.instrument,
    mapping: CryptoRegistration.ethMainnet.mapping)
  try await registry.registerCrypto(
    CryptoRegistration.ethOptimism.instrument,
    mapping: CryptoRegistration.ethOptimism.mapping)
  try await registry.registerCrypto(
    CryptoRegistration.ethBase.instrument,
    mapping: CryptoRegistration.ethBase.mapping)
  // Simulate PR5 having set alias_of on the retired rows.
  try await queue.write { database in
    try database.execute(
      sql: "UPDATE instrument SET alias_of = '1:native' WHERE id = '10:native'")
    try database.execute(
      sql: "UPDATE instrument SET alias_of = '1:native' WHERE id = '8453:native'")
  }
}

/// Returns all `deletion_journal` rows for `zone_name = 'profile-index'`.
private func journalEntries(in queue: DatabaseQueue) async throws -> [DeletionJournalRow] {
  try await queue.read { database in
    try DeletionJournalRow
      .filter(DeletionJournalRow.Columns.zoneName == DeletionJournal.profileIndexZoneName)
      .fetchAll(database)
  }
}

// MARK: - Suite

@MainActor
@Suite("UnifiedIdentityAliasCleanup: run()")
struct UnifiedIdentityAliasCleanupTests {

  // MARK: - Deletes aliased rows + writes journal

  @Test("deletes aliased rows and writes journal entries with correct fields")
  func deletesAliasedRowsAndWritesJournal() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let defaults = try makeIsolatedDefaults(tag: "delete")
    try await seedAliasedRegistry(queue: queue)
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)

    let cleanup = UnifiedInstrumentIdentityAliasCleanup(
      profileIndexDatabase: queue,
      userDefaults: defaults)
    try await cleanup.run()

    // Retired rows must be gone.
    let aliasedCount = try await queue.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM instrument WHERE alias_of IS NOT NULL") ?? 0
    }
    #expect(aliasedCount == 0)

    // Canonical row must still exist.
    let canonicalExists = try await queue.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM instrument WHERE id = '1:native'") ?? 0
    }
    #expect(canonicalExists == 1)

    // Journal must have entries for each retired id.
    let entries = try await journalEntries(in: queue)
    #expect(entries.count == 2)
    let recordNames = Set(entries.map(\.recordName))
    #expect(recordNames == ["10:native", "8453:native"])
    // Every entry must carry the correct zone and record type.
    for entry in entries {
      #expect(entry.zoneName == DeletionJournal.profileIndexZoneName)
      #expect(entry.recordType == InstrumentRow.recordType)
    }

    // PR6 flag must be set.
    #expect(UnifiedInstrumentIdentityAliasCleanup.isComplete(in: defaults))
  }

  // MARK: - Leaves canonical rows

  @Test("leaves alias_of IS NULL rows untouched")
  func leavesCanonicalRowsIntact() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let defaults = try makeIsolatedDefaults(tag: "canonical")
    try await seedAliasedRegistry(queue: queue)
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)

    let cleanup = UnifiedInstrumentIdentityAliasCleanup(
      profileIndexDatabase: queue,
      userDefaults: defaults)
    try await cleanup.run()

    let canonicalExists = try await queue.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM instrument WHERE id = '1:native' AND alias_of IS NULL") ?? 0
    }
    #expect(canonicalExists == 1)
  }

  // MARK: - Idempotent

  @Test("second run is a no-op (flag already set, no error, rows still gone)")
  func idempotentRerun() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let defaults = try makeIsolatedDefaults(tag: "idempotent")
    try await seedAliasedRegistry(queue: queue)
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)

    let cleanup = UnifiedInstrumentIdentityAliasCleanup(
      profileIndexDatabase: queue,
      userDefaults: defaults)
    try await cleanup.run()
    // Second run: own flag is now set → short-circuits.
    try await cleanup.run()

    let aliasedCount = try await queue.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM instrument WHERE alias_of IS NOT NULL") ?? 0
    }
    #expect(aliasedCount == 0)
    #expect(UnifiedInstrumentIdentityAliasCleanup.isComplete(in: defaults))
  }

  // MARK: - PR5 flag unset → no-op, PR6 flag NOT set

  @Test("no-op when PR5 migration flag is unset; PR6 flag must NOT be set")
  func noOpWhenPR5FlagUnset() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let defaults = try makeIsolatedDefaults(tag: "pr5unset")
    try await seedAliasedRegistry(queue: queue)
    // PR5 flag deliberately NOT set.

    let cleanup = UnifiedInstrumentIdentityAliasCleanup(
      profileIndexDatabase: queue,
      userDefaults: defaults)
    try await cleanup.run()

    // Retired rows must still exist (nothing was deleted).
    let aliasedCount = try await queue.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM instrument WHERE alias_of IS NOT NULL") ?? 0
    }
    #expect(aliasedCount == 2)
    // Journal must be empty.
    let entries = try await journalEntries(in: queue)
    #expect(entries.isEmpty)
    // PR6 flag must NOT be set.
    #expect(!UnifiedInstrumentIdentityAliasCleanup.isComplete(in: defaults))
  }

  // MARK: - Own-flag short-circuit

  @Test("immediate no-op when own PR6 flag is already set")
  func ownFlagShortCircuit() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let defaults = try makeIsolatedDefaults(tag: "ownflag")
    try await seedAliasedRegistry(queue: queue)
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)
    // Pre-set PR6 flag — simulate a prior completed run.
    defaults.set(true, forKey: UnifiedInstrumentIdentityAliasCleanup.gateKey)

    let cleanup = UnifiedInstrumentIdentityAliasCleanup(
      profileIndexDatabase: queue,
      userDefaults: defaults)
    try await cleanup.run()

    // Aliased rows must still exist (short-circuit fired before any delete).
    let aliasedCount = try await queue.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM instrument WHERE alias_of IS NOT NULL") ?? 0
    }
    #expect(aliasedCount == 2)
    // Journal must be empty (no new entries written).
    let entries = try await journalEntries(in: queue)
    #expect(entries.isEmpty)
  }

  // MARK: - Empty-aliased case sets flag

  @Test("flag is set even when no aliased rows exist (converged/no-crypto device)")
  func emptyAliasedCaseSetsFlag() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let defaults = try makeIsolatedDefaults(tag: "empty")
    // Only a canonical row — no alias_of rows.
    let registry = GRDBInstrumentRegistryRepository(database: queue)
    try await registry.registerCrypto(
      CryptoRegistration.ethMainnet.instrument,
      mapping: CryptoRegistration.ethMainnet.mapping)
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)

    let cleanup = UnifiedInstrumentIdentityAliasCleanup(
      profileIndexDatabase: queue,
      userDefaults: defaults)
    try await cleanup.run()

    // No journal rows written (nothing to delete).
    let entries = try await journalEntries(in: queue)
    #expect(entries.isEmpty)
    // Flag must still be set.
    #expect(UnifiedInstrumentIdentityAliasCleanup.isComplete(in: defaults))
  }

  // MARK: - resetGateFlag

  @Test("resetGateFlag clears a previously-set PR6 completion flag")
  func resetGateFlagClearsFlag() throws {
    let defaults = try makeIsolatedDefaults(tag: "reset")
    defaults.set(true, forKey: UnifiedInstrumentIdentityAliasCleanup.gateKey)
    #expect(UnifiedInstrumentIdentityAliasCleanup.isComplete(in: defaults))
    UnifiedInstrumentIdentityAliasCleanup.resetGateFlag(in: defaults)
    #expect(!UnifiedInstrumentIdentityAliasCleanup.isComplete(in: defaults))
  }
}
