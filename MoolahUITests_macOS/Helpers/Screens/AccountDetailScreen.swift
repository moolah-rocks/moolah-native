import XCTest

/// Driver for `PositionsChartTransactionsSplit`, the unified account-detail
/// container. Returned from `MoolahApp.accountDetail`.
///
/// On macOS the container renders one of two shapes:
///   - Multi-instrument: `ResizableVSplit` with the positions table pinned in
///     the top pane and a `[Transactions | Chart]` toggle in the bottom pane
///     (default: Transactions).
///   - Fiat-only: a single full-height pane carrying just the toggle
///     (no Positions surface).
@MainActor
struct AccountDetailScreen {
  let app: MoolahApp

  /// Asserts the pinned Positions pane is present within `timeout` seconds.
  /// Expected for macOS multi-instrument accounts
  /// (`AccountDetailLayout.hasNonHostHoldings == true`).
  func expectPositionsPanePinned(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let pane = app.element(for: UITestIdentifiers.AccountDetail.positionsPane)
    if !pane.waitForExistence(timeout: timeout) {
      Trace.recordFailure("positions pane did not appear")
      XCTFail(
        "Pinned positions pane did not appear within \(timeout)s for a multi-instrument "
          + "account. Check PositionsChartTransactionsSplit renders the pinned top pane "
          + "when hasPositions is true.")
    }
  }

  /// Asserts NO Positions pane exists (macOS fiat-only single-pane layout).
  /// The tab picker (the `[Transactions | Chart]` toggle) must exist first,
  /// so the container has rendered before asserting the pane's absence.
  func expectNoPositionsPane(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let picker = app.element(for: UITestIdentifiers.AccountDetail.tabPicker)
    if !picker.waitForExistence(timeout: timeout) {
      Trace.recordFailure("tab picker did not appear")
      XCTFail("Account-detail toggle did not appear within \(timeout)s")
      return
    }
    let pane = app.element(for: UITestIdentifiers.AccountDetail.positionsPane)
    XCTAssertFalse(
      pane.exists,
      "Positions pane should be absent for a fiat-only account (no non-host holdings).")
  }

  /// Asserts the transactions surface is showing by default. The toggle
  /// defaults to Transactions, so the transaction-list container is present
  /// and the chart pane is not.
  func expectTransactionsDefault(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let list = app.element(for: UITestIdentifiers.TransactionList.container)
    if !list.waitForExistence(timeout: timeout) {
      Trace.recordFailure("transaction list not shown by default")
      XCTFail("Transactions is not the default bottom-pane tab within \(timeout)s")
      return
    }
    XCTAssertFalse(
      app.element(for: UITestIdentifiers.AccountDetail.chartPane).exists,
      "Chart pane should not be visible while Transactions is the selected tab.")
  }

  /// Clicks the "Chart" segment of the bottom toggle and waits for the chart
  /// pane to appear.
  func toggleToChart(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let segment = app.pickerSegment(label: UITestIdentifiers.AccountDetail.chartSegmentLabel)
    if !segment.waitForExistence(timeout: timeout) {
      Trace.recordFailure("Chart segment button did not appear")
      XCTFail(
        "Chart segment button did not appear within \(timeout)s. "
          + "Check the bottom-pane Picker has rendered.")
      return
    }
    segment.click()
    let chart = app.element(for: UITestIdentifiers.AccountDetail.chartPane)
    if !chart.waitForExistence(timeout: timeout) {
      Trace.recordFailure("chart pane did not appear after toggling")
      XCTFail("Chart pane did not appear within \(timeout)s of clicking the Chart segment")
    }
  }

  /// Asserts the performance-tiles strip is present within `timeout` seconds.
  /// The Chart pane must be showing first (call `toggleToChart()` on macOS).
  /// Expected for accounts with non-host holdings (crypto / exchange / mixed).
  func expectPerformanceTiles(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let tiles = app.element(for: UITestIdentifiers.AccountDetail.performanceTiles)
    if !tiles.waitForExistence(timeout: timeout) {
      Trace.recordFailure("performance tiles did not appear")
      XCTFail(
        "Performance tiles did not appear within \(timeout)s on the Chart pane for a "
          + "multi-instrument account. Check computePerformance feeds a non-nil "
          + "AccountPerformance into PositionsAssemblyContext.")
    }
  }

  /// Asserts the performance-tiles strip is absent (fiat-only account shows
  /// the plain total header instead). The Chart pane must be showing first,
  /// so the pane has rendered before asserting the strip's absence.
  func expectNoPerformanceTiles(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let chart = app.element(for: UITestIdentifiers.AccountDetail.chartPane)
    if !chart.waitForExistence(timeout: timeout) {
      Trace.recordFailure("chart pane did not appear")
      XCTFail("Chart pane did not appear within \(timeout)s")
      return
    }
    XCTAssertFalse(
      app.element(for: UITestIdentifiers.AccountDetail.performanceTiles).exists,
      "Performance tiles should be absent for a fiat-only account (no invested / P&L data).")
  }

  /// Clicks the "Transactions" segment of the bottom toggle and waits for
  /// the transaction list to reappear.
  func toggleToTransactions(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let segment = app.pickerSegment(label: UITestIdentifiers.AccountDetail.transactionsSegmentLabel)
    if !segment.waitForExistence(timeout: timeout) {
      Trace.recordFailure("Transactions segment button did not appear")
      XCTFail(
        "Transactions segment button did not appear within \(timeout)s. "
          + "Check the bottom-pane Picker has rendered.")
      return
    }
    segment.click()
    let list = app.element(for: UITestIdentifiers.TransactionList.container)
    if !list.waitForExistence(timeout: timeout) {
      Trace.recordFailure("transaction list did not reappear after toggling")
      XCTFail("Transaction list did not reappear within \(timeout)s")
    }
  }
}
