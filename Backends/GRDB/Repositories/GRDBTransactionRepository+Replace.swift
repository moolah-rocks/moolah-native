import Foundation
import GRDB

extension GRDBTransactionRepository {
  /// Atomic delete-then-create. Deletes every `deletingIds` transaction
  /// (legs first, then the header — the schema has no FK CASCADE on
  /// `transaction_leg.transaction_id`, so legs are removed explicitly,
  /// mirroring `delete(id:)`) and inserts every `creating` transaction,
  /// all inside one `database.write { … }`. On any throw the whole
  /// write rolls back, so a transfer collapse / split can never leave
  /// half the rows on disk. Non-fiat leg instruments are registered
  /// before the write for the same cross-database reason as `create`.
  /// Post-commit hooks fan out per deleted and per created row, matching
  /// `delete(id:)` / `createMany(_:)`.
  ///
  /// When a `creating` transaction (or one of its legs) REUSES a
  /// `deletingIds` row's id — any caller that rewrites a row under its own
  /// id — the deleted row's cached `encoded_system_fields` blob is
  /// snapshotted (strictly per record type) and re-attached to the
  /// re-created row, and the self-queued `.deleteRecord` for that id is
  /// suppressed. Without that, the re-created row would land with a `nil`
  /// cache; once it goes clean the #1085 modification-date gate fails open
  /// and a stale self-echo clobbers it back to the deleted version (the
  /// placeholder-revert data loss — issue #1090). Headers and legs whose ids
  /// are NOT reused are deleted and fan out a `.deleteRecord`.
  ///
  /// A re-attached blob carries the change tag of the server's last-seen
  /// version of that id, so the row's re-upload is a normal conditional
  /// update on the existing record — not a fresh create that CloudKit would
  /// reject with `.serverRecordChanged`. A genuine cross-device conflict is
  /// still resolved by the existing conflict path; nothing here is new.
  func replace(
    deletingIds: [UUID],
    creating: [Transaction]
  ) async throws -> [Transaction] {
    try await Self.registerNonFiatLegInstruments(
      creating.flatMap(\.legs), using: instrumentRegistrar)

    let outcome = try await database.write { database -> ReplaceOutcome in
      let snapshot = try Self.deleteAndSnapshot(
        deletingIds: deletingIds, in: database)
      let createdLegIds = try Self.performCreateMany(
        database: database,
        transactions: creating,
        preservedTransactionFields: snapshot.preservedTransactionFields,
        preservedLegFields: snapshot.preservedLegFields)
      // Durable deletion intents (issue #1090) for headers/legs deleted and
      // NOT re-created here. `performCreateMany` already cleared intents for
      // the re-created ids (D1-b), so a tombstone is left only for
      // genuinely-removed rows — mirroring the `.deleteRecord` suppression.
      try Self.recordReplaceDeletions(
        deletingIds: deletingIds,
        deletedLegIds: snapshot.deletedLegIds,
        creating: creating,
        createdLegIds: createdLegIds,
        in: database)
      return ReplaceOutcome(
        deletedLegIds: snapshot.deletedLegIds, createdLegIds: createdLegIds)
    }

    // Post-commit fan-out order: all deleted headers, then all deleted
    // legs, then all created headers, then all created legs. The sync
    // engine processes each emit independently by `(recordType, id)`,
    // so this grouped order is observationally equivalent to the
    // per-transaction header-then-legs order `delete(id:)` uses.
    //
    // Suppress the `.deleteRecord` for any id re-created in this same
    // `replace`: the re-create already emits a `.saveRecord` (an upsert) for
    // the reused id, so also queuing a delete would race a stale delete
    // against that save. Genuinely-removed ids still fan out a delete.
    let recreatedTransactionIds = Set(creating.map(\.id))
    let recreatedLegIds = Set(outcome.createdLegIds)
    for id in deletingIds where !recreatedTransactionIds.contains(id) {
      onRecordDeleted(TransactionRow.recordType, id)
    }
    for legId in outcome.deletedLegIds where !recreatedLegIds.contains(legId) {
      onRecordDeleted(TransactionLegRow.recordType, legId)
    }
    for transaction in creating {
      onRecordChanged(TransactionRow.recordType, transaction.id)
    }
    for legId in outcome.createdLegIds {
      onRecordChanged(TransactionLegRow.recordType, legId)
    }
    return creating
  }

