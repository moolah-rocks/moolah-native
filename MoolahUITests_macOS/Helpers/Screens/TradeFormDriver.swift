import XCTest

/// Driver for the trade-mode editor in `TransactionDetailView`. Returned from
/// `MoolahApp.tradeForm`. Covers mode-switching, Paid/Received leg editing,
/// and fee management.
///
/// All action methods start with `Trace.record(#function, …)` and wait for a
/// real post-condition before returning — see `guides/UI_TEST_GUIDE.md` §3.
@MainActor
struct TradeFormDriver {
  let app: MoolahApp

  // MARK: - Mode switching

  /// Taps the Type picker (a macOS popup button) to open the native menu, then
  /// selects "Trade". Returns once the Paid amount field appears, proving the
  /// view re-rendered in trade mode.
  func switchToTradeMode() {
    Trace.record(#function)
    let picker = app.element(for: UITestIdentifiers.Detail.modeTypePicker)
    if !picker.waitForExistence(timeout: 10) {
      Trace.recordFailure("modeTypePicker did not appear")
      XCTFail("Type picker '\(UITestIdentifiers.Detail.modeTypePicker)' did not appear within 10s")
      return
    }
    picker.click()

    // ui-test-review: allow single-resolver — on macOS, SwiftUI Pickers open
    // a native NSMenu whose items attach to the application's menu hierarchy
    // at runtime as descendants of the popUpButton. Their AX labels are
    // empty (the inline `Text(…)` inside the ForEach doesn't propagate to
    // the NSMenuItem), so label-based lookup is unavailable; positional
    // indexing scoped to the picker is the only stable handle. The
    // production picker is built from
    // `[.income, .expense, .transfer, .trade, .custom]`, so Trade is at
    // index 3. Scoping to `picker.menuItems` excludes the static
    // `Transaction > Type ▸ Trade` menu-bar entry, which descends from the
    // app's menu bar, not the popUpButton.
    let tradeItem = picker.menuItems.element(boundBy: 3)
    if !tradeItem.waitForExistence(timeout: 10) {
      Trace.recordFailure("popup menu item at index 3 did not appear after opening type picker")
      XCTFail("Picker popup item at index 3 (Trade) did not appear within 10s of opening")
      return
    }
    tradeItem.click()

    // Post-condition: the Paid amount field must exist, proving the view
    // switched to trade mode.
    let paidField = app.element(for: UITestIdentifiers.Detail.tradePaidAmount)
    if !paidField.waitForExistence(timeout: 10) {
      Trace.recordFailure("tradePaidAmount did not appear after switching to Trade mode")
      XCTFail(
        "Trade mode did not render: '\(UITestIdentifiers.Detail.tradePaidAmount)' "
          + "did not appear within 10s")
    }
  }

  // MARK: - Paid leg

  /// Clears and types `amount` into the Paid amount field, then opens the
  /// instrument picker via the `tradePaidInstrument` container and picks
  /// `instrumentId`. Returns once `instrumentPicker.field.<instrumentId>`
  /// exists, proving the selection propagated.
  func setPaid(amount: String, instrumentId: String) {
    Trace.record(#function, detail: "amount=\(amount) instrument=\(instrumentId)")
    setAmountField(UITestIdentifiers.Detail.tradePaidAmount, to: amount)
    setInstrument(
      containerIdentifier: UITestIdentifiers.Detail.tradePaidInstrument,
      instrumentId: instrumentId)
  }

  // MARK: - Received leg

  /// Clears and types `amount` into the Received amount field, then opens the
  /// instrument picker via the `tradeReceivedInstrument` container and picks
  /// `instrumentId`. Returns once `instrumentPicker.field.<instrumentId>`
  /// exists, proving the selection propagated.
  func setReceived(amount: String, instrumentId: String) {
    Trace.record(#function, detail: "amount=\(amount) instrument=\(instrumentId)")
    setAmountField(UITestIdentifiers.Detail.tradeReceivedAmount, to: amount)
    setInstrument(
      containerIdentifier: UITestIdentifiers.Detail.tradeReceivedInstrument,
      instrumentId: instrumentId)
  }

  // MARK: - Fee management

  /// Taps "+ Add Fee", enters `amount` into the fee amount field (at
  /// `feeDisplayIndex`), changes the fee instrument if it differs from "AUD",
  /// and commits `category` via the fee leg's category autocomplete dropdown.
  ///
  /// - Parameters:
  ///   - feeDisplayIndex: Zero-based index corresponding to
  ///     `UITestIdentifiers.Detail.tradeFeeAmount(_:)`. For the first fee, pass 0.
  ///   - feeLegIndex: Absolute `legDrafts` index of the fee leg. For a fresh
  ///     trade with two `.trade` legs, the first fee lands at index 2.
  func addFee(
    amount: String,
    instrumentId: String,
    category: String,
    feeDisplayIndex: Int = 0,
    feeLegIndex: Int = 2
  ) {
    Trace.record(
      #function,
      detail: "amount=\(amount) instrument=\(instrumentId) category=\(category)")

    // Tap "+ Add Fee".
    let addFeeButton = app.element(for: UITestIdentifiers.Detail.tradeAddFeeButton)
    if !addFeeButton.waitForExistence(timeout: 10) {
      Trace.recordFailure("tradeAddFeeButton did not appear")
      XCTFail(
        "Add Fee button '\(UITestIdentifiers.Detail.tradeAddFeeButton)' did not appear within 10s")
      return
    }
    addFeeButton.click()

    // Wait for the fee amount field (proves the fee row inserted).
    let feeAmountId = UITestIdentifiers.Detail.tradeFeeAmount(feeDisplayIndex)
    let feeAmountField = app.element(for: feeAmountId)
    if !feeAmountField.waitForExistence(timeout: 10) {
      Trace.recordFailure("fee amount field '\(feeAmountId)' did not appear after tapping Add Fee")
      XCTFail("Fee amount field '\(feeAmountId)' did not appear within 10s of tapping Add Fee")
      return
    }

    // Enter the fee amount.
    setAmountField(feeAmountId, to: amount)

    // Change the fee instrument (the fee's InstrumentPickerField shows
    // `instrumentPicker.field.<currentId>` on the inner button; because no
    // separate container identifier is set on the fee's picker, locate the
    // button directly via `instrumentPicker.field.AUD` — the fee always
    // defaults to AUD on a fresh Brokerage account).
    if instrumentId != "AUD" {
      setInstrument(containerIdentifier: nil, fieldId: "AUD", instrumentId: instrumentId)
    }

    // Enter the category via the leg's autocomplete field.
    let categoryDriver = AutocompleteFieldDriver(
      app: app,
      fieldIdentifier: UITestIdentifiers.Detail.legCategory(feeLegIndex),
      dropdownIdentifier: UITestIdentifiers.Autocomplete.legCategory(feeLegIndex),
      suggestionIdentifier: { rowIndex in
        UITestIdentifiers.Autocomplete.legCategorySuggestion(feeLegIndex, rowIndex)
      }
    )
    categoryDriver.tap()
    categoryDriver.type(category)
    categoryDriver.expectSuggestionsVisible(count: 1)
    categoryDriver.pressArrowDown()
    categoryDriver.expectHighlightedSuggestion(at: 0)
    categoryDriver.pressEnter()
  }

  // MARK: - Post-condition waits

  /// Waits for a transaction list row whose accessibility label contains
  /// `marker` to appear, up to `timeout` seconds. Trade rows combine
  /// children so the accessibility label is `"Trade, <title>, <amount>,
  /// <date>"` — the trade-title sentence is in the middle, not at the
  /// start, hence `CONTAINS` rather than `BEGINSWITH`. Routes through
  /// `MoolahApp.staticTexts(matching:)` / `cells(matching:)` — the
  /// documented escape hatch from `element(for:)` for label-substring
  /// scans where no stable per-row identifier exists.
  func waitForTradeRow(containing marker: String, timeout: TimeInterval = 10) {
    Trace.record(#function, detail: "marker=\(marker)")
    let predicate = NSPredicate(format: "label CONTAINS %@", marker)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !app.staticTexts(matching: predicate).isEmpty { return }
      if !app.cells(matching: predicate).isEmpty { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    Trace.recordFailure("no row containing '\(marker)' after \(timeout)s")
    XCTFail("No transaction row containing '\(marker)' appeared within \(timeout)s")
  }

  // MARK: - Private helpers

  /// Polls `element.isHittable` until it returns `true` or `timeout` elapses.
  /// Returns `true` on hittable, `false` on timeout. Use after
  /// `waitForExistence` when the element may briefly exist in the AX tree
  /// before becoming hittable (e.g. while an overlapping sheet animates out).
  private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if element.isHittable { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return element.isHittable
  }

  /// Clears any existing text in `identifier` and types `text`. Returns once
  /// the field's `value` contains `text`.
  private func setAmountField(_ identifier: String, to text: String) {
    let field = app.element(for: identifier)
    if !field.waitForExistence(timeout: 10) {
      Trace.recordFailure("amount field '\(identifier)' did not appear")
      XCTFail("Amount field '\(identifier)' did not appear within 10s")
      return
    }
    // `waitForExistence` only checks AX-tree presence — a field can exist
    // in the AX tree but not yet be hittable. The historical reason
    // (sheet-dismissal animation overlap) is now handled at the source by
    // `awaitPickerDismissal` waiting for the popover's host NSWindow to
    // finish tearing down, so by the time control reaches `setAmountField`
    // the form is guaranteed interactive. This 10s wait remains as a
    // narrow safety margin against transient SwiftUI re-layout after
    // `switchToTradeMode` and the typing-in-Paid path before any picker
    // has opened.
    if !waitForHittable(field, timeout: 10) {
      Trace.recordFailure("amount field '\(identifier)' was not hittable within 10s")
      XCTFail("Amount field '\(identifier)' was not hittable within 10s")
      return
    }
    field.click()
    app.pressKeyboardShortcut("a", modifiers: .command)
    field.typeText(text)

    // Post-condition: field reports the typed value. Failure to converge
    // within 10 s is a real driver/product bug — fail loudly so the trace
    // points at the right action, mirroring `AutocompleteFieldDriver.type(_:)`.
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if let value = field.value as? String, value.contains(text) { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure(
      "amount field '\(identifier)' did not contain '\(text)' within 10s")
    XCTFail("Amount field '\(identifier)' did not contain '\(text)' within 10s")
  }

  /// Opens the `InstrumentPickerSheet` by clicking either `containerIdentifier`
  /// (when the outer view has an explicit identifier) or the inner field button
  /// `instrumentPicker.field.<fieldId>`. Then searches for and picks `instrumentId`.
  private func setInstrument(
    containerIdentifier: String?,
    fieldId: String = "AUD",
    instrumentId: String
  ) {
    Trace.record(#function, detail: "instrument=\(instrumentId)")
    // Tap the picker button to open the sheet.
    let button: XCUIElement
    if let container = containerIdentifier {
      button = app.element(for: container)
    } else {
      button = app.element(for: UITestIdentifiers.InstrumentPicker.field(fieldId))
    }
    if !button.waitForExistence(timeout: 10) {
      Trace.recordFailure("instrument picker button did not appear")
      XCTFail("Instrument picker button did not appear within 10s")
      return
    }
    button.click()

    // Wait for the sheet to appear.
    let sheet = app.element(for: UITestIdentifiers.InstrumentPicker.sheet)
    if !sheet.waitForExistence(timeout: 10) {
      Trace.recordFailure("instrumentPicker.sheet did not appear after tap")
      XCTFail("InstrumentPickerSheet did not appear within 10s of tapping the picker button")
      return
    }

    // Search and pick.
    let searchField = app.element(for: UITestIdentifiers.InstrumentPicker.searchField)
    if !searchField.waitForExistence(timeout: 10) {
      Trace.recordFailure("instrumentPicker.searchField did not appear")
      XCTFail("InstrumentPickerSheet search field did not appear within 10s")
      return
    }
    searchField.click()
    searchField.typeText(instrumentId)

    let row = app.element(for: UITestIdentifiers.InstrumentPicker.row(instrumentId))
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure("instrumentPicker.row.\(instrumentId) did not appear after search")
      XCTFail(
        "InstrumentPickerSheet row for '\(instrumentId)' did not appear within 10s of searching")
      return
    }
    // The search input is debounced (250 ms in `InstrumentPickerStore`), so
    // immediately after `typeText` returns the row list is still settling —
    // existing rows may shift while filtered results animate in. Wait for
    // the target row to become hittable before clicking, otherwise a click
    // can land on a stale frame and the sheet never receives the tap.
    if !waitForHittable(row, timeout: 10) {
      Trace.recordFailure("instrumentPicker.row.\(instrumentId) was not hittable within 10s")
      XCTFail(
        "InstrumentPickerSheet row for '\(instrumentId)' was not hittable within 10s of appearing")
      return
    }
    row.click()
    awaitPickerDismissal(
      sheet: sheet,
      containerIdentifier: containerIdentifier,
      instrumentId: instrumentId)
  }

  /// Awaits the picker's full teardown after a row has been committed.
  /// Three sequential post-conditions, in order of how the dismissal
  /// actually unwinds on macOS:
  ///
  /// 1. The SwiftUI sheet *content* leaves the AX tree — the inner
  ///    `instrumentPicker.sheet` view unmounts.
  /// 2. The picker's *host* NSWindow finishes its close animation —
  ///    `app.popover.exists` returns `false` only once the NSPopover's
  ///    backing NSWindow has been fully closed.
  /// 3. The picker anchor in the parent window is hittable again.
  ///
  /// (2) is the load-bearing signal and the only post-condition that
  /// proves the trade form is interactive again. On macOS the picker is
  /// presented as a `.popover` — a separate NSWindow. AX reports
  /// `sheet.exists == false` the moment the SwiftUI content unmounts,
  /// but the host NSWindow can still be in its close animation, and
  /// while it is alive its residual modal state can block hit-testing
  /// on the parent window — even for fields far from the popover
  /// anchor (e.g. the Received amount field after dismissing the Paid
  /// instrument popover). The popover anchor is not a reliable proxy:
  /// it sits adjacent to the popover and can come back to life before
  /// the rest of the form does on slow CI runners, leaving subsequent
  /// `setAmountField` calls with a field that is in the AX tree but
  /// not yet hittable (observed on GitHub macos-26 runners). Waiting
  /// for the host NSWindow itself to
  /// leave the application's window list — the positive signal — is
  /// what makes the form deterministically interactive again.
  ///
  /// The anchor is the same element `setInstrument` clicked to open the
  /// sheet — either the caller's `containerIdentifier` (paid/received
  /// wrap a `CompactInstrumentPickerButton` which has no inner
  /// `instrumentPicker.field.<id>` identifier), or the fallback inner
  /// `instrumentPicker.field.<id>` button (fee path).
  private func awaitPickerDismissal(
    sheet: XCUIElement,
    containerIdentifier: String?,
    instrumentId: String
  ) {
    Trace.record(#function, detail: "instrument=\(instrumentId)")
    let sheetGone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: sheet
    )
    if XCTWaiter().wait(for: [sheetGone], timeout: 10) != .completed {
      Trace.recordFailure("instrumentPicker.sheet did not dismiss after picking '\(instrumentId)'")
      XCTFail("InstrumentPickerSheet did not dismiss within 10s of picking '\(instrumentId)'")
      return
    }

    let popoverGone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: app.popover
    )
    if XCTWaiter().wait(for: [popoverGone], timeout: 10) != .completed {
      Trace.recordFailure(
        "popover host NSWindow did not tear down within 10s after picking '\(instrumentId)'")
      XCTFail(
        "Popover host NSWindow was still present 10s after the "
          + "InstrumentPickerSheet content unmounted — parent-window "
          + "hit-testing is still blocked by residual modal state")
      return
    }

    let anchorIdentifier =
      containerIdentifier ?? UITestIdentifiers.InstrumentPicker.field(instrumentId)
    let anchor = app.element(for: anchorIdentifier)
    if !waitForHittable(anchor, timeout: 10) {
      Trace.recordFailure(
        "picker anchor '\(anchorIdentifier)' was not hittable within 10s of pick")
      XCTFail(
        "Picker anchor '\(anchorIdentifier)' was not hittable within 10s "
          + "of dismissing the sheet")
    }
  }
}

// MARK: - MoolahApp + TradeFormDriver

extension MoolahApp {
  /// Driver for the trade-mode section of the transaction detail inspector.
  var tradeForm: TradeFormDriver { TradeFormDriver(app: self) }
}
