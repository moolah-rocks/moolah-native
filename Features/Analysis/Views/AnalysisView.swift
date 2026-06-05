import SwiftUI

struct AnalysisView: View {
  @Environment(AccountStore.self) private var accountStore
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(TransactionStore.self) private var transactionStore
  @Environment(ProfileSession.self) private var session
  @Environment(\.scenePhase) private var scenePhase

  @Bindable var store: AnalysisStore
  /// Navigates the sidebar selection when a "For You" insight is opened.
  /// Threaded from `ContentView` (which owns the selection) rather than read via
  /// `@FocusedValue(\.sidebarSelection)`: this view also *writes* focused scene
  /// values, and a focused-value reader here drove an infinite SwiftUI update
  /// cycle (focus write → focus-dependent body invalidation → rewrite → …).
  var onNavigate: (SidebarSelection) -> Void = { _ in }
  @State private var selectedUpcomingTransaction: Transaction?

  var body: some View {
    ScrollView {
      // Load-state check on the full array — not a display-window question.
      if store.isLoading && store.dailyBalances.isEmpty {
        ProgressView("Loading analysis...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .frame(minHeight: 400)
      } else if let error = store.error {
        ContentUnavailableView {
          Label("Error Loading Analysis", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error.localizedDescription)
        } actions: {
          Button("Try Again") {
            Task { await store.loadAll() }
          }
        }
      } else {
        contentView(store: store)
      }
    }
    .transactionInspector(
      selectedTransaction: $selectedUpcomingTransaction,
      accounts: accountStore.accounts,
      categories: categoryStore.categories,
      earmarks: earmarkStore.earmarks,
      transactionStore: transactionStore,
      showRecurrence: true
    )
    .profileNavigationTitle("Analysis")
    .focusedSceneValue(\.newTransactionAction, createNewScheduledTransaction)
    .focusedSceneValue(
      \.analysisRoute,
      AnalysisRouteParams(history: store.historyMonths, forecast: store.forecastMonths)
    )
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Section("History") {
            HistoryPicker(selection: $store.historyMonths)
          }

          Section("Forecast") {
            ForecastPicker(selection: $store.forecastMonths)
          }
        } label: {
          Label("Filters", systemImage: "slider.horizontal.3")
        }
      }

      ToolbarItem(placement: .primaryAction) {
        Button {
          createNewScheduledTransaction()
        } label: {
          Label("Add Scheduled Transaction", systemImage: "plus")
        }
      }
    }
    .task {
      // The upcoming card displays scheduled transactions. Wins the
      // SwiftData SQL connection race for the upcoming-card data before
      // the heavier analysis loads start so the visible card paints in
      // well under a second on cold launch. See
      // `plans/2026-04-27-upcoming-card-cold-load-plan.md`.
      await transactionStore.load(filter: TransactionFilter(scheduled: .scheduledOnly))
      await store.loadAll()
      await session.insightStore?.refreshIfStale(minimumInterval: 60)
    }
    .task {
      // Long-lived reactive subscription for the upcoming card. Runs
      // alongside the priming `.task` above; the prior `load(filter:)`
      // sets `currentFilter` so the inner subscription cycle sees the
      // matching state and the rate-tick path keeps the running balances
      // fresh on remote sync. The surrounding `.task` cancels this on
      // view unmount.
      await transactionStore.observe(filter: TransactionFilter(scheduled: .scheduledOnly))
    }
    .onChange(of: store.historyMonths) { _, _ in
      Task { await store.loadAll() }
    }
    .onChange(of: store.forecastMonths) { _, _ in
      Task { await store.loadAll() }
    }
    .onChange(of: scenePhase) { oldPhase, newPhase in
      // Only refresh when returning from the background (not from brief inactive
      // states like share sheets, system dialogs, or Command-Tab). Use a staleness
      // threshold to avoid disruptive reloads when the app has just been loaded.
      if oldPhase == .background && newPhase == .active {
        Task { await store.refreshIfStale(minimumInterval: 60) }
        Task { await session.insightStore?.refreshIfStale(minimumInterval: 60) }
      }
    }
  }

  private func createNewScheduledTransaction() {
    let accounts = accountStore.accounts
    let instrument = accounts.ordered.first?.instrument ?? .AUD
    let fallbackAccountId = accounts.ordered.first?.id

    // Persist the placeholder directly so the returned transaction carries
    // the same UUID. The inspector's `.id(selected.id)` stays stable and
    // the detail view's focus state survives the create (see
    // `plans/2026-04-21-transaction-detail-focus-design.md`).
    let placeholder: Transaction? = fallbackAccountId.map { id in
      Transaction(
        date: Date(),
        payee: "",
        recurPeriod: .month,
        recurEvery: 1,
        legs: [TransactionLeg(accountId: id, instrument: instrument, quantity: 0, type: .expense)]
      )
    }
    selectedUpcomingTransaction = placeholder
    guard let placeholder else { return }
    Task {
      _ = await transactionStore.create(placeholder)
    }
  }

  @ViewBuilder
  private func contentView(store: AnalysisStore) -> some View {
    VStack(spacing: 20) {
      if let insightStore = session.insightStore, !insightStore.items.isEmpty {
        ForYouCard(
          items: insightStore.items,
          onDismiss: { item in Task { await insightStore.dismiss(item.scored) } },
          onNavigate: onNavigate)
      }
      NetWorthGraphCard(balances: store.displayedDailyBalances)
      upcomingAndIncomeExpense(store: store)
      ExpenseBreakdownCard(
        breakdown: store.displayedExpenseBreakdown,
        categories: categoryStore.categories
      )
      CategoriesOverTimeCard(
        entries: store.categoriesOverTime(categories: categoryStore.categories),
        categories: categoryStore.categories,
        // Instrument is uniform across the profile; read the full (unclipped) array so
        // a narrow display window with no rows in range doesn't fall back to .AUD.
        instrument: store.dailyBalances.first?.balance.instrument ?? .AUD,
        showActualValues: $store.showActualValues
      )
    }
  }

  @ViewBuilder
  private func upcomingAndIncomeExpense(store: AnalysisStore) -> some View {
    #if os(macOS)
      HStack(alignment: .top, spacing: 20) {
        UpcomingTransactionsCard(
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore,
          selectedTransaction: $selectedUpcomingTransaction
        )
        IncomeExpenseTableCard(data: store.displayedIncomeAndExpense)
      }
    #else
      UpcomingTransactionsCard(
        accounts: accountStore.accounts,
        categories: categoryStore.categories,
        earmarks: earmarkStore.earmarks,
        transactionStore: transactionStore,
        selectedTransaction: $selectedUpcomingTransaction
      )
      IncomeExpenseTableCard(data: store.displayedIncomeAndExpense)
    #endif
  }
}