  /// Records durable deletion intents (issue #1090) for the headers and legs
  /// that `replace` deleted and did NOT re-create. Re-created ids are skipped
  /// (their intents were already cleared by `performCreateMany`), mirroring the
  /// post-commit `.deleteRecord` suppression so the journal and the queued CK
  /// deletes agree exactly.
  private static func recordReplaceDeletions(
    deletingIds: [UUID],
    deletedLegIds: [UUID],
    creating: [Transaction],
    createdLegIds: [UUID],
    in database: Database
  ) throws {
    let recreatedTransactionIds = Set(creating.map(\.id))
    let recreatedLegIds = Set(createdLegIds)
    for id in deletingIds where !recreatedTransactionIds.contains(id) {
      try DeletionJournal.recordDataDeletion(
        recordName: TransactionRow.recordName(for: id),
        recordType: TransactionRow.recordType,
        at: Date(),
        in: database)
    }
    for legId in deletedLegIds where !recreatedLegIds.contains(legId) {
      try recordLegDeletion(legId, in: database)
    }
  }

  /// Deletes every `deletingIds` transaction (legs first, then the header) and,
  /// in the same pass, snapshots each deleted row's cached
  /// `encoded_system_fields` blob — strictly per record type — so `replace`
  /// can re-attach a blob to any re-created same-id row. Throws
  /// `BackendError.notFound` if a header id is absent, preserving the original
  /// all-or-nothing contract.
  private static func deleteAndSnapshot(
    deletingIds: [UUID], in database: Database
  ) throws -> ReplaceDeletionSnapshot {
    var deletedLegIds: [UUID] = []
    var preservedTransactionFields: [UUID: Data?] = [:]
    var preservedLegFields: [UUID: Data?] = [:]
    for id in deletingIds {
      let legRows =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == id)
        .fetchAll(database)
      let legIds = legRows.map(\.id)
      for legRow in legRows {
        preservedLegFields[legRow.id] = legRow.encodedSystemFields
      }
      if !legIds.isEmpty {
        _ =
          try TransactionLegRow
          .filter(legIds.contains(TransactionLegRow.Columns.id))
          .deleteAll(database)
      }
      // Snapshot the header's blob before the row is removed.
      if let headerRow =
        try TransactionRow
        .filter(TransactionRow.Columns.id == id)
        .fetchOne(database)
      {
        preservedTransactionFields[id] = headerRow.encodedSystemFields
      }
      let didDelete = try TransactionRow.deleteOne(database, id: id)
      guard didDelete else {
        throw BackendError.notFound("Transaction not found")
      }
      deletedLegIds.append(contentsOf: legIds)
    }
    return ReplaceDeletionSnapshot(
      deletedLegIds: deletedLegIds,
      preservedTransactionFields: preservedTransactionFields,
      preservedLegFields: preservedLegFields)
  }
}

/// The deleted-side result of one `replace` write: the leg ids removed plus
/// the per-record-type cached-blob snapshots used to re-attach a reused id's
/// CloudKit system fields to its re-created row.
private struct ReplaceDeletionSnapshot: Sendable {
  let deletedLegIds: [UUID]
  let preservedTransactionFields: [UUID: Data?]
  let preservedLegFields: [UUID: Data?]
}

/// Per-write tally of the leg ids touched by `replace`, carried out of
/// the `database.write` closure so the post-commit sync hooks fan out
/// after the transaction commits (a hook fired inside the write would
/// observe rows that a later rollback discards).
private struct ReplaceOutcome: Sendable {
  let deletedLegIds: [UUID]
  let createdLegIds: [UUID]
}
