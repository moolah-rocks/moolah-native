import Foundation

/// Pure, side-effect-free transformation from store snapshots to the
/// sidebar's `[SidebarRow]` tree. The single source of truth for which
/// rows the macOS sidebar shows and in what order. Consumed by
/// `SidebarOutlineController` to drive `NSOutlineView`'s data source.
///
/// `build(from:)` takes a ``SidebarRowTree/Snapshot`` describing the
/// full store state and returns a `Result` value with `roots:
/// [SidebarRow]` (the source-list group headers), `isExpandable(_:)`
/// (whether the outline should draw a disclosure triangle), and
/// `children(of:)` (the ordered children of an expandable row; empty
/// for leaves). A conceptual group with zero current members is
/// reported as non-expandable — the disclosure triangle should not
/// flash for an empty group.
enum SidebarRowTree {
  struct Snapshot {
    let accounts: Accounts
    let groups: [AccountGroup]
    let earmarks: [Earmark]
    let currentTotal: InstrumentAmount?
    let investmentTotal: InstrumentAmount?
    let earmarkedTotal: InstrumentAmount?
    let netWorth: InstrumentAmount?
    let showHidden: Bool
    let unreviewedBadgeCount: Int
  }

  struct Result: Sendable {
    let roots: [SidebarRow]
    private let childMap: [SidebarRow: [SidebarRow]]

    init(roots: [SidebarRow], childMap: [SidebarRow: [SidebarRow]]) {
      self.roots = roots
      self.childMap = childMap
    }

    /// Whether the outline view should treat `row` as expandable. Returns
    /// `false` for leaf rows (accounts, earmarks, totals, navigation
    /// links) and for conceptual containers with zero current children
    /// (e.g. an empty `AccountGroup`).
    func isExpandable(_ row: SidebarRow) -> Bool {
      childMap[row] != nil
    }

    /// Ordered children of `row`. Empty for any row where
    /// `isExpandable(_:)` returns `false`.
    func children(of row: SidebarRow) -> [SidebarRow] {
      childMap[row] ?? []
    }
  }

  static func build(from snapshot: Snapshot) -> Result {
    let grouped = snapshot.accounts.groupAwareSidebar(
      groups: snapshot.groups, showHidden: snapshot.showHidden)

    var childMap: [SidebarRow: [SidebarRow]] = [:]
    childMap[.section(.current)] = grouped.current.map(Self.row(from:))
    childMap[.section(.investments)] = grouped.investments.map(Self.row(from:))
    // Earmarks, Totals, Navigation populated in later tasks.

    for entry in grouped.current + grouped.investments {
      if case let .group(group, members) = entry, !members.isEmpty {
        childMap[.group(group.id)] = members.map { .account($0.id) }
      }
    }

    let roots: [SidebarRow] = [.section(.current), .section(.investments)]
    return Result(roots: roots, childMap: childMap)
  }

  private static func row(from entry: SidebarBucketEntry) -> SidebarRow {
    switch entry {
    case .account(let account): return .account(account.id)
    case .group(let group, _): return .group(group.id)
    }
  }
}
