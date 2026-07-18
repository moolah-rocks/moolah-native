import XCTest

/// Driver for the transaction detail view (right column or sheet).
/// Exposes typed sub-drivers for each editable field; tests never reach
/// `XCUIElement` directly. See `guides/UI_TEST_GUIDE.md` §3 (driver
/// invariants).
@MainActor
struct TransactionDetailScreen {
  let app: MoolahApp

  /// Driver for the payee field — a text field with autocomplete dropdown.
  var payee: AutocompleteFieldDriver {
    AutocompleteFieldDriver(
      app: app,
      fieldIdentifier: UITestIdentifiers.Detail.payee,
      dropdownIdentifier: UITestIdentifiers.Autocomplete.payee,
      suggestionIdentifier: UITestIdentifiers.Autocomplete.payeeSuggestion(_:)
    )
  }

  /// Driver for the simple-mode category field — a text field with
  /// autocomplete dropdown. Only exposes the single-leg section; multi-leg
  /// (custom) transactions use `leg(_:).category` instead.
  var category: AutocompleteFieldDriver {
    AutocompleteFieldDriver(
      app: app,
      fieldIdentifier: UITestIdentifiers.Detail.category,
      dropdownIdentifier: UITestIdentifiers.Autocomplete.category,
      suggestionIdentifier: UITestIdentifiers.Autocomplete.categorySuggestion(_:)
    )
  }

  /// Driver for a single sub-transaction (leg) section in a multi-leg
  /// (`isCustom`) transaction. Legs are ordered by `sortOrder`; index 0
  /// is the first leg the user sees.
  func leg(_ index: Int) -> LegSectionDriver {
    LegSectionDriver(app: app, legIndex: index)
  }

  /// Counterpart amount field that is rendered only for cross-currency
  /// transfers.
  var counterpartAmount: CounterpartAmountDriver {
    CounterpartAmountDriver(app: app)
  }

  /// Moves keyboard focus from the Amount field to its adjacent instrument
  /// picker, then activates the picker with Space. Returns once the picker
  /// sheet appears.
  func openInstrumentPickerWithKeyboard() {
    Trace.record(#function)
    let amountField = app.element(for: UITestIdentifiers.Detail.amount)
    if !amountField.waitUntilHittable(timeout: 10) {
      Trace.recordFailure("transaction amount field was not hittable")
      XCTFail("Transaction amount field was not hittable within 10s")
      return
    }
    amountField.click()
    app.pressKeyboardShortcut(XCUIKeyboardKey.tab.rawValue)

    let picker = app.element(for: UITestIdentifiers.Detail.amountInstrument)
    let focusDeadline = Date().addingTimeInterval(10)
    while Date() < focusDeadline {
      if (picker.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard (picker.value(forKey: "hasKeyboardFocus") as? Bool) == true else {
      Trace.recordFailure("transaction instrument picker did not receive keyboard focus")
      XCTFail("Transaction instrument picker did not receive keyboard focus within 10s")
      return
    }

    app.pressSpaceKey(on: picker)

    let sheet = app.element(for: UITestIdentifiers.InstrumentPicker.sheet)
    if !sheet.waitForExistence(timeout: 10) {
      Trace.recordFailure("instrument picker sheet did not appear after pressing Space")
      XCTFail("Instrument picker sheet did not appear within 10s of pressing Space")
    }
  }

  /// Selects a new "To Account" (counterpart account) for a transfer via
  /// the transfer account picker. Clicks the picker to open its menu,
  /// clicks the menu item with the given display name, and returns once
  /// the picker's displayed title reflects the selection — proving the
  /// SwiftUI state binding (`draft.legDrafts[counterpartIndex].accountId`)
  /// has propagated. The menu-dismissal signal on its own is not a
  /// sufficient post-condition; it can fire before the picker re-renders.
  func selectToAccount(named name: String) {
    Trace.record(detail: "toAccount=\(name)")
    let picker = app.element(for: UITestIdentifiers.Detail.toAccountPicker)
    if !picker.waitForExistence(timeout: 10) {
      Trace.recordFailure("to-account picker did not appear")
      XCTFail(
        "To-account picker '\(UITestIdentifiers.Detail.toAccountPicker)' "
          + "did not appear within 10s")
      return
    }
    picker.click()

    // ui-test-review: allow single-resolver — on macOS, SwiftUI Pickers
    // open a native NSMenu whose items attach to the application's menu
    // hierarchy at runtime. `.accessibilityIdentifier(_:)` on the inline
    // `Text(account.name)` inside the `ForEach` does not propagate to the
    // NSMenuItem, so querying by label via `menuItems[name]` is the only
    // viable resolution path here.
    let menuItem = app.application.menuItems[name]
    if !menuItem.waitForExistence(timeout: 10) {
      Trace.recordFailure("menu item '\(name)' did not appear")
      XCTFail("Picker menu item '\(name)' did not appear within 10s")
      return
    }
    menuItem.click()

    // Post-condition: the picker's displayed selection updates to the new
    // value — a more reliable signal than menu dismissal because it
    // proves the SwiftUI binding flowed through, not just that the popup
    // closed. macOS pop-up buttons expose the selection via `value`, not
    // `title`; the latter is empty.
    let deadline = Date().addingTimeInterval(10)
    var lastValue = ""
    while Date() < deadline {
      lastValue = (picker.value as? String) ?? ""
      if lastValue == name { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure(
      "picker value was '\(lastValue)' after selecting '\(name)'")
    XCTFail(
      "To-account picker did not show '\(name)' within 10s of selection (was '\(lastValue)')")
  }
}
