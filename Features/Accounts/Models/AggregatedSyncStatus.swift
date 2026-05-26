import Foundation

/// Aggregate of the per-member `AccountSyncStatus` values that make up an
/// `AccountViewContext`. A 1-element input collapses to the underlying
/// per-account status (synced → `.allSynced`, in-progress → `.syncing(0,
/// 1)`, error → `.failed(memberIds: [id])`) so the same path serves
/// single-account headers and composite group headers.
enum AggregatedSyncStatus: Sendable, Equatable {
  case allSynced
  case syncing(done: Int, total: Int)
  case failed(memberIds: [UUID])

  /// Collapses an array of per-member statuses to a single aggregate.
  /// Precedence: any failure → `.failed`; otherwise any in-progress →
  /// `.syncing(done:total:)`; otherwise `.allSynced`. Empty input
  /// returns `.allSynced` so a non-syncable context (no members claim
  /// the sync surface) is silently silent.
  static func aggregate(_ statuses: [AccountSyncStatus]) -> AggregatedSyncStatus {
    if statuses.isEmpty { return .allSynced }
    let failed = statuses.filter(\.hasError).map(\.accountId)
    if !failed.isEmpty { return .failed(memberIds: failed) }
    let inProgress = statuses.filter(\.isInProgress).count
    if inProgress > 0 {
      return .syncing(done: statuses.count - inProgress, total: statuses.count)
    }
    return .allSynced
  }
}
