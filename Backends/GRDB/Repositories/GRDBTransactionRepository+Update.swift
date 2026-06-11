// Backends/GRDB/Repositories/GRDBTransactionRepository+Update.swift

import Foundation
import GRDB

extension GRDBTransactionRepository {
  // MARK: - Update pipeline

  struct UpdateOutcome: Sendable {
    let deletedLegIds: [UUID]
    let upsertedLegIds: [UUID]
  }

  private struct LegDiff: Sendable {
    let deletedIds: [UUID]
    let existingFieldsByLegId: [UUID: Data?]
  }

  /// Fetches the persisted leg rows for `transactionId`, snapshots their
  /// `encodedSystemFields` blobs by id, deletes any legs absent from
  /// `newLegIds`, and returns the deleted ids plus the field map so the
  /// upsert pass can re-attach each surviving leg's blob.
  private static func computeLegDiff(
    database: Database,
    transactionId: UUID,
    newLegIds: Set<UUID>
  ) throws -> LegDiff {
    let existingRows =
      try TransactionLegRow
      .filter(TransactionLegRow.Columns.transactionId == transactionId)
      .fetchAll(database)
    let oldLegIds: Set<UUID> = Set(existingRows.map(\.id))
    let existingFieldsByLegId: [UUID: Data?] = Dictionary(
      uniqueKeysWithValues: existingRows.map { ($0.id, $0.encodedSystemFields) })
    let deletedLegIds = oldLegIds.subtracting(newLegIds)

    if !deletedLegIds.isEmpty {
      _ =
        try TransactionLegRow
        .filter(deletedLegIds.contains(TransactionLegRow.Columns.id))
        .deleteAll(database)
    }

    return LegDiff(
      deletedIds: Array(deletedLegIds),
      existingFieldsByLegId: existingFieldsByLegId)
  }

  /// Single-statement body of `update`'s `database.write { … }`
  /// closure. Looks up the existing header row, applies the domain
  /// fields, diffs the supplied legs against the persisted set by
  /// stable id, and returns the deleted/upserted leg ids so the caller
  /// can fan out the right hooks after the transaction commits.
  ///
  /// Diff-by-id (rather than delete-then-insert with fresh UUIDs)
  /// preserves leg `id`s and each leg's cached
  /// `encoded_system_fields` blob across saves. Without that
  /// preservation, every header-only edit would tear down the leg
  /// rows, drop their CK system fields, and the next sync pass would
  /// re-upload the whole thing as if unsynced
  /// (`unsyncedRowIdsSync` filters on `encoded_system_fields IS NULL`).
  static func performUpdate(
    database: Database,
    transaction: Transaction
  ) throws -> UpdateOutcome {
    guard
      var existing =
        try TransactionRow
        .filter(TransactionRow.Columns.id == transaction.id)
        .fetchOne(database)
    else {
      throw BackendError.notFound("Transaction not found")
    }
    applyMetadata(of: transaction, to: &existing)
    try existing.update(database)
    try markTransactionNeedsPush(id: transaction.id, in: database)

    let newLegIds: Set<UUID> = Set(transaction.legs.map(\.id))
    let diff = try Self.computeLegDiff(
      database: database,
      transactionId: transaction.id,
      newLegIds: newLegIds)
    // Durable deletion intents (issue #1090) for legs removed by this edit —
    // `computeLegDiff` has already deleted their rows in this txn.
    for legId in diff.deletedIds {
      try recordLegDeletion(legId, in: database)
    }

    // Upsert every leg in the new array. Idempotent for unchanged
    // rows; updates `sort_order` for legs that moved; inserts new
    // legs. Order: deletions first so the
    // `(transaction_id, sort_order)` pair is never transiently
    // duplicated by a moving leg landing on a soon-to-be-deleted
    // leg's slot. There is no UNIQUE(transaction_id, sort_order)
    // constraint so this is defensive rather than required, but it
    // keeps the intermediate state consistent for any future
    // debugger snapshot.
    var upsertedLegIds: [UUID] = []
    upsertedLegIds.reserveCapacity(transaction.legs.count)
    for (index, leg) in transaction.legs.enumerated() {
      var legRow = TransactionLegRow(
        id: leg.id,
        domain: leg,
        transactionId: transaction.id,
        sortOrder: index)
      // Re-attach the cached CK system fields blob for legs that
      // already existed; new legs land with `nil` and the sync layer
      // stamps them after the first successful upload.
      if let existingFields = diff.existingFieldsByLegId[leg.id] {
        legRow.encodedSystemFields = existingFields
      }
      try legRow.upsert(database)
      try markLegNeedsPush(id: leg.id, in: database)
      upsertedLegIds.append(leg.id)
    }

    // D1-b (issue #1090): the (re-)written header and its current legs drop any
    // stale deletion intents in the same write.
    try clearDeletionIntents(for: transaction, in: database)

    return UpdateOutcome(
      deletedLegIds: diff.deletedIds,
      upsertedLegIds: upsertedLegIds)
  }

  /// Rewrites the row from the domain transaction, preserving the
  /// CloudKit system-fields blob. Using the canonical encoder keeps
  /// every denormalised column (incl. import-origin discriminator and
  /// transfer-suggestion) in sync without per-column maintenance.
  private static func applyMetadata(
    of transaction: Transaction, to row: inout TransactionRow
  ) {
    let savedSystemFields = row.encodedSystemFields
    row = TransactionRow(domain: transaction)
    row.encodedSystemFields = savedSystemFields
  }
}
