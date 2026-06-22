import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for the CryptoCompare API key UI surface on `CryptoTokenStore`.
/// The store wraps a `KeychainStore` keyed on
/// (`com.moolah.api-keys`, `cryptocompare`) — the same entry the price
/// client reads on the fetch side, so a write here must round-trip
/// through the keychain to be picked up by the next price request.
///
/// Production uses the iCloud-synced keychain
/// (`synchronizable: true`), but the macOS test runner cannot write to
/// it (the runner isn't part of an iCloud-signed-in user session). We
/// inject a per-test, non-synchronisable `KeychainStore` instance via
/// the store's test seam initialiser. Each test uses a unique service
/// id (`UUID()` in the prefix) so concurrent test runs cannot collide
/// on the same keychain row, mirroring `KeychainStoreTests`.
@Suite("CryptoTokenStore — CryptoCompare API key")
@MainActor
struct CryptoSettingsCryptoCompareKeyTests {
  private struct Fixture {
    let store: CryptoTokenStore
    let cryptocompareKeychain: KeychainStore
    let coingeckoKeychain: KeychainStore
  }

  /// Builds a store whose CryptoCompare + CoinGecko keychain entries are
  /// non-synchronisable and namespaced under per-test unique service
  /// ids. Returns the keychain handles too so tests can read the raw
  /// entry to confirm round-trips.
  private func makeFixture() throws -> Fixture {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let priceService = CryptoPriceService(
      clients: [FixedCryptoPriceClient()], database: database)
    let alchemyService = "com.moolah.test.alchemy.\(UUID().uuidString)"
    let coingeckoService = "com.moolah.test.coingecko.\(UUID().uuidString)"
    let cryptocompareService = "com.moolah.test.cryptocompare.\(UUID().uuidString)"
    let alchemyKeychain = KeychainStore(
      service: alchemyService, account: "alchemy", synchronizable: false)
    let coingeckoKeychain = KeychainStore(
      service: coingeckoService, account: "coingecko", synchronizable: false)
    let cryptocompareKeychain = KeychainStore(
      service: cryptocompareService, account: "cryptocompare", synchronizable: false)
    let store = CryptoTokenStore(
      registry: registry,
      cryptoPriceService: priceService,
      conversionService: FakeConversionService.passthrough,
      apiKeyStore: coingeckoKeychain,
      alchemyKeyStore: alchemyKeychain,
      cryptocompareKeyStore: cryptocompareKeychain)
    return Fixture(
      store: store,
      cryptocompareKeychain: cryptocompareKeychain,
      coingeckoKeychain: coingeckoKeychain)
  }

  // MARK: - Save / read round-trip

  @Test("saveCryptoCompareApiKey persists through KeychainStore")
  func saveCryptoCompareApiKeyPersists() throws {
    let fixture = try makeFixture()
    defer { fixture.cryptocompareKeychain.clear() }

    fixture.store.saveCryptoCompareApiKey("cc_test_round_trip_abc")

    #expect(fixture.store.hasCryptoCompareApiKey == true)
    let restored = try fixture.cryptocompareKeychain.restoreString()
    #expect(restored == "cc_test_round_trip_abc")
  }

  @Test("hasCryptoCompareApiKey is false on a fresh keychain entry")
  func hasCryptoCompareApiKeyIsFalseWhenEmpty() throws {
    let fixture = try makeFixture()
    #expect(fixture.store.hasCryptoCompareApiKey == false)
  }

  @Test("clearCryptoCompareApiKey removes the keychain entry")
  func clearCryptoCompareApiKeyRemovesEntry() throws {
    let fixture = try makeFixture()
    fixture.store.saveCryptoCompareApiKey("cc_test_clear_me")
    fixture.store.clearCryptoCompareApiKey()
    #expect(fixture.store.hasCryptoCompareApiKey == false)
  }

  // MARK: - Trimming

  @Test("saveCryptoCompareApiKey trims surrounding whitespace before persisting")
  func saveCryptoCompareApiKeyTrimsWhitespace() throws {
    let fixture = try makeFixture()
    defer { fixture.cryptocompareKeychain.clear() }

    fixture.store.saveCryptoCompareApiKey("  k  ")

    #expect(fixture.store.hasCryptoCompareApiKey == true)
    #expect(try fixture.cryptocompareKeychain.restoreString() == "k")
  }

  @Test("saveCryptoCompareApiKey ignores an all-whitespace key")
  func saveCryptoCompareApiKeyIgnoresBlank() throws {
    let fixture = try makeFixture()
    defer { fixture.cryptocompareKeychain.clear() }

    fixture.store.saveCryptoCompareApiKey("   ")

    #expect(fixture.store.hasCryptoCompareApiKey == false)
    #expect(try fixture.cryptocompareKeychain.restoreString() == nil)
  }

  // MARK: - Service / account isolation

  @Test("saveCryptoCompareApiKey writes to the cryptocompare keychain, not coingecko")
  func saveCryptoCompareApiKeyTargetsCryptoCompareAccount() throws {
    let fixture = try makeFixture()
    defer {
      fixture.cryptocompareKeychain.clear()
      fixture.coingeckoKeychain.clear()
    }

    fixture.store.saveCryptoCompareApiKey("cc_isolation_test_xyz")

    #expect(try fixture.cryptocompareKeychain.restoreString() == "cc_isolation_test_xyz")
    // The write must not spill into the CoinGecko slot. With per-test
    // unique service ids this is guaranteed by construction; the
    // assertion documents the contract for future readers.
    #expect(try fixture.coingeckoKeychain.restoreString() == nil)
  }

  // MARK: - Privacy

  @Test("saveCryptoCompareApiKey does not surface the key in store.error on success")
  func saveCryptoCompareApiKeyNeverLogsKeyOnSuccess() throws {
    let fixture = try makeFixture()
    defer { fixture.cryptocompareKeychain.clear() }

    let secret = "cc_privacy_canary_should_not_appear"
    fixture.store.saveCryptoCompareApiKey(secret)

    #expect(fixture.store.error?.contains(secret) != true)
  }
}
