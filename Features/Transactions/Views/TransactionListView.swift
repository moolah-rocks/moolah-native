import SwiftUI

struct TransactionListView: View {
  // MARK: - Properties
  /// Grouping for the rendered list. Default `.flat` keeps existing
  /// callers unchanged. `.scheduledStatus` bundles a `pendingPayId`
  /// binding that the row's Pay action writes into; the binding is
  /// structurally required when the caller selects that case (no
  /// `Binding<>` defaults to silently-discarding `.constant(nil)`).
  ///
  /// Grouping is @MainActor-only; do not add Sendable conformance —
  /// `Binding<T>`'s closures are MainActor-isolated.
  enum Grouping {
    case flat
    case scheduledStatus(today: Date, pendingPayId: Binding<Transaction.ID?>)
  }

  let title: String
  let baseFilter: TransactionFilter
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let grouping: Grouping
  let amountPresentation: TransactionListAmountPresentation?
  let allowsScheduledFilter: Bool
  let allowsAddingTransactions: Bool
  let allowsSpamFiltering: Bool
  let emptyState: TransactionListEmptyState?
  @Environment(ImportStore.self) private var importStore
  // Module-internal (not `private`) so the file-scope extension in
  // `TransactionListView+List.swift` can read it from the list code.
  // SwiftLint's `strict_fileprivate` rule disallows `fileprivate`, making
  // `internal` the smallest legal cross-file scope. Unlike `activeFilter` /
  // `showFilterSheet`, the extension never reassigns this — it only calls
  // methods through the optional (`scrollCollapse?.update(...)` / `reset()`).
  @Environment(\.transactionScrollCollapse) var scrollCollapse

  /// When non-nil, the parent owns the selection and handles the inspector.
  /// When nil, TransactionListView manages its own selection and inspector.
  private let _externalSelection: Binding<Transaction?>?

  @State private var _internalSelection: Transaction?
  // Widened from `private` to module-internal so the file-scope extension in
  // `TransactionListView+List.swift` can read/mutate these from its
  // computed views and helpers. SwiftLint's `strict_fileprivate` rule
  // disallows `fileprivate`, making `internal` the smallest legal scope
  // when the helpers move to a sibling file.
  @State var activeFilter: TransactionFilter
  @State var showFilterSheet = false

  var filter: TransactionFilter { activeFilter }

  var displayTitle: String {
    if activeFilter != baseFilter {
      return "Filtered Transactions"
    }
    return title
  }

  var selectedTransaction: Transaction? {
    get { _externalSelection?.wrappedValue ?? _internalSelection }
    nonmutating set {
      if let ext = _externalSelection {
        ext.wrappedValue = newValue
      } else {
        _internalSelection = newValue
      }
    }
  }

  var selectedTransactionBinding: Binding<Transaction?> {
    if let ext = _externalSelection {
      return ext
    }
    return $_internalSelection
  }

  /// Raw multi-selection the `List` writes into (⌘/⇧-click). The single
  /// `selectedTransaction` (and therefore the inspector) is derived from
  /// it: exactly one selected row opens the inspector as before; zero or
  /// two-plus selected rows close it (multi-select has no inspector — a
  /// merge candidate, not a detail target). Published as the
  /// `multiSelectedTransactionIDs` focused value and read by both merge
  /// gates — "Merge as Transfer" (pair) and "Merge Transactions" (N-way).
  @State var multiSelectedTransactionIDs: Set<Transaction.ID> = []

  private var handlesOwnInspector: Bool { _externalSelection == nil }

  init(
    title: String,
    filter: TransactionFilter,
    initialFilter: TransactionFilter? = nil,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    grouping: Grouping = .flat,
    amountPresentation: TransactionListAmountPresentation? = nil,
    allowsScheduledFilter: Bool = true,
    allowsAddingTransactions: Bool = true,
    allowsSpamFiltering: Bool = true,
    emptyState: TransactionListEmptyState? = nil
  ) {
    self.title = title
    self.baseFilter = filter
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.grouping = grouping
    self.amountPresentation = amountPresentation
    self.allowsScheduledFilter = allowsScheduledFilter
    self.allowsAddingTransactions = allowsAddingTransactions
    self.allowsSpamFiltering = allowsSpamFiltering
    self.emptyState = emptyState
    self._externalSelection = nil
    self._activeFilter = State(initialValue: initialFilter ?? filter)
  }

