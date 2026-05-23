import XCTest

/// Behaviour tests for the simple-mode category autocomplete dropdown on
/// `TransactionDetailView`. The `.tradeBaseline` seed includes the
/// "Groceries" and "Gym" categories so the prefix "G" yields two
/// matches and the prefix "Gro" matches exactly one.
@MainActor
final class TransactionDetailCategoryTests: MoolahUITestCase {
  /// Per [#509](https://github.com/moolah-rocks/moolah-native/issues/509),
  /// arrow-key highlighting + Tab must commit the highlighted suggestion
  /// — the same as Enter or clicking the suggestion. Without this, the
  /// blur handler would dismiss the highlight, then the typed text would
  /// fail to resolve to a known category, and the field would be
  /// cleared. The fix lives in
  /// `TransactionDraft.commitHighlightedCategoryOrNormalise(...)` and
  /// the section's blur handler.
  func testTabFromHighlightedCategoryCommitsSuggestion() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)

    app.transactionDetail.category.tap()
    app.transactionDetail.category.type("Gro")
    app.transactionDetail.category.expectSuggestionsVisible(count: 1)
    app.transactionDetail.category.pressArrowDown()
    app.transactionDetail.category.expectHighlightedSuggestion(at: 0)

    app.transactionDetail.category.pressTab()

    app.transactionDetail.category.expectValue("Groceries")
    app.transactionDetail.category.expectSuggestionsHidden()
  }

  /// Regression for [#509](https://github.com/moolah-rocks/moolah-native/issues/509)
  /// reopening: pressing Enter to commit the highlighted suggestion and then
  /// Tabbing to the next field must keep the committed value. The original
  /// fix only handled the "Tab without Enter" path; this case (Enter then Tab)
  /// was still clearing the field because the blur handler renormalised
  /// against a category text that had been just-set, found a stale
  /// resolution, and cleared.
  func testEnterThenTabPreservesCommittedCategory() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)

    app.transactionDetail.category.tap()
    app.transactionDetail.category.type("Gro")
    app.transactionDetail.category.expectSuggestionsVisible(count: 1)
    app.transactionDetail.category.pressArrowDown()
    app.transactionDetail.category.expectHighlightedSuggestion(at: 0)

    app.transactionDetail.category.pressEnter()
    app.transactionDetail.category.expectValue("Groceries")

    app.transactionDetail.category.pressTab()

    app.transactionDetail.category.expectValue("Groceries")
    app.transactionDetail.category.expectSuggestionsHidden()
  }
}
