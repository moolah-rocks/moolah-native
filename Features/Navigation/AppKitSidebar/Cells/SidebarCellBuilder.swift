#if os(macOS)
  import AppKit
  import SwiftUI

  /// Builds the `NSTableCellView` for each `SidebarRow`. Single dispatch
  /// point so `SidebarOutlineDelegate` stays focused on outline-protocol
  /// glue rather than cell construction. All cells are
  /// `NSHostingView`-wrapped SwiftUI content via
  /// `NSTableCellView.hosting(...)` which handles padding,
  /// accessibility-identifier attachment, and right-click menu
  /// forwarding.
  ///
  /// Store references are read directly inside cell builders; the
  /// SwiftUI views observe via `@Observable` so the surrounding outline
  /// rebuild gives each cell a fresh snapshot. The one exception is
  /// `availableFunds`, which is a derived value computed by the parent
  /// representable in a single place — kept as a closure so the
  /// builder doesn't duplicate the derivation.
  @MainActor
  struct SidebarCellBuilder {
    let accountStore: AccountStore
    let accountGroupStore: AccountGroupStore
    let earmarkStore: EarmarkStore
    let importStore: ImportStore
    let availableFunds: () -> InstrumentAmount?
    let selectionBinding: Binding<SidebarSelection?>
    let accountToEditBinding: Binding<Account?>
    let onAddAccount: () -> Void
    let onAddEarmark: () -> Void

    func makeCell(for row: SidebarRow) -> NSTableCellView {
      switch row {
      case .section(let kind): return sectionCell(kind: kind)
      case .account(let id): return accountCell(id: id)
      case .group(let id): return groupCell(id: id)
      case .earmark(let id): return earmarkCell(id: id)
      case .total(let kind): return totalCell(kind: kind)
      case .navigation(let kind): return navigationCell(kind: kind)
      }
    }

    // MARK: - Cell builders

    private func sectionCell(kind: SidebarRow.SectionKind) -> NSTableCellView {
      let title = Self.sectionTitle(for: kind)
      return NSTableCellView.hosting {
        SidebarSectionHeaderRowView(title: title)
          .accessibilityHidden(title.isEmpty)
      }
    }

    private func accountCell(id: UUID) -> NSTableCellView {
      guard let account = accountStore.accounts.by(id: id) else {
        return NSTableCellView()
      }
      let menu = SidebarContextMenuBuilder.accountMenu(
        accountId: id,
        accountStore: accountStore,
        selection: selectionBinding,
        accountToEdit: accountToEditBinding)
      return NSTableCellView.hosting(
        accessibilityIdentifier: UITestIdentifiers.Sidebar.account(id),
        menu: menu
      ) {
        AccountSidebarRow(
          account: account,
          isSelected: selectionBinding.wrappedValue == .account(id),
          isMember: account.groupId != nil
        )
        .environment(accountStore)
      }
    }

    private func groupCell(id: UUID) -> NSTableCellView {
      guard let group = accountGroupStore.by(id: id) else {
        return NSTableCellView()
      }
      let memberIds =
        accountStore.accounts.ordered
        .filter { $0.groupId == id }
        .sorted { $0.position < $1.position }
        .map(\.id)
      let isSelected = selectionBinding.wrappedValue == .group(id)
      return NSTableCellView.hosting(
        accessibilityIdentifier: UITestIdentifiers.Sidebar.group(id)
      ) {
        GroupAggregateBalanceLoader(
          memberIds: memberIds,
          targetInstrument: group.instrument
        ) { balance in
          AccountGroupSidebarRow(
            group: group,
            isSelected: isSelected,
            isExpanded: .constant(false),
            aggregateBalance: balance,
            showChevron: false)
        }
        .environment(accountStore)
      }
    }

    private func earmarkCell(id: UUID) -> NSTableCellView {
      guard let earmark = earmarkStore.earmarks.by(id: id) else {
        return NSTableCellView()
      }
      let isSelected = selectionBinding.wrappedValue == .earmark(id)
      return NSTableCellView.hosting(
        accessibilityIdentifier: UITestIdentifiers.Sidebar.earmark(id)
      ) {
        EarmarkRowView(earmark: earmark, isSelected: isSelected)
          .environment(earmarkStore)
      }
    }

    private func totalCell(kind: SidebarRow.TotalKind) -> NSTableCellView {
      let descriptor = totalDescriptor(for: kind)
      return NSTableCellView.hosting {
        SidebarTotalRowView(
          label: descriptor.label,
          amount: descriptor.amount,
          emphasised: descriptor.emphasised)
      }
    }

    private func navigationCell(kind: SidebarRow.NavigationKind) -> NSTableCellView {
      let descriptor = Self.navigationDescriptor(for: kind, importStore: importStore)
      return NSTableCellView.hosting(
        accessibilityIdentifier: UITestIdentifiers.Sidebar.view(descriptor.idSuffix)
      ) {
        SidebarNavigationRowView(
          title: descriptor.title,
          systemImage: descriptor.icon,
          badgeCount: descriptor.badge)
      }
    }

    // MARK: - Descriptors

    private struct TotalDescriptor {
      let label: String
      let amount: InstrumentAmount?
      let emphasised: Bool
    }

    private func totalDescriptor(for kind: SidebarRow.TotalKind) -> TotalDescriptor {
      switch kind {
      case .currentTotal:
        return TotalDescriptor(
          label: "Current Total",
          amount: accountStore.convertedCurrentTotal,
          emphasised: false)
      case .investmentTotal:
        return TotalDescriptor(
          label: "Investment Total",
          amount: accountStore.convertedInvestmentTotal,
          emphasised: false)
      case .earmarkedTotal:
        return TotalDescriptor(
          label: "Earmarked Total",
          amount: earmarkStore.convertedTotalBalance,
          emphasised: false)
      case .availableFunds:
        return TotalDescriptor(
          label: "Available Funds", amount: availableFunds(), emphasised: true)
      case .netWorth:
        return TotalDescriptor(
          label: "Net Worth", amount: accountStore.convertedNetWorth, emphasised: true)
      }
    }

    private struct NavigationDescriptor {
      let title: String
      let icon: String
      let badge: Int
      let idSuffix: String
    }

    private static func navigationDescriptor(
      for kind: SidebarRow.NavigationKind,
      importStore: ImportStore
    ) -> NavigationDescriptor {
      switch kind {
      case .analysis:
        return NavigationDescriptor(
          title: "Analysis", icon: "chart.bar.xaxis", badge: 0, idSuffix: "analysis")
      case .reports:
        return NavigationDescriptor(
          title: "Reports", icon: "chart.bar.fill", badge: 0, idSuffix: "reports")
      case .categories:
        return NavigationDescriptor(
          title: "Categories", icon: "tag", badge: 0, idSuffix: "categories")
      case .upcoming:
        return NavigationDescriptor(
          title: "Upcoming", icon: "calendar", badge: 0, idSuffix: "upcoming")
      case .recentlyAdded:
        return NavigationDescriptor(
          title: "Recently Added",
          icon: "tray.full",
          badge: importStore.unreviewedBadgeCount,
          idSuffix: "recentlyAdded")
      case .allTransactions:
        return NavigationDescriptor(
          title: "All Transactions",
          icon: "list.bullet",
          badge: 0,
          idSuffix: "allTransactions")
      }
    }

    private static func sectionTitle(for kind: SidebarRow.SectionKind) -> String {
      switch kind {
      case .current: return "Current Accounts"
      case .earmarks: return "Earmarks"
      case .investments: return "Investments"
      case .totals: return ""
      case .navigation: return ""
      }
    }
  }
#endif
