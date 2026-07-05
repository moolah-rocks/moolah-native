// MoolahTests/Sync/ApplyPathSharedRegistryResolutionTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the contract that the sync apply-path repository bundle resolves
/// and registers instruments against the SHARED profile-index registry,
/// not the per-profile `instrument` table.
///
/// Every `InstrumentRecord` apply lands on the profile-index zone
/// (`ProfileIndexSyncHandler` + the shared registry); the per-profile
/// `ProfileDataSyncHandler` traps/skips them. The
/// `instrumentResolver` / `instrumentRegistrar` injected into the
/// txn/account/earmark/investment repos by `makeForApply` are the
/// shared registry. The apply path never invokes them (it writes raw
/// Rows via `applyRemoteChangesSync`), and there is no per-profile
/// `instrument` table, so any apply-time instrument resolution lands
/// against the profile-index DB — the per-profile table is
/// structurally unreachable.
@MainActor
@Suite("Apply-path bundle resolves via the shared registry")
struct ApplyPathSharedRegistryResolutionTests {

  @Test(
    "makeForApply resolver reads instruments from the shared registry, not the per-profile table")
  func resolverUsesSharedRegistry() async throws {
    // Two distinct databases: the per-profile DB (which has no
    // `instrument` table) and the shared profile-index DB.
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedDB = try ProfileIndexDatabase.openInMemory()
    let sharedRegistry = GRDBInstrumentRegistryRepository(database: sharedDB)

    // A crypto instrument that exists ONLY in the shared registry.
    let crypto = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6)
    try await sharedRegistry.registerCrypto(
      crypto,
      mapping: CryptoProviderMapping(
        instrumentId: crypto.id,
        coingeckoId: "usd-coin",
        binanceSymbol: nil))

    let bundle = ProfileGRDBRepositories.makeForApply(
      database: perProfile, sharedRegistry: sharedRegistry)

    // All four repos resolve the crypto instrument because their injected
    // resolver is the shared registry, not the per-profile shim.
    let txnMap = try await bundle.transactions.instrumentResolver.instrumentMap()
    let accountMap = try await bundle.accounts.instrumentResolver.instrumentMap()
    let earmarkMap = try await bundle.earmarks.instrumentResolver.instrumentMap()
    let investmentMap =
      try await bundle.investmentValues.instrumentResolver.instrumentMap()
    #expect(txnMap[crypto.id]?.kind == .cryptoToken)
    #expect(accountMap[crypto.id]?.kind == .cryptoToken)
    #expect(earmarkMap[crypto.id]?.kind == .cryptoToken)
    #expect(investmentMap[crypto.id]?.kind == .cryptoToken)

    // The per-profile `instrument` table does not exist — resolution
    // through it is structurally impossible, a strictly stronger
    // guarantee than "the table is empty".
    let perProfileTableExists = try await perProfile.read { database in
      try Bool.fetchOne(
        database,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM sqlite_master WHERE type='table' AND name='instrument')
          """) ?? true
    }
    #expect(perProfileTableExists == false)
  }

  @Test("apply bundle never resolves through the per-profile instrument table")
  func applyBundleIgnoresPerProfileInstrumentTable() async throws {
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedRegistry = try SharedRegistryTestSupport.makeSharedRegistry()
    let bundle = ProfileGRDBRepositories.makeForApply(
      database: perProfile, sharedRegistry: sharedRegistry)

    // The per-profile `instrument` table does not exist, so it is
    // structurally impossible for the bundle's resolver to fall back to
    // a per-profile crypto row.
    let perProfileTableExists = try await perProfile.read { database in
      try Bool.fetchOne(
        database,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM sqlite_master WHERE type='table' AND name='instrument')
          """) ?? true
    }
    #expect(perProfileTableExists == false)

    // A crypto id present in neither the per-profile DB nor the shared
    // registry resolves to nothing — resolution is shared-only.
    let map = try await bundle.transactions.instrumentResolver.instrumentMap()
    #expect(
      map["1:native"] == nil,
      "the apply bundle must not resolve crypto from any per-profile table")
  }
}
