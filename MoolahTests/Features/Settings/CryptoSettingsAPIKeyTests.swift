// MoolahTests/Features/Settings/CryptoSettingsAPIKeyTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for the Alchemy API key UI surface on `CryptoTokenStore`.
/// The store wraps a `KeychainStore` keyed on
/// (`com.moolah.api-keys`, `alchemy`) — the same entry
/// `ProfileSession.resolveAlchemyApiKey()` reads on the sync side, so
/// a write here must round-trip through the keychain to be picked up
/// by the next sync cycle.
///
/// Production uses the iCloud-synced keychain
/// (`synchronizable: true`), but the macOS test runner cannot write to
/// it (the runner isn't part of an iCloud-signed-in user session). We
/// inject a per-test, non-synchronisable `KeychainStore` instance via
/// the store's test seam initialiser. Each test uses a unique service
/// id (`UUID()` in the prefix) so concurrent test runs cannot collide
/// on the same keychain row, mirroring `KeychainStoreTests`.
///
/// We still cover the "production wires the iCloud-synced keychain at
/// the canonical service / account" claim via a separate test that
/// inspects the production initialiser's plumbing without depending on
/// a successful save.
@Suite("CryptoTokenStore — Alchemy API key")
@MainActor
struct CryptoSettingsAPIKeyTests {
  private struct Fixture {
    let store: CryptoTokenStore
    let alchemyKeychain: KeychainStore
    let coingeckoKeychain: KeychainStore
  }

  /// Builds a store whose Alchemy + CoinGecko keychain entries are
  /// non-synchronisable and namespaced under per-test unique service
  /// ids. Returns the keychain handles too so tests can read the raw
  /// entry to confirm round-trips.
  private func makeFixture() throws -> Fixture {
    // Registry + price cache live on the profile-index DB.
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
      conversionService: RecordingConversionService(),
      apiKeyStore: coingeckoKeychain,
      alchemyKeyStore: alchemyKeychain,
      cryptocompareKeyStore: cryptocompareKeychain)
    return Fixture(
      store: store,
      alchemyKeychain: alchemyKeychain,
      coingeckoKeychain: coingeckoKeychain)
  }

  // MARK: - Save / read round-trip

  @Test("saveAlchemyApiKey persists through KeychainStore")
  func saveAlchemyApiKeyPersists() throws {
    let fixture = try makeFixture()
    defer { fixture.alchemyKeychain.clear() }

    fixture.store.saveAlchemyApiKey("alch_test_round_trip_abc")

    #expect(fixture.store.hasAlchemyApiKey == true)
    let restored = try fixture.alchemyKeychain.restoreString()
    #expect(restored == "alch_test_round_trip_abc")
  }

  @Test("hasAlchemyApiKey is false on a fresh keychain entry")
  func hasAlchemyApiKeyIsFalseWhenEmpty() throws {
    let fixture = try makeFixture()
    #expect(fixture.store.hasAlchemyApiKey == false)
  }

  @Test("clearAlchemyApiKey removes the keychain entry")
  func clearAlchemyApiKeyRemovesEntry() throws {
    let fixture = try makeFixture()
    fixture.store.saveAlchemyApiKey("alch_test_clear_me")
    fixture.store.clearAlchemyApiKey()
    #expect(fixture.store.hasAlchemyApiKey == false)
  }

  // MARK: - Trimming

  @Test("saveAlchemyApiKey trims surrounding whitespace before persisting")
  func saveAlchemyApiKeyTrimsWhitespace() throws {
    let fixture = try makeFixture()
    defer { fixture.alchemyKeychain.clear() }

    fixture.store.saveAlchemyApiKey("  k  ")

    #expect(fixture.store.hasAlchemyApiKey == true)
    #expect(try fixture.alchemyKeychain.restoreString() == "k")
  }

  @Test("saveAlchemyApiKey ignores an all-whitespace key")
  func saveAlchemyApiKeyIgnoresBlank() throws {
    let fixture = try makeFixture()
    defer { fixture.alchemyKeychain.clear() }

    fixture.store.saveAlchemyApiKey("   ")

    #expect(fixture.store.hasAlchemyApiKey == false)
    #expect(try fixture.alchemyKeychain.restoreString() == nil)
  }

  // MARK: - Service / account isolation

  @Test("saveAlchemyApiKey writes to the alchemy keychain, not coingecko")
  func saveAlchemyApiKeyTargetsAlchemyAccount() throws {
    let fixture = try makeFixture()
    defer {
      fixture.alchemyKeychain.clear()
      fixture.coingeckoKeychain.clear()
    }

    fixture.store.saveAlchemyApiKey("alch_isolation_test_xyz")

    #expect(try fixture.alchemyKeychain.restoreString() == "alch_isolation_test_xyz")
    // The write must not spill into the CoinGecko slot. With per-test
    // unique service ids this is guaranteed by construction; the
    // assertion documents the contract for future readers.
    #expect(try fixture.coingeckoKeychain.restoreString() == nil)
  }

  // MARK: - Privacy

  @Test("saveAlchemyApiKey does not surface the key in store.error on success")
  func saveAlchemyApiKeyNeverLogsKeyOnSuccess() throws {
    let fixture = try makeFixture()
    defer { fixture.alchemyKeychain.clear() }

    let secret = "alch_privacy_canary_should_not_appear"
    fixture.store.saveAlchemyApiKey(secret)

    // The store's `error` should not contain the secret value on
    // either path. (On success it's nil; we still check just in case
    // a future refactor sets an info string with the key inside.)
    #expect(fixture.store.error?.contains(secret) != true)
  }
}
