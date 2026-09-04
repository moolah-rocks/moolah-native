import XCTest

/// End-to-end coverage that Recently Added uses the normal selectable
/// transaction list and preserves the standard detail actions.
@MainActor
final class TransferDetectionUITests: MoolahUITestCase {
  func testRecentlyAddedSelectionShowsTransferReviewInStandardInspector() {
    let app = launch(seed: .transferDetectionBaseline)
    app.sidebar.switchToNamed(.recentlyAdded)
    app.recentlyAdded.expectVisible()

    let transactionId = UITestFixtures.TransferDetection.primaryOutgoingId
    app.recentlyAdded.openTransaction(transactionId)

    app.transactionDetail.payee.expectValue(
      UITestFixtures.TransferDetection.primaryOutgoingPayee)
    app.transactionDetail.expectTransferSuggestion(for: transactionId)
  }
}
