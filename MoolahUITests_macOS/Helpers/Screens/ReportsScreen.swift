import XCTest

/// Symbolic reference to a top-level category header in the Reports
/// category tables. Tests reference headers by name; the driver maps each
/// case to the seeded root-category UUID.
enum ReportsCategoryHeader {
  /// `.tradeBaseline`'s Groceries expense category — a root category with
  /// one directly-categorised expense (Woolworths) and no subcategories.
  /// The "top-level category with its own transactions" case.
  case groceries

  var id: UUID {
    switch self {
    case .groceries: return UITestFixtures.TradeBaseline.groceriesCategoryId
    }
  }
}

/// Driver for the Reports view's category tables (Income / Expenses).
/// Returned from `MoolahApp.reports`. Reach it via
/// `sidebar.switchToNamed(.reports)` first.
@MainActor
struct ReportsScreen {
  let app: MoolahApp

  /// Taps the given top-level category header, drilling into a
  /// `TransactionListView` scoped to that category's whole subtree.
  ///
  /// Returns once the transaction-list container is in the accessibility
  /// tree — the "drill-down rendered" post-condition. It also absorbs the
  /// asynchronous category-balance load: the header row itself only
  /// materialises once `ReportingStore.loadCategoryBalances` completes, so
  /// the bounded `waitForExistence` on the header covers that gap without an
  /// explicit sleep. `exists` (not `isHittable`) mirrors
  /// `SidebarScreen.switchToAccount`: the macOS `List`-backed container is
  /// never reported as hittable — only its rows are.
  func tapCategoryHeader(_ header: ReportsCategoryHeader) {
    Trace.record(detail: "header=\(header)")
    let identifier = UITestIdentifiers.Reports.categoryHeader(header.id)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure("reports category header '\(identifier)' did not appear")
      XCTFail("Reports category header for \(header) did not appear within 10s")
      return
    }
    row.click()

    let listContainer = app.element(for: UITestIdentifiers.TransactionList.container)
    if !listContainer.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "transaction list container did not appear after tapping header \(header)")
      XCTFail(
        "Drill-down transaction list did not render within 10s of tapping header \(header)")
    }
  }
}
