import SwiftUI

/// Trigger action for creating a new transaction (File > New Transaction, ⌘N).
struct NewTransactionActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for creating a new earmark (File > New Earmark, ⇧⌘N).
struct NewEarmarkActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for creating a new account (File > New Account, ⌃⌘N).
struct NewAccountActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for creating a new category (File > New Category, ⌥⌘N).
struct NewCategoryActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for refreshing the focused window's data (⌘R).
struct RefreshActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for focusing the search field in the active list (⌘F).
struct FindInListActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Binding to the View > Show Hidden Accounts toggle.
struct ShowHiddenAccountsKey: FocusedValueKey {
  typealias Value = Binding<Bool>
}

/// Binding to the View > Show / Hide Spam Transactions toggle.
struct ShowSpamTransactionsKey: FocusedValueKey {
  typealias Value = Binding<Bool>
}

/// The transaction currently selected in the focused window (for Transaction menu).
struct SelectedTransactionKey: FocusedValueKey {
  typealias Value = Binding<Transaction?>
}

/// Trigger action for Transaction > Edit Transaction… Published by the
/// leaf that owns the transaction selection; `nil` when no transaction is
/// selected (which disables the menu item).
struct EditTransactionActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for Transaction > Delete Transaction… Published by the
/// leaf that owns the transaction selection; `nil` when no transaction is
/// selected (which disables the menu item).
struct DeleteTransactionActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for Transaction > Pay Scheduled Transaction. Published
/// by the Upcoming leaf when a scheduled (recurring) transaction is
/// selected; `nil` otherwise (which disables the menu item).
struct PayTransactionActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// The set of transaction ids the focused list has multi-selected. The
/// Transaction > Merge as Transfer command and the list toolbar gate on
/// this being exactly two transactions on disjoint accounts. Empty (not
/// nil) when nothing is multi-selected; nil when no list publishes it.
struct TransferMergeSelectionKey: FocusedValueKey {
  typealias Value = Set<Transaction.ID>
}

/// Trigger action for Transaction > Merge as Transfer. Published by the
/// list leaf only when its multi-selection is exactly two
/// detection-eligible transactions on disjoint accounts; `nil`
/// otherwise (which disables the menu item). The gate predicate
/// (`Transaction.canManualMerge`) lives on the leaf so the menu bar,
/// toolbar, and context menu all apply the same rule.
struct MergeAsTransferActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for Transaction > Split Back into Separate
/// Transactions… Published by the leaf that owns the focused
/// transaction only when it `isMergedTransfer`; `nil` otherwise (which
/// disables the menu item). The leaf arms its own confirmation dialog.
struct UnmergeTransferActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// The account currently selected in the focused window (for Account menu items).
struct SelectedAccountKey: FocusedValueKey {
  typealias Value = Binding<Account?>
}

/// The earmark currently selected in the focused window (for Earmark menu items).
struct SelectedEarmarkKey: FocusedValueKey {
  typealias Value = Binding<Earmark?>
}

/// The category currently selected in the focused window (for Category menu items).
struct SelectedCategoryKey: FocusedValueKey {
  typealias Value = Binding<Category?>
}

/// Binding to the sidebar destination (for Go menu ⌘1…⌘9).
struct SidebarSelectionKey: FocusedValueKey {
  typealias Value = Binding<SidebarSelection?>
}

/// Trigger action for Go > Go Back (⌘[). `nil` when there is nothing to go back to.
struct GoBackActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for Go > Go Forward (⌘]). `nil` when there is nothing to go forward to.
struct GoForwardActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for File > Import CSV… (⇧⌘I). Opens the file picker in
/// the focused window.
struct ImportCSVActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for Edit > Paste CSV (⌥⇧⌘V). Reads tabular text from
/// the pasteboard and runs it through the ImportStore pipeline.
struct PasteCSVActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Action published by an open transaction inspector while its type
/// picker is interactive. Drives the Transaction > Type submenu (⌥⌘1–⌥⌘5).
/// `nil` whenever no editable inspector is in scope (e.g. opening-balance
/// transactions, irreducible-custom shapes, or no inspector open).
struct SetTransactionTypeActionKey: FocusedValueKey {
  typealias Value = (TransactionDetailMode) -> Void
}

/// The UUID of the transaction currently selected in whichever
/// transaction list owns the focused window's selection. Read-only;
/// used by the Handoff publisher to compose the current route.
struct SelectedTransactionIDKey: FocusedValueKey {
  typealias Value = UUID
}

/// The Analysis view's current parameters when it is the focused detail
/// view. Read-only; used by the Handoff publisher.
struct AnalysisRouteKey: FocusedValueKey {
  typealias Value = AnalysisRouteParams
}

/// The Reports view's current date range when it is the focused detail
/// view. Read-only; used by the Handoff publisher.
struct ReportsRouteKey: FocusedValueKey {
  typealias Value = ReportsRouteParams
}

