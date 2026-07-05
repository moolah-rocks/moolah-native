import SwiftUI
import os

private let logger = Logger(subsystem: "com.moolah.app", category: "EarmarkBudgetSectionView")

struct EarmarkBudgetSectionView: View {
  let earmark: Earmark
  let categories: Categories
  let analysisRepository: AnalysisRepository
  // `internal` (not `private`) — read from `EarmarkBudgetSectionView+Rows.swift` too.
  @Environment(EarmarkStore.self) var earmarkStore

  @State private var categoryBalances: [UUID: InstrumentAmount] = [:]
  @State private var uncategorised: InstrumentAmount?
  @State private var isLoadingBalances = false
  @State private var loadError: Error?
  @State private var showAddSheet = false
  // Read/written from `EarmarkBudgetSectionView+Rows.swift` too, so these
  // (and the computed/helper members below marked the same way) are not
  // `private` — `private` is file-scoped in Swift and would be invisible to
  // an extension in another file (see `SidebarView` / `SidebarView+Sections`
  // for the established precedent of this split).
  @State var editingLineItem: BudgetLineItem?
  @State var deleteConfirmation: BudgetLineItem?

  @ScaledMetric var columnMinWidth: CGFloat = 70
  @ScaledMetric var columnIdealWidth: CGFloat = 90

  var body: some View {
    Group {
      if earmarkStore.isBudgetLoading || isLoadingBalances {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let loadError {
        ContentUnavailableView {
          Label("Error Loading Budget", systemImage: "exclamationmark.triangle")
        } description: {
          Text(loadError.localizedDescription)
        } actions: {
          Button("Try Again") {
            Task {
              await loadCategoryBalances()
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if lineItems.isEmpty && earmarkStore.budgetItems.isEmpty {
        ContentUnavailableView(
          "No Budget",
          systemImage: "bookmark",
          description: Text(
            PlatformActionVerb.emptyStatePrompt(
              buttonLabel: "+", suffix: "to add your first budget allocation."))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        budgetList
      }
    }
    .task(id: earmark.id) {
      await loadData()
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showAddSheet = true
        } label: {
          Label("Add Budget Line Item", systemImage: "plus")
        }
        .accessibilityLabel("Add budget line item")
      }
    }
    .sheet(isPresented: $showAddSheet) {
      AddBudgetLineItemSheet(
        earmark: earmark,
        categories: categories,
        existingCategoryIds: Set(earmarkStore.budgetItems.map(\.categoryId))
      )
    }
    .sheet(item: $editingLineItem) { lineItem in
      EditBudgetAmountSheet(
        earmark: earmark,
        lineItem: lineItem
      )
    }
    .confirmationDialog(
      "Delete Budget Item",
      isPresented: Binding(
        get: { deleteConfirmation != nil },
        set: { if !$0 { deleteConfirmation = nil } }
      ),
      presenting: deleteConfirmation
    ) { item in
      Button("Delete", role: .destructive) {
        Task {
          await earmarkStore.removeBudgetItem(
            earmarkId: earmark.id, categoryId: item.id)
        }
      }
    } message: { item in
      Text("Remove \(item.categoryPath) from the budget?")
    }
    .refreshable {
      await loadData()
    }
  }

  // `internal` (not `private`) — read from `budgetList`/`deleteBudgetItems` in
  // `EarmarkBudgetSectionView+Rows.swift` as well as from `body` above.
  var lineItems: [BudgetLineItem] {
    BudgetLineItem.buildLineItems(
      budgetItems: earmarkStore.budgetItems,
      categoryBalances: categoryBalances,
      categories: categories,
      earmarkInstrument: earmark.instrument,
      uncategorised: uncategorised
    )
  }

  private func loadData() async {
    isLoadingBalances = true
    async let budgetLoad: () = earmarkStore.loadBudget(earmarkId: earmark.id)
    async let balancesLoad: () = loadCategoryBalances()
    _ = await (budgetLoad, balancesLoad)
    isLoadingBalances = false
  }

  private func loadCategoryBalances() async {
    let distantPast = Date.distantPast
    let now = Date()
    loadError = nil
    do {
      let result = try await analysisRepository.fetchCategoryBalances(
        dateRange: distantPast...now,
        transactionType: .expense,
        filters: TransactionFilter(earmarkId: earmark.id),
        targetInstrument: earmark.instrument
      )
      categoryBalances = result.byCategory
      uncategorised = result.uncategorised
    } catch is CancellationError {
      // `.task(id: earmark.id)` is cancelled whenever the earmark changes or the
      // view goes away; treat it as a normal lifecycle event rather than an error
      // (mirrors `ReportingStore.loadCategoryBalances`).
    } catch {
      logger.error("Failed to load category balances for earmark \(earmark.id): \(error)")
      categoryBalances = [:]
      uncategorised = nil
      loadError = error
    }
  }
}

private struct EarmarkBudgetPreviewIds {
  let groceriesId = UUID()
  let diningId = UUID()
}

@MainActor
private func seedEarmarkBudgetPreview(
  backend: any BackendProvider,
  earmark: Earmark,
  earmarkStore: EarmarkStore,
  ids: EarmarkBudgetPreviewIds
) async {
  let accountId = UUID()
  _ = try? await backend.accounts.create(
    Account(id: accountId, name: "Test", type: .bank, instrument: .AUD))
  _ = try? await backend.earmarks.create(earmark)
  _ = try? await backend.categories.create(Category(id: ids.groceriesId, name: "Groceries"))
  _ = try? await backend.categories.create(Category(id: ids.diningId, name: "Dining"))

  // Budgeted category with spend against it.
  await earmarkStore.addBudgetItem(
    earmarkId: earmark.id,
    categoryId: ids.groceriesId,
    amount: InstrumentAmount(quantity: 300, instrument: .AUD))
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date(),
      payee: "Supermarket",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: -150,
          type: .expense,
          categoryId: ids.groceriesId,
          earmarkId: earmark.id)
      ]))

