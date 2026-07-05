import SwiftUI

/// The unified account-detail container for crypto / exchange / standard /
/// group accounts. Presents three data-driven surfaces from three content
/// builders:
///   - **Transactions** — always present, the default selection.
///   - **Positions** — only when `hasPositions` (non-host holdings).
///   - **Chart** — always present (perf tiles + total + value chart).
///
/// **iOS:** a segmented `Picker` over `AccountDetailLayout.iOSTabs`
/// (`[Transactions | Chart]`, inserting `Positions` between them when
/// `hasPositions`). Transactions is first and default.
///
/// **macOS:** when `hasPositions`, a `ResizableVSplit` with the positions
/// table pinned in the top pane and a `[Transactions | Chart]` toggle
/// (default Transactions) in the resizable bottom pane. When fiat-only, no
/// split — a single full-height pane carrying just the toggle. The divider
/// autosaves under a key distinct from the legacy chartless and the
/// investment split keys so no user inherits a stale divider.
struct PositionsChartTransactionsSplit<Transactions: View, Positions: View, Chart: View>: View {
  let hasPositions: Bool
  let autosaveName: String
  let initialTopHeight: CGFloat
  @ViewBuilder let transactions: () -> Transactions
  @ViewBuilder let positions: () -> Positions
  @ViewBuilder let chart: () -> Chart

  #if os(macOS)
    @State private var bottomTab: AccountDetailTab = .transactions
    @State private var scrollCollapse = TransactionScrollCollapse()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
  #else
    @State private var selectedTab: AccountDetailTab = .transactions
  #endif

  init(
    hasPositions: Bool,
    autosaveName: String = "account-detail.positions-pinned-split",
    initialTopHeight: CGFloat = 260,
    @ViewBuilder transactions: @escaping () -> Transactions,
    @ViewBuilder positions: @escaping () -> Positions,
    @ViewBuilder chart: @escaping () -> Chart
  ) {
    self.hasPositions = hasPositions
    self.autosaveName = autosaveName
    self.initialTopHeight = initialTopHeight
    self.transactions = transactions
    self.positions = positions
    self.chart = chart
  }

  var body: some View {
    #if os(macOS)
      macBody
    #else
      iOSBody
    #endif
  }

  // MARK: - iOS

