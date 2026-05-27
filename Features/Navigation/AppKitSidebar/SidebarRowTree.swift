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
  struct Snapshot: Sendable {
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

    /// Empty result used by the data source before the controller's
    /// first `apply(...)` call. Required because `NSOutlineView` queries
    /// the data source from `loadView()` before any tree is built.
    static let empty = Result(roots: [], childMap: [:])

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
    childMap[.section(.current)] =
      grouped.current.map(Self.row(from:))
      + Self.trailingTotal(.currentTotal, when: snapshot.currentTotal)
    childMap[.section(.investments)] =
      grouped.investments.map(Self.row(from:))
      + Self.trailingTotal(.investmentTotal, when: snapshot.investmentTotal)
    childMap[.section(.earmarks)] =
      snapshot.earmarks.map { .earmark($0.id) }
      + Self.trailingTotal(.earmarkedTotal, when: snapshot.earmarkedTotal)
    childMap[.section(.totals)] = Self.summaryTotals(from: snapshot)
    childMap[.section(.navigation)] = Self.navigationRows()

    for entry in grouped.current + grouped.investments {
      if case let .group(group, members) = entry, !members.isEmpty {
        childMap[.group(group.id)] = members.map { .account($0.id) }
      }
    }

    let roots: [SidebarRow] = [
      .section(.current),
      .section(.earmarks),
      .section(.investments),
      .section(.totals),
      .section(.navigation),
    ]
    return Result(roots: roots, childMap: childMap)
  }

  private static func row(from entry: SidebarBucketEntry) -> SidebarRow {
    switch entry {
    case .account(let account): return .account(account.id)
    case .group(let group, _): return .group(group.id)
    }
  }

  /// `[.total(kind)]` when `amount` is non-nil; empty array otherwise.
  /// Used to append per-bucket totals (Current / Investment / Earmarked)
  /// as the trailing row of their own section — mirroring the iOS
  /// `totalRow(label:value:)` placement inside each `Section { … }`.
  private static func trailingTotal(
    _ kind: SidebarRow.TotalKind, when amount: InstrumentAmount?
  ) -> [SidebarRow] {
    amount != nil ? [.total(kind)] : []
  }

  /// The implicit Totals section's rows: derived summaries that don't
  /// belong to any single bucket. `availableFunds` requires a non-nil
  /// `currentTotal` and a positive `earmarkedTotal` — mirroring the
  /// gating in `SidebarView+Sections.swift`'s `totalsSection` body.
  private static func summaryTotals(from snapshot: Snapshot) -> [SidebarRow] {
    var totals: [SidebarRow] = []
    if snapshot.currentTotal != nil,
      let earmarked = snapshot.earmarkedTotal,
      earmarked.isPositive
    {
      totals.append(.total(.availableFunds))
    }
    if snapshot.netWorth != nil { totals.append(.total(.netWorth)) }
    return totals
  }

  /// The fixed-order set of Navigation rows. Order is stable across
  /// snapshots and matches the existing SwiftUI sidebar's order.
  private static func navigationRows() -> [SidebarRow] {
    [
      .navigation(.analysis),
      .navigation(.reports),
      .navigation(.categories),
      .navigation(.upcoming),
      .navigation(.recentlyAdded),
      .navigation(.allTransactions),
    ]
  }
}
