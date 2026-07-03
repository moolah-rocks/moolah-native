import Foundation

// Provider-neutral sync-source resolution for `SyncedAccountStore`.
extension SyncedAccountStore {

  /// The first registered `AccountSyncSource` that claims `account`, or `nil`
  /// if none do. Centralises the provider-neutral lookup so the store never
  /// branches on `account.type` itself; shared with `accountsToSync`.
  func source(for account: Account) -> (any AccountSyncSource)? {
    sources.first(where: { $0.handles(account) })
  }
}
