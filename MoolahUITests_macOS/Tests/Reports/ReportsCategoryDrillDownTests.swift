import XCTest

/// Verifies you can drill into a *top-level* category header in the Reports
/// category tables, not just its subcategory rows.
///
/// This earns a UI test (over a store test) because the failure class is the
/// real SwiftUI event loop: the header lives in a macOS `List` `Section`
/// header, a position where a `NavigationLink`'s hittability is not
/// guaranteed. The test proves the header is a live navigation target and
/// routes to a category-scoped transaction list. The subtree-vs-exact
/// category-id selection that backs the drill-down is unit-tested in
/// `CategoryDrillDownTests`.
///
/// The Reports view defaults to a `.last12Months` window; `.tradeBaseline`
/// dates its historical expenses relative to launch (see
/// `UITestHistoricalExpense.daysAgo`), so the Groceries expense is always
/// inside that window regardless of when the suite runs.
final class ReportsCategoryDrillDownTests: MoolahUITestCase {
  @MainActor
  func testTappingTopLevelCategoryHeaderShowsItsTransactions() {
    let app = launch(seed: .tradeBaseline)
    app.sidebar.switchToNamed(.reports)

    app.reports.tapCategoryHeader(.groceries)

    // The Groceries header drills into the Woolworths expense directly
    // categorised under Groceries; the uncategorised BHP trade is excluded,
    // proving the drill-down is scoped to the tapped category rather than
    // showing every transaction.
    app.transactionList.expectTransactionVisible(
      UITestFixtures.TradeBaseline.woolworthsGroceriesExpenseId)
    app.transactionList.expectTransactionAbsent(
      UITestFixtures.TradeBaseline.bhpPurchaseId)
  }
}