  /// Embedded init — parent provides selection binding and handles the
  /// inspector. Used by leaves such as `EarmarkDetailView` that own
  /// transaction selection outside the list.
  init(
    title: String,
    filter: TransactionFilter,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    grouping: Grouping = .flat,
    amountPresentation: TransactionListAmountPresentation? = nil,
    allowsScheduledFilter: Bool = true,
    allowsAddingTransactions: Bool = true,
    allowsSpamFiltering: Bool = true,
    emptyState: TransactionListEmptyState? = nil,
    selectedTransaction: Binding<Transaction?>
  ) {
    self.title = title
    self.baseFilter = filter
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.grouping = grouping
    self.amountPresentation = amountPresentation
    self.allowsScheduledFilter = allowsScheduledFilter
    self.allowsAddingTransactions = allowsAddingTransactions
    self.allowsSpamFiltering = allowsSpamFiltering
    self.emptyState = emptyState
    self._externalSelection = selectedTransaction
    self._activeFilter = State(initialValue: filter)
  }

  // Widened from `private` to module-internal so the file-scope extension in
  // `TransactionListView+List.swift` can sync these into `transactionStore`
  // from `.onAppear` / `.onChange` modifiers and read them in the iOS toolbar.
  // SwiftLint's `strict_fileprivate` rule disallows `fileprivate`, making
  // `internal` the smallest legal cross-file scope.
  @AppStorage("showSpamTransactions") var showSpamTransactions = false
  @Environment(\.spamInstruments) var spamInstruments

  @State private var showError = false
  @State private var errorTitle = "Could not update transactions"
  @State private var errorMessage = ""
  @State var searchText = ""
  @FocusState private var searchFieldFocused: Bool
  @State var transactionPendingDelete: Transaction.ID?
  @State var transactionPendingUnmerge: Transaction.ID?
  @State var createRuleFromTransaction: Transaction?
}

// The body, its focused-command sub-expressions, and the row/import
// helpers live in this same-file extension so the `TransactionListView`
// struct body stays within SwiftLint's type-body-length budget; a
// same-file extension keeps `private` members accessible.
extension TransactionListView {
  // MARK: - Body

  /// Wraps `transactionsList` with the spam-filter priming modifiers so the
  /// `body` modifier chain stays within the Swift type-checker's expression
  /// complexity budget. Keeping these in a separate sub-expression lets the
  /// compiler resolve the view type in two passes rather than one giant chain.
  private var spamFilteredList: some View {
    exportableTransactionsList
      .onAppear {
        if allowsSpamFiltering {
          transactionStore.primeSpamFilter(
            instruments: spamInstruments,
            showSpam: showSpamTransactions)
        }
      }
      .onChange(of: showSpamTransactions) { _, newValue in
        if allowsSpamFiltering {
          transactionStore.showSpam = newValue
        }
      }
      .onChange(of: spamInstruments) { _, newValue in
        if allowsSpamFiltering {
          transactionStore.setSpamInstruments(newValue)
        }
      }
  }

  /// Focused-scene action for Transaction > Merge as Transfer, or nil
  /// when the multi-selection is not a valid transfer pair. Extracted
  /// from `body` so the modifier chain stays within the SwiftUI
  /// type-checker's expression-complexity budget.
  private var mergeAsTransferSceneAction: (() -> Void)? {
    manualMergePair.map { pair in
      { Task { await transactionStore.manualMerge(pair.0, pair.1) } }
    }
  }

  /// Focused-scene action for Transaction > Merge Transactions, or nil
  /// when the multi-selection is not a valid general-merge candidate.
  /// Extracted alongside `mergeAsTransferSceneAction` for the same
  /// type-checker-budget reason.
  private var mergeTransactionsSceneAction: (() -> Void)? {
    let selection = mergeSelection
    guard !selection.isEmpty else { return nil }
    return { Task { await transactionStore.mergeTransactions(selection) } }
  }

  /// The list plus its inspector and the focused-scene command values.
  /// Split out of `body` (which continues with the alert / confirmation
  /// dialogs / CSV addons) so each half stays within the SwiftUI
  /// type-checker's expression-complexity budget — the same two-pass
  /// rationale as `spamFilteredList`.
  private var listWithFocusedCommands: some View {
    spamFilteredList
      .modifier(
        OptionalTransactionInspector(
          enabled: handlesOwnInspector,
          selectedTransaction: selectedTransactionBinding,
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore,
          viewingAccountId: filter.accountId
        )
      )
      .focusedSceneValue(\.newTransactionAction, newTransactionAction)
      .focusedSceneValue(\.findInListAction) { searchFieldFocused = true }
      .searchFocused($searchFieldFocused)
      // When the inspector opens, release our claim on the `.searchable`
      // first responder so focus can land on the detail view's payee/amount
      // field (set imperatively by `TransactionDetailView.task(id:)`).
      // Without this, AppKit's responder-chain fallback — reinforced after
      // a ⌘N menu event — would restore focus to the search field.
      .onChange(of: selectedTransaction) { _, new in
        if new != nil { searchFieldFocused = false }
      }
      .focusedSceneValue(\.selectedTransaction, selectedTransactionBinding)
      .focusedSceneValue(\.selectedTransactionID, selectedTransaction?.id)
      .focusedSceneValue(\.multiSelectedTransactionIDs, multiSelectedTransactionIDs)
      .focusedSceneValue(\.mergeAsTransferAction, mergeAsTransferSceneAction)
      .focusedSceneValue(\.mergeTransactionsAction, mergeTransactionsSceneAction)
      .focusedSceneValue(
        \.unmergeTransferAction,
        selectedTransaction?.isMergedTransfer == true
          ? { transactionPendingUnmerge = selectedTransaction?.id }
          : nil
      )
      .focusedSceneValue(
        \.editTransactionAction,
        selectedTransaction != nil
          ? {
            // Discoverability affordance: under the current architecture
            // dismissing the inspector clears `selectedTransaction` (see
            // `TransactionInspectorModifier.isPresented`), so this action is
            // only published when the inspector is already open and the
            // self-assign is a no-op. The menu item exists so users can
            // discover that Edit is available without right-clicking the row.
            // If the inspector ever stops clearing selection on dismissal,
            // this self-assign needs to become an explicit reopen path.
            selectedTransaction = selectedTransaction
          }
          : nil
      )
      .focusedSceneValue(
        \.deleteTransactionAction,
        selectedTransaction != nil
          ? { transactionPendingDelete = selectedTransaction?.id }
          : nil
      )
  }

