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
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure("transaction row '\(identifier)' did not appear")
      XCTFail("Transaction list row for \(entry) did not appear within 3s")
      return
    }
    row.click()
    let payee = app.element(for: UITestIdentifiers.Detail.payee)
    if !payee.waitForExistence(timeout: 10) {
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
    if !payee.waitForExistence(timeout: 10) {
      Trace.recordFailure("detail.payee did not appear after ⌘N")
      XCTFail("Transaction detail did not surface payee field after ⌘N")
    }
  }

  /// Opens the transaction filter sheet from the toolbar Filter button and
  /// returns a driver bound to it. Returns once the sheet's Apply button is
  /// in the accessibility tree — the "sheet presented" post-condition.
  func openFilter() -> TransactionFilterScreen {
    Trace.record(#function)
    let button = app.element(for: UITestIdentifiers.TransactionList.filterButton)
    if !button.waitForExistence(timeout: 10) {
      Trace.recordFailure("filter toolbar button did not appear")
      XCTFail("Transaction list Filter button did not appear within 3s")
      return TransactionFilterScreen(app: app)
    }
    button.click()

    let apply = app.element(for: UITestIdentifiers.TransactionFilter.apply)
    if !apply.waitForExistence(timeout: 10) {
      Trace.recordFailure("filter sheet Apply button did not appear after opening filter")
      XCTFail("Filter sheet did not present within 3s of tapping Filter")
    }
    return TransactionFilterScreen(app: app)
  }

  // MARK: - Row visibility expectations
  //
  // Expectation methods: they carry a bounded post-condition wait (the
  // preceding action's reload is asynchronous) but never mutate state and
  // never record a trace breadcrumb — per the driver invariants.

  /// Asserts the given transaction's row is present, waiting up to 3s for
  /// the (asynchronous) filtered reload to surface it.
  func expectTransactionVisible(_ transactionId: UUID) {
    let identifier = UITestIdentifiers.TransactionList.transaction(transactionId)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure("expected transaction row '\(identifier)' to be visible")
      XCTFail("Transaction row \(transactionId) was not visible within 3s")
    }
  }

  /// Asserts the given transaction's row is (and stays) absent after a
  /// filter is applied.
  ///
  /// Filtered reloads are asynchronous, so a naive `exists == false` check
  /// races the reload two ways: a row that *should* stay absent (the
  /// scope-preserving case) could pass before a buggy widening reload
  /// surfaces it, and a row that *should* disappear (the narrowing case)
  /// starts out present. This handles both: it first gives the reload a
  /// bounded window to surface the row; if the row never appears it is
  /// correctly absent, and if it does appear it must then disappear once
  /// the (scope-preserving) reload settles — otherwise scope was lost and
  /// the assertion fails.
  ///
  /// Worst-case budget is 6 s (two sequential 3 s windows); the common
  /// correctly-absent path returns in ~0 ms.
  func expectTransactionAbsent(_ transactionId: UUID) {
    let identifier = UITestIdentifiers.TransactionList.transaction(transactionId)
    let row = app.element(for: identifier)
    // Bounded window for an asynchronous (possibly buggy) reload to
    // surface the row. Never appearing within it = correctly absent.
    guard row.waitForExistence(timeout: 3) else { return }
    // It is present (either already, in the narrowing case, or via a
    // scope-losing reload). It must now settle to absent.
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: row)
    if XCTWaiter.wait(for: [expectation], timeout: 3) != .completed {
      Trace.recordFailure("expected transaction row '\(identifier)' to be absent")
      XCTFail("Transaction row \(transactionId) was unexpectedly visible")
    }
  }
}
