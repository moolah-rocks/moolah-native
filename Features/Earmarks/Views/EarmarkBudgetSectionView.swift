import SwiftUI

struct EarmarkBudgetSectionView: View {
  let earmark: Earmark
  let categories: Categories
  let analysisRepository: AnalysisRepository
  @Environment(EarmarkStore.self) private var earmarkStore

  @State private var categoryBalances: [UUID: InstrumentAmount] = [:]
  @State private var isLoadingBalances = false
  @State private var showAddSheet = false
  @State private var editingLineItem: BudgetLineItem?
  @State private var deleteConfirmation: BudgetLineItem?

  @ScaledMetric private var columnMinWidth: CGFloat = 70
  @ScaledMetric private var columnIdealWidth: CGFloat = 90

  var body: some View {
    Group {
      if earmarkStore.isBudgetLoading || isLoadingBalances {
        ProgressView()
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

  private var lineItems: [BudgetLineItem] {
    BudgetLineItem.buildLineItems(
      budgetItems: earmarkStore.budgetItems,
      categoryBalances: categoryBalances,
      categories: categories,
      earmarkInstrument: earmark.instrument
    )
  }

  private var totalActual: InstrumentAmount {
    // All line items share the earmark's instrument (see
    // `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 1/2). Budget items are
    // stored in the earmark's instrument; category balances are fetched
    // with `targetInstrument: earmark.instrument` below.
    lineItems.reduce(.zero(instrument: earmark.instrument)) { $0 + $1.actual }
  }

  private var totalBudgeted: InstrumentAmount {
    lineItems.reduce(.zero(instrument: earmark.instrument)) { $0 + $1.budgeted }
  }

  private var totalRemaining: InstrumentAmount {
    totalBudgeted + totalActual
  }

  private var unallocated: InstrumentAmount? {
    BudgetLineItem.unallocatedAmount(
      budgetItems: earmarkStore.budgetItems,
      savingsGoal: earmark.savingsGoal
    )
  }

  private var budgetList: some View {
    List {
      Section {
        headerRow
          .listRowBackground(Color.clear)

        ForEach(lineItems) { lineItem in
          budgetRow(lineItem)
        }
        .onDelete { offsets in
          deleteBudgetItems(at: offsets)
        }
      }

      Section {
        totalRow

        if let unallocated {
          unallocatedRow(unallocated)
        }
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
  }

  private var headerRow: some View {
    HStack(spacing: 0) {
      Text("Category")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Actual")
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
      Text("Budget")
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
      Text("Remaining")
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityAddTraits(.isHeader)
  }

  private func budgetRow(_ lineItem: BudgetLineItem) -> some View {
    HStack(spacing: 0) {
      Text(lineItem.categoryPath)
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.body)

      InstrumentAmountView(amount: lineItem.actual)
        .font(.body)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)

      Button {
        editingLineItem = lineItem
      } label: {
        InstrumentAmountView(amount: lineItem.budgeted, colorOverride: .primary)
          .font(.body)
          .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Edit budget for \(lineItem.categoryPath)")

      InstrumentAmountView(amount: lineItem.remaining)
        .font(.body)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(lineItem.categoryPath): spent \(lineItem.actual.formatted), budget \(lineItem.budgeted.formatted), remaining \(lineItem.remaining.formatted)"
    )
  }

  private var totalRow: some View {
    HStack(spacing: 0) {
      Text("Total")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)

      InstrumentAmountView(amount: totalActual)
        .font(.headline)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)

      InstrumentAmountView(amount: totalBudgeted, colorOverride: .primary)
        .font(.headline)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)

      InstrumentAmountView(amount: totalRemaining)
        .font(.headline)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Total: spent \(totalActual.formatted), budget \(totalBudgeted.formatted), remaining \(totalRemaining.formatted)"
    )
  }

  private func unallocatedRow(_ amount: InstrumentAmount) -> some View {
    HStack(spacing: 0) {
      Text("Unallocated")
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      Spacer()
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth)

      InstrumentAmountView(amount: amount)
        .font(.body)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)

      InstrumentAmountView(amount: amount)
        .font(.body)
        .frame(minWidth: columnMinWidth, idealWidth: columnIdealWidth, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Unallocated: \(amount.formatted)")
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
    do {
      categoryBalances =
        try await analysisRepository.fetchCategoryBalances(
          dateRange: distantPast...now,
          transactionType: .expense,
          filters: TransactionFilter(earmarkId: earmark.id),
          targetInstrument: earmark.instrument
        ).byCategory
    } catch {
      categoryBalances = [:]
    }
  }

  private func deleteBudgetItems(at offsets: IndexSet) {
    let items = lineItems
    // Use confirmation for first item; swipe-delete only allows single items
    if let first = offsets.first {
      deleteConfirmation = items[first]
    }
  }
}
