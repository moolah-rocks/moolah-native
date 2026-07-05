import SwiftUI

/// Main Reports view displaying income and expense breakdown by category.
struct ReportsView: View {
  let reportingStore: ReportingStore
  let categories: Categories
  let accounts: Accounts
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @Environment(ProfileSession.self) private var session

  /// Last-used range, persisted locally so a relative preset restores as the
  /// relative preset (re-resolved against today), not the fixed dates it
  /// referred to when picked. Read/written via `ReportsPeriodStorage`.
  @State private var dateRange: DateRange
  @State private var customFrom: Date
  @State private var customTo: Date

  /// Resolved date range, computed once when dateRange or custom dates change.
  /// Stored in @State to avoid re-evaluating Date() on every SwiftUI render cycle.
  @State private var resolvedFrom: Date
  @State private var resolvedTo: Date

  init(
    reportingStore: ReportingStore,
    categories: Categories,
    accounts: Accounts,
    earmarks: Earmarks,
    transactionStore: TransactionStore
  ) {
    self.reportingStore = reportingStore
    self.categories = categories
    self.accounts = accounts
    self.earmarks = earmarks
    self.transactionStore = transactionStore

    // Seed all range state from the persisted preference so the first render
    // loads the restored window with no flash of the default range.
    let seed = ReportsPeriodStorage.seed()
    _dateRange = State(initialValue: seed.dateRange)
    _customFrom = State(initialValue: seed.customFrom)
    _customTo = State(initialValue: seed.customTo)
    _resolvedFrom = State(initialValue: seed.resolvedFrom)
    _resolvedTo = State(initialValue: seed.resolvedTo)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        dateRangeSelector
        Divider()
        reportContent
      }
      .profileNavigationTitle("Reports")
      .navigationDestination(for: CategoryDrillDown.self) { drillDown in
        drillDownDestination(drillDown)
      }
      .navigationDestination(for: UncategorisedDrillDown.self) { drillDown in
        uncategorisedDrillDownDestination(drillDown)
      }
    }
    .task(id: DateRangeKey(from: resolvedFrom, to: resolvedTo)) {
      await reportingStore.loadCategoryBalances(dateRange: resolvedFrom...resolvedTo)
    }
    .focusedSceneValue(
      \.reportsRoute,
      ReportsRouteParams(from: resolvedFrom, to: resolvedTo)
    )
    .onChange(of: dateRange) { _, newValue in
      ReportsPeriodStorage.persist(range: newValue)
      guard newValue != .custom else { return }
      resolvedFrom = newValue.startDate()
      resolvedTo = newValue.endDate()
    }
    .onChange(of: customFrom) { _, newValue in
      guard dateRange == .custom else { return }
      ReportsPeriodStorage.persistCustomFrom(newValue)
      resolvedFrom = newValue
    }
    .onChange(of: customTo) { _, newValue in
      guard dateRange == .custom else { return }
      ReportsPeriodStorage.persistCustomTo(newValue)
      resolvedTo = newValue
    }
  }

  @ViewBuilder private var reportContent: some View {
    if reportingStore.isLoadingCategoryBalances {
      ProgressView("Loading report...")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let error = reportingStore.categoryBalancesError {
      ContentUnavailableView {
        Label("Error Loading Report", systemImage: "exclamationmark.triangle")
      } description: {
        Text(error.localizedDescription)
      } actions: {
        Button("Try Again") {
          Task {
            await reportingStore.loadCategoryBalances(dateRange: resolvedFrom...resolvedTo)
          }
        }
      }
    } else {
      incomeAndExpenseTables
    }
  }

  @ViewBuilder private var incomeAndExpenseTables: some View {
    // Income and Expense columns: side by side on macOS, stacked on iOS.
    #if os(macOS)
      HStack(spacing: 0) {
        categoryTable(
          title: "Income",
          balances: reportingStore.incomeBalances,
          transactionType: .income,
          uncategorised: reportingStore.incomeUncategorised,
          hasUnavailableData: reportingStore.incomeHasUnavailableData)
        Divider()
        categoryTable(
          title: "Expenses",
          balances: reportingStore.expenseBalances,
          transactionType: .expense,
          uncategorised: reportingStore.expenseUncategorised,
          hasUnavailableData: reportingStore.expenseHasUnavailableData)
      }
    #else
      VStack(spacing: 0) {
        categoryTable(
          title: "Income",
          balances: reportingStore.incomeBalances,
          transactionType: .income,
          uncategorised: reportingStore.incomeUncategorised,
          hasUnavailableData: reportingStore.incomeHasUnavailableData)
        Divider()
        categoryTable(
          title: "Expenses",
          balances: reportingStore.expenseBalances,
          transactionType: .expense,
          uncategorised: reportingStore.expenseUncategorised,
          hasUnavailableData: reportingStore.expenseHasUnavailableData)
      }
    #endif
  }

  private func categoryTable(
    title: String,
    balances: [UUID: InstrumentAmount],
    transactionType: TransactionType,
    uncategorised: InstrumentAmount?,
    hasUnavailableData: Bool
  ) -> some View {
    CategoryBalanceTable(
      title: title,
      balances: balances,
      categories: categories,
      dateRange: resolvedFrom...resolvedTo,
      profileInstrument: reportingStore.profileCurrency,
      uncategorised: uncategorised,
      transactionType: transactionType,
      hasUnavailableData: hasUnavailableData)
  }

  @ViewBuilder
  private func drillDownDestination(_ drillDown: CategoryDrillDown) -> some View {
    let categoryName =
      categories.by(id: drillDown.categoryId).map { categories.path(for: $0) } ?? "Category"
    TransactionListView(
      title: categoryName,
      filter: TransactionFilter(
        dateRange: drillDown.dateRange,
        categoryIds: drillDown.categoryIds(in: categories)),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore)
  }

  @ViewBuilder
  private func uncategorisedDrillDownDestination(_ drillDown: UncategorisedDrillDown)
    -> some View
  {
    TransactionListView(
      title: "Uncategorised",
      filter: TransactionFilter(
        dateRange: drillDown.dateRange,
        uncategorisedLegType: drillDown.transactionType),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore)
  }

  /// Stable identity for the `.task(id:)` trigger — re-running the load
  /// whenever either endpoint changes while letting SwiftUI cancel any
  /// in-flight request when the view disappears.
  private struct DateRangeKey: Hashable {
    let from: Date
    let to: Date
  }

  private var dateRangeSelector: some View {
    HStack(spacing: 16) {
      Picker("Date Range", selection: $dateRange) {
        ForEach(DateRange.allCases) { range in
          Text(range.displayName).tag(range)
        }
      }
      .pickerStyle(.menu)
      #if os(macOS)
        .frame(width: 200)
      #endif

      if dateRange == .custom {
        DatePicker("From", selection: $customFrom, displayedComponents: .date)
          .labelsHidden()

        DatePicker("To", selection: $customTo, displayedComponents: .date)
          .labelsHidden()
      }

      Spacer()
    }
    .padding()
  }
}