  var body: some View {
    listWithFocusedCommands
      .alert(errorTitle, isPresented: $showError) {
        Button("Dismiss", role: .cancel) {}
      } message: {
        Text(errorMessage)
      }
      .task(id: transactionStore.error?.localizedDescription) {
        // Re-fires whenever the store's error description changes — including
        // the X → nil transition that follows a successful retry. Without the
        // `else` branch a stale `showError = true` would survive the error
        // being cleared by the next `load()`, latching the alert on every
        // subsequent mount.
        if let error = transactionStore.error {
          errorTitle = "Could not update transactions"
          errorMessage = error.userMessage
          showError = true
        } else {
          showError = false
        }
      }
      .confirmationDialog(
        "Delete this transaction?",
        isPresented: Binding(
          get: { transactionPendingDelete != nil },
          set: { if !$0 { transactionPendingDelete = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button("Delete Transaction", role: .destructive) {
          if let id = transactionPendingDelete {
            Task { await transactionStore.delete(id: id) }
          }
          transactionPendingDelete = nil
        }
        Button("Cancel", role: .cancel) { transactionPendingDelete = nil }
      } message: {
        Text("This action cannot be undone.")
      }
      .confirmationDialog(
        "Split Transfer into Separate Transactions",
        isPresented: Binding(
          get: { transactionPendingUnmerge != nil },
          set: { if !$0 { transactionPendingUnmerge = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button("Split Back into Separate Transactions", role: .destructive) {
          if let id = transactionPendingUnmerge,
            let transfer = displayedTransactions.first(where: {
              $0.transaction.id == id
            })?.transaction
          {
            Task { await transactionStore.unmerge(transfer) }
          }
          transactionPendingUnmerge = nil
        }
        Button("Cancel", role: .cancel) { transactionPendingUnmerge = nil }
      } message: {
        Text(
          "The two original transactions are restored and stay separate. "
            + "This decision is synced across your devices.")
      }
      .modifier(
        TransactionListCSVImportAddons(
          createRuleFromTransaction: $createRuleFromTransaction,
          corpusProvider: {
            displayedTransactions.compactMap {
              $0.transaction.importOrigin?.singleOrigin?.rawDescription
            }
          },
          forcedAccountId: filter.accountId,
          ingestDroppedURLs: ingestDroppedURLs))
  }

  // MARK: - Helpers

  /// Mirror of `RecentlyAddedView.ingestDroppedURLs` but with a forced
  /// account. Kept here so the view can hand off to `ImportStore`
  /// directly; logic is intentionally minimal (security-scope → read
  /// bytes → ingest).
  ///
  /// `ImportStore` writes via `backend.transactions.create(_:)`. The
  /// view's reactive subscription on `transactionStore.observe(filter:)`
  /// will see the writes via `repository.observe(...)` and refresh the
  /// list automatically — no explicit reload is needed here.
  private func ingestDroppedURLs(_ urls: [URL], forcedAccountId: UUID) async {
    for url in urls {
      guard url.pathExtension.lowercased() == "csv" || url.pathExtension.isEmpty else {
        continue
      }
      let didStart = url.startAccessingSecurityScopedResource()
      defer {
        if didStart { url.stopAccessingSecurityScopedResource() }
      }
      let data: Data
      do {
        data = try Data(contentsOf: url)
      } catch {
        errorTitle = "Could not read file"
        errorMessage =
          "\(url.lastPathComponent) could not be opened. "
          + "Check that the file is still available, then try again."
        showError = true
        continue
      }
      _ = await importStore.ingest(
        data: data,
        source: .droppedFile(url: url, forcedAccountId: forcedAccountId))
    }
  }
}
