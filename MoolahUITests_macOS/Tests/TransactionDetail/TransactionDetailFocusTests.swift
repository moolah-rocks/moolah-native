import XCTest

/// Behaviour tests for keyboard focus on `TransactionDetailView`.
@MainActor
final class TransactionDetailFocusTests: MoolahUITestCase {
  func testOpeningTradeFocusesPayee() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)

    app.transactionDetail.payee.expectFocused()
  }

  /// ⌘N is the keyboard entry-point for new transactions. The detail
  /// inspector must land first-responder on the payee field so the user
  /// can start typing immediately without clicking.
  func testCreatingTransactionFocusesPayee() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.createTransaction()

    app.transactionDetail.payee.expectFocused()
  }

  /// ⌘N while the inspector is *already open* (showing an existing
  /// transaction) must still land first-responder on the new
  /// transaction's payee field — the inspector content swaps in place
  /// rather than presenting fresh, and focus must follow.
  func testCreatingSecondTransactionFocusesPayee() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)
    app.transactionDetail.payee.expectFocused()

    app.transactionList.createTransaction()
    // The payee element identifier is shared between the two transactions,
    // so `createTransaction()`'s existence wait can't tell the swapped-in
    // new view from the still-mounted old one. Wait for the payee value to
    // clear (the new placeholder has an empty payee) as the swap barrier
    // before asserting where focus landed.
    app.transactionDetail.payee.expectValue("")

    app.transactionDetail.payee.expectFocused()
  }
}
