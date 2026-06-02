import Foundation

/// Maps an insight's deep-link references onto a `SidebarSelection`, so the
/// "For You" panel can navigate to the entity an insight is about. Pure and
/// unit-tested; lives in the Features layer because `SidebarSelection` is a
/// navigation type the Domain layer (where `InsightReferences` lives) must
/// not depend on.
///
/// Priority — account → earmark → group → categories — picks the most
/// specific destination when an insight references several. Insights that
/// reference only an instrument or a transaction have no sidebar destination
/// (there is no per-instrument or per-transaction sidebar row), so they
/// return `nil` and the row shows no navigation affordance.
enum InsightNavigationTarget {
  static func sidebarSelection(for references: InsightReferences) -> SidebarSelection? {
    if let accountId = references.accountIds.first {
      return .account(accountId)
    }
    if let earmarkId = references.earmarkIds.first {
      return .earmark(earmarkId)
    }
    if let groupId = references.groupIds.first {
      return .group(groupId)
    }
    if !references.categoryIds.isEmpty {
      return .categories
    }
    return nil
  }
}
