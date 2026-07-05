import XCTest

/// Driver for the Recently Added landing page (`RecentlyAddedView`):
/// the imported-row list, its passive "possible transfer" pill, and the
/// macOS row context-menu merge / dismiss actions. Returned from
/// `MoolahApp.recentlyAdded`.
///
/// Row content is wrapped in `.accessibilityElement(children: .combine)`
/// for VoiceOver, so the per-row handle is the row-level identifier
/// `UITestIdentifiers.RecentlyAdded.row(_:)`; the merge / dismiss
/// actions live in the row's context menu and are opened by
/// right-clicking that row element. Every action method records a trace
/// breadcrumb and waits on a real post-condition; expectation methods
/// are read-only and do not record a breadcrumb. All element lookups go
/// through `MoolahApp.element(for:)`.
@MainActor
struct RecentlyAddedScreen {
  let app: MoolahApp

  /// Asserts the Recently Added container is on screen — the presence
  /// sentinel a subsequent pill-absence assertion relies on so an
  /// absence check cannot pass vacuously when the view failed to render.
  func expectVisible() {
    let container = app.element(for: UITestIdentifiers.RecentlyAdded.container)
    if !container.waitForExistence(timeout: 10) {
      Trace.recordFailure("recentlyadded.container did not appear")
      XCTFail("Recently Added view did not render within 10s")
    }
  }

