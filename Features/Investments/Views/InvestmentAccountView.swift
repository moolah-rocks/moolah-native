import OSLog
import SwiftUI

/// Anchor `@AccessibilityFocusState` reads/writes inside
/// `InvestmentAccountView`. File-private so the type's body stays focused
/// on layout; only one case is required because every relayout target is
/// the same logical "content has just (re-)mounted" event.
private enum InvestmentAccountFocusAnchor: Hashable {
  case content
}

/// Enforces Apple's iOS HIG 44×44 pt minimum touch target on the
/// time-period picker buttons. macOS uses pointer precision so the
/// modifier is a no-op there; the wrapping lets the call site stay
/// declarative without `#if` clutter.
private struct TimePeriodHitTarget: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
      content.frame(minHeight: 44).contentShape(Rectangle())
    #else
      content
    #endif
  }
}

/// Combined investment account view showing summary panels, chart with valuations list,
/// and an embedded transaction list.
struct InvestmentAccountView: View {
  /// Composite identity used to drive `.task(id:)`. Re-fires when the account
  /// changes (navigation). Carrying `mode` is a safety-net: if a sync push
  /// delivers a mode change while the view is still mounted, `loadAllData`
  /// re-runs before the dispatch boundary swaps views.
  private struct LoadKey: Equatable {
    let id: UUID
    let mode: ValuationMode
  }

  static let logger = Logger(
    subsystem: "com.moolah.app", category: "InvestmentAccountView")

  let account: Account
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let investmentStore: InvestmentStore
  let transactionStore: TransactionStore

  @Environment(ProfileSession.self) var session
  @State private var showingAddValue = false
  @State private var selectedTransaction: Transaction?
  /// Tracks whether `loadAllData` has run at least once for this account.
  /// Gates the body so `legacyValuationsLayout` is shown only after data is
  /// available — without this, the embedded `TransactionListView` with its
  /// `.toolbar` would mount before the store is ready, potentially
  /// double-registering toolbar items in SwiftUI's AppKit toolbar bridge and
  /// crashing Release builds.
  @State private var initialLoadComplete = false

  /// Anchor VoiceOver moves to on initial-load completion.
  /// Without this, focus lingers on a stale element and reads back
  /// unrelated content.
  @AccessibilityFocusState private var focusAnchor: InvestmentAccountFocusAnchor?

  var body: some View {
    Group {
      if !initialLoadComplete {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityLabel("Loading account data")
      } else {
        legacyValuationsLayout
      }
    }
    .accessibilityFocused($focusAnchor, equals: .content)
    .transactionInspector(
      selectedTransaction: $selectedTransaction,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      viewingAccountId: account.id
    )
    .profileNavigationTitle(account.name)
    .sheet(isPresented: $showingAddValue) {
      AddInvestmentValueView(
        accountId: account.id, instrument: account.instrument, store: investmentStore)
    }
    .task(id: LoadKey(id: account.id, mode: account.valuationMode)) {
      initialLoadComplete = false
      await investmentStore.loadAllData(
        account: account, profileCurrency: session.profile.instrument)
      initialLoadComplete = true
      focusAnchor = .content
    }
    .refreshable {
      await investmentStore.loadAllData(
        account: account, profileCurrency: session.profile.instrument)
    }
  }
}

extension InvestmentAccountView {
  /// Embedded transaction list for this account. Each call site builds a
  /// fresh `TransactionListView`; this is a method (not a `@ViewBuilder`
  /// computed property) so the per-call instantiation is explicit at the
  /// call site rather than masquerading as a stable view value.
  @ViewBuilder
  private func makeAccountTransactionList() -> some View {
    TransactionListView(
      title: "",
      filter: TransactionFilter(accountId: account.id),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      selectedTransaction: $selectedTransaction
    )
  }

  @ViewBuilder private var legacyValuationsLayout: some View {
    RecordedValueInvestmentLayout {
      legacySummary
    } chartAndValuations: {
      legacyChartAndValuations
    } transactions: {
      makeAccountTransactionList()
    }
  }

  @ViewBuilder private var legacySummary: some View {
    if !investmentStore.values.isEmpty,
      let performance = investmentStore.accountPerformance
    {
      AccountPerformanceTiles(title: account.name, performance: performance)
    }
  }

  /// Chart + valuations layout: side-by-side on macOS, stacked on iOS.
  @ViewBuilder private var legacyChartAndValuations: some View {
    #if os(macOS)
      HStack(alignment: .top, spacing: 0) {
        VStack(spacing: 16) {
          timePeriodPicker
          InvestmentChartView(
            dataPoints: investmentStore.chartDataPoints,
            instrument: account.instrument)
        }
        .padding()

        Divider()

        valuationsList
          .frame(width: 240)
      }
    #else
      VStack(spacing: 0) {
        VStack(spacing: 16) {
          timePeriodPicker
          InvestmentChartView(
            dataPoints: investmentStore.chartDataPoints,
            instrument: account.instrument)
        }
        .padding()

        Divider()

        valuationsList
          .frame(maxHeight: 300)
      }
    #endif
  }

  // MARK: - Valuations List

  private var valuationsList: some View {
    VStack(spacing: 0) {
      valuationsHeader
      Divider()
      valuationsBody
    }
  }

  private var valuationsHeader: some View {
    HStack {
      Text("Valuations").font(.headline)
      Spacer()
      Button {
        showingAddValue = true
      } label: {
        Label("Record Value", systemImage: "plus")
          .labelStyle(.iconOnly)
      }
      .help("Record Value")
      // `.iconOnly` style hides the title from screen readers on iOS, which
      // then announce the SF Symbol name ("plus") instead of the action.
      // Pin the action label explicitly so VoiceOver reads "Record Value".
      .accessibilityLabel("Record Value")
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  @ViewBuilder private var valuationsBody: some View {
    if investmentStore.values.isEmpty && !investmentStore.isLoading {
      ContentUnavailableView(
        "No Values",
        systemImage: "chart.line.uptrend.xyaxis",
        description: noValuesPrompt
      )
    } else {
      List {
        ForEach(investmentStore.values) { value in
          InvestmentValueListRow(value: value) {
            Task {
              await investmentStore.removeValue(accountId: account.id, date: value.date)
            }
          }
        }
      }
      .listStyle(.inset)
    }
  }

  private var noValuesPrompt: Text {
    Text(PlatformActionVerb.emptyStatePrompt(buttonLabel: "+", suffix: "to record a value"))
  }

  // MARK: - Time Period Picker

  private var timePeriodPicker: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(TimePeriod.allCases) { period in
          Button {
            investmentStore.selectedPeriod = period
          } label: {
            Text(period.label)
              .font(.caption)
              .fontWeight(investmentStore.selectedPeriod == period ? .bold : .regular)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(
                investmentStore.selectedPeriod == period
                  ? Color.accentColor.opacity(0.15)
                  : Color.clear
              )
              .cornerRadius(8)
              .modifier(TimePeriodHitTarget())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Show \(period.label) history")
          .accessibilityAddTraits(
            investmentStore.selectedPeriod == period ? .isSelected : [])
        }
      }
    }
  }
}

// Preview seeds and `#Preview` blocks live in `InvestmentAccountView+Previews.swift`.
