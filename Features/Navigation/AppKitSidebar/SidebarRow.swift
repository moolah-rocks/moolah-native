import Foundation

/// One row in the unified macOS sidebar `NSOutlineView`. Every visible
/// row — section header, account, group, member account, earmark,
/// total, navigation link — is represented as one of these. Equality
/// and hash key off the case identifier (`id`) so the outline view's
/// per-item diff, the expansion `Set<SidebarRow>`, and the selection
/// binding all behave under store mutations that produce a row with
/// identical contents but a fresh struct value.
enum SidebarRow: Hashable, Sendable, Identifiable {
  case section(SectionKind)
  case account(UUID)
  case group(UUID)
  case earmark(UUID)
  case total(TotalKind)
  case navigation(NavigationKind)

  enum SectionKind: Hashable, Sendable {
    case current
    case earmarks
    case investments
    case totals
    case navigation
  }

  enum TotalKind: Hashable, Sendable {
    case currentTotal
    case investmentTotal
    case earmarkedTotal
    case availableFunds
    case netWorth
  }

  enum NavigationKind: Hashable, Sendable {
    case analysis
    case reports
    case categories
    case upcoming
    case recentlyAdded
    case allTransactions
  }

  /// Stable per-case identifier — used directly as the `Identifiable.id`
  /// and as the value handed to `NSOutlineView` as the item handle.
  /// All `Hashable`-equal `SidebarRow` values share the same `id`.
  var id: String {
    switch self {
    case .section(let kind): return "section.\(kind)"
    case .account(let id): return "account.\(id.uuidString)"
    case .group(let id): return "group.\(id.uuidString)"
    case .earmark(let id): return "earmark.\(id.uuidString)"
    case .total(let kind): return "total.\(kind)"
    case .navigation(let kind): return "navigation.\(kind)"
    }
  }
}
