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
      try ProfileRow
        .filter(Set(ids).contains(ProfileRow.Columns.id))
        .updateAll(database, [ProfileRow.Columns.needsPush.set(to: false)])
    }
  }
}
