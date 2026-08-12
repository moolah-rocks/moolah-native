import Foundation

/// Destination for opening the evidence behind a "For You" observation.
/// Transaction-backed insights open All Transactions with a preset filter;
/// entity-backed insights open the relevant detail screen.
///
/// Priority — explicit transaction filter → earmark → group → category
/// transactions → account — preserves purpose-built budget/group screens
/// while ensuring observations backed by categorized activity open the
/// relevant transactions rather than a broad entity or category editor.
enum InsightNavigationTarget: Equatable {
  case sidebar(SidebarSelection)
  case transactions(TransactionFilter)

  static func target(for insight: Insight) -> Self? {
    let references = insight.references
    if let filter = references.transactionFilter {
      return .transactions(filter)
    }
    if let earmarkId = references.earmarkIds.first {
      return .sidebar(.earmark(earmarkId))
    }
    if let groupId = references.groupIds.first {
      return .sidebar(.group(groupId))
    }
    if !references.categoryIds.isEmpty {
      return .transactions(
        TransactionFilter(
          scheduled: .nonScheduledOnly,
          categoryIds: Set(references.categoryIds)))
    }
    if let accountId = references.accountIds.first {
      return .sidebar(.account(accountId))
    }
    return nil
  }
}
