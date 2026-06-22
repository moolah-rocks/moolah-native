// MoolahTests/Features/CryptoTokenStoreSpamInstrumentsTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoTokenStore.spamInstruments")
@MainActor
struct CryptoTokenStoreSpamInstrumentsTests {
  private struct Fixture {
    let store: CryptoTokenStore
  }

  /// Builds a fresh store backed by an in-memory GRDB database with
  /// `presetCount` built-in presets registered so the store has rows to
  /// flip to `.spam` and assert membership of `spamInstruments`.
  private func makeStore(presetCount: Int = 2) async throws -> Fixture {
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
    return Fixture(store: store)
  }

  @Test("includes only registrations with .spam status")
  func includesOnlySpam() async throws {
    let fixture = try await makeStore(presetCount: 1)
    let toMarkSpam = try #require(fixture.store.registrations.first)

    await fixture.store.setStatus(.spam, for: toMarkSpam)

    #expect(fixture.store.spamInstruments == [toMarkSpam.instrument])
  }

  @Test("empty when no registrations are .spam")
  func emptyWhenNoneSpam() async throws {
    let fixture = try await makeStore(presetCount: 1)
    #expect(fixture.store.spamInstruments.isEmpty)
  }

  @Test("two spam registrations both appear")
  func bothSpamPresent() async throws {
    let fixture = try await makeStore()
    let registrations = fixture.store.registrations
    try #require(registrations.count >= 2)

    await fixture.store.setStatus(.spam, for: registrations[0])
    await fixture.store.setStatus(.spam, for: registrations[1])

    #expect(
      fixture.store.spamInstruments
        == Set([registrations[0].instrument, registrations[1].instrument]))
  }
}