  // Spend in a category with no budget item ("unbudgeted" row).
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-86400),
      payee: "Restaurant",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: -60,
          type: .expense,
          categoryId: ids.diningId,
          earmarkId: earmark.id)
      ]))

  // Spend with no category at all — synthesizes the "Uncategorised" row.
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-2 * 86400),
      payee: "Cash Withdrawal",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: -40,
          type: .expense,
          earmarkId: earmark.id)
      ]))
}

#Preview {
  let backend = PreviewBackend.create()
  let earmark = Earmark(name: "Holiday Fund", instrument: .AUD)
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let ids = EarmarkBudgetPreviewIds()
  let categories = Categories(from: [
    Category(id: ids.groceriesId, name: "Groceries"),
    Category(id: ids.diningId, name: "Dining"),
  ])
  return NavigationStack {
    EarmarkBudgetSectionView(
      earmark: earmark,
      categories: categories,
      analysisRepository: backend.analysis
    )
    .environment(earmarkStore)
  }
  .previewProfileEnvironment()
  .task {
    await seedEarmarkBudgetPreview(
      backend: backend, earmark: earmark, earmarkStore: earmarkStore, ids: ids)
  }
}

/// `AnalysisRepository` double that always fails `fetchCategoryBalances`, so
/// this preview can exercise `EarmarkBudgetSectionView`'s `loadError` /
/// "Try Again" `ContentUnavailableView` branch without a real backend error.
private struct FailingCategoryBalancesRepository: AnalysisRepository {
  struct PreviewError: Error, LocalizedError {
    var errorDescription: String? { "Preview-only failure" }
  }

  func fetchDailyBalances(after: Date?, forecastUntil: Date?) async throws -> [DailyBalance] { [] }
  func fetchExpenseBreakdown(monthEnd: Int, after: Date?) async throws -> [ExpenseBreakdown] { [] }
  func fetchIncomeAndExpense(
    monthEnd: Int, after: Date?
  ) async throws -> [MonthlyIncomeExpense] { [] }
  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> CategoryBalances {
    throw PreviewError()
  }
}

#Preview("Load error") {
  let backend = PreviewBackend.create()
  let earmark = Earmark(name: "Holiday Fund", instrument: .AUD)
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  return NavigationStack {
    EarmarkBudgetSectionView(
      earmark: earmark,
      categories: Categories(from: []),
      analysisRepository: FailingCategoryBalancesRepository()
    )
    .environment(earmarkStore)
  }
  .previewProfileEnvironment()
  .task {
    _ = try? await backend.earmarks.create(earmark)
  }
}
