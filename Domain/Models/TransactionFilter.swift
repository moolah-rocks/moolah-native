import Foundation

struct TransactionFilter: Sendable, Equatable {
  var accountId: UUID?
  /// Multi-account filter for composite views (e.g. an `AccountGroup`
  /// detail view rendering merged transactions across its members).
  /// Independent of `accountId`; the GRDB fetch layer ORs them together
  /// (a transaction matches if any of its legs hits `accountId` *or* any
  /// id in `accountIds`). Typical callers populate exactly one — either
  /// `accountId` (single-account view) or `accountIds` (group view).
  /// An empty set means "no multi-account filter" (treated as a no-op
  /// by the fetch layer).
  var accountIds: Set<UUID>
  var earmarkId: UUID?
  var scheduled: ScheduledFilter
  var dateRange: ClosedRange<Date>?
  var categoryIds: Set<UUID>
  var payee: String?

  init(
    accountId: UUID? = nil,
    accountIds: Set<UUID> = [],
    earmarkId: UUID? = nil,
    scheduled: ScheduledFilter = .all,
    dateRange: ClosedRange<Date>? = nil,
    categoryIds: Set<UUID> = [],
    payee: String? = nil
  ) {
    self.accountId = accountId
    self.accountIds = accountIds
    self.earmarkId = earmarkId
    self.scheduled = scheduled
    self.dateRange = dateRange
    self.categoryIds = categoryIds
    self.payee = payee
  }
}

extension TransactionFilter {
  var hasActiveFilters: Bool {
    accountId != nil || !accountIds.isEmpty || earmarkId != nil
      || scheduled != .all
      || dateRange != nil || !categoryIds.isEmpty || payee != nil
  }

  /// True when *any* account-scoped predicate is present — a single
  /// `accountId` (single-account view) or a non-empty `accountIds` set
  /// (account-group view). Views use this to choose between in-scope and
  /// all-legs account context when labelling transaction rows
  /// (`TransactionListView`'s `accountContext(for:)`). Both scopes carry a
  /// running balance; the GRDB running-balance gate keys off
  /// `FetchSnapshot.hasAccountFilter`, not this property.
  var hasAccountFilter: Bool {
    accountId != nil || !accountIds.isEmpty
  }
}
