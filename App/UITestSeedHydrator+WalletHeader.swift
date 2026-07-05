import Foundation
import GRDB

// Wallet-header sync-error seed helpers for `UITestSeedHydrator`.
//
// Seeds a CloudKit-backed AUD profile with one Ethereum crypto wallet
// account whose `wallet_sync_state` row carries a `network` error. The
// header renders `SyncedAccountHeaderView.errorCaption` at first paint
// without any sync cycle running — no Alchemy key is required.
//
// Split into its own file (mirroring the `+GroupFilterScope` /
// `+TransferDetection` split) so the core `UITestSeedHydrator` enum body
// stays under SwiftLint's `type_body_length` threshold.
extension UITestSeedHydrator {
  static func hydrateWalletHeaderSyncError(
    into manager: ProfileContainerManager
  ) throws -> Profile {
    let fixtures = UITestFixtures.WalletHeaderSyncError.self

    let profile = Profile(
      id: fixtures.profileId,
      label: fixtures.profileLabel,
      currencyCode: fixtures.profileCurrencyCode,
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try upsertProfile(profile, into: manager)

    let database = try manager.database(for: profile.id)
    let instrument = profile.instrument

    // Instrument identity lives on the shared profile-index registry.
    // Register the profile denomination before any leg fans a domain
    // `Instrument` out of it.
    try manager.profileIndexDatabase.write { indexDatabase in
      try upsertInstrument(instrument, in: indexDatabase)
    }

    try database.write { profileDatabase in
      try upsertAccount(
        AccountSpec(
          id: fixtures.walletAccountId,
          name: fixtures.walletAccountName,
          type: .crypto,
          instrumentId: instrument.id,
          position: 0,
          valuationMode: .calculatedFromTrades,
          walletAddress: fixtures.walletAddress,
          chainId: fixtures.walletChainId),
        in: profileDatabase)
      // Seed a network error so `SyncedAccountHeaderLogic.errorCaption`
      // returns a non-nil string at first paint — no sync cycle runs.
      let errorJson = walletSyncErrorJson()
      try upsertWalletSyncState(
        accountId: fixtures.walletAccountId,
        lastErrorJson: errorJson,
        in: profileDatabase)
    }

    return profile
  }

  /// Produces a JSON-encoded `WalletSyncError.network` payload suitable
  /// for the `wallet_sync_state.last_error_json` column. Uses the new
  /// attribution format so the decoder takes the `.kind`-keyed path.
  ///
  /// SAFETY: synchronous JSON encoding of a small Codable value; never
  /// produces invalid UTF-8 per `JSONEncoder` contract.
  private static func walletSyncErrorJson() -> String {
    let error = WalletSyncError.network(
      underlyingDescription: "UI test seeded error")
    guard
      let data = try? JSONEncoder().encode(error),
      let json = String(bytes: data, encoding: .utf8)
    else {
      fatalError("walletSyncErrorJson: failed to encode WalletSyncError")
    }
    return json
  }
}
