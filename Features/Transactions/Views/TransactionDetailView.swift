import SwiftUI

struct TransactionDetailView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let showRecurrence: Bool
  let viewingAccountId: UUID?
  let onUpdate: (Transaction) -> Void
  let onDelete: (UUID) -> Void

  @Environment(ProfileSession.self) private var session: ProfileSession?

  // `draft`, the confirmation flags, the autocomplete/leg state, and
  // `focusedField` use internal access (no `private`) so the section-
  // composition builders in `TransactionDetailView+FormContent.swift`
  // and the action helpers in `+Actions.swift` can reach them across
  // the file boundary. SwiftLint's strict_fileprivate rule makes
  // internal the smallest legal cross-file scope.
  @State var draft: TransactionDraft
  @State var showDeleteConfirmation = false
  @State var showTransferDismissConfirmation = false
  @State var showUnmergeConfirmation = false
  @State var payeeState = PayeeAutocompleteState()
  @State var categoryState = CategoryAutocompleteState()
  @State var legCategoryStates: [Int: CategoryAutocompleteState] = [:]
  @State var legPendingDeletion: Int?
  /// Snapshot of whether the transaction was a blank/new draft at open
  /// time (empty payee + all-zero legs). Captured once at init so that
  /// `autofillFromPayee` only copies fields from a matched transaction
  /// when the user is filling in a fresh transaction — never when they
  /// are editing an existing one. Without this guard, selecting a payee
  /// from the dropdown while editing a $5,000 transfer would clobber the
  /// amount, type, and category.
  @State var openedAsNewTransaction: Bool
  @FocusState var focusedField: TransactionDetailFocus?

  init(
    transaction: Transaction,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    showRecurrence: Bool = false,
    viewingAccountId: UUID? = nil,
    onUpdate: @escaping (Transaction) -> Void,
    onDelete: @escaping (UUID) -> Void
  ) {
    self.transaction = transaction
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.showRecurrence = showRecurrence
    self.viewingAccountId = viewingAccountId
    self.onUpdate = onUpdate
    self.onDelete = onDelete

    var initialDraft = TransactionDraft(
      from: transaction, viewingAccountId: viewingAccountId, accounts: accounts)
    for i in initialDraft.legDrafts.indices {
      if let catId = initialDraft.legDrafts[i].categoryId,
        let cat = categories.by(id: catId)
      {
        initialDraft.legDrafts[i].categoryText = categories.path(for: cat)
      }
    }
    _draft = State(initialValue: initialDraft)

    let payeeEmpty = (transaction.payee?.isEmpty ?? true)
    let allLegsZero = transaction.legs.allSatisfy { $0.quantity == .zero }
    _openedAsNewTransaction = State(initialValue: payeeEmpty && allLegsZero)
  }

  var body: some View {
    formContent
      .formStyle(.grouped)
      .overlayPreferenceValue(PayeeFieldAnchorKey.self) { anchor in
        PayeeAutocompleteOverlay(
          anchor: anchor,
          payee: $draft.payee,
          state: $payeeState,
          suggestionSource: transactionStore.payeeSuggestionSource,
          onAutofill: autofillFromPayee
        )
      }
      .overlayPreferenceValue(CategoryPickerAnchorKey.self) { anchor in
        TransactionDetailCategoryOverlay(
          anchor: anchor,
          draft: $draft,
          categories: categories,
          state: $categoryState
        )
      }
      .overlayPreferenceValue(LegCategoryPickerAnchorKey.self) { anchors in
        TransactionDetailLegCategoryOverlay(
          anchors: anchors,
          draft: $draft,
          categories: categories,
          legStates: $legCategoryStates
        )
      }
      .navigationTitle("Transaction Details")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      #if os(macOS)
        // `defaultFocus` alone does not pull first-responder into the inspector
        // when focus currently sits outside its region; `.task(id:)` runs
        // after the view is in the window hierarchy and imperatively claims
        // focus on the expected field. The list view cooperates by blurring
        // the `.searchable` toolbar field when the inspector opens, so the
        // responder chain's fallback doesn't steal our assignment.
        .defaultFocus($focusedField, isSimpleEarmarkOnly ? .amount : .payee)
        .task(id: transaction.id) {
          focusedField = isSimpleEarmarkOnly ? .amount : .payee
        }
      #endif
      .onChange(of: draft) { _, _ in debouncedSave() }
      .confirmationDialog(
        "Delete Transaction",
        isPresented: $showDeleteConfirmation,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          onDelete(transaction.id)
        }
      } message: {
        Text("Are you sure you want to delete this transaction? This cannot be undone.")
      }
      .confirmationDialog(
        "Delete Sub-transaction",
        isPresented: Binding(
          get: { legPendingDeletion != nil },
          set: { if !$0 { legPendingDeletion = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          if let index = legPendingDeletion {
            draft.removeLeg(at: index)
            shiftLegCategoryStates(after: index)
            legPendingDeletion = nil
          }
        }
      } message: {
        Text("Are you sure you want to delete this sub-transaction?")
      }
      .confirmationDialog(
        "Dismiss Transfer Suggestion",
        isPresented: $showTransferDismissConfirmation,
        titleVisibility: .visible
      ) {
        Button("Dismiss Suggestion", role: .destructive) {
          Task { await transactionStore.dismissSuggestedTransfer(transaction) }
        }
        .accessibilityIdentifier(UITestIdentifiers.TransferDetection.dismissConfirm)
      } message: {
        Text(
          "These transactions stay separate and will not be suggested as a "
            + "transfer again. This decision is synced across your devices.")
      }
      .confirmationDialog(
        "Split Transfer into Separate Transactions",
        isPresented: $showUnmergeConfirmation,
        titleVisibility: .visible
      ) {
        Button("Split Back into Separate Transactions", role: .destructive) {
          Task { await transactionStore.unmerge(transaction) }
        }
      } message: {
        Text(
          "The two original transactions are restored and stay separate. "
            + "This decision is synced across your devices.")
      }
  }
}

// Form body + mode-aware section composition (`formContent`,
// `simpleModeContent`, `tradeModeContent`, …) live in
// TransactionDetailView+FormContent.swift.
// Computed helpers (isEditable, isSimpleEarmarkOnly, instruments,
// bindings, isScheduled) live in TransactionDetailView+Helpers.swift.
// Actions (autofillFromPayee, debouncedSave, saveIfValid) and the
// unmergeSection view builder live in TransactionDetailView+Actions.swift.