struct HistoryPicker: View {
  @Binding var selection: Int

  var body: some View {
    Picker("History Period", selection: $selection) {
      Text("1 Month").tag(1)
      Text("3 Months").tag(3)
      Text("6 Months").tag(6)
      Text("1 Year").tag(12)
      Text("2 Years").tag(24)
      Text("3 Years").tag(36)
      Text("All").tag(0)
    }
  }
}

struct ForecastPicker: View {
  @Binding var selection: Int

  var body: some View {
    Picker("Forecast Period", selection: $selection) {
      Text("None").tag(0)
      Text("1 Month").tag(1)
      Text("3 Months").tag(3)
      Text("6 Months").tag(6)
    }
  }
}

@MainActor
private func seedAnalysisPreview(
  backend: any BackendProvider
) async {
  let account = Account(id: UUID(), name: "Checking", type: .bank, instrument: .AUD)
  _ = try? await backend.accounts.create(account)
  let category = Category(id: UUID(), name: "Groceries")
  _ = try? await backend.categories.create(category)
  for index in 0..<30 {
    _ = try? await backend.transactions.create(
      Transaction(
        id: UUID(),
        date: Date().addingTimeInterval(-86400 * Double(index)),
        payee: "Transaction \(index)",
        legs: [
          TransactionLeg(
            accountId: account.id,
            instrument: .AUD,
            quantity: index.isMultiple(of: 2)
              ? Decimal(Int.random(in: 100...500)) : -Decimal(Int.random(in: 50...200)),
            type: index.isMultiple(of: 2) ? .income : .expense,
            categoryId: index.isMultiple(of: 3) ? category.id : nil
          )
        ]))
  }
  // CategoryStore is reactive — it'll see the seeded category via
  // `observeAll()` without an explicit load() call.
}

#Preview {
  let backend = PreviewBackend.create()
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let categoryStore = CategoryStore(repository: backend.categories)
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let analysisStore = AnalysisStore(repository: backend.analysis)

  return NavigationStack {
    AnalysisView(store: analysisStore)
      .environment(accountStore)
      .environment(categoryStore)
      .environment(earmarkStore)
      .environment(transactionStore)
      .task {
        await seedAnalysisPreview(backend: backend)
      }
  }
  .previewProfileEnvironment()
}