  #if !os(macOS)
    private var iOSBody: some View {
      let tabs = AccountDetailLayout.iOSTabs(hasPositions: hasPositions)
      return VStack(spacing: 0) {
        Picker("Show", selection: $selectedTab) {
          ForEach(tabs, id: \.self) { tab in
            Text(label(for: tab)).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Account detail section")
        .accessibilityIdentifier(UITestIdentifiers.AccountDetail.tabPicker)
        .padding(.horizontal)
        .padding(.vertical, 8)

        Divider()

        selectedContent
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
      // If holdings disappear (e.g. the last non-host position is sold or
      // flagged spam) while the Positions tab is selected, fall back to
      // Transactions so the picker never points at a removed tab.
      .onChange(of: hasPositions) { _, nowHasPositions in
        if !nowHasPositions, selectedTab == .positions {
          selectedTab = .transactions
        }
      }
    }

    @ViewBuilder private var selectedContent: some View {
      switch selectedTab {
      case .transactions: transactions()
      case .positions: positionsPane
      case .chart: chartPane
      }
    }
  #endif

  // MARK: - macOS

  #if os(macOS)
    @ViewBuilder private var macBody: some View {
      if AccountDetailLayout.macShowsPinnedPositions(hasPositions: hasPositions) {
        ResizableVSplit(
          autosaveName: autosaveName,
          initialTopHeight: initialTopHeight,
          minTopHeight: 120,
          minBottomHeight: 320,
          collapsed: scrollCollapse.isCollapsed,
          reduceMotion: reduceMotion
        ) {
          positionsPane
        } bottom: {
          bottomToggle
        }
      } else {
        bottomToggle
      }
    }

    private var bottomToggle: some View {
      VStack(spacing: 0) {
        // The segmented toggle is extracted into an `Equatable` view and
        // wrapped in `.equatable()` so that content-only re-renders of the
        // surrounding panes do NOT re-render the `Picker`. See
        // `BottomTabToggle` for why re-rendering it mid-click drops the
        // selection change under load.
        BottomTabToggle(selection: bottomTab, binding: $bottomTab)
          .equatable()

        Divider()

        Group {
          switch bottomTab {
          case .transactions:
            transactions()
              .environment(\.transactionScrollCollapse, scrollCollapse)
          case .chart:
            chartPane
          case .positions:
            // Not reachable — the bottom toggle only offers Transactions /
            // Chart; positions is the pinned top pane.
            EmptyView()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
    }
  #endif

  // MARK: - Shared pane wrappers

  // `.accessibilityElement(children: .contain)` turns each wrapper into a
  // single accessibility container carrying the pane identifier, while its
  // descendants keep their own identities. Without it, a bare
  // `.accessibilityIdentifier` on a container propagates down and stamps the
  // pane id onto every descendant leaf — which overrode the `performanceTiles`
  // identifier on the Annualised Return tile (it surfaced as `chartPane`
  // instead). Containing the children lets both the pane id and the inner
  // `performanceTiles` id surface as distinct, queryable elements.
  private var positionsPane: some View {
    positions()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(UITestIdentifiers.AccountDetail.positionsPane)
  }

  private var chartPane: some View {
    chart()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(UITestIdentifiers.AccountDetail.chartPane)
  }

}

/// Visible label for a bottom-pane / tab segment. File-scoped so both the
/// iOS `Picker` and the macOS `BottomTabToggle` share one mapping.
private func label(for tab: AccountDetailTab) -> String {
  switch tab {
  case .transactions: return "Transactions"
  case .positions: return "Positions"
  case .chart: return "Chart"
  }
}

#if os(macOS)
  /// The macOS `[Transactions | Chart]` segmented toggle, extracted into an
  /// `Equatable` view (used with `.equatable()`) so unrelated re-renders of
  /// the surrounding panes don't disturb the underlying `NSSegmentedControl`.
  ///
  /// The bottom pane's `positionsInput` is written progressively by the async
  /// valuator + performance pipeline. Each write re-renders the container; if
  /// the segmented `Picker` re-rendered with it, AppKit would re-apply
  /// `selectedSegment` from `selection` (`updateNSView`). When that re-apply
  /// lands in the window of a segment click — common under load, and made more
  /// likely by the per-account performance compute delaying the final write to
  /// around the second toggle click — it reverts the in-flight click and the
  /// selection binding never updates, so the tab silently fails to switch (the
  /// observed CI flake). Comparing only the selected value keeps the control
  /// stable across content-only re-renders while still updating on a genuine
  /// selection change.
  private struct BottomTabToggle {
    /// The current selection as an immutable `Sendable` value so `==` can read
    /// it from the nonisolated `Equatable` requirement (`binding` is a
    /// `MainActor`-isolated `var` and can't be read there). `binding` is used
    /// only to write the owner's `@State` back and is excluded from `==`.
    let selection: AccountDetailTab
    @Binding var binding: AccountDetailTab
  }

  extension BottomTabToggle: View {
    var body: some View {
      Picker("Show", selection: $binding) {
        ForEach(AccountDetailLayout.macBottomTabs, id: \.self) { tab in
          Text(label(for: tab)).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityLabel("Account detail section")
      .accessibilityIdentifier(UITestIdentifiers.AccountDetail.tabPicker)
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
  }

  extension BottomTabToggle: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.selection == rhs.selection
    }
  }
#endif

#Preview("Multi-instrument — pinned split / 3 tabs") {
  PositionsChartTransactionsSplit(hasPositions: true) {
    Color.green.opacity(0.15).overlay(Text("Transactions"))
  } positions: {
    Color.blue.opacity(0.15).overlay(Text("Positions"))
  } chart: {
    Color.orange.opacity(0.15).overlay(Text("Chart + performance"))
  }
  .frame(width: 520, height: 620)
}

#Preview("Fiat-only — single pane / 2 tabs") {
  PositionsChartTransactionsSplit(hasPositions: false) {
    Color.green.opacity(0.15).overlay(Text("Transactions"))
  } positions: {
    Color.blue.opacity(0.15).overlay(Text("Positions"))
  } chart: {
    Color.orange.opacity(0.15).overlay(Text("Chart + performance"))
  }
  .frame(width: 520, height: 620)
}
