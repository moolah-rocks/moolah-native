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
  let app: MoolahApp

  // MARK: - Open / dismiss

  /// Right-clicks the sidebar row for `account` and clicks the "Edit
  /// Account…" item to present the dialog. Returns once the Cancel
  /// button has materialised, providing a reliable presence sentinel for
  /// subsequent content assertions.
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
  /// sentinel so subsequent assertions cannot pass vacuously when the sheet
  /// failed to open.
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

}
