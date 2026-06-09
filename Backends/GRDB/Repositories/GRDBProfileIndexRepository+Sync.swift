// Backends/GRDB/Repositories/GRDBProfileIndexRepository+Sync.swift

import Foundation
import GRDB

// MARK: - needs_push dirty-flag helpers (issue #1081)
//
// Mirror the per-profile repositories' `+Sync.swift` helpers. The
// `profile` table carries the same local-only `needs_push` column (v4
// migration). Kept in a separate file from the main repository so the
// main file stays under the 400-line limit.

extension GRDBProfileIndexRepository {
  /// Sets `needs_push = 1` for `id` inside the caller's write transaction.
  /// See `GRDBAccountRepository.markNeedsPushSync(id:in:)` (issue #1081).
  func markNeedsPushSync(id: UUID, in database: Database) throws {
    _ =
      try ProfileRow
      .filter(ProfileRow.Columns.id == id)
      .updateAll(database, [ProfileRow.Columns.needsPush.set(to: true)])
  }

  /// Self-opening convenience for callers outside an apply transaction
  /// (tests, and the upload-ack path's clear). Opens its own write.
  func markNeedsPushSync(id: UUID) throws {
    try database.write { database in try markNeedsPushSync(id: id, in: database) }
  }

  /// In-transaction profile upsert/delete (mirrors the self-write
  /// `applyRemoteChangesSync(saved:deleted:)` on the main repository).
  /// Runs against the caller's `database` so the dirty check and the
  /// upsert share one transaction (issue #1081 — no echo race).
  func applyRemoteChangesSync(
    saved rows: [ProfileRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows { try row.upsert(database) }
    for id in ids { _ = try ProfileRow.deleteOne(database, id: id) }
  }

  /// In-transaction system-fields-only write (change tag), for dirty
  /// profile echoes that must NOT have their field values overwritten.
  /// Runs against the caller's `database` so it shares the apply
  /// transaction (issue #1081).
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)], in database: Database
  ) throws {
    for (id, data) in updates {
      _ =
        try ProfileRow
        .filter(ProfileRow.Columns.id == id)
        .updateAll(database, [ProfileRow.Columns.encodedSystemFields.set(to: data)])
    }
  }

  /// Subset of `ids` whose profile row currently has `needs_push = 1`,
  /// read inside the caller's transaction.
  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let idSet = Set(ids)
    return Set(
      try ProfileRow
        .filter(idSet.contains(ProfileRow.Columns.id))
        .filter(ProfileRow.Columns.needsPush == true)
        .select(ProfileRow.Columns.id, as: UUID.self)
        .fetchAll(database))
  }

  func dirtyIdsSync(from ids: [UUID]) throws -> Set<UUID> {
    try database.read { database in try dirtyIdsSync(from: ids, in: database) }
  }

  /// Clears `needs_push` for the given ids in one transaction. Returns the
  /// number of rows updated.
  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID]) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return try database.write { database in
      try clearNeedsPushBatchSync(ids, in: database)
    }
  }

  /// In-transaction counterpart to `clearNeedsPushBatchSync(_:)`. Runs
  /// against the caller's active `database` so the upload-ack path can
  /// re-read the profile row, compare it to the sent record, and clear the
  /// flag all inside one transaction — no window for a concurrent rename
  /// to interleave between compare and clear (issue #1081).
  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID], in database: Database) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return
      try ProfileRow
      .filter(Set(ids).contains(ProfileRow.Columns.id))
      .updateAll(database, [ProfileRow.Columns.needsPush.set(to: false)])
  }

  /// In-transaction row lookup, mirroring the main repository's
  /// `fetchRowSync(id:)` self-read. Reads against the caller's `database`
  /// so the ack-clear compare-and-clear shares one transaction (#1081).
  func fetchRowSync(id: UUID, in database: Database) throws -> ProfileRow? {
    try ProfileRow
      .filter(ProfileRow.Columns.id == id)
      .fetchOne(database)
  }
}