private struct ReportsPreviewIds {
  let salaryId = UUID()
  let groceriesId = UUID()
  let rentId = UUID()
}

@MainActor
private func seedReportsPreview(
  backend: any BackendProvider,
  account: Account,
  ids: ReportsPreviewIds
) async {
  _ = try? await backend.accounts.create(
    account, openingBalance: InstrumentAmount(quantity: 5_000, instrument: .AUD))
  _ = try? await backend.categories.create(Category(id: ids.salaryId, name: "Salary"))
  _ = try? await backend.categories.create(Category(id: ids.groceriesId, name: "Groceries"))
  _ = try? await backend.categories.create(Category(id: ids.rentId, name: "Rent"))
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date(),
      payee: "Employer",
      legs: [
        TransactionLeg(
          accountId: account.id,
          instrument: .AUD,
          quantity: 4500,
          type: .income,
          categoryId: ids.salaryId)
      ]))
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-86400),
      payee: "Supermarket",
      legs: [
        TransactionLeg(
          accountId: account.id,
          instrument: .AUD,
          quantity: -220,
          type: .expense,
          categoryId: ids.groceriesId)
      ]))
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-2 * 86400),
      payee: "Landlord",
      legs: [
        TransactionLeg(
          accountId: account.id,
          instrument: .AUD,
          quantity: -1800,
          type: .expense,
          categoryId: ids.rentId)
      ]))
}

#Preview {
  let backend = PreviewBackend.create()
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let reportingStore = ReportingStore(
    transactionRepository: backend.transactions,
    analysisRepository: backend.analysis,
    conversionService: backend.conversionService,
    profileCurrency: .AUD)
  let ids = ReportsPreviewIds()
  let categories = Categories(from: [
    Category(id: ids.salaryId, name: "Salary"),
    Category(id: ids.groceriesId, name: "Groceries"),
    Category(id: ids.rentId, name: "Rent"),
  ])
  let account = Account(name: "Checking", type: .bank, instrument: .AUD)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  return ReportsView(
    reportingStore: reportingStore,
    categories: categories,
    accounts: Accounts(from: [account]),
    earmarks: Earmarks(from: []),
    transactionStore: transactionStore
  )
  .previewProfileEnvironment(session: session)
  .frame(width: 900, height: 600)
  .task {
    await seedReportsPreview(backend: backend, account: account, ids: ids)
  }
}
