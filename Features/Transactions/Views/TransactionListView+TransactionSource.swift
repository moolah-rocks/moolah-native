import SwiftUI

extension TransactionListView {
  /// The projection rendered by this list. Tax drill-downs must retain spam
  /// transactions because the selected tax total includes their contributions.
  var displayedTransactions: [TransactionWithBalance] {
    allowsSpamFiltering
      ? transactionStore.transactions
      : transactionStore.unfilteredTransactions
  }

  var filteredTransactions: [TransactionWithBalance] {
    if searchText.isEmpty {
      return displayedTransactions
    }
    return displayedTransactions.filter {
      $0.transaction.payee?.localizedCaseInsensitiveContains(searchText) ?? false
    }
  }

  /// Bridges the `List`'s multi-selection to the single transaction inspector.
  var listSelectionBinding: Binding<Set<Transaction.ID>> {
    Binding(
      get: {
        if let id = selectedTransaction?.id { return [id] }
        return multiSelectedTransactionIDs
      },
      set: { newSelection in
        multiSelectedTransactionIDs = newSelection
        if newSelection.count == 1, let id = newSelection.first {
          selectedTransaction =
            displayedTransactions.first {
              $0.transaction.id == id
            }?.transaction
        } else {
          selectedTransaction = nil
        }
      }
    )
  }
}
