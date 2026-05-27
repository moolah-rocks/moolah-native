import Foundation

/// One node in the macOS sidebar outline. Each `SidebarOutlineView`
/// instance renders the contents of a single `AccountBucket` (Current
/// or Investments) — section chrome ("Current Accounts" /
/// "Investments") is supplied by the surrounding SwiftUI `Section`,
/// not as items in the tree. Root-level items are therefore the
/// bucket's standalone accounts + groups intermixed by `position`,
/// matching `Accounts.groupAwareSidebar(...)`. A group's `children`
/// are its member accounts (sorted by member `position`); an account's
/// `children` is always `nil`.
///
/// `Identifiable` is required by the vendored `OutlineView` package;
/// `Hashable` is required so SwiftUI's `Binding<SidebarOutlineItem?>`
/// selection can deduplicate. Equality is by `id` (the kind's stable
/// identifier).
struct SidebarOutlineItem: Identifiable, Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case account(UUID)
    case group(UUID)
  }

  let kind: Kind
  // `nil` means "this item is a leaf — never show a disclosure
  // triangle". `[]` (empty array) means "this item is expandable but
  // currently has no children — render an expandable triangle".
  // The vendored `OutlineView` keys `NSOutlineView.isItemExpandable`
  // off `children != nil`, so swapping to a non-optional empty
  // collection here would force every account row to render a useless
  // disclosure triangle. The SwiftLint `discouraged_optional_collection`
  // rule is silenced for that reason; replacing the optional with an
  // empty array would break the AppKit contract.
  // swiftlint:disable:next discouraged_optional_collection
  let children: [SidebarOutlineItem]?

  var id: Kind { kind }

  static func == (lhs: SidebarOutlineItem, rhs: SidebarOutlineItem) -> Bool {
    lhs.kind == rhs.kind
  }

  func hash(into hasher: inout Hasher) { hasher.combine(kind) }

  // MARK: - Tree construction

  /// Builds a flat outline tree for one bucket. Root-level items are
  /// the bucket's standalone accounts + groups intermixed by
  /// `position`, exactly as produced by
  /// `Accounts.groupAwareSidebar(...)`. **No section-header items** —
  /// those are now supplied by the surrounding SwiftUI `Section`
  /// chrome inside `SidebarView+Sections.swift`.
  static func tree(
    accounts: Accounts,
    groups: [AccountGroup],
    bucket: AccountBucket
  ) -> [SidebarOutlineItem] {
    let grouped = accounts.groupAwareSidebar(groups: groups)
    let entries: [SidebarBucketEntry] = {
      switch bucket {
      case .current: return grouped.current
      case .investments: return grouped.investments
      }
    }()
    return entries.map(item(from:))
  }

  private static func item(from entry: SidebarBucketEntry) -> SidebarOutlineItem {
    switch entry {
    case .account(let account):
      return SidebarOutlineItem(kind: .account(account.id), children: nil)
    case let .group(group, members):
      return SidebarOutlineItem(
        kind: .group(group.id),
        children: members.map { SidebarOutlineItem(kind: .account($0.id), children: nil) }
      )
    }
  }
}
