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
  /// Type-scoped drill-down filter for the Reports "Uncategorised" row:
  /// when set, restricts the result to transactions having a leg with
  /// `categoryId == nil` and this `TransactionType`.
  var uncategorizedLegType: TransactionType?

  init(
    accountId: UUID? = nil,
    accountIds: Set<UUID> = [],
    earmarkId: UUID? = nil,
    scheduled: ScheduledFilter = .all,
    dateRange: ClosedRange<Date>? = nil,
    categoryIds: Set<UUID> = [],
    payee: String? = nil,
    uncategorizedLegType: TransactionType? = nil
  ) {
    self.accountId = accountId
    self.accountIds = accountIds
    self.earmarkId = earmarkId
    self.scheduled = scheduled
    self.dateRange = dateRange
    self.categoryIds = categoryIds
    self.payee = payee
    self.uncategorizedLegType = uncategorizedLegType
  }
}

extension TransactionFilter {
  var hasActiveFilters: Bool {
    accountId != nil || !accountIds.isEmpty || earmarkId != nil
      || scheduled != .all
      || dateRange != nil || !categoryIds.isEmpty || payee != nil
      || uncategorizedLegType != nil
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

extension TransactionFilter {
  /// Returns the `accountIds` set to store on the filter, given a
  /// scope-aware account-picker selection.
  ///
  /// `selection` follows the multi-select convention where an empty set
  /// means "all available". Both an empty selection and a selection that
  /// covers every available account resolve to `scope` — so applying a
  /// filter inside an account group can never widen the result past the
  /// group's members. A global view (empty `scope`) resolves the same
  /// "all" cases back to an empty set, i.e. all accounts. A strict subset
  /// is stored verbatim.
  static func scopedAccountIds(
    forSelection selection: Set<UUID>,
    scope: Set<UUID>,
    available: Set<UUID>
  ) -> Set<UUID> {
    if selection.isEmpty || selection == available {
      return scope
    }
    return selection
  }
}
