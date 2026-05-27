import Foundation

/// One node in the macOS sidebar outline. The two top-level entries are
/// the bucket section headers ("Current Accounts", "Investments"); their
/// children are bucket entries (standalone accounts + groups intermixed
/// by `position`, exactly as produced by
/// `Accounts.groupAwareSidebar(...)`). A group's `children` are its
/// member accounts (sorted by member `position`); an account's
/// `children` is always `nil`.
///
/// `Identifiable` is required by the vendored `OutlineView` package;
/// `Hashable` is required so SwiftUI's `Binding<SidebarOutlineItem?>`
/// selection can deduplicate. Equality is by `id` (the kind's stable
/// identifier).
struct SidebarOutlineItem: Identifiable, Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case currentAccountsHeader
    case investmentsHeader
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

  /// Derives the outline tree from the same source-of-truth helper the
  /// SwiftUI sidebar uses (`Accounts.groupAwareSidebar`). Hidden /
  /// excluded handling rides along — callers don't pass `excluding` /
  /// `alwaysInclude` here; the helper is invoked with defaults because
  /// the sidebar never wants to hide its own rows.
  static func tree(
    accounts: Accounts,
    groups: [AccountGroup]
  ) -> [SidebarOutlineItem] {
    let grouped = accounts.groupAwareSidebar(groups: groups)
    return [
      section(.currentAccountsHeader, entries: grouped.current),
      section(.investmentsHeader, entries: grouped.investments),
    ]
  }

  private static func section(
    _ kind: Kind, entries: [SidebarBucketEntry]
  ) -> SidebarOutlineItem {
    SidebarOutlineItem(
      kind: kind,
      children: entries.map(item(from:))
    )
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
