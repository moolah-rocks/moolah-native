import XCTest

/// Driver for the `CreateAccountView` sheet. Returned from
/// `MoolahApp.createAccount`.
///
/// The sheet is opened by tapping the "New Account" toolbar button in the
/// sidebar (macOS only). Each action method starts with
/// `Trace.record(#function)` and waits for a real post-condition before
/// returning — see `guides/UI_TEST_GUIDE.md` §3 (driver invariants).
@MainActor
struct CreateAccountScreen {
  let app: MoolahApp

  /// Driver for the currency field — the `InstrumentPickerField` inside
  /// `CreateAccountView`.
  var currency: InstrumentPickerFieldDriver { InstrumentPickerFieldDriver(app: app) }

  // MARK: - Actions

  /// Taps the "New Account" toolbar button in the sidebar to present
  /// `CreateAccountView`. Returns once the sheet's currency field is
  /// visible in the accessibility tree.
  func open(initialCurrencyId: String) {
    Trace.record(#function, detail: "initialCurrencyId=\(initialCurrencyId)")
    let button = app.element(for: UITestIdentifiers.Sidebar.newAccountButton)
    if !button.waitForExistence(timeout: 10) {
      Trace.recordFailure("sidebar.toolbar.newAccount button did not appear")
      XCTFail("New Account toolbar button did not appear within 10s")
      return
    }
    button.click()

    // Post-condition: the currency picker field must be visible in the sheet.
    let field = app.element(for: UITestIdentifiers.InstrumentPicker.field(initialCurrencyId))
    if !field.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "instrumentPicker.field.\(initialCurrencyId) did not appear in CreateAccountView")
      XCTFail(
        "CreateAccountView currency field did not appear within 10s "
          + "(expected instrumentPicker.field.\(initialCurrencyId))")
    }
  }
}
