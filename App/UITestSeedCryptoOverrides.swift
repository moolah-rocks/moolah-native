import Foundation

/// UI-testing-only overrides for the CoinGecko catalogue and the token
/// resolution client. Consulted from `ProfileSession.makeRegistryWiring`
/// when the process was launched with `--ui-testing` and the active
/// `UITestSeed` requests a deterministic catalogue/resolver instead of
/// the live SQLite-backed snapshot and network resolver.
///
/// The live `SQLiteCoinGeckoCatalog` reads from disk and `refreshIfStale()`
/// can hit the CoinGecko API; `CompositeTokenResolutionClient` always hits
/// the network. Neither is acceptable in a UI test, so seeds that exercise
/// the picker substitute the pair below for a fixed, in-memory snapshot.
///
/// The concrete fakes live in their own files (one primary type per file):
///   - `PreloadedCryptoCatalog.swift`
///   - `PreloadedTokenResolutionClient.swift`
@MainActor
enum UITestSeedCryptoOverrides {
  /// Returns the catalogue/resolver pair to use under UI testing for the
  /// given seed, or `nil` to fall through to the production wiring. Any
  /// seed not listed here uses the live wiring (so for example
  /// `tradeBaseline` keeps the SQLite snapshot — the trade tests don't
  /// exercise crypto search).
  static func overrides(
    for seed: UITestSeed
  ) -> (catalog: any CoinGeckoCatalog, resolutionClient: any TokenResolutionClient)? {
    switch seed {
    case .cryptoCatalogPreloaded:
      return (
        catalog: PreloadedCryptoCatalog.cryptoCatalogPreloaded,
        resolutionClient: PreloadedTokenResolutionClient.cryptoCatalogPreloaded
      )
    case .tradeBaseline,
      .welcomeEmpty,
      .welcomeSingleCloudProfile,
      .welcomeMultipleCloudProfiles,
      .welcomeDownloading,
      .sidebarFooterUpToDate,
      .sidebarFooterReceiving,
      .sidebarFooterSending,
      .tradeReady,
      .incompatibleProfile,
      .transferDetectionBaseline,
      .pendingWebImportOneChaseInbox,
      .insightsForYouBaseline,
      .weeklyRecapBaseline:
      return nil
    }
  }
}
