// MoolahTests/App/UnifiedIdentityMigrationTestSupport.swift

import Foundation
import GRDB

@testable import Moolah

/// Namespace marker (required by CODE_GUIDE §5 file_name rule).
enum UnifiedIdentityMigrationTestSupport {}

// MARK: - MigrationTestHarness

/// Minimal in-memory harness for `UnifiedInstrumentIdentityMigration` mapping
/// tests. Wires a real `GRDBInstrumentRegistryRepository` +
/// `CanonicalInstrumentResolver` over an in-memory profile-index DB.
/// Per-profile dependencies (`dataDatabaseProvider`, `allProfileIds`, `rePush`)
/// are no-op stubs — Task 1 tests cover mapping derivation only.
@MainActor
struct MigrationTestHarness {
  let registry: GRDBInstrumentRegistryRepository
  let resolver: CanonicalInstrumentResolver
  let migration: UnifiedInstrumentIdentityMigration

  static func make() throws -> MigrationTestHarness {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let resolver = CanonicalInstrumentResolver()
    let suiteName = "test-migration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    let migration = UnifiedInstrumentIdentityMigration(
      profileIndexDatabase: database,
      dataDatabaseProvider: { _ in try ProfileDatabase.openInMemory() },
      allProfileIds: { [] },
      registry: registry,
      resolver: resolver,
      rePush: { _ in },
      userDefaults: defaults)
    return MigrationTestHarness(registry: registry, resolver: resolver, migration: migration)
  }

  /// Seeds the shared registry with `registrations`, writing each via the
  /// normal `registerCrypto` path. Retired rows (with a provider mapping but
  /// a chain-scoped id that resolves to a different canonical id) are
  /// acceptable; `alias_of` is written separately by Task 2.
  func seedSharedRegistry(_ registrations: [CryptoRegistration]) async throws {
    for registration in registrations {
      try await registry.registerCrypto(registration.instrument, mapping: registration.mapping)
    }
  }
}

// MARK: - CryptoRegistration test fixtures

extension CryptoRegistration {
  /// ETH on Ethereum mainnet — canonical (`1:native`).
  static let ethMainnet = CryptoRegistration(
    instrument: .crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    mapping: CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"))

  /// ETH on Optimism — retired cross-chain id (`10:native`).
  static let ethOptimism = CryptoRegistration(
    instrument: .crypto(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    mapping: CryptoProviderMapping(
      instrumentId: "10:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"))

  /// ETH on Base — retired cross-chain id (`8453:native`).
  static let ethBase = CryptoRegistration(
    instrument: .crypto(
      chainId: 8453, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    mapping: CryptoProviderMapping(
      instrumentId: "8453:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"))

  /// USDC on Ethereum mainnet — canonical.
  static let usdcMainnet = CryptoRegistration(
    instrument: .crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC", name: "USD Coin", decimals: 6),
    mapping: CryptoProviderMapping(
      instrumentId: "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      coingeckoId: "usd-coin", cryptocompareSymbol: "USDC", binanceSymbol: "USDCUSDT"))

  /// USDC on Optimism — retired cross-chain id.
  static let usdcOptimism = CryptoRegistration(
    instrument: .crypto(
      chainId: 10,
      contractAddress: "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      symbol: "USDC", name: "USD Coin", decimals: 6),
    mapping: CryptoProviderMapping(
      instrumentId: "10:0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      coingeckoId: "usd-coin", cryptocompareSymbol: "USDC", binanceSymbol: "USDCUSDT"))

  /// A token with no provider mapping — stays chain-scoped; forms a
  /// singleton `assetKey` group so it is never aliased.
  static func noKeyToken(chainId: Int, address: String) -> CryptoRegistration {
    CryptoRegistration(
      instrument: .crypto(
        chainId: chainId, contractAddress: address,
        symbol: "UNK", name: "Unknown Token", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "\(chainId):\(address.lowercased())",
        coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil))
  }
}
