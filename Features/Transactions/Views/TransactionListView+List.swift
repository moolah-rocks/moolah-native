import SwiftUI

extension TransactionListView {
  // MARK: - Selection Bridging

  /// Bridges the `List`'s `Set<Transaction.ID>` selection to the
  /// existing single-selection inspector. The getter projects the
  /// single `selectedTransaction` (so an inspector-driven selection
  /// highlights its row); the setter records the full multi-selection
  /// and resolves a single pick to `selectedTransaction`, leaving it
  /// `nil` for an empty or multi-row selection.
  var listSelectionBinding: Binding<Set<Transaction.ID>> {
    Binding(
      get: {
        if let id = selectedTransaction?.id { return [id] }
        return transferMergeSelection
      },
      set: { newSelection in
        transferMergeSelection = newSelection
        if newSelection.count == 1, let id = newSelection.first {
          selectedTransaction =
            transactionStore.transactions.first {
              $0.transaction.id == id
            }?.transaction
        } else {
          selectedTransaction = nil
        }
      }
    )
  }

  // MARK: - Top-Level View Composition

  /// Module-internal (not `private`) because `TransactionListView.body` in
  /// the main `.swift` file references this directly. The `private` scope
  /// SwiftLint would prefer is unavailable across files even within the
  /// same type's extensions; module-internal is the smallest legal scope.
  var transactionsList: some View {
    List(selection: listSelectionBinding) {
      listContent
    }
    #if os(macOS)
      .listStyle(.inset)
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentOffset.y
      } action: { _, newOffset in
        scrollCollapse?.update(offsetY: newOffset)
      }
    #else
      .listStyle(.plain)
    #endif
    .accessibilityIdentifier(UITestIdentifiers.TransactionList.container)
    .profileNavigationTitle(displayTitle)
    .toolbar { listToolbarContent }
    .sheet(isPresented: $showFilterSheet) {
      TransactionFilterView(
        filter: activeFilter,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        onApply: { newFilter in
          activeFilter = newFilter
          showFilterSheet = false
        }
      )
    }
    .onChange(of: baseFilter) { _, newBase in
      // Genuine context change (e.g. user navigated from one account to
      // another): clear any stale selection and reset the user-applied
      // filter so the toolbar reflects the new context.
      selectedTransaction = nil
      activeFilter = newBase
      // A new account/earmark always opens with its header expanded; it
      // collapses again only once the user scrolls. No-op when no split
      // is hosting us.
      scrollCollapse?.reset()
    }
    .task(id: activeFilter) {
      // The view-driven reactive subscription. The store owns the
      // for-await loop; the view only starts and cancels it. `.task`
      // runs `observe(filter:)` until cancelled (filter change or
      // unmount).
      await transactionStore.observe(filter: activeFilter)
    }
    .refreshable {
      await transactionStore.load(
        filter: filter)
    }
    .searchable(text: $searchText, prompt: "Search payee")
    .overlay {
      emptyStateOverlay
    }
  }

  /// The list's toolbar items. Extracted from `transactionsList`'s
  /// modifier chain so that closure stays within SwiftLint's
  /// closure-body length budget as items are added.
  @ToolbarContentBuilder private var listToolbarContent: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      Button {
        showFilterSheet = true
      } label: {
        Label(
          "Filter",
          systemImage: activeFilter != baseFilter
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle")
      }
    }

    ToolbarItem(placement: .automatic) {
      Button {
        Task { await transactionStore.load(filter: filter) }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
    }

    ToolbarItem(placement: .automatic) {
      Button {
        if let (sideA, sideB) = manualMergePair {
          Task { await transactionStore.manualMerge(sideA, sideB) }
        }
      } label: {
        Label("Merge as Transfer", systemImage: "arrow.left.arrow.right")
      }
      .disabled(manualMergePair == nil)
    }

    ToolbarItem(placement: .primaryAction) {
      addToolbarButton
    }

    #if os(iOS)
      ToolbarItem(placement: .primaryAction) {
        Button {
          showSpamTransactions.toggle()
        } label: {
          Label(
            showSpamTransactions ? "Hide Spam Transactions" : "Show Spam Transactions",
            systemImage: showSpamTransactions ? "eye" : "eye.slash"
          )
        }
        .accessibilityLabel("Spam Transactions")
        .accessibilityValue(showSpamTransactions ? "shown" : "hidden")
        .accessibilityIdentifier(UITestIdentifiers.TransactionList.spamToggleButton)
      }
    #endif
  }

  // MARK: - List Content & Toolbar

  /// The List content, branched on `grouping`. The `.flat` case renders
  /// today's flat list; `.scheduledStatus` sections rows into Overdue /
  /// Upcoming via the store's pre-computed paths. Both branches share the
  /// surrounding modifier chain on `transactionsList` so future modifier
  /// additions don't have to be duplicated.
  @ViewBuilder private var listContent: some View {
    switch grouping {
    case .flat:
      ForEach(filteredTransactions) { entry in
        transactionRow(for: entry)
      }
      loadMoreFooter
    case .scheduledStatus:
      let overdue = transactionStore.scheduledOverdueTransactions
      let upcoming = transactionStore.scheduledUpcomingTransactions
      if !overdue.isEmpty {
        Section("Overdue") {
          ForEach(overdue) { entry in
            transactionRow(for: entry)
          }
        }
      }
      if !upcoming.isEmpty {
        Section("Upcoming") {
          ForEach(upcoming) { entry in
            transactionRow(for: entry)
          }
        }
      }
    }
  }

  /// The toolbar's primary-action Add button. Branches on `grouping` so
  /// the `.scheduledStatus` mode shows "Add Scheduled Transaction" with a
  /// `calendar.badge.plus` icon and creates a recurring placeholder.
  @ViewBuilder private var addToolbarButton: some View {
    if case .scheduledStatus = grouping {
      Button {
        createNewScheduledTransaction()
      } label: {
        Label("Add Scheduled Transaction", systemImage: "calendar.badge.plus")
      }
    } else {
      Button {
        createNewTransaction()
      } label: {
        Label("Add Transaction", systemImage: "plus")
      }
    }
  }

  // MARK: - Row Rendering & Per-Row Helpers

  private var scopeReferenceInstrument: Instrument {
    if let accountId = filter.accountId, let account = accounts.by(id: accountId) {
      return account.instrument
    }
    if let earmarkId = filter.earmarkId, let earmark = earmarks.by(id: earmarkId) {
      return earmark.instrument
    }
    // The fallback path is only reachable when the filter has neither an
    // accountId nor an earmarkId — i.e., All Transactions / Recently Added.
    // Use the account-aligned `currentTargetInstrument` (tracks the loaded
    // account's instrument) rather than the profile-default `targetInstrument`
    // so a no-account filter against a non-profile-currency view still resolves
    // to the right reference instrument.
    return transactionStore.currentTargetInstrument
  }

  /// Per-row description perspective. When the filter scopes to one or more
  /// accounts, returns the single in-scope account id iff the transaction
  /// touches exactly one of them; otherwise nil for the no-context style.
  /// When the filter has no account scope (all-accounts / scheduled), treats
  /// every leg's account as in scope so single-account transactions still
  /// resolve to that account and multi-account ones fall back to no-context.
  private func accountContext(for transaction: Transaction) -> UUID? {
    let inScopeAccountIds: [UUID]
    if filter.hasAccountFilter {
      var scope: Set<UUID> = filter.accountIds
      if let id = filter.accountId { scope.insert(id) }
      inScopeAccountIds = transaction.legs
        .compactMap(\.accountId)
        .filter { scope.contains($0) }
    } else {
      inScopeAccountIds = transaction.legs.compactMap(\.accountId)
    }
    let uniqueAccounts = Set(inScopeAccountIds)
    return uniqueAccounts.count == 1 ? uniqueAccounts.first : nil
  }

  @ViewBuilder
  private func transactionRow(for entry: TransactionWithBalance) -> some View {
    let scheduled = scheduledRowConfig(for: entry)
    TransactionRowView(
      transaction: entry.transaction,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      displayAmounts: entry.displayAmounts,
      balance: entry.balance,
      scopeReferenceInstrument: scopeReferenceInstrument,
      hideEarmark: filter.earmarkId != nil,
      accountContext: accountContext(for: entry.transaction),
      isOverdue: scheduled?.isOverdue ?? false,
      isDueToday: scheduled?.isDueToday ?? false,
      onPay: scheduled?.onPay,
      pendingPayId: scheduled?.pendingPayId
    )
    .tag(entry.transaction.id)
    .accessibilityIdentifier(
      UITestIdentifiers.TransactionList.transaction(entry.transaction.id)
    )
    .contentShape(Rectangle())
    .contextMenu { rowContextMenu(for: entry.transaction, isScheduled: scheduled != nil) }
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) {
        transactionPendingDelete = entry.transaction.id
      } label: {
        Label("Delete Transaction", systemImage: "trash")
      }
    }
    .swipeActions(edge: .leading) {
      if let scheduled {
        Button {
          scheduled.onPay()
        } label: {
          Label("Pay Scheduled Transaction", systemImage: "checkmark.circle")
        }
        .tint(.green)
      }
    }
    .task {
      if entry.id == transactionStore.transactions.last?.id {
        await transactionStore.loadMore()
      }
    }
  }

  /// Cached set of overdue transaction ids, computed once per body
  /// evaluation rather than per row. Empty for any non-scheduled grouping.
  private var overdueTransactionIds: Set<Transaction.ID> {
    Set(transactionStore.scheduledOverdueTransactions.map(\.transaction.id))
  }

  /// Per-row scheduled context. Returns `nil` for any non-scheduled
  /// grouping; the row then renders with all defaults (no overdue
  /// styling, no Pay button, no leading swipe). For `.scheduledStatus`,
  /// it computes the row's overdue / due-today flags against the store's
  /// pre-computed sectioning (so a row's section assignment and its
  /// `isOverdue` flag can never disagree) and exposes a typed Pay
  /// closure that writes the row id into the case's binding.
  private func scheduledRowConfig(for entry: TransactionWithBalance) -> ScheduledRowConfig? {
    guard case let .scheduledStatus(today, pendingPayId) = grouping else {
      return nil
    }
    let isOverdue = overdueTransactionIds.contains(entry.transaction.id)
    let isDueToday =
      !isOverdue
      && Calendar.current.isDate(entry.transaction.date, inSameDayAs: today)
    return ScheduledRowConfig(
      isOverdue: isOverdue,
      isDueToday: isDueToday,
      pendingPayId: pendingPayId.wrappedValue,
      onPay: { pendingPayId.wrappedValue = entry.transaction.id }
    )
  }

  @ViewBuilder
  private func rowContextMenu(for transaction: Transaction, isScheduled: Bool) -> some View {
    if isScheduled, case .scheduledStatus(_, let pendingPayId) = grouping {
      Button("Pay Scheduled Transaction\u{2026}", systemImage: "checkmark.circle") {
        pendingPayId.wrappedValue = transaction.id
      }
    }
    Button("Edit Transaction\u{2026}", systemImage: "pencil") {
      selectedTransaction = transaction
    }
    // Only offer "Create rule from this…" for CSV-imported rows —
    // ImportOrigin is how we extract distinguishing tokens, and
    // manually-entered transactions don't have one.
    if transaction.importOrigin?.singleOrigin != nil {
      Button("Create rule from this\u{2026}", systemImage: "plus.rectangle.on.folder") {
        createRuleFromTransaction = transaction
      }
    }
    if let pair = manualMergePair, pair.0.id == transaction.id || pair.1.id == transaction.id {
      Button("Merge as Transfer", systemImage: "arrow.left.arrow.right") {
        Task { await transactionStore.manualMerge(pair.0, pair.1) }
      }
      .accessibilityIdentifier(UITestIdentifiers.TransferDetection.merge(transaction.id))
    }
    let mergeCandidates = mergeSelection
    if mergeCandidates.contains(where: { $0.id == transaction.id }) {
      Button("Merge Transactions", systemImage: "arrow.triangle.merge") {
        Task { await transactionStore.mergeTransactions(mergeCandidates) }
      }
      .accessibilityIdentifier(UITestIdentifiers.TransactionMerge.merge(transaction.id))
    }
    if transaction.isMergedTransfer {
      Button(
        "Split Back into Separate Transactions\u{2026}",
        systemImage: "arrow.triangle.branch",
        role: .destructive
      ) {
        transactionPendingUnmerge = transaction.id
      }
      .accessibilityIdentifier(UITestIdentifiers.TransferDetection.unmerge(transaction.id))
    }
    Divider()
    Button("Delete Transaction\u{2026}", systemImage: "trash", role: .destructive) {
      transactionPendingDelete = transaction.id
    }
  }

}

// MARK: - Supporting Types

/// Per-row scheduled context bundle. Held as a `let` on the row so the
/// nil-vs-non-nil distinction (no scheduled context vs. scheduled
/// context) drives both the row's flags and the leading-swipe Pay
/// action — keeps the row's "is this a scheduled row" check on a
/// single source of truth.
private struct ScheduledRowConfig {
  let isOverdue: Bool
  let isDueToday: Bool
  let pendingPayId: Transaction.ID?
  let onPay: () -> Void
}
