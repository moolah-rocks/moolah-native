// MoolahTests/App/UnifiedIdentityAliasCleanupRollbackTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

// MARK: - Error type

private enum AliasCleanupTestError: Error, Equatable {
  case injected
}

// MARK: - Snapshot helpers

/// Captures the ids of all `instrument` rows plus every `deletion_journal` row.
/// Used to prove byte-identical state before and after a rolled-back write.
private struct SharedDBSnapshot: Equatable {
  let instrumentIds: [String]
  let aliasedIds: [String]
  let journalRecordNames: [String]
}

private func fetchSharedSnapshot(_ database: Database) throws -> SharedDBSnapshot {
  let allIds = try String.fetchAll(
    database, sql: "SELECT id FROM instrument ORDER BY id")
  let aliasedIds = try String.fetchAll(
    database,
    sql: "SELECT id FROM instrument WHERE alias_of IS NOT NULL ORDER BY id")
  let journalNames = try String.fetchAll(
    database,
    sql: "SELECT record_name FROM deletion_journal ORDER BY record_name")
  return SharedDBSnapshot(
    instrumentIds: allIds,
    aliasedIds: aliasedIds,
    journalRecordNames: journalNames)
}

private func snapshot(queue: DatabaseQueue) async throws -> SharedDBSnapshot {
  try await queue.read { try fetchSharedSnapshot($0) }
}

// MARK: - Tests

@MainActor
@Suite("UnifiedIdentityAliasCleanup: rollback atomicity")
struct UnifiedIdentityAliasCleanupRollbackTests {
  /// Seeds the shared registry with a canonical row and two retired rows (both
  /// aliased), captures a snapshot before the cleanup, injects a fault that
  /// fires after the FIRST delete (inside the write transaction), and asserts
  /// the shared DB is byte-identical afterward — no row deleted, no journal
  /// entry written, PR6 flag unset.
  ///
  /// This is the release-blocking atomicity proof: if the deletes + journal
  /// writes were NOT inside a single `database.write` transaction, the fault
  /// would leave one row deleted and one journal entry written before the
  /// snapshot comparison fails.
  @Test("a throw inside the write rolls every delete and journal write back byte-identical")
  func rollbackLeavesSharedDBUnchanged() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let defaults = try #require(
      UserDefaults(suiteName: "alias-cleanup-rollback-\(UUID().uuidString)"))
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
    try await queue.write { database in
      try database.execute(
        sql: "UPDATE instrument SET alias_of = '1:native' WHERE id = '10:native'")
      try database.execute(
        sql: "UPDATE instrument SET alias_of = '1:native' WHERE id = '8453:native'")
    }
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)

    let before = try await snapshot(queue: queue)

    var cleanup = UnifiedInstrumentIdentityAliasCleanup(
      profileIndexDatabase: queue,
      userDefaults: defaults)
    cleanup.faultAfterFirstDeleteForTesting = { _ in throw AliasCleanupTestError.injected }

    await #expect(throws: AliasCleanupTestError.self) {
      try await cleanup.run()
    }

    let after = try await snapshot(queue: queue)
    // Database must be byte-identical — no partial delete survived the rollback.
    #expect(after == before)
    // PR6 flag must NOT be set (run() throws before reaching the flag write).
    #expect(!UnifiedInstrumentIdentityAliasCleanup.isComplete(in: defaults))
  }
}
