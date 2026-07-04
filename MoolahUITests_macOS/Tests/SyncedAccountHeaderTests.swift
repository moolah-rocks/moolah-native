import XCTest

/// UI-level smoke test for `SyncedAccountHeaderView`.
///
/// Verifies that the wallet-header caption element retains its
/// `WalletAccountHeader.errorCaption` accessibility identifier after the
/// inline-layout change (Task 2). The test seeds a crypto account with a
/// pre-existing sync error so that `errorCaption` is non-nil at first
/// paint — no sync cycle runs during the test.
///
/// The `.walletHeaderSyncError` seed seeds:
///   - a CloudKit-backed AUD profile with one Ethereum wallet account
///     (`chainId = 1`, `walletAddress` set to a deterministic hex string)
///   - a `wallet_sync_state` row with `lastErrorJson` set to a
///     `WalletSyncError.network` payload so
///     `SyncedAccountHeaderView.errorCaption` is non-nil on first render.
///   - a test-local (non-iCloud-synced) Alchemy key override via
///     `UITestSeedCryptoOverrides.alchemyKeyStore(for:)` so
///     `SyncedAccountHeaderLogic.hasCredential` evaluates to `true` after
///     the view's `.task` fires — preventing the missing-credential hint
///     from replacing the error caption.
@MainActor
final class SyncedAccountHeaderTests: MoolahUITestCase {
  /// Opens the seeded synced-account detail and asserts that the error
  /// caption element is present in the header, proving the inline-layout
  /// change preserved the caption's accessibility identifier and that the
  /// element is reachable from a UI test.
  func testErrorCaptionIsPresentOnSyncErrorAccount() throws {
    let app = launch(seed: .walletHeaderSyncError)
    app.sidebar.switchToAccount(.walletWithSyncError)
    app.syncedAccountHeader.expectErrorCaptionVisible()
  }
}
