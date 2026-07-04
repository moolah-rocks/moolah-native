import XCTest

/// Driver for the transaction filter sheet (`TransactionFilterView`).
/// Obtained from `TransactionListScreen.openFilter()`; every action waits
/// on a real post-condition and resolves elements through the single
/// `MoolahApp.element(for:)` seam.
@MainActor
struct TransactionFilterScreen {
  let app: MoolahApp

  /// Enables or disables the "Filter by Date" toggle. When enabled the
  /// dialog seeds a `[now − 1 month, now]` range. Clicks only when the
  /// toggle is not already in the desired state, then waits for the
  /// checkbox value to settle as the post-condition.
  func toggleDateFilter(on enabled: Bool) {
    Trace.record(#function, detail: "on=\(enabled)")
    let toggle = app.element(for: UITestIdentifiers.TransactionFilter.dateToggle)
    if !toggle.waitForExistence(timeout: 3) {
      Trace.recordFailure("filter date toggle did not appear")
      XCTFail("Filter 'Filter by Date' toggle did not appear within 3s")
      return
    }
    if isOn(toggle) != enabled {
      toggle.click()
    }
    let predicate = NSPredicate(format: "value == %d", enabled ? 1 : 0)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: toggle)
    if XCTWaiter.wait(for: [expectation], timeout: 3) != .completed {
      Trace.recordFailure("filter date toggle did not settle to on=\(enabled)")
      XCTFail("Filter date toggle did not reach on=\(enabled) within 3s")
    }
  }

  /// Opens the account multi-select popover, toggles the given account's
  /// row, and dismisses the popover so the sheet's Apply button is
  /// reachable again. Waits for the popover to close as the post-condition.
  func selectAccount(_ accountId: UUID) {
    Trace.record(#function, detail: "account=\(accountId)")
    let picker = app.element(for: UITestIdentifiers.TransactionFilter.accountPicker)
    if !picker.waitForExistence(timeout: 3) {
      Trace.recordFailure("account picker trigger did not appear")
      XCTFail("Filter account picker did not appear within 3s")
      return
    }
    picker.click()

    let row = app.element(for: UITestIdentifiers.TransactionFilter.account(accountId))
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("account row '\(accountId)' did not appear in the picker")
      XCTFail("Account row \(accountId) did not appear in the picker within 3s")
      return
    }
    row.click()

    // The multi-select popover stays open after a toggle; dismiss it so
    // the sheet's Apply button is hittable again.
    app.pressKeyboardShortcut(XCUIKeyboardKey.escape.rawValue)
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app.popover)
    if XCTWaiter.wait(for: [expectation], timeout: 3) != .completed {
      Trace.recordFailure("account picker popover did not close")
      XCTFail("Account picker popover did not close within 3s")
    }
  }

  /// Taps Apply and waits for the sheet to dismiss: the Apply button
  /// leaving the accessibility tree is the "filter committed" signal. The
  /// list reload that follows is asynchronous, so callers assert the
  /// post-reload state via `TransactionListScreen`'s
  /// `expectTransactionVisible(_:)` / `expectTransactionAbsent(_:)`, which
  /// each carry their own bounded wait.
  func apply() {
    Trace.record(#function)
    let applyButton = app.element(for: UITestIdentifiers.TransactionFilter.apply)
    if !applyButton.waitForExistence(timeout: 3) {
      Trace.recordFailure("filter Apply button did not appear")
      XCTFail("Filter Apply button did not appear within 3s")
      return
    }
    applyButton.click()

    let dismissed = NSPredicate(format: "exists == false")
    let dismissExpectation = XCTNSPredicateExpectation(
      predicate: dismissed, object: applyButton)
    if XCTWaiter.wait(for: [dismissExpectation], timeout: 3) != .completed {
      Trace.recordFailure("filter sheet did not dismiss after Apply")
      XCTFail("Filter sheet did not dismiss within 3s of tapping Apply")
    }
  }

  // MARK: - Private helpers

  /// Reads a checkbox / toggle's on-state, tolerant of the several value
  /// encodings AppKit surfaces for an `AXCheckBox` (Int, Bool, or String).
  private func isOn(_ element: XCUIElement) -> Bool {
    switch element.value {
    case let intValue as Int: return intValue != 0
    case let boolValue as Bool: return boolValue
    case let stringValue as String: return stringValue == "1"
    default: return false
    }
  }
}
