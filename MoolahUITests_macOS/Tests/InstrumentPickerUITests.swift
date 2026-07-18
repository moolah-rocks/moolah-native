import XCTest

/// Happy-path UI test for `InstrumentPickerField` + `InstrumentPickerSheet`.
///
/// Reaches the picker via `CreateAccountView`'s currency field. The
/// `.tradeBaseline` seed is used; no new seed is needed.
///
/// The test verifies the full open → search → pick → dismiss → field-updates
/// cycle that is only observable through the real SwiftUI event loop — the
/// reason a store test cannot cover this. See `guides/UI_TEST_GUIDE.md` §1.
@MainActor
final class InstrumentPickerUITests: MoolahUITestCase {
  /// Opening the picker, searching for "USD", tapping the USD row, and
  /// asserting the field reflects the new selection.
  func testPickingInstrumentUpdatesField() {
    let app = launch(seed: .tradeBaseline)

    // Open CreateAccountView — the currency field starts at AUD (the profile
    // instrument).
    app.createAccount.open(initialCurrencyId: "AUD")

    // Tap the field to open the sheet. tap() waits for sheet appearance as
    // its post-condition, so no separate expectSheetVisible() call is needed.
    app.createAccount.currency.tap(currentId: "AUD")

    // Type "USD" into the searchable field and wait for the row to appear.
    app.createAccount.currency.search("USD")

    // Tap the USD row, which dismisses the sheet and updates the selection.
    app.createAccount.currency.pickRow("USD")

    // The field button identifier must now be instrumentPicker.field.USD.
    app.createAccount.currency.expectFieldSelection("USD")
  }

  /// Keyboard activation must create the picker and its store atomically;
  /// replacing the store while presenting can crash AppKit's popover path.
  func testSpaceOpensFocusedInstrumentPickerField() {
    let app = launch(seed: .tradeBaseline)

    app.createAccount.open(initialCurrencyId: "AUD")
    app.createAccount.currency.activateWithKeyboard(currentId: "AUD")
  }
}
