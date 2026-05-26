// Backends/GRDB/Repositories/GRDBGroupUIStateRepository.swift

import Foundation
import GRDB

/// GRDB-backed implementation of `GroupUIStateRepository`. Stores the
/// per-device sidebar expand / collapse state for `AccountGroup` rows in
/// the local `account_group_ui` table (v15 migration). NOT synced via
/// CKSyncEngine.
///
/// Implemented as a `Sendable` struct (not a `final class` with
/// `@unchecked Sendable`) per CONCURRENCY_GUIDE §2: the only stored
/// properties are `let database: any DatabaseWriter` and a shared
/// `ObservationErrorChannel` (an `actor`, implicitly `Sendable`). No
/// mutable state, no observation fan-out — none of the genuine reasons
/// that force `@unchecked` in the synced repositories.
///
/// Same lifetime model as `GRDBWalletSyncStateRepository`: built once
/// per `CloudKitBackend` from the same `DatabaseWriter` that every other
/// per-profile repo uses, so all writes route through the queue's
/// serial executor and observations share the same change-notification
/// surface as the rest of the per-profile graph.
struct GRDBGroupUIStateRepository: GroupUIStateRepository, Sendable {
  private let database: any DatabaseWriter
  private let errorChannel = ObservationErrorChannel()

  init(database: any DatabaseWriter) {
    self.database = database
  }

  func isExpanded(groupId: UUID) async throws -> Bool {
    try await database.read { database in
      try Bool.fetchOne(
        database,
        sql: "SELECT is_expanded FROM account_group_ui WHERE group_id = ?",
        arguments: [groupId]) ?? false
    }
  }

  func setExpanded(_ expanded: Bool, for groupId: UUID) async throws {
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO account_group_ui (group_id, is_expanded) VALUES (?, ?)
          ON CONFLICT(group_id) DO UPDATE SET is_expanded = excluded.is_expanded
          """,
        arguments: [groupId, expanded])
    }
  }

  func expandedGroupIds() async throws -> Set<UUID> {
    try await database.read { database in
      let ids = try UUID.fetchAll(
        database,
        sql: "SELECT group_id FROM account_group_ui WHERE is_expanded = 1")
      return Set(ids)
    }
  }

  /// Streams the set of expanded group ids. Emits an initial snapshot
  /// and again on every change to the `account_group_ui` table. The
  /// table has no sync-bookkeeping columns (it's local-only), so the
  /// full-table tracking region is fine — no `observableRegion`
  /// allowlist is needed.
  func observeExpandedGroupIds() -> AsyncStream<Set<UUID>> {
    ValueObservation
      .tracking { database in
        let ids = try UUID.fetchAll(
          database,
          sql: "SELECT group_id FROM account_group_ui WHERE is_expanded = 1")
        return Set(ids)
      }
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBGroupUIStateRepository.observeExpandedGroupIds")
  }

  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
