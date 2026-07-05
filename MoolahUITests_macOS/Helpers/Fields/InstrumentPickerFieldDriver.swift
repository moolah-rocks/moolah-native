import XCTest

/// Driver for `InstrumentPickerField` — the button that opens the searchable
/// instrument picker sheet when a CloudKit-backed profile is active.
///
/// Each action method starts with `Trace.record(#function)` and waits for a
/// real post-condition before returning — see
/// `guides/UI_TEST_GUIDE.md` §3 (driver invariants).
///
/// Usage:
///   app.createAccount.currency.tap(currentId: "AUD")
///   app.createAccount.currency.search("USD")
///   app.createAccount.currency.pickRow("USD")
///   app.createAccount.currency.expectFieldSelection("USD")
@MainActor
struct InstrumentPickerFieldDriver {
  let app: MoolahApp

  // MARK: - Actions

  /// Taps the picker field button (currently showing `currentId`) to open
  /// the instrument picker sheet. Returns once `instrumentPicker.sheet` is
  /// visible in the accessibility tree.
  func tap(currentId: String) {
    Trace.record(#function, detail: "currentId=\(currentId)")
    let button = app.element(for: UITestIdentifiers.InstrumentPicker.field(currentId))
    if !button.waitForExistence(timeout: 10) {
      Trace.recordFailure("field button 'instrumentPicker.field.\(currentId)' did not appear")
      XCTFail(
        "InstrumentPickerField button for '\(currentId)' did not appear within 10s")
      return
    }
    button.click()
    let sheet = app.element(for: UITestIdentifiers.InstrumentPicker.sheet)
    if !sheet.waitForExistence(timeout: 10) {
      Trace.recordFailure("instrumentPicker.sheet did not appear after tapping field")
      XCTFail("InstrumentPickerSheet did not appear within 10s of tapping the field button")
    }
  }

  /// Types `query` into the picker's search field. Returns once the row for
  /// `query` exists in the list (proving the search result propagated).
  func search(_ query: String) {
    Trace.record(#function, detail: "query=\(query)")
    // The macOS picker uses a custom VStack layout with an explicit TextField
    // (`instrumentPicker.searchField`) rather than `.searchable` on a
    // NavigationStack; the latter does not expose an accessible search field
    // inside a popover on macOS.
    let searchField = app.element(for: UITestIdentifiers.InstrumentPicker.searchField)
    if !searchField.waitForExistence(timeout: 10) {
      Trace.recordFailure("instrumentPicker.searchField did not appear")
      XCTFail("InstrumentPickerSheet search field did not appear within 10s")
      return
    }
    searchField.click()
    searchField.typeText(query)

    // Post-condition: the row for the searched id must appear in the list.
    let row = app.element(for: UITestIdentifiers.InstrumentPicker.row(query))
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "instrumentPicker.row.\(query) did not appear after searching '\(query)'")
      XCTFail(
        "InstrumentPickerSheet row for '\(query)' did not appear within 10s of searching")
    }
  }

  /// Taps the row for `instrumentId` inside the sheet. Returns once both
  /// the sheet has dismissed (proven by `instrumentPicker.sheet` disappearing)
  /// AND the field button has updated to show the new selection (proven by
  /// `instrumentPicker.field.<instrumentId>` appearing).
  func pickRow(_ instrumentId: String) {
    Trace.record(#function, detail: "instrumentId=\(instrumentId)")
    let row = app.element(for: UITestIdentifiers.InstrumentPicker.row(instrumentId))
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure("instrumentPicker.row.\(instrumentId) not found for pick")
      XCTFail("InstrumentPickerSheet row for '\(instrumentId)' did not appear within 10s")
      return
    }
    row.click()

    // Post-condition 1: the sheet must dismiss after the pick.
    let sheet = app.element(for: UITestIdentifiers.InstrumentPicker.sheet)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if !sheet.exists { break }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if sheet.exists {
      Trace.recordFailure("instrumentPicker.sheet did not dismiss after picking '\(instrumentId)'")
      XCTFail("InstrumentPickerSheet did not dismiss within 10s of picking '\(instrumentId)'")
      return
    }

    // Post-condition 2: field button updates to the new selection.
    let updatedField = app.element(for: UITestIdentifiers.InstrumentPicker.field(instrumentId))
    if !updatedField.waitForExistence(timeout: 10) {
      Trace.recordFailure("field did not update to '\(instrumentId)' after sheet dismissed")
      XCTFail("InstrumentPickerField did not update to '\(instrumentId)' within 10s of picking")
    }
  }

  // MARK: - Expectations (read-only)

  /// Asserts the field button now shows `instrumentId` as the selection —
  /// i.e. `instrumentPicker.field.<instrumentId>` exists in the tree.
  /// Since `pickRow()` already guarantees propagation, this is a snapshot
  /// assertion (no polling needed when called after `pickRow`).
  func expectFieldSelection(_ instrumentId: String) {
    let identifier = UITestIdentifiers.InstrumentPicker.field(instrumentId)
    let button = app.element(for: identifier)
    XCTAssertTrue(
      button.exists,
      "InstrumentPickerField did not show '\(instrumentId)' — expected after pickRow()")
  }
}
