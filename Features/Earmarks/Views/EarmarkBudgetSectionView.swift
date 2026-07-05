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
