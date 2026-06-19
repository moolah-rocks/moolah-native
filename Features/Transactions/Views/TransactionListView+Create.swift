import SwiftUI

extension TransactionListView {
  /// The action exposed via `\.newTransactionAction` for window-menu /
  /// keyboard-shortcut "New Transaction". Routes to
  /// `createNewScheduledTransaction()` when grouping is `.scheduledStatus`
  /// (so ⌘N from the Upcoming view creates a recurring placeholder), and
  /// to the default `createNewTransaction()` otherwise.
  var newTransactionAction: () -> Void {
    if case .scheduledStatus = grouping {
      return createNewScheduledTransaction
    }
    return createNewTransaction
  }

  func createNewTransaction() {
    let instrument = accounts.ordered.first?.instrument ?? .AUD

    // Build the placeholder with its own UUID and send that exact
    // transaction through `store.create`. CloudKit's repository echoes
    // the input transaction, so `selectedTransaction.id` stays stable
    // across the persist — the inspector's `.id(selected.id)` does not
    // force a view recreation and the detail view's focus state survives.
    let placeholder: Transaction?
    if let earmarkId = filter.earmarkId, filter.accountId == nil {
      placeholder = Transaction(
        date: Date(),
        payee: "",
        legs: [
          TransactionLeg(
            accountId: nil,
            instrument: instrument,
            quantity: 0,
            type: .income,
            earmarkId: earmarkId)
        ]
      )
    } else if let acctId = filter.accountId ?? accounts.ordered.first?.id {
      placeholder = Transaction(
        date: Date(),
        payee: "",
        legs: [
          TransactionLeg(accountId: acctId, instrument: instrument, quantity: 0, type: .expense)
        ]
      )
    } else {
      placeholder = nil
    }

    selectedTransaction = placeholder
    guard let placeholder else { return }
    Task {
      _ = await transactionStore.create(placeholder)
    }
  }

  /// Creates a new scheduled (recurring) transaction placeholder.
  /// Mirrors `createNewTransaction()` but seeds the placeholder with a
  /// monthly recurrence so the inspector opens in the recurring-transaction
  /// editing mode. Used by the `.scheduledStatus` grouping's Add toolbar
  /// button and `\.newTransactionAction` focused-scene-value.
  func createNewScheduledTransaction() {
    let instrument = accounts.ordered.first?.instrument ?? .AUD
    let fallbackAccountId = accounts.ordered.first?.id

    let placeholder: Transaction? = fallbackAccountId.map { id in
      Transaction(
        date: Date(),
        payee: "",
        recurPeriod: .month,
        recurEvery: 1,
        legs: [TransactionLeg(accountId: id, instrument: instrument, quantity: 0, type: .expense)]
      )
    }
    selectedTransaction = placeholder
    guard let placeholder else { return }
    Task {
      _ = await transactionStore.create(placeholder)
    }
  }
}
