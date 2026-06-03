import Foundation

/// Persists per-`InsightKind` dismissal counts that feed `InsightRanker`'s
/// fatigue penalty. Synced across devices via CKSyncEngine so a dismissal on
/// one device downranks the kind everywhere.
///
/// Mutations go through `recordDismissal(of:)` (an atomic increment) rather
/// than a generic `create`/`update`, because the only user action is "the user
/// dismissed an insight of this kind" — there is no edit-an-arbitrary-count
/// affordance. The synchronous sync entry points the CKSyncEngine delegate
/// needs live on the concrete `GRDBInsightDismissalRepository`, not on this
/// protocol.
protocol InsightDismissalRepository: Sendable {
  /// Every persisted dismissal tally. Kinds never dismissed are absent.
  func fetchAll() async throws -> [InsightDismissal]

  /// Streams the full tally set whenever the underlying table changes
  /// (local mutation or remote sync). Initial value is the current state.
  func observeAll() -> AsyncStream<[InsightDismissal]>

  /// Out-of-band observation errors. See `guides/DATABASE_CODE_GUIDE.md` §2.
  func observeErrors() -> AsyncStream<any Error>

  /// Atomically increments the dismissal count for `kind` (creating the row
  /// with count 1 on first dismissal) and returns the updated tally.
  @discardableResult
  func recordDismissal(of kind: InsightKind) async throws -> InsightDismissal
}
