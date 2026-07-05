import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for the CoinGecko API key UI surface on `CryptoTokenStore`.
/// The store wraps a `KeychainStore` keyed on
/// (`com.moolah.api-keys`, `coingecko`) — the same entry
/// `ProfileSession.resolveCoinGeckoApiKey()` reads on the price /
/// resolution side, so a write here must round-trip through the
/// keychain to be picked up by the next fetch.
///
/// Production uses the iCloud-synced keychain
/// (`synchronizable: true`), but the macOS test runner cannot write to
/// it (the runner isn't part of an iCloud-signed-in user session). We
/// inject a per-test, non-synchronisable `KeychainStore` instance via
/// the store's test seam initialiser. Each test uses a unique service
/// id (`UUID()` in the prefix) so concurrent test runs cannot collide
/// on the same keychain row, mirroring `KeychainStoreTests`.
@Suite("CryptoTokenStore — CoinGecko API key")
@MainActor
struct CryptoSettingsCoinGeckoKeyTests {
  private struct Fixture {
    let store: CryptoTokenStore
    let coingeckoKeychain: KeychainStore
  }

  /// Builds a store whose CoinGecko keychain entry is non-synchronisable
  /// and namespaced under a per-test unique service id. Returns the
  /// keychain handle too so tests can read the raw entry to confirm
  /// round-trips.
  private func makeFixture() throws -> Fixture {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let priceService = CryptoPriceService(
      clients: [FixedCryptoPriceClient()], database: database)
    let alchemyService = "com.moolah.test.alchemy.\(UUID().uuidString)"
    let coingeckoService = "com.moolah.test.coingecko.\(UUID().uuidString)"
    let alchemyKeychain = KeychainStore(
      service: alchemyService, account: "alchemy", synchronizable: false)
    let coingeckoKeychain = KeychainStore(
      service: coingeckoService, account: "coingecko", synchronizable: false)
    let store = CryptoTokenStore(
      registry: registry,
      cryptoPriceService: priceService,
      conversionService: FakeConversionService.passthrough,
      apiKeyStore: coingeckoKeychain,
      alchemyKeyStore: alchemyKeychain)
    return Fixture(store: store, coingeckoKeychain: coingeckoKeychain)
  }

  // MARK: - Save / read round-trip

  @Test("saveCoinGeckoApiKey persists through KeychainStore")
  func saveCoinGeckoApiKeyPersists() throws {
    let fixture = try makeFixture()
    defer { fixture.coingeckoKeychain.clear() }

    fixture.store.saveCoinGeckoApiKey("cg_test_round_trip_abc")

    #expect(fixture.store.hasCoinGeckoApiKey == true)
    let restored = try fixture.coingeckoKeychain.restoreString()
    #expect(restored == "cg_test_round_trip_abc")
  }

  @Test("hasCoinGeckoApiKey is false on a fresh keychain entry")
  func hasCoinGeckoApiKeyIsFalseWhenEmpty() throws {
    let fixture = try makeFixture()
    #expect(fixture.store.hasCoinGeckoApiKey == false)
  }

  @Test("clearCoinGeckoApiKey removes the keychain entry")
  func clearCoinGeckoApiKeyRemovesEntry() throws {
    let fixture = try makeFixture()
    fixture.store.saveCoinGeckoApiKey("cg_test_clear_me")
    fixture.store.clearCoinGeckoApiKey()
    #expect(fixture.store.hasCoinGeckoApiKey == false)
  }

  // MARK: - Trimming

  @Test("saveCoinGeckoApiKey trims surrounding whitespace before persisting")
  func saveCoinGeckoApiKeyTrimsWhitespace() throws {
    let fixture = try makeFixture()
    defer { fixture.coingeckoKeychain.clear() }

    fixture.store.saveCoinGeckoApiKey("  k  ")

    #expect(fixture.store.hasCoinGeckoApiKey == true)
    #expect(try fixture.coingeckoKeychain.restoreString() == "k")
  }

  @Test("saveCoinGeckoApiKey ignores an all-whitespace key")
  func saveCoinGeckoApiKeyIgnoresBlank() throws {
    let fixture = try makeFixture()
    defer { fixture.coingeckoKeychain.clear() }

    fixture.store.saveCoinGeckoApiKey("   ")

    #expect(fixture.store.hasCoinGeckoApiKey == false)
    #expect(try fixture.coingeckoKeychain.restoreString() == nil)
  }
}
