import Foundation
import GRDB
import Testing

@testable import Moolah

/// Rollback contract tests for the multi-statement writes on
/// `GRDBTransferSuggestionRepository`. Each method opens a single
/// transaction that touches more than one row; if any statement fails,
/// prior state must survive byte-equal. Mirrors the BEFORE-trigger
/// sentinel pattern used in `CSVImportRollbackTests` so the production
/// code path is exercised end-to-end (not a hand-rolled mirror).
@Suite("Transfer suggestion GRDB rollback contracts")
struct TransferSuggestionRollbackTests {

  // MARK: - applyRemoteChangesSync(saved:deleted:) — saved batch

  @Test
  func applyRemoteChangesSavedBatchRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBTransferSuggestionRepository(database: database)
    let prior = makeSuggestionRow(txA: UUID(), txB: UUID())
    try await database.write { database in
      try prior.insert(database)
    }

    // Trigger that aborts the second insert when the record name
    // matches the sentinel. The first row in the batch upserts
    // successfully; the trigger fires inside `applyRemoteChangesSync`'s
    // single transaction so all statements (including the upsert that
    // already touched the prior row) must roll back.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_transfer_suggestion_upsert
          BEFORE INSERT ON transfer_suggestion
          WHEN NEW.record_name = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // First row mutates the prior row (same id → upsert UPDATE);
    // second row trips the sentinel trigger.
    var mutatingSeed = prior
    mutatingSeed.suggestedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let mutating = mutatingSeed
    let failing = makeSentinelRow(txA: UUID(), txB: UUID())
    do {
      try repo.applyRemoteChangesSync(saved: [mutating, failing], deleted: [])
      Issue.record("applyRemoteChangesSync should have thrown but did not")
    } catch {
      // Expected — trigger raises ABORT.
    }

    let surviving = try await database.read { database in
      try TransferSuggestionRow
        .filter(TransferSuggestionRow.Columns.id == prior.id)
        .fetchOne(database)
    }
    let row = try #require(surviving)
    // The mutated value from the failed batch must NOT have landed —
    // the prior row's suggestedAt survives byte-equal.
    #expect(row.suggestedAt == prior.suggestedAt)
  }

  // MARK: - applyRemoteChangesSync(saved:deleted:) — delete batch

  @Test
  func applyRemoteChangesDeleteBatchRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBTransferSuggestionRepository(database: database)
    let first = makeSuggestionRow(txA: UUID(), txB: UUID())
    let second = makeSentinelRow(txA: UUID(), txB: UUID())
    try await database.write { database in
      try first.insert(database)
      try second.insert(database)
      // The second id's row carries the sentinel record name; the
      // trigger aborts any DELETE that would remove it. The delete
      // batch removes both ids, so the first row's DELETE succeeds
      // inside the single transaction and the second row's DELETE trips
      // the trigger — the entire transaction must roll back, leaving
      // BOTH rows intact.
      try database.execute(
        sql: """
          CREATE TRIGGER fail_transfer_suggestion_delete
          BEFORE DELETE ON transfer_suggestion
          WHEN OLD.record_name = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    do {
      try repo.applyRemoteChangesSync(saved: [], deleted: [first.id, second.id])
      Issue.record("applyRemoteChangesSync should have thrown but did not")
    } catch {
      // Expected.
    }

    try await database.read { database in
      let firstSurvivor =
        try TransferSuggestionRow
        .filter(TransferSuggestionRow.Columns.id == first.id)
        .fetchOne(database)
      let secondSurvivor =
        try TransferSuggestionRow
        .filter(TransferSuggestionRow.Columns.id == second.id)
        .fetchOne(database)
      // The rolled-back first DELETE did NOT leave the first row gone.
      #expect(firstSurvivor != nil)
      #expect(secondSurvivor != nil)
    }
  }

  // MARK: - setEncodedSystemFieldsBatchSync

  @Test
  func setEncodedSystemFieldsBatchRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBTransferSuggestionRepository(database: database)
    var firstSeed = makeSuggestionRow(txA: UUID(), txB: UUID())
    firstSeed.encodedSystemFields = Data([0xAA, 0xBB])
    var secondSeed = makeSentinelRow(txA: UUID(), txB: UUID())
    secondSeed.encodedSystemFields = Data([0xCC, 0xDD])
    let first = firstSeed
    let second = secondSeed
    try await database.write { database in
      try first.insert(database)
      try second.insert(database)
      // The second row carries the sentinel record name; the trigger
      // aborts the UPDATE that would touch it. The batch updates both
      // ids, so the first row's UPDATE succeeds inside the single
      // transaction and the second row's UPDATE trips the trigger — the
      // entire transaction must roll back, leaving the first row's
      // encoded_system_fields unchanged on disk.
      try database.execute(
        sql: """
          CREATE TRIGGER fail_transfer_suggestion_sysfields_update
          BEFORE UPDATE ON transfer_suggestion
          WHEN OLD.record_name = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    do {
      _ = try repo.setEncodedSystemFieldsBatchSync([
        (id: first.id, data: Data([0x01])),
        (id: second.id, data: Data([0x02])),
      ])
      Issue.record("setEncodedSystemFieldsBatchSync should have thrown but did not")
    } catch {
      // Expected.
    }

    let surviving = try await database.read { database in
      try TransferSuggestionRow
        .filter(TransferSuggestionRow.Columns.id == first.id)
        .fetchOne(database)
    }
    let row = try #require(surviving)
    // The first row's blob must be byte-equal to its pre-batch value —
    // the rolled-back UPDATE did NOT land its `Data([0x01])`.
    #expect(row.encodedSystemFields == Data([0xAA, 0xBB]))
  }

  // MARK: - Helpers

  private func makeSuggestionRow(txA: UUID, txB: UUID) -> TransferSuggestionRow {
    TransferSuggestionRow(
      domain: TransferSuggestion(
        transactionIds: [txA, txB],
        suggestedAt: Date(timeIntervalSince1970: 1_700_000_000)))
  }

  /// A row whose `record_name` carries the `___FAIL___` sentinel so the
  /// BEFORE-trigger fires only for this (second) batch entry.
  private func makeSentinelRow(txA: UUID, txB: UUID) -> TransferSuggestionRow {
    var row = makeSuggestionRow(txA: txA, txB: txB)
    row.recordName = "___FAIL___"
    return row
  }
}
