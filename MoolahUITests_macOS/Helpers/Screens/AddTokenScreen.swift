import XCTest

/// Driver for the `AddTokenSheet`'s embedded `InstrumentPickerSheet` filtered
/// to crypto tokens. Returned via `MoolahApp.addToken` once the sheet has
/// been opened from the Crypto Settings tab.
///
/// The sheet itself is the standard `InstrumentPickerSheet`, so its
/// `instrumentPicker.searchField` and `instrumentPicker.row.<id>`
/// identifiers (defined in `UITestIdentifiers.InstrumentPicker`) are reused
/// here verbatim.
///
/// Action methods start with `Trace.record(#function)` and wait for a real
/// post-condition before returning — see `guides/UI_TEST_GUIDE.md` §3.
@MainActor
struct AddTokenScreen {
  let app: MoolahApp

  // MARK: - Actions

  /// Types `query` into the picker's search field. Waits for the typed
  /// value to propagate into the field's accessibility `value` before
  /// returning so any subsequent `waitForResult(instrumentId:)` call sees
  /// the search debounce fire against the intended query, not against an
  /// empty string. The row-appearance post-condition itself is delegated
  /// to `waitForResult(instrumentId:)` so a caller types the prefix and
  /// then waits for the specific row, mirroring the user's perception
  /// ("type, see, click").
  func search(_ query: String) {
    Trace.record(#function, detail: "query=\(query)")
    let field = app.element(for: UITestIdentifiers.InstrumentPicker.searchField)
    if !field.waitForExistence(timeout: 10) {
      Trace.recordFailure("instrumentPicker.searchField did not appear")
      XCTFail("AddTokenSheet search field did not appear within 10s")
      return
    }
    field.click()
    field.typeText(query)
    let valuePropagated = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", query as CVarArg),
      object: field
    )
    if XCTWaiter().wait(for: [valuePropagated], timeout: 10) != .completed {
      Trace.recordFailure(
        "instrumentPicker.searchField value did not reach '\(query)' after typeText")
      XCTFail("Search field did not show typed value '\(query)'")
    }
  }

  /// Waits up to `timeout` seconds for the picker row whose Instrument id
  /// matches `instrumentId` to appear. The catalog's debounce + async
  /// search lookup means this post-condition is the right gate for "the
  /// user can now click the row I want".
  func waitForResult(instrumentId: String, timeout: TimeInterval = 10) {
    Trace.record(#function, detail: "instrumentId=\(instrumentId)")
    let row = app.element(for: UITestIdentifiers.InstrumentPicker.row(instrumentId))
    if !row.waitForExistence(timeout: timeout) {
      Trace.recordFailure(
        "instrumentPicker.row.\(instrumentId) did not appear within \(timeout)s")
      XCTFail(
        "Picker row for '\(instrumentId)' did not appear within \(timeout)s of search")
    }
  }

  /// Clicks the row for `instrumentId`. Does NOT wait for sheet dismissal —
  /// the resolution + registration is async (see
  /// `InstrumentPickerStore.select(_:)` and the `isResolving` overlay), so
  /// the dismissal post-condition is exposed as a separate
  /// `waitForDismiss()` action that the caller invokes when ready.
  ///
  /// After the click we wait for the row to stop being hittable as a
  /// minimal post-condition that the click registered: either the sheet
  /// dismisses (success path — `waitForDismiss()` covers that) or the
  /// `isResolving` overlay disables the row while the network round-trip
  /// runs.
  func selectResult(instrumentId: String) {
    Trace.record(#function, detail: "instrumentId=\(instrumentId)")
    let row = app.element(for: UITestIdentifiers.InstrumentPicker.row(instrumentId))
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "instrumentPicker.row.\(instrumentId) not found for selection")
      XCTFail(
        "Picker row for '\(instrumentId)' did not appear within 10s of selectResult")
      return
    }
    row.click()
    let consumed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false || isHittable == false"),
      object: row
    )
    _ = XCTWaiter().wait(for: [consumed], timeout: 10)
    // Note: dismissal (success path) is the responsibility of waitForDismiss().
  }

  /// Waits for the picker sheet to dismiss, by polling the sentinel
  /// `instrumentPicker.sheet` identifier. The sheet stays up while the
  /// store's `isResolving` overlay is active (network round-trip in
  /// `TokenResolutionClient.resolve()` and the registry write); a clean
  /// dismissal proves both completed successfully.
  func waitForDismiss(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let sheet = app.element(for: UITestIdentifiers.InstrumentPicker.sheet)
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: sheet
    )
    if XCTWaiter().wait(for: [expectation], timeout: timeout) != .completed {
      Trace.recordFailure(
        "instrumentPicker.sheet still visible after \(timeout)s — resolve/register stalled")
      XCTFail(
        "AddTokenSheet did not dismiss within \(timeout)s of selectResult")
    }
  }
}
