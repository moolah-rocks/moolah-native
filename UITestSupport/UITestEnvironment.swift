import Foundation

/// Environment-variable names the app and UI-test target both read.
///
/// Compiled into both targets so the launch wiring (`MoolahApp.launch`)
/// and the consumers (e.g. the fallback inbox in `MoolahApp+Setup`) cannot
/// disagree on the key.
///
/// Split out of `UITestFixtures.swift` into its own file — a coherent,
/// independently-named top-level type, not an arbitrary line-count split.
public enum UITestEnvironment {
  /// Directory the app's `PendingImportsBannerFallback` inbox is rooted
  /// at when `InboxWriter.shared()` is unavailable (the `--ui-testing`
  /// case). Both the seed hydrator (which writes the fixture payload)
  /// and the app's launch wiring (which constructs the `InboxWriter`)
  /// read this value, so the seed's writes and the banner's reads land
  /// on the same on-disk directory.
  public static let inboxDirectory = "MOOLAH_UI_TEST_INBOX_DIR"

  /// Set to `"1"` when the app under test should treat an Alchemy API key
  /// as present (`CryptoTokenStore.hasAlchemyApiKey == true`), without
  /// writing to the system keychain. Used by seeds that need
  /// `SyncedAccountHeaderLogic.hasCredential` to evaluate to `true` for
  /// a crypto account while avoiding `SecItemAdd` calls that can hang or
  /// fail in headless CI environments (interactive keychain authorization
  /// not available).
  public static let alchemyKeyPresent = "MOOLAH_UI_TEST_ALCHEMY_KEY_PRESENT"

  /// Set to `"1"` when `CryptoTokenStore.probeEndpoints()` should treat
  /// every configured custom RPC endpoint as reachable on chain 1
  /// (Ethereum) instead of issuing a live `eth_chainId` JSON-RPC call.
  /// Used by the "Custom RPC Endpoints" Settings section UI test so
  /// adding an arbitrary endpoint URL deterministically resolves to a
  /// green "Ethereum" status badge without any network access — mirrors
  /// `alchemyKeyPresent`'s env-var-instead-of-real-I/O approach.
  public static let rpcProbeStubbedReachable = "MOOLAH_UI_TEST_RPC_PROBE_REACHABLE"
}
