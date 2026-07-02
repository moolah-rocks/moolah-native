// MoolahTests/App/UnifiedIdentityMigrationRollbackTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

// MARK: - Error type

private enum MigrationTestError: Error, Equatable {
  case injected
}

// MARK: - Snapshot

/// Captures the instrument-id FK columns and `needs_push` flags for every
/// table touched by `rewriteProfile`. Used to prove byte-identical state
/// before and after a rolled-back write.
private struct ProfileSnapshot: Equatable {
  let legInstrumentIds: [String]
  let legNeedsPush: [Int]
  let earmarkInstrumentIds: [String]
  /// Nullable — earmark.savings_target_instrument_id is `TEXT` without NOT NULL.
  let earmarkSavingsTargetIds: [String?]
  let earmarkNeedsPush: [Int]
  let ebiInstrumentIds: [String]
  let ebiNeedsPush: [Int]
  let groupInstrumentIds: [String]
  let groupNeedsPush: [Int]
  let ivInstrumentIds: [String]
  let ivNeedsPush: [Int]
  let acctInstrumentIds: [String]
  let acctNeedsPush: [Int]
}

/// Reads `ProfileSnapshot` from all FK tables touched by `rewriteProfile`.
/// Extracted from the `queue.read` closure to stay under `closure_body_length`.
private func fetchProfileSnapshot(_ database: Database) throws -> ProfileSnapshot {
  let legIds = try String.fetchAll(
    database, sql: "SELECT instrument_id FROM transaction_leg ORDER BY rowid")
  let legNp = try Int.fetchAll(
    database, sql: "SELECT needs_push FROM transaction_leg ORDER BY rowid")
  let emkIds = try String.fetchAll(
    database, sql: "SELECT instrument_id FROM earmark ORDER BY rowid")
  let emkStIds = try Row.fetchAll(
    database, sql: "SELECT savings_target_instrument_id FROM earmark ORDER BY rowid"
  ).map { $0[0] as String? }
  let emkNp = try Int.fetchAll(
    database, sql: "SELECT needs_push FROM earmark ORDER BY rowid")
  let ebiIds = try String.fetchAll(
    database, sql: "SELECT instrument_id FROM earmark_budget_item ORDER BY rowid")
  let ebiNp = try Int.fetchAll(
    database, sql: "SELECT needs_push FROM earmark_budget_item ORDER BY rowid")
  let grpIds = try String.fetchAll(
    database, sql: "SELECT instrument_id FROM account_group ORDER BY rowid")
  let grpNp = try Int.fetchAll(
    database, sql: "SELECT needs_push FROM account_group ORDER BY rowid")
  let ivIds = try String.fetchAll(
    database, sql: "SELECT instrument_id FROM investment_value ORDER BY rowid")
  let ivNp = try Int.fetchAll(
    database, sql: "SELECT needs_push FROM investment_value ORDER BY rowid")
  let acctIds = try String.fetchAll(
    database, sql: "SELECT instrument_id FROM account ORDER BY rowid")
  let acctNp = try Int.fetchAll(
    database, sql: "SELECT needs_push FROM account ORDER BY rowid")
  return ProfileSnapshot(
    legInstrumentIds: legIds, legNeedsPush: legNp,
    earmarkInstrumentIds: emkIds, earmarkSavingsTargetIds: emkStIds, earmarkNeedsPush: emkNp,
    ebiInstrumentIds: ebiIds, ebiNeedsPush: ebiNp,
    groupInstrumentIds: grpIds, groupNeedsPush: grpNp,
    ivInstrumentIds: ivIds, ivNeedsPush: ivNp,
    acctInstrumentIds: acctIds, acctNeedsPush: acctNp)
}

private func snapshotProfile(_ queue: DatabaseQueue) async throws -> ProfileSnapshot {
  try await queue.read { try fetchProfileSnapshot($0) }
}

// MARK: - Tests

@MainActor
@Suite("UnifiedIdentityMigration: rollback atomicity")
struct UnifiedIdentityMigrationRollbackTests {
  /// Seeds a profile with rows across all six FK tables referencing retired
  /// instrument ids, captures a full snapshot before migration, injects a
  /// fault that fires after the FIRST UPDATE statement (inside the write
  /// transaction), and asserts the snapshot is byte-identical afterward.
  ///
  /// This is the RELEASE-BLOCKING safety proof: if `rewriteProfile`'s seven
  /// UPDATEs were NOT inside a single `queue.write` transaction, the fault
  /// would leave some rows rewritten and the before/after comparison would
  /// fail.
  @Test("a throw inside the profile write rolls every table back byte-identical")
  func rollbackLeavesProfileUnchanged() async throws {
    let (harness, cache) = try makeProfileRewriteHarness()
    let profileId = UUID()
    let queue = try cache.database(for: profileId)
    try await queue.write { database in try seedRetiredRows(database) }
    let before = try await snapshotProfile(queue)

    var migration = harness.migration
    migration.faultAfterFirstStatementForTesting = { _ in throw MigrationTestError.injected }
    await #expect(throws: MigrationTestError.self) {
      try await migration.rewriteProfile(
        profileId, mapping: ["10:native": "1:native", "8453:native": "1:native"])
    }

    let after = try await snapshotProfile(queue)
    #expect(after == before)  // no partial rewrite survived the rollback
  }
}
