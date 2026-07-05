import XCTest

/// Driver for the `EditAccountView` sheet. Returned from
/// `MoolahApp.editAccount`.
///
/// Open the sheet via `open(account:)` (right-clicks the sidebar row and
/// chooses the context-menu "Edit Account…" item) or by some other test
/// path that should still call `expectVisible()` before any content
/// assertion runs — see `guides/UI_TEST_GUIDE.md` §3 invariant 1
/// ("Actions wait for post-conditions") and §3 invariant 2
/// ("Actions fail loudly").
@MainActor
struct EditAccountScreen {
  /// Test-side mirror of `ValuationMode`. UI tests don't import the
  /// `Moolah` app module, so the production enum is not visible here;
  /// the driver carries this small mirror alongside the helper that
  /// translates each case to the user-visible label and accessibility
  /// hint produced by `EditAccountView`. If the production strings
  /// change, update the helpers below to match — they are deliberately
  /// duplicated rather than re-imported.
  enum Mode: Equatable {
    case recordedValue
    case calculatedFromTrades
  }

  let app: MoolahApp

  // MARK: - Open / dismiss

  /// Right-clicks the sidebar row for `account` and clicks the "Edit
  /// Account…" item to present the dialog. Returns once the Cancel
  /// button has materialised — the presence sentinel a subsequent
  /// `expectValuationSectionAbsent()` call relies on, so the absence
  /// check can't pass vacuously when the sheet failed to open.
  func open(account: SidebarAccount) {
    Trace.record(#function, detail: "account=\(account)")
    let row = app.element(for: UITestIdentifiers.Sidebar.account(account.id))
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "sidebar row '\(UITestIdentifiers.Sidebar.account(account.id))' did not appear")
      XCTFail("Sidebar row for account \(account) did not appear within 10s")
      return
    }
    row.rightClick()

