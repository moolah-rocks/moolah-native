import XCTest

/// Driver for the `SyncedAccountHeaderView` bar rendered above the
/// transaction list on a synced (`.crypto` or `.exchange`) account.
/// Returned from `MoolahApp.syncedAccountHeader`.
///
/// All identifier lookups go through `MoolahApp.element(for:)`; action
/// methods record a trace breadcrumb and wait on a real post-condition
/// (UI_TEST_GUIDE §3 invariants).
@MainActor
struct SyncedAccountHeaderScreen {
  let app: MoolahApp

  // MARK: - Expectations

  /// Asserts that the inline error caption is present in the wallet
  /// header within `timeout` seconds. Fails with an actionable message if
  /// the element does not appear — indicating either the header is absent,
  /// `errorCaption` is `nil`, or `hasCredential` evaluated to `false`
  /// (which causes the missing-credential hint to render in its place;
  /// seed an Alchemy credential via the `walletHeaderSyncError` seed
  /// infrastructure to keep this element stable).
  func expectErrorCaptionVisible(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let element = app.element(for: UITestIdentifiers.WalletAccountHeader.errorCaption)
    if !element.waitForExistence(timeout: timeout) {
      Trace.recordFailure("errorCaption element did not appear within \(timeout)s")
      XCTFail(
        "Error caption did not appear within \(timeout)s after opening a synced account with "
          + "a seeded sync error. "
          + "Check that SyncedAccountHeaderView renders errorCaptionView for a crypto account "
          + "whose wallet_sync_state has a non-nil lastErrorJson and whose hasCredential "
          + "evaluates to true (the .walletHeaderSyncError seed injects an Alchemy key via "
          + "launchEnvironment so the .task result is true).")
    }
  }
}
