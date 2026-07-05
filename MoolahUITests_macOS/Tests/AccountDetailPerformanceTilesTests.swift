import XCTest

/// macOS UI tests for Increment 3 — the `AccountPerformanceTiles` strip in the
/// unified account-detail Chart pane. Seeded via `.accountDetailLayout`:
/// a multi-currency account (holds USD → tiles) and a fiat-only checking
/// (AUD only → no tiles).
@MainActor
final class AccountDetailPerformanceTilesTests: MoolahUITestCase {
  /// A multi-instrument account shows the performance tiles on its Chart pane.
  func testMultiInstrumentAccountShowsPerformanceTiles() throws {
    let app = launch(seed: .accountDetailLayout)
    app.sidebar.switchToAccount(.multiCurrency)
    app.accountDetail.expectPositionsPanePinned()
    app.accountDetail.toggleToChart()
    app.accountDetail.expectPerformanceTiles()
  }

  /// A fiat-only account shows no performance tiles — the plain total header
  /// rides at the top of its Chart pane instead.
  func testFiatOnlyAccountShowsNoPerformanceTiles() throws {
    let app = launch(seed: .accountDetailLayout)
    app.sidebar.switchToAccount(.everydayFiat)
    app.accountDetail.expectNoPositionsPane()
    app.accountDetail.toggleToChart()
    app.accountDetail.expectNoPerformanceTiles()
  }
}
