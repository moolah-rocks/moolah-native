import XCTest

/// macOS UI regression for Increment 4 — every account type now renders the
/// single unified `AccountDetailView` (header slot + `PositionsChartTransactionsSplit`).
/// Crypto retains its synced header above the split; a real `.calculatedFromTrades`
/// investment account exercises `AccountDetailView(alwaysShowsFullSurface: true)`
/// (the core Increment-4 routing change), pins its positions pane, and shows
/// performance tiles on the Chart pane.
@MainActor
final class AccountDetailUnifiedLayoutTests: MoolahUITestCase {
  // MARK: - Crypto account

  /// A crypto wallet shows the synced-account header above the unified split.
  func testCryptoAccountShowsSyncedHeaderAboveDetail() throws {
    let app = launch(seed: .walletHeaderSyncError)
    app.sidebar.switchToAccount(.walletWithSyncError)
    app.syncedAccountHeader.expectErrorCaptionVisible()
  }

  /// A crypto wallet defaults the unified split to the Transactions pane.
  func testCryptoAccountDefaultsDetailToTransactions() throws {
    let app = launch(seed: .walletHeaderSyncError)
    app.sidebar.switchToAccount(.walletWithSyncError)
    app.accountDetail.expectTransactionsDefault()
  }

  // MARK: - Investment account (.calculatedFromTrades)

  /// A funded `.calculatedFromTrades` investment account pins the Positions
  /// pane in the macOS unified layout, exercising
  /// `AccountDetailView(alwaysShowsFullSurface: true)`.
  func testInvestmentAccountPinsPositionsPane() throws {
    let app = launch(seed: .investmentTradeReady)
    app.sidebar.switchToAccount(.investmentPortfolio)
    app.accountDetail.expectPositionsPanePinned()
  }

  /// A funded `.calculatedFromTrades` investment account shows performance
  /// tiles on the Chart pane of the unified layout.
  func testInvestmentAccountShowsPerformanceTilesOnChart() throws {
    let app = launch(seed: .investmentTradeReady)
    app.sidebar.switchToAccount(.investmentPortfolio)
    app.accountDetail.toggleToChart()
    app.accountDetail.expectPerformanceTiles()
  }
}
