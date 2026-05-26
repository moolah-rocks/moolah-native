import Foundation

/// Per-profile local-only persistence for sidebar UI state on
/// `AccountGroup` rows.
///
/// The only state stored today is each group's `isExpandedInSidebar`
/// preference. The repository is intentionally narrow — it owns one
/// `Bool` per group id, nothing more. Group lifecycle (`create` /
/// `delete`) is the `AccountGroupRepository`'s responsibility; the
/// underlying GRDB FK with `ON DELETE CASCADE` reaps stale UI-state
/// rows automatically when a group is deleted, so this repo never has
/// to mirror group deletes.
///
/// Why a separate repository (rather than a field on `AccountGroup`):
/// expand state is **per-device**, never synced via CloudKit. Putting
/// it on the domain type would either force every sync record to carry
/// a field that shouldn't sync, or require model-level branching at
/// every write site. A dedicated repo keeps the sync surface clean and
/// the storage local.
///
/// Convention: methods return the **default** (`false` / empty set)
/// when no row exists. Callers never have to handle a "row missing"
/// case — groups are simply collapsed by default.
protocol GroupUIStateRepository: Sendable {
  /// Returns `true` if the group is currently expanded in the sidebar.
  /// Returns `false` when no row exists — groups default to collapsed.
  func isExpanded(groupId: UUID) async throws -> Bool

  /// Persists the expand state for a single group. Upserts on the
  /// primary key so repeated calls are idempotent.
  func setExpanded(_ expanded: Bool, for groupId: UUID) async throws

  /// Fetches the set of expanded group ids in one query. Anything not
  /// in the set is collapsed. Used to seed the sidebar binding at
  /// launch.
  func expandedGroupIds() async throws -> Set<UUID>

  /// Hot stream of expanded-id snapshots. Emits an initial snapshot and
  /// again on every persisted change to the `account_group_ui` table.
  /// Errors are surfaced out-of-band on `observeErrors()` — the value
  /// stream itself is non-throwing.
  func observeExpandedGroupIds() -> AsyncStream<Set<UUID>>

  /// Companion error stream. A healthy observation stays quiet here for
  /// its lifetime; a programmer-bug or non-recoverable I/O error from
  /// the underlying observation is yielded once and the stream
  /// completes.
  func observeErrors() -> AsyncStream<any Error>
}