  /// Asserts the passive transfer pill is present for the given
  /// transaction. The Recently Added row wraps its content in
  /// `.accessibilityElement(children: .combine)` for VoiceOver, which
  /// flattens the pill's own identifier into the combined row element —
  /// so presence is asserted by waiting on the stable row handle and
  /// checking its combined accessibility label carries the pill title
  /// (the title is appended to the row label only when the transaction
  /// has a `TransferSuggestion`).
  func expectPillVisible(for id: UUID) {
    let row = app.element(for: UITestIdentifiers.RecentlyAdded.row(id))
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "recently added row '\(UITestIdentifiers.RecentlyAdded.row(id))' did not appear")
      XCTFail("Recently Added row for \(id) did not appear within 10s")
      return
    }
    let prefix = UITestIdentifiers.TransferDetection.pillLabelPrefix
    if !row.label.contains(prefix) {
      Trace.recordFailure(
        "row '\(id)' label '\(row.label)' did not contain pill title '\(prefix)'")
      XCTFail("Transfer pill title absent from row \(id) label: '\(row.label)'")
    }
  }

  /// Asserts the Recently Added row for the given transaction is gone.
  /// This is the post-merge signal: the merge replaces the two
  /// single-account sides with one `.merged` transfer that the view
  /// filters out, so the source row handle itself disappears. The caller
  /// must have established a presence sentinel (e.g. `expectVisible()`)
  /// so this cannot pass vacuously.
  func expectRowRemoved(for id: UUID) {
    let row = app.element(for: UITestIdentifiers.RecentlyAdded.row(id))
    if !row.waitForNonExistence(timeout: 10) {
      Trace.recordFailure(
        "recently added row '\(UITestIdentifiers.RecentlyAdded.row(id))' "
          + "still present; row not removed")
      XCTFail("Recently Added row for \(id) was still present after 10s")
    }
  }

  /// Asserts the transfer pill is gone for the given transaction while
  /// the row itself remains. This is the post-dismiss signal: dismiss
  /// deletes the `TransferSuggestion` record for the pair, leaving
  /// both `.single` rows in Recently Added — the pill title drops out
  /// of the row's combined accessibility label but the row handle
  /// persists. The row's continued existence is the presence sentinel,
  /// asserted first so this cannot pass vacuously, before the bounded
  /// wait for the pill title to clear from the still-present row's
  /// label.
  func expectPillCleared(for id: UUID) {
    let row = app.element(for: UITestIdentifiers.RecentlyAdded.row(id))
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "recently added row '\(UITestIdentifiers.RecentlyAdded.row(id))' "
          + "did not appear; cannot assert pill cleared")
      XCTFail("Recently Added row for \(id) did not appear within 10s")
      return
    }
    if !waitForPillCleared(id) {
      Trace.recordFailure(
        "row '\(id)' label '\(row.label)' still contains pill title "
          + "'\(UITestIdentifiers.TransferDetection.pillLabelPrefix)'")
      XCTFail(
        "Transfer pill title still present on row \(id) label after 10s: '\(row.label)'")
    }
  }

  /// Right-clicks the given row to open its macOS context menu and
  /// clicks "Merge as Transfer". Returns once the row has been removed
  /// from Recently Added — the merge replaces the two single-account
  /// sides with one `.merged` transfer that the view filters out, so
  /// the row's disappearance is the post-condition.
  func tapMerge(for id: UUID) {
    Trace.record(#function, detail: "id=\(id)")
    let row = app.element(for: UITestIdentifiers.RecentlyAdded.row(id))
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "recently added row '\(UITestIdentifiers.RecentlyAdded.row(id))' did not appear")
      XCTFail("Recently Added row for \(id) did not appear within 10s")
      return
    }
    row.rightClick()

    let mergeItem = app.element(for: UITestIdentifiers.TransferDetection.merge(id))
    if !mergeItem.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "merge menu item '\(UITestIdentifiers.TransferDetection.merge(id))' "
          + "did not appear after right-click")
      XCTFail("'Merge as Transfer' menu item did not appear within 10s")
      return
    }
    mergeItem.click()

    if !row.waitForNonExistence(timeout: 10) {
      Trace.recordFailure("row '\(id)' still present 10s after merge")
      XCTFail("Recently Added row for \(id) did not collapse within 10s of merge")
    }
  }

  /// Right-clicks the given row, clicks "Not a Transfer", and confirms
  /// the destructive button in the "Dismiss Transfer Suggestion"
  /// confirmation dialog. Dismiss deletes the `TransferSuggestion`
  /// record for the pair; the transaction stays a recently-imported
  /// `.single` row, so the row remains while only the pill goes away.
  /// Returns once the pill title has cleared from the still-present
  /// row's combined accessibility label — that pill clearing on the
  /// surviving row is the post-condition.
  func tapDismiss(for id: UUID) {
    Trace.record(#function, detail: "id=\(id)")
    let row = app.element(for: UITestIdentifiers.RecentlyAdded.row(id))
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "recently added row '\(UITestIdentifiers.RecentlyAdded.row(id))' did not appear")
      XCTFail("Recently Added row for \(id) did not appear within 10s")
      return
    }
    row.rightClick()

    let dismissItem = app.element(for: UITestIdentifiers.TransferDetection.dismiss(id))
    if !dismissItem.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "dismiss menu item '\(UITestIdentifiers.TransferDetection.dismiss(id))' "
          + "did not appear after right-click")
      XCTFail("'Not a Transfer' menu item did not appear within 10s")
      return
    }
    dismissItem.click()

    let confirm = app.element(for: UITestIdentifiers.TransferDetection.dismissConfirm)
    if !confirm.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "dismiss confirm button '\(UITestIdentifiers.TransferDetection.dismissConfirm)' "
          + "did not appear")
      XCTFail("'Dismiss Suggestion' confirm button did not appear within 10s")
      return
    }
    confirm.click()

    if !waitForPillCleared(id) {
      Trace.recordFailure(
        "row '\(id)' label '\(row.label)' still contains pill title "
          + "'\(UITestIdentifiers.TransferDetection.pillLabelPrefix)' 10s after dismiss")
      XCTFail(
        "Transfer pill title did not clear from row \(id) within 10s of dismiss: "
          + "'\(row.label)'")
    }
  }

  // MARK: - Private helpers

  /// Bounded wait for the transfer pill title to drop out of the
  /// combined accessibility label of the (still-present) Recently Added
  /// row for `id`. The label update is async — it lands on the next view
  /// refresh after the dismiss coordinator write — so this evaluates a
  /// closure `NSPredicate` against the live row element via
  /// `XCTNSPredicateExpectation` + `XCTWaiter`, the sanctioned
  /// bounded-wait per UI_TEST_GUIDE §3 (no sleeps / no retries). Returns
  /// `true` once the label no longer contains the pill prefix, `false`
  /// on timeout.
  private func waitForPillCleared(_ id: UUID) -> Bool {
    let row = app.element(for: UITestIdentifiers.RecentlyAdded.row(id))
    let prefix = UITestIdentifiers.TransferDetection.pillLabelPrefix
    let predicate = NSPredicate { _, _ in
      !row.label.contains(prefix)
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
  }
}
