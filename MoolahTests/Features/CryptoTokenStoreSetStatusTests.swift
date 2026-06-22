// MoolahTests/Features/CryptoTokenStoreSetStatusTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for `CryptoTokenStore.setStatus(_:for:)`. The method must:
///
/// 1. Persist the new `pricingStatus` through the registry repository so
///    the change survives restart and propagates through CKSyncEngine.
/// 2. Synchronously invalidate the conversion-service cache for the
///    affected instrument so the next aggregation reads fresh data.
/// 3. Refresh the local in-memory `registrations` list so observers see
///    the update without an explicit `loadRegistrations()` call.
///
/// The registry is exercised through a real
/// `GRDBInstrumentRegistryRepository` (in-memory SQLite) per the
/// project's "test against a real repository" convention. The
/// conversion service is the only piece mocked here — it sits at the
/// `BackendProvider` boundary and a stub is the cleanest way to assert
/// invocation order.
@Suite("CryptoTokenStore.setStatus")
@MainActor
struct CryptoTokenStoreSetStatusTests {
  // MARK: - Fixture

  /// Bundle returned from `makeStore` so tests can reach the registry
  /// (for direct read-back of persisted values) and the recording
  /// conversion service (for invalidation assertions) alongside the
  /// store under test.
  private struct Fixture {
    let store: CryptoTokenStore
    let registry: GRDBInstrumentRegistryRepository
    let conversionService: FakeConversionService
  }

  /// Builds a fresh store backed by an in-memory GRDB database with
  /// `count` built-in presets registered so the store has rows to mutate.
  private func makeStore(presetCount: Int = 1) async throws -> Fixture {
    // Registry + price cache live on the profile-index DB.
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    for preset in CryptoRegistration.builtInPresets.prefix(presetCount) {
      try await registry.registerCrypto(preset.instrument, mapping: preset.mapping)
    }
    let priceService = CryptoPriceService(
      clients: [FixedCryptoPriceClient()], database: database)
    let conversionService = FakeConversionService.passthrough
    let store = CryptoTokenStore(
      registry: registry,
      cryptoPriceService: priceService,
      conversionService: conversionService)
    await store.loadRegistrations()
    return Fixture(
      store: store, registry: registry, conversionService: conversionService)
  }

  // MARK: - Persistence

  @Test("setStatus(.spam) is persisted by the registry")
  func setStatusPersistsThroughRegistry() async throws {
    let fixture = try await makeStore()
    let registration = try #require(fixture.store.registrations.first)

    await fixture.store.setStatus(.spam, for: registration)

    let reloaded = try await fixture.registry.allCryptoRegistrations()
    let updated = try #require(reloaded.first { $0.id == registration.id })
    #expect(updated.pricingStatus == .spam)
  }

  @Test("setStatus refreshes the store's in-memory registrations list")
  func setStatusRefreshesInMemoryList() async throws {
    let fixture = try await makeStore()
    let registration = try #require(fixture.store.registrations.first)

    await fixture.store.setStatus(.spam, for: registration)

    let updated = try #require(
      fixture.store.registrations.first { $0.id == registration.id })
    #expect(updated.pricingStatus == .spam)
  }

  // MARK: - Cache invalidation

  @Test("setStatus invalidates the conversion cache exactly once")
  func setStatusInvalidatesCacheExactlyOnce() async throws {
    let fixture = try await makeStore()
    let registration = try #require(fixture.store.registrations.first)

    await fixture.store.setStatus(.spam, for: registration)

    #expect(fixture.conversionService.invalidatedInstruments.count == 1)
    let firstInvalidated =
      try #require(fixture.conversionService.invalidatedInstruments.first)
    #expect(firstInvalidated.id == registration.instrument.id)
  }

  @Test("Setting the same status twice still invalidates the cache twice")
  func setStatusInvalidatesEvenWhenStatusUnchanged() async throws {
    let fixture = try await makeStore()
    let registration = try #require(fixture.store.registrations.first)

    await fixture.store.setStatus(.spam, for: registration)
    await fixture.store.setStatus(.spam, for: registration)

    // No premature dedup at the store layer — the design relies on the
    // conversion service to be cheaply idempotent rather than the caller.
    #expect(fixture.conversionService.invalidatedInstruments.count == 2)
    #expect(
      fixture.conversionService.invalidatedInstruments.allSatisfy {
        $0.id == registration.instrument.id
      })
  }

  @Test("setStatus only invalidates the supplied instrument, not unrelated ones")
  func setStatusOnlyInvalidatesSuppliedInstrument() async throws {
    let fixture = try await makeStore(presetCount: 2)
    let target = try #require(fixture.store.registrations.first)
    let other = try #require(fixture.store.registrations.last)
    #expect(target.id != other.id)

    await fixture.store.setStatus(.spam, for: target)

    #expect(
      fixture.conversionService.invalidatedInstruments.allSatisfy {
        $0.id == target.instrument.id
      })
  }

  // MARK: - Round-trips through the full enum

  @Test("setStatus accepts every TokenPricingStatus case")
  func setStatusRoundTripsAllCases() async throws {
    let fixture = try await makeStore()
    let registration = try #require(fixture.store.registrations.first)

    for status in TokenPricingStatus.allCases {
      await fixture.store.setStatus(status, for: registration)
      let reloaded = try await fixture.registry.allCryptoRegistrations()
      let updated = try #require(reloaded.first { $0.id == registration.id })
      #expect(updated.pricingStatus == status)
    }
  }
}
