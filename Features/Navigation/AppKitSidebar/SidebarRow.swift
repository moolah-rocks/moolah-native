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

extension SidebarRow {
  /// The parent `SidebarSelection?` value that corresponds to this
  /// row, or `nil` if the row is non-selectable (sections, totals).
  var asSelection: SidebarSelection? {
    switch self {
    case .section, .total: return nil
    case .account(let id): return .account(id)
    case .group(let id): return .group(id)
    case .earmark(let id): return .earmark(id)
    case .navigation(let kind): return kind.asSelection
    }
  }

  /// The `SidebarRow` that corresponds to the given selection. Every
  /// `SidebarSelection` case maps to a row, so this is non-failable —
  /// the optional-init signature is preserved purely for symmetry with
  /// `asSelection` (which can be nil for non-selectable rows).
  init?(selection: SidebarSelection) {
    switch selection {
    case .account(let id): self = .account(id)
    case .group(let id): self = .group(id)
    case .earmark(let id): self = .earmark(id)
    case .analysis: self = .navigation(.analysis)
    case .reports: self = .navigation(.reports)
    case .categories: self = .navigation(.categories)
    case .upcomingTransactions: self = .navigation(.upcoming)
    case .recentlyAdded: self = .navigation(.recentlyAdded)
    case .allTransactions: self = .navigation(.allTransactions)
    }
  }
}

extension SidebarRow.NavigationKind {
  /// The `SidebarSelection` value that corresponds to this navigation
  /// kind. Split out from `SidebarRow.asSelection` so the parent switch
  /// stays under SwiftLint's `cyclomatic_complexity` threshold.
  var asSelection: SidebarSelection {
    switch self {
    case .analysis: return .analysis
    case .reports: return .reports
    case .categories: return .categories
    case .upcoming: return .upcomingTransactions
    case .recentlyAdded: return .recentlyAdded
    case .allTransactions: return .allTransactions
    }
  }
}
