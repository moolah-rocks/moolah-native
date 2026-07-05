import XCTest

/// macOS UI regression for Increment 4 — every account type now renders the
/// single unified `AccountDetailView` (header slot + `PositionsChartTransactionsSplit`).
/// Crypto retains its synced header above the split; a funded position-tracked
/// investment account retains its performance tiles + pinned positions after
/// being folded off the old `PositionsTransactionsSplit` path.
@MainActor
final class AccountDetailUnifiedLayoutTests: MoolahUITestCase {
  /// A crypto wallet shows the synced-account header AND the unified split.
  func testCryptoAccountShowsHeaderAndUnifiedSplit() throws {
    let app = launch(seed: .walletHeaderSyncError)
    app.sidebar.switchToAccount(.walletWithSyncError)
    app.syncedAccountHeader.expectErrorCaptionVisible()
    app.accountDetail.expectTransactionsDefault()
  }

  /// A funded investment `.calculatedFromTrades` account, folded onto the
  /// unified path, still pins its positions pane and shows the performance
  /// tiles on the Chart pane.
  func testInvestmentAccountShowsPinnedPositionsAndPerformanceTiles() throws {
    let app = launch(seed: .tradeReady)
    app.sidebar.switchToAccount(.tradeReadyBrokerage)
    app.accountDetail.expectPositionsPanePinned()
    app.accountDetail.toggleToChart()
    app.accountDetail.expectPerformanceTiles()
  }
}
