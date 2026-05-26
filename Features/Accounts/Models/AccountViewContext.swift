import Foundation

/// What the detail view renders. Built from `SidebarSelection`; the detail
/// view binds to this rather than reading `Account` directly. Selecting a
/// group produces a context with N member ids; selecting a single account
/// produces a 1-element list. Same code path serves both.
///
/// Order of `accountIds` is preserved so the "first account in this
/// context" (e.g. the default for the New Transaction button) is
/// deterministic.
struct AccountViewContext: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case account
    case group
  }

  let kind: Kind
  let displayName: String
  /// Instrument the detail view displays totals in. For accounts this is
  /// the account's `instrument`; for groups it's the group's `instrument`
  /// (defaults to the profile's currency in Phase 3).
  let displayInstrument: Instrument
  /// The bucket the entity lives in. Drives any UI affordances that
  /// differ across buckets (e.g. valuation-mode toggle only shows for
  /// `.investments`).
  let bucket: AccountBucket
  /// The set of accounts whose data the detail view aggregates over.
  /// Single account → `[account.id]`. Group → member ids in member-
  /// position order. Order is preserved so callers that need a default
  /// member (e.g. New Transaction button) can take `accountIds.first`.
  let accountIds: [UUID]
  /// Aggregated sync status across `accountIds`. A 1-element input
  /// collapses to the underlying per-account status unchanged, so the
  /// same path serves single-account headers.
  let syncStatus: AggregatedSyncStatus

  /// True when this context represents a single account that itself has
  /// members in `accountIds`. Used to gate per-account sync-config UI
  /// (retry button, last-sync indicator) that doesn't make sense for
  /// groups (or for a transient zero-member context).
  var supportsPerAccountSyncControls: Bool {
    kind == .account && accountIds.count == 1
  }
}
