import SwiftUI

// MARK: - Actions

extension TransactionDetailView {
  func autofillFromPayee(_ selectedPayee: String) {
    // Only auto-copy amount/type/category from a past transaction when
    // the user is filling in a fresh draft. Editing an existing
    // transaction's payee must never rewrite other fields — do not
    // remove this guard without replacing the invariant it enforces.
    guard openedAsNewTransaction else { return }
    Task {
      guard
        let match = await transactionStore.payeeSuggestionSource.fetchTransactionForAutofill(
          payee: selectedPayee)
      else { return }
      draft.applyAutofill(from: match, categories: categories, accounts: accounts)
    }
  }

  func debouncedSave() {
    transactionStore.debouncedSave { [self] in
      saveIfValid()
    }
  }

  func saveIfValid() {
    guard
      let updated = draft.toTransaction(
        id: transaction.id,
        accounts: accounts,
        earmarks: earmarks)
    else { return }
    onUpdate(updated)
  }

  /// "Split Back into Separate Transactions…" action for a merged
  /// transfer. Self-hides unless the transaction `isMergedTransfer`
  /// (the same predicate the menu bar / list context menu gate on).
  /// `role: .destructive` here only — the detail/context red-label cue
  /// is useful for an irreversible-feeling action; the menu-bar button
  /// carries no role. The button only arms the parent's confirmation
  /// flag; the dialog and the `transactionStore.unmerge(...)` dispatch
  /// live in `TransactionDetailView`'s body (the house pattern).
  @ViewBuilder var unmergeSection: some View {
    if transaction.isMergedTransfer {
      Section {
        Button(role: .destructive) {
          showUnmergeConfirmation = true
        } label: {
          Text("Split Back into Separate Transactions\u{2026}")
            .frame(maxWidth: .infinity)
        }
      }
    }
  }
}