extension FocusedValues {
  var newTransactionAction: NewTransactionActionKey.Value? {
    get { self[NewTransactionActionKey.self] }
    set { self[NewTransactionActionKey.self] = newValue }
  }
  var newEarmarkAction: NewEarmarkActionKey.Value? {
    get { self[NewEarmarkActionKey.self] }
    set { self[NewEarmarkActionKey.self] = newValue }
  }
  var newAccountAction: NewAccountActionKey.Value? {
    get { self[NewAccountActionKey.self] }
    set { self[NewAccountActionKey.self] = newValue }
  }
  var newCategoryAction: NewCategoryActionKey.Value? {
    get { self[NewCategoryActionKey.self] }
    set { self[NewCategoryActionKey.self] = newValue }
  }
  var refreshAction: RefreshActionKey.Value? {
    get { self[RefreshActionKey.self] }
    set { self[RefreshActionKey.self] = newValue }
  }
  var findInListAction: FindInListActionKey.Value? {
    get { self[FindInListActionKey.self] }
    set { self[FindInListActionKey.self] = newValue }
  }
  var showHiddenAccounts: ShowHiddenAccountsKey.Value? {
    get { self[ShowHiddenAccountsKey.self] }
    set { self[ShowHiddenAccountsKey.self] = newValue }
  }
  var showSpamTransactions: ShowSpamTransactionsKey.Value? {
    get { self[ShowSpamTransactionsKey.self] }
    set { self[ShowSpamTransactionsKey.self] = newValue }
  }
  var selectedTransaction: SelectedTransactionKey.Value? {
    get { self[SelectedTransactionKey.self] }
    set { self[SelectedTransactionKey.self] = newValue }
  }
  var editTransactionAction: EditTransactionActionKey.Value? {
    get { self[EditTransactionActionKey.self] }
    set { self[EditTransactionActionKey.self] = newValue }
  }
  var deleteTransactionAction: DeleteTransactionActionKey.Value? {
    get { self[DeleteTransactionActionKey.self] }
    set { self[DeleteTransactionActionKey.self] = newValue }
  }
  var payTransactionAction: PayTransactionActionKey.Value? {
    get { self[PayTransactionActionKey.self] }
    set { self[PayTransactionActionKey.self] = newValue }
  }
  var transferMergeSelection: TransferMergeSelectionKey.Value? {
    get { self[TransferMergeSelectionKey.self] }
    set { self[TransferMergeSelectionKey.self] = newValue }
  }
  var mergeAsTransferAction: MergeAsTransferActionKey.Value? {
    get { self[MergeAsTransferActionKey.self] }
    set { self[MergeAsTransferActionKey.self] = newValue }
  }
  var unmergeTransferAction: UnmergeTransferActionKey.Value? {
    get { self[UnmergeTransferActionKey.self] }
    set { self[UnmergeTransferActionKey.self] = newValue }
  }
  var selectedAccount: SelectedAccountKey.Value? {
    get { self[SelectedAccountKey.self] }
    set { self[SelectedAccountKey.self] = newValue }
  }
  var selectedEarmark: SelectedEarmarkKey.Value? {
    get { self[SelectedEarmarkKey.self] }
    set { self[SelectedEarmarkKey.self] = newValue }
  }
  var selectedCategory: SelectedCategoryKey.Value? {
    get { self[SelectedCategoryKey.self] }
    set { self[SelectedCategoryKey.self] = newValue }
  }
  var sidebarSelection: SidebarSelectionKey.Value? {
    get { self[SidebarSelectionKey.self] }
    set { self[SidebarSelectionKey.self] = newValue }
  }
  var goBackAction: GoBackActionKey.Value? {
    get { self[GoBackActionKey.self] }
    set { self[GoBackActionKey.self] = newValue }
  }
  var goForwardAction: GoForwardActionKey.Value? {
    get { self[GoForwardActionKey.self] }
    set { self[GoForwardActionKey.self] = newValue }
  }
  var importCSVAction: ImportCSVActionKey.Value? {
    get { self[ImportCSVActionKey.self] }
    set { self[ImportCSVActionKey.self] = newValue }
  }
  var pasteCSVAction: PasteCSVActionKey.Value? {
    get { self[PasteCSVActionKey.self] }
    set { self[PasteCSVActionKey.self] = newValue }
  }
  var setTransactionTypeAction: SetTransactionTypeActionKey.Value? {
    get { self[SetTransactionTypeActionKey.self] }
    set { self[SetTransactionTypeActionKey.self] = newValue }
  }
  var selectedTransactionID: SelectedTransactionIDKey.Value? {
    get { self[SelectedTransactionIDKey.self] }
    set { self[SelectedTransactionIDKey.self] = newValue }
  }
  var analysisRoute: AnalysisRouteKey.Value? {
    get { self[AnalysisRouteKey.self] }
    set { self[AnalysisRouteKey.self] = newValue }
  }
  var reportsRoute: ReportsRouteKey.Value? {
    get { self[ReportsRouteKey.self] }
    set { self[ReportsRouteKey.self] = newValue }
  }
}
