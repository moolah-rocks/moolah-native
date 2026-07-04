import SwiftUI

struct TransactionFilterView: View {
  let filter: TransactionFilter
  /// The navigation scope's account universe. Empty means the global
  /// transaction list (all accounts selectable). Non-empty (an account
  /// group, or a single account) constrains the account picker to those
  /// ids and is the fallback applied when the selection means "all".
  let scopeAccountIds: Set<UUID>
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let onApply: (TransactionFilter) -> Void

  @State private var selectedAccountIds: Set<UUID> = []
  @State private var showAccountPicker = false
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
    scopeAccountIds: Set<UUID>,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    onApply: @escaping (TransactionFilter) -> Void
  ) {
    self.filter = filter
    self.scopeAccountIds = scopeAccountIds
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.onApply = onApply

    // Seed the picker from the incoming filter. When the filter's account
    // set equals the whole scope (the default group filter), seed empty so
    // the picker reads "All accounts"; a strict subset seeds that subset.
    let incoming = filter.accountIds
    _selectedAccountIds = State(
      initialValue: incoming == scopeAccountIds ? [] : incoming)
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
          .accessibilityIdentifier(UITestIdentifiers.TransactionFilter.apply)
      }
      ToolbarItem(placement: .destructiveAction) {
        Button("Reset", role: .destructive) { clearAll() }
          .disabled(!hasAnySelection)
      }
    }
  }

  private var hasAnySelection: Bool {
    !selectedAccountIds.isEmpty
      || selectedEarmarkId != nil
      || selectedScheduled != .all
      || dateRangeLowerBound != nil
      || dateRangeUpperBound != nil
      || !selectedCategoryIds.isEmpty
      || !payeeText.isEmpty
  }

  /// Accounts offered in the picker: the scope's members, or every account
  /// when the scope is global (empty).
  private var availableAccounts: [Account] {
    guard !scopeAccountIds.isEmpty else { return accounts.ordered }
    return accounts.ordered.filter { scopeAccountIds.contains($0.id) }
  }

  private var availableAccountIds: Set<UUID> {
    Set(availableAccounts.map(\.id))
  }

  private var scopeSection: some View {
    Section("Scope") {
      // A single-account view has nothing to narrow, so the account
      // control only appears when more than one account is in scope.
      if availableAccounts.count > 1 {
        accountPickerRow
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

  private var dateRangeSection: some View {
    Section("Date Range") {
      Toggle("Filter by Date", isOn: dateRangeEnabledBinding)
        .accessibilityIdentifier(UITestIdentifiers.TransactionFilter.dateToggle)
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

    let resolvedAccountIds = TransactionFilter.scopedAccountIds(
      forSelection: selectedAccountIds,
      scope: scopeAccountIds,
      available: availableAccountIds)

    let newFilter = TransactionFilter(
      accountId: filter.accountId,
      accountIds: resolvedAccountIds,
      earmarkId: selectedEarmarkId,
      scheduled: selectedScheduled,
      dateRange: dateRange,
      categoryIds: selectedCategoryIds,
      payee: payeeText.isEmpty ? nil : payeeText
    )

    onApply(newFilter)
  }

  private func clearAll() {
    selectedAccountIds = []
    selectedEarmarkId = nil
    selectedScheduled = .all
    dateRangeLowerBound = nil
    dateRangeUpperBound = nil
    selectedCategoryIds = []
    payeeText = ""
  }
}

// MARK: - Picker Row Views

extension TransactionFilterView {
  @ViewBuilder private var accountPickerRow: some View {
    let summary = AccountMultiSelectPicker.selectionSummary(
      for: selectedAccountIds, available: availableAccounts)
    #if os(macOS)
      LabeledContent("Accounts") {
        Button {
          showAccountPicker = true
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
        .accessibilityLabel("Accounts")
        .accessibilityValue(summary)
        .accessibilityHint("Opens the account picker")
        .accessibilityIdentifier(UITestIdentifiers.TransactionFilter.accountPicker)
        .popover(isPresented: $showAccountPicker, arrowEdge: .trailing) {
          AccountMultiSelectPicker(
            accounts: availableAccounts,
            selectedIds: $selectedAccountIds
          )
          .frame(width: 320, height: 420)
        }
      }
    #else
      NavigationLink {
        AccountMultiSelectPicker(
          accounts: availableAccounts,
          selectedIds: $selectedAccountIds
        )
      } label: {
        LabeledContent("Accounts", value: summary)
      }
      .accessibilityIdentifier(UITestIdentifiers.TransactionFilter.accountPicker)
      .accessibilityHint("Opens the account picker")
    #endif
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
      .accessibilityHint("Opens the category picker")
    #endif
  }
}

#Preview {
  let accounts = Accounts(from: [
    Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 2449.77)]
    ),
    Account(
      id: UUID(),
      name: "Savings",
      type: .bank,
      instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 8150.00)]
    ),
  ])

  let categories = Categories(from: [
    Category(id: UUID(), name: "Groceries", parentId: nil),
    Category(id: UUID(), name: "Transport", parentId: nil),
  ])

  let earmarks = Earmarks(from: [Earmark(id: UUID(), name: "Emergency Fund", instrument: .AUD)])

  TransactionFilterView(
    filter: TransactionFilter(),
    scopeAccountIds: [],
    accounts: accounts,
    categories: categories,
    earmarks: earmarks,
    onApply: { _ in }
  )
}
