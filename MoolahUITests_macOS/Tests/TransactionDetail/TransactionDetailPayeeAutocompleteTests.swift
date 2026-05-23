import XCTest

/// Behaviour tests for the payee autocomplete dropdown on
/// `TransactionDetailView`. Covers: show on typing, hide on clearing,
/// arrow-key highlight + Return commit, and Escape reset. The `.tradeBaseline`
/// seed includes historical expenses with prefix "Wool" (Woolworths ×2,
/// Woolworths Metro ×1) plus a Coles expense and the BHP trade so every
/// prefix has a deterministic result set.
@MainActor
final class TransactionDetailPayeeAutocompleteTests: MoolahUITestCase {
  func testTypingPrefixShowsDropdown() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)
    app.transactionDetail.payee.tap()
    app.transactionDetail.payee.clear()
    app.transactionDetail.payee.type("Wool")

    app.transactionDetail.payee.expectSuggestionsVisible(count: 2)
  }

  func testClearingFieldHidesDropdown() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)
    app.transactionDetail.payee.tap()
    app.transactionDetail.payee.clear()
    app.transactionDetail.payee.type("Wool")
    app.transactionDetail.payee.expectSuggestionsVisible(count: 2)

    app.transactionDetail.payee.clear()

    app.transactionDetail.payee.expectSuggestionsHidden()
  }

  func testArrowDownThenReturnSelectsFirstSuggestion() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)
    app.transactionDetail.payee.tap()
    app.transactionDetail.payee.clear()
    app.transactionDetail.payee.type("Wool")
    app.transactionDetail.payee.expectSuggestionsVisible(count: 2)

    app.transactionDetail.payee.pressArrowDown()
    app.transactionDetail.payee.expectHighlightedSuggestion(at: 0)
    app.transactionDetail.payee.pressEnter()

    app.transactionDetail.payee.expectValue("Woolworths")
    app.transactionDetail.payee.expectSuggestionsHidden()
  }

  /// Escape closes the dropdown but must leave the user's typed text
  /// alone. Per [#510](https://github.com/moolah-rocks/moolah-native/issues/510),
  /// the user is in control of what is in the payee field — autocomplete
  /// is an aid, not a constraint, so dismissing the dropdown without a
  /// commit must not also wipe what the user has typed.
  func testEscapeKeepsTypedTextAndClosesDropdown() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)
    app.transactionDetail.payee.tap()
    app.transactionDetail.payee.clear()
    app.transactionDetail.payee.type("Wool")
    app.transactionDetail.payee.expectSuggestionsVisible(count: 2)

    app.transactionDetail.payee.pressEscape()

    app.transactionDetail.payee.expectValue("Wool")
    app.transactionDetail.payee.expectSuggestionsHidden()
  }

  /// Typing the exact text of a historical payee must still show that
  /// payee in the dropdown. The seed contains two "Woolworths" expenses
  /// plus one "Woolworths Metro", so after typing "Woolworths" the user
  /// should see two suggestions — "Woolworths" (dedup-merged across the
  /// two historical entries) and "Woolworths Metro". The previous bug
  /// silently filtered the exact match out, surfacing only one option
  /// and giving the impression the app had forgotten the payee the user
  /// had just typed.
  func testTypingExactPayeeIncludesItInSuggestions() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)
    app.transactionDetail.payee.tap()
    app.transactionDetail.payee.clear()
    app.transactionDetail.payee.type("Woolworths")

    app.transactionDetail.payee.expectSuggestionsVisible(count: 2)
  }
}