    // SwiftUI does propagate `.accessibilityIdentifier(_:)` onto
    // context-menu Buttons (verified — the menu item's identifier
    // appears in the accessibility tree). Resolve by identifier
    // rather than by label so we don't collide with the menu-bar
    // "Account → Edit Account…" command, which carries the same
    // title.
    let editItem = app.element(for: UITestIdentifiers.Sidebar.editAccountContextMenuItem)
    if !editItem.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "sidebar.contextMenu.editAccount item did not appear after right-click")
      XCTFail("'Edit Account…' menu item did not appear within 10s of right-click")
      return
    }
    editItem.click()

    expectVisible()
  }

  /// Asserts the dialog is currently on screen. Used as a presence
  /// sentinel: a subsequent absence assertion on the Valuation section
  /// would otherwise pass vacuously when the sheet failed to open.
  /// The Cancel button is the working sentinel because SwiftUI's
  /// `.accessibilityIdentifier(_:)` on `NavigationStack` / `Form`
  /// does not propagate to the macOS-rendered window root.
  func expectVisible() {
    Trace.record(#function)
    let cancelButton = app.element(for: UITestIdentifiers.EditAccount.cancelButton)
    if !cancelButton.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "editAccount.cancel did not appear; the Edit Account sheet failed to open")
      XCTFail("EditAccountView dialog did not appear within 10s")
    }
  }

  /// Closes the dialog by clicking the Cancel toolbar button. Returns
  /// once the dialog's root container disappears.
  func cancel() {
    Trace.record(#function)
    let cancelButton = app.element(for: UITestIdentifiers.EditAccount.cancelButton)
    if !cancelButton.waitForExistence(timeout: 10) {
      Trace.recordFailure("editAccount.cancel button did not appear")
      XCTFail("Cancel button did not appear within 10s")
      return
    }
    cancelButton.click()

    // Post-condition: the Cancel button (which IS the sentinel)
    // disappears once the sheet is dismissed.
    if !cancelButton.waitForNonExistence(timeout: 10) {
      Trace.recordFailure("editAccount.cancel did not disappear after Cancel click")
      XCTFail("EditAccountView dialog did not disappear within 10s of Cancel")
    }
  }

  // MARK: - Expectations (read-only)

  /// Asserts the Valuation section's picker is present. Caller must have
  /// already invoked `open(account:)` or `expectVisible()` so a missing
  /// picker reflects the rule, not a missing sheet.
  func expectValuationSectionVisible() {
    Trace.record(#function)
    let picker = app.element(for: UITestIdentifiers.EditAccount.valuationModePicker)
    if !picker.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "editAccount.valuationMode picker did not appear; expected for "
          + "recordedValue or has-snapshots accounts")
      XCTFail("Valuation picker did not appear within 10s")
    }
  }

  /// Asserts the Valuation section's picker is **not** present. Pairs
  /// with a prior `expectVisible()` call so a missing picker reflects
  /// the rule rather than a missing sheet. Uses XCTest's
  /// `waitForNonExistence(timeout:)`, which returns `true` when the
  /// element either never existed or disappeared within the window —
  /// the right primitive for confirming the asynchronous `.task`
  /// probe didn't reveal the section.
  func expectValuationSectionAbsent() {
    Trace.record(#function)
    let picker = app.element(for: UITestIdentifiers.EditAccount.valuationModePicker)
    if !picker.waitForNonExistence(timeout: 2) {
      Trace.recordFailure(
        "editAccount.valuationMode picker appeared but the rule says it "
          + "should be hidden for new calculatedFromTrades accounts")
      XCTFail("Valuation picker should be hidden but is present")
    }
  }

  /// Asserts the picker's currently-selected value reads as `expected`.
  /// Reads the macOS pop-up button's `value` attribute — the SwiftUI
  /// idiom for the displayed label of a `Picker(... selection:)`.
  /// Uses `XCTNSPredicateExpectation` rather than a hand-rolled poll
  /// loop, per UI_TEST_GUIDE §3 (no sleeps / no retries).
  func expectValuationMode(_ expected: Mode) {
    Trace.record(#function, detail: "expected=\(expected)")
    let picker = app.element(for: UITestIdentifiers.EditAccount.valuationModePicker)
    if !picker.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "editAccount.valuationMode picker did not appear; cannot read selection")
      XCTFail("Valuation picker did not appear within 10s")
      return
    }
    let expectedLabel = displayLabel(for: expected)
    let predicate = NSPredicate { _, _ in
      (picker.value as? String) == expectedLabel
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    if XCTWaiter().wait(for: [expectation], timeout: 10) != .completed {
      let actual = (picker.value as? String) ?? "<no value>"
      Trace.recordFailure(
        "editAccount.valuationMode shows '\(actual)', expected '\(expectedLabel)'")
      XCTFail("Valuation picker shows '\(actual)', expected '\(expectedLabel)'")
    }
  }

  // MARK: - Mutations

  /// Click the picker, choose `mode`, and assert the selection updated.
  /// Caller must have already invoked `open(account:)`. Resolves the
  /// menu-item by user-visible label via `MoolahApp.menuItem(label:)`,
  /// because `NSMenuItem` does not inherit the SwiftUI accessibility
  /// identifier on macOS.
  func selectValuationMode(_ mode: Mode) {
    Trace.record(#function, detail: "mode=\(mode)")
    let picker = app.element(for: UITestIdentifiers.EditAccount.valuationModePicker)
    if !picker.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "editAccount.valuationMode picker did not appear; cannot change selection")
      XCTFail("Valuation picker did not appear within 10s")
      return
    }
    picker.click()
    let label = displayLabel(for: mode)
    let item = app.menuItem(label: label)
    if !item.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "Picker option '\(label)' did not appear after clicking valuation picker")
      XCTFail("Picker option '\(label)' did not appear within 10s")
      return
    }
    item.click()
    expectValuationMode(mode)
  }

  /// Click the Save toolbar button. Returns once the dialog dismisses
  /// (the Cancel button — which doubles as the dialog presence sentinel
  /// — disappears).
  func save() {
    Trace.record(#function)
    let saveButton = app.element(for: UITestIdentifiers.EditAccount.saveButton)
    if !saveButton.waitForExistence(timeout: 10) {
      Trace.recordFailure("editAccount.save button did not appear")
      XCTFail("Save button did not appear within 10s")
      return
    }
    saveButton.click()
    let cancelButton = app.element(for: UITestIdentifiers.EditAccount.cancelButton)
    if !cancelButton.waitForNonExistence(timeout: 10) {
      Trace.recordFailure(
        "editAccount.cancel did not disappear after Save click; sheet still open")
      XCTFail("EditAccountView dialog did not disappear within 10s of Save")
    }
  }

  // MARK: - Helpers

  /// Maps `Mode` to the user-visible Picker label produced by
  /// `EditAccountView.valuationSection`. Kept private so the test body
  /// stays free of raw strings — drivers own all label-mapping.
  private func displayLabel(for mode: Mode) -> String {
    switch mode {
    case .recordedValue: return "Recorded value"
    case .calculatedFromTrades: return "Calculated from trades"
    }
  }

}
