import SwiftUI

struct TransactionFilterView: View {
  let filter: TransactionFilter
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let onApply: (TransactionFilter) -> Void

  @State private var selectedAccountId: UUID?
  @State private var selectedEarmarkId: UUID?
  @State private var selectedScheduled: ScheduledFilter = .all
  @State private var dateRangeLowerBound: Date?
  @State private var dateRangeUpperBound: Date?
  @State private var selectedCategoryIds: Set<UUID> = []
  @State private var payeeText: String = ""
  @State private var showCategoryPicker = false

  @Environment(\.dismiss) private var dismiss

  init(
    filter: TransactionFilter,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    onApply: @escaping (TransactionFilter) -> Void
  ) {
    self.filter = filter
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.onApply = onApply

    _selectedAccountId = State(initialValue: filter.accountId)
    _selectedEarmarkId = State(initialValue: filter.earmarkId)
    _selectedScheduled = State(initialValue: filter.scheduled)
    _dateRangeLowerBound = State(initialValue: filter.dateRange?.lowerBound)
    _dateRangeUpperBound = State(initialValue: filter.dateRange?.upperBound)
    _selectedCategoryIds = State(initialValue: filter.categoryIds)
    _payeeText = State(initialValue: filter.payee ?? "")
  }

  var body: some View {
    NavigationStack {
      form
    }
    #if os(macOS)
      .frame(minWidth: 500, minHeight: 400)
    #endif
  }

  private var form: some View {
    Form {
      scopeSection
      matchSection
      dateRangeSection
    }
    .formStyle(.grouped)
    .navigationTitle("Filter Transactions")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Apply") { applyFilter() }
      }
      ToolbarItem(placement: .destructiveAction) {
        Button("Reset", role: .destructive) { clearAll() }
          .disabled(!hasAnySelection)
      }
    }
  }

  private var hasAnySelection: Bool {
    selectedAccountId != nil
      || selectedEarmarkId != nil
      || selectedScheduled != .all
      || dateRangeLowerBound != nil
      || dateRangeUpperBound != nil
      || !selectedCategoryIds.isEmpty
      || !payeeText.isEmpty
  }

  private var scopeSection: some View {
    Section("Scope") {
      Picker("Account", selection: $selectedAccountId) {
        Text("All Accounts").tag(nil as UUID?)
        ForEach(accounts.ordered) { account in
          Text(account.name).tag(account.id as UUID?)
        }
      }
      Picker("Earmark", selection: $selectedEarmarkId) {
        Text("All Earmarks").tag(nil as UUID?)
        ForEach(earmarks.ordered) { earmark in
          Text(earmark.name).tag(earmark.id as UUID?)
        }
      }
    }
  }

  private var matchSection: some View {
    Section("Match") {
      if categories.roots.isEmpty {
        LabeledContent("Categories") {
          Text("No categories available").foregroundStyle(.secondary)
        }
      } else {
        categoryPickerRow
      }
      TextField("Payee", text: $payeeText, prompt: Text("Contains…"))
      Picker("Schedule", selection: $selectedScheduled) {
        Text("All Transactions").tag(ScheduledFilter.all)
        Text("Scheduled Only").tag(ScheduledFilter.scheduledOnly)
        Text("Non-Scheduled Only").tag(ScheduledFilter.nonScheduledOnly)
      }
    }
  }

  @ViewBuilder private var categoryPickerRow: some View {
    // Local `let` is fine before `#if` inside @ViewBuilder — it's a binding,
    // not a result-builder statement.
    let summary = categories.selectionSummary(for: selectedCategoryIds)
    #if os(macOS)
      // The full row is the trigger so any click inside the cell opens the
      // popover — matching how Picker rows in the same form behave. The
      // chevron makes the affordance discoverable without colour.
      LabeledContent("Categories") {
        Button {
          showCategoryPicker = true
        } label: {
          HStack(spacing: 6) {
            Text(summary)
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Categories")
        .accessibilityValue(summary)
        .accessibilityHint("Opens the category picker")
        .popover(isPresented: $showCategoryPicker, arrowEdge: .trailing) {
          CategoryMultiSelectPicker(
            categories: categories,
            selectedIds: $selectedCategoryIds
          )
          .frame(width: 320, height: 420)
        }
      }
    #else
      NavigationLink {
        CategoryMultiSelectPicker(
          categories: categories,
          selectedIds: $selectedCategoryIds
        )
      } label: {
        LabeledContent("Categories", value: summary)
      }
    #endif
  }

  private var dateRangeSection: some View {
    Section("Date Range") {
      Toggle("Filter by Date", isOn: dateRangeEnabledBinding)
      if dateRangeLowerBound != nil && dateRangeUpperBound != nil {
        DatePicker(
          "Start Date", selection: lowerBoundBinding, displayedComponents: .date
        )
        .monospacedDigit()
        DatePicker(
          "End Date", selection: upperBoundBinding, displayedComponents: .date
        )
        .monospacedDigit()
      }
    }
  }

  private var dateRangeEnabledBinding: Binding<Bool> {
    Binding(
      get: { dateRangeLowerBound != nil && dateRangeUpperBound != nil },
      set: { enabled in
        guard enabled else {
          dateRangeLowerBound = nil
          dateRangeUpperBound = nil
          return
        }
        let now = Date()
        dateRangeLowerBound = Calendar.current.date(byAdding: .month, value: -1, to: now)
        dateRangeUpperBound = now
      }
    )
  }

  private var lowerBoundBinding: Binding<Date> {
    Binding(
      get: { dateRangeLowerBound ?? Date() },
      set: { dateRangeLowerBound = $0 }
    )
  }

  private var upperBoundBinding: Binding<Date> {
    Binding(
      get: { dateRangeUpperBound ?? Date() },
      set: { dateRangeUpperBound = $0 }
    )
  }

  private func applyFilter() {
    var dateRange: ClosedRange<Date>?
    if let lower = dateRangeLowerBound, let upper = dateRangeUpperBound {
      dateRange = lower...upper
    }

    let newFilter = TransactionFilter(
      accountId: selectedAccountId,
      earmarkId: selectedEarmarkId,
      scheduled: selectedScheduled,
      dateRange: dateRange,
      categoryIds: selectedCategoryIds,
      payee: payeeText.isEmpty ? nil : payeeText
    )

    onApply(newFilter)
  }

  private func clearAll() {
    selectedAccountId = nil
    selectedEarmarkId = nil
    selectedScheduled = .all
    dateRangeLowerBound = nil
    dateRangeUpperBound = nil
    selectedCategoryIds = []
    payeeText = ""
  }
}

#Preview {
  let accountId = UUID()
  let categoryId = UUID()
  let earmarkId = UUID()

  let accounts = Accounts(from: [
    Account(
      id: accountId,
      name: "Checking",
      type: .bank,
      instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 2449.77)]
    )
  ])

  let categories = Categories(from: [
    Category(id: categoryId, name: "Groceries", parentId: nil),
    Category(id: UUID(), name: "Transport", parentId: nil),
  ])

  let earmarks = Earmarks(from: [
    Earmark(
      id: earmarkId, name: "Emergency Fund", instrument: .AUD
    )
  ])

  TransactionFilterView(
    filter: TransactionFilter(),
    accounts: accounts,
    categories: categories,
    earmarks: earmarks,
    onApply: { _ in }
  )
}
