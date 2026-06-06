import XCTest

/// Symbolic reference to a transaction in the seeded fixture. Tests
/// reference transactions by name; the driver maps each case to the
/// seeded UUID.
enum TransactionListEntry {
  case bhpPurchase
  case splitShop

  /// The fixed UUID written to the seeded `ProfileContainerManager` by
  /// `UITestSeedHydrator`.
  var id: UUID {
    switch self {
    case .bhpPurchase: return UITestFixtures.TradeBaseline.bhpPurchaseId
    case .splitShop: return UITestFixtures.TradeBaseline.splitShopId
    }
  }
}

/// Driver for the transaction list (centre column). Returned from
/// `MoolahApp.transactionList`.
@MainActor
struct TransactionListScreen {
  let app: MoolahApp

  /// Opens the given transaction in the detail view. Returns once the
  /// detail surface for that transaction is visible (i.e. the payee field
  /// has been added to the accessibility tree).
  func openTransaction(_ entry: TransactionListEntry) {
    Trace.record(#function, detail: "entry=\(entry)")
    let identifier = UITestIdentifiers.TransactionList.transaction(entry.id)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("transaction row '\(identifier)' did not appear")
      XCTFail("Transaction list row for \(entry) did not appear within 3s")
      return
    }
    row.click()
    let payee = app.element(for: UITestIdentifiers.Detail.payee)
    if !payee.waitForExistence(timeout: 3) {
      Trace.recordFailure("detail.payee did not appear after opening \(entry)")
      XCTFail("Transaction detail did not surface payee field after opening \(entry)")
    }
  }

  /// Triggers the "New Transaction" menu command (⌘N) and returns once
  /// the detail surface for the new transaction is visible (i.e. the
  /// payee field exists in the accessibility tree). The caller is
  /// responsible for focus assertions — this method does not assume the
  /// field has been auto-focused.
  ///
  /// **Panel-swap caveat:** when the inspector is already open showing an
  /// existing transaction, the payee element exists before ⌘N fires, so
  /// the existence wait below returns immediately and cannot distinguish
  /// the still-mounted old view from the swapped-in new one. In that case
  /// the caller must additionally wait on a value change only the new view
  /// can produce (e.g. `transactionDetail.payee.expectValue("")`) before
  /// asserting focus. See `testCreatingSecondTransactionFocusesPayee`.
  func createTransaction() {
    Trace.record(#function)
    app.pressKeyboardShortcut("n", modifiers: .command)
    let payee = app.element(for: UITestIdentifiers.Detail.payee)
    if !payee.waitForExistence(timeout: 3) {
      Trace.recordFailure("detail.payee did not appear after ⌘N")
      XCTFail("Transaction detail did not surface payee field after ⌘N")
    }
  }
}
