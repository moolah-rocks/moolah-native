import XCTest

/// macOS UI tests for `PositionsChartTransactionsSplit`, the unified
/// account-detail container. Seeded via `.accountDetailLayout`:
/// a multi-currency bank account (pinned positions) and a fiat-only
/// checking (single toggle pane).
///
/// The seed hydrates:
///   - "Multi-Currency" bank account (AUD host + USD position) — triggers
///     `AccountDetailLayout.hasNonHostHoldings == true`, so the macOS
///     layout shows the `ResizableVSplit` with the Positions pane pinned
///     above the `[Transactions | Chart]` toggle.
///   - "Everyday" bank account (AUD-only positions) — `hasNonHostHoldings`
///     is `false`, so only the toggle pane renders (no Positions surface).
@MainActor
final class AccountDetailSplitTests: MoolahUITestCase {
  /// A multi-instrument account pins the Positions pane and defaults the
  /// bottom toggle to Transactions.
  func testMultiInstrumentAccountPinsPositionsAndDefaultsToTransactions() throws {
    let app = launch(seed: .accountDetailLayout)
    app.sidebar.switchToAccount(.multiCurrency)
    app.accountDetail.expectPositionsPanePinned()
    app.accountDetail.expectTransactionsDefault()
  }

  /// Toggling the bottom pane to Chart shows the chart pane; toggling back
  /// restores the transaction list.
  func testToggleBetweenTransactionsAndChart() throws {
    let app = launch(seed: .accountDetailLayout)
    app.sidebar.switchToAccount(.multiCurrency)
    app.accountDetail.expectTransactionsDefault()
    app.accountDetail.toggleToChart()
    app.accountDetail.toggleToTransactions()
  }

  /// A fiat-only account renders a single toggle pane with no Positions
  /// surface, still defaulting to Transactions.
  func testFiatOnlyAccountHasNoPositionsPane() throws {
    let app = launch(seed: .accountDetailLayout)
    app.sidebar.switchToAccount(.everydayFiat)
    app.accountDetail.expectNoPositionsPane()
    app.accountDetail.expectTransactionsDefault()
  }
}
