import XCTest

/// Driver for the Recently Added transaction list.
@MainActor
struct RecentlyAddedScreen {
  let app: MoolahApp

  func expectVisible() {
    let container = app.element(for: UITestIdentifiers.TransactionList.container)
    if !container.waitForExistence(timeout: 10) {
      Trace.recordFailure("standard transaction list did not appear in Recently Added")
      XCTFail("Recently Added transaction list did not render within 10s")
    }
  }

  /// Selects an imported row and waits for the standard transaction
  /// inspector's payee field to appear.
  func openTransaction(_ id: UUID) {
    Trace.record(#function, detail: "id=\(id)")
    let identifier = UITestIdentifiers.TransactionList.transaction(id)
    let row = app.element(for: identifier)
    if !row.waitUntilHittable(timeout: 10) {
      Trace.recordFailure("recently added transaction row '\(identifier)' was not hittable")
      XCTFail("Recently Added transaction row for \(id) was not hittable within 10s")
      return
    }
    row.click()
    let payee = app.element(for: UITestIdentifiers.Detail.payee)
    if !payee.waitForExistence(timeout: 10) {
      Trace.recordFailure("transaction inspector did not open after selecting row '\(id)'")
      XCTFail("Transaction inspector did not open within 10s of selecting row \(id)")
    }
  }
}
