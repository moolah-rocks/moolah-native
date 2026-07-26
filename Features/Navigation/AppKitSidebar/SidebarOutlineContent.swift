#if os(macOS)
  import Foundation

  /// Values that affect the rows rendered by the macOS sidebar. Selection
  /// is intentionally absent: `SidebarSelectionState` updates the installed
  /// hosted rows without reloading the outline.
  struct SidebarOutlineContent: Equatable {
    let accounts: [Account]
    let groups: [AccountGroup]
    let earmarks: [Earmark]
    let currentTotal: InstrumentAmount?
    let investmentTotal: InstrumentAmount?
    let earmarkedTotal: InstrumentAmount?
    let netWorth: InstrumentAmount?
    let showHidden: Bool
    let unreviewedBadgeCount: Int
    let editingRowId: UUID?

    init(snapshot: SidebarRowTree.Snapshot, editingRowId: UUID?) {
      accounts = snapshot.accounts.ordered
      groups = snapshot.groups
      earmarks = snapshot.earmarks
      currentTotal = snapshot.currentTotal
      investmentTotal = snapshot.investmentTotal
      earmarkedTotal = snapshot.earmarkedTotal
      netWorth = snapshot.netWorth
      showHidden = snapshot.showHidden
      unreviewedBadgeCount = snapshot.unreviewedBadgeCount
      self.editingRowId = editingRowId
    }
  }
#endif
