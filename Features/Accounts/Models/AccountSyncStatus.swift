import Foundation

/// Per-account sync state snapshot used to build an `AggregatedSyncStatus`
/// over a context's `accountIds`. Built from `SyncedAccountStore`'s
/// `inProgressAccountIds` and `statePerAccount[id]?.lastError` so the
/// context-builder doesn't need to know the underlying store shape.
struct AccountSyncStatus: Sendable, Equatable {
  let accountId: UUID
  let isInProgress: Bool
  let hasError: Bool
}
