// MoolahTests/Features/Settings/SpamTokensViewTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for the data the Spam Tokens view renders. Like the
/// Discovered Tokens inbox, the testable surface is the store rather
/// than the SwiftUI view:
///
/// 1. `CryptoTokenStore.spamRegistrations` filters by status.
/// 2. `setStatus(.unpriced, for:)` (the "Restore" action) flips a
///    spam row back to the inbox.
@Suite("Spam Tokens view — data behaviour")
@MainActor
struct SpamTokensViewTests {
  private struct Fixture {
    let store: CryptoTokenStore
    let registry: GRDBInstrumentRegistryRepository
    let conversionService: FakeConversionService
  }

  private func makeFixture() async throws -> Fixture {
    // Registry + price cache live on the profile-index DB.
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let priceService = CryptoPriceService(
      clients: [FixedCryptoPriceClient()], database: database)
    let conversionService = FakeConversionService.passthrough
    let store = CryptoTokenStore(
      registry: registry,
      cryptoPriceService: priceService,
      conversionService: conversionService)
    return Fixture(
      store: store, registry: registry, conversionService: conversionService)
  }

  /// Seed a registration with the given pricing status. Two-step write
  /// because `registerCrypto` always inserts as `.priced` on first
  /// write — `update(_:)` then forces the desired status.
  @discardableResult
  private func seed(
    in registry: GRDBInstrumentRegistryRepository,
    status: TokenPricingStatus,
    contractAddress: String,
    symbol: String
  ) async throws -> CryptoRegistration {
    let instrument = Instrument.crypto(
      chainId: 1, contractAddress: contractAddress,
      symbol: symbol, name: symbol, decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: instrument.id, coingeckoId: nil,
      binanceSymbol: nil)
    try await registry.registerCrypto(instrument, mapping: mapping)
    let registration = CryptoRegistration(
      instrument: instrument, mapping: mapping, pricingStatus: status)
    try await registry.update(registration)
    return registration
  }

  // MARK: - Filtering

  @Test("spamRegistrations surfaces only .spam rows")
  func surfacesOnlySpamRows() async throws {
    let fixture = try await makeFixture()
    _ = try await seed(
      in: fixture.registry, status: .spam,
      contractAddress: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", symbol: "SPAM")
    _ = try await seed(
      in: fixture.registry, status: .unpriced,
      contractAddress: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", symbol: "UNPR")
    let priced = CryptoRegistration.builtInPresets[1]
    try await fixture.registry.registerCrypto(priced.instrument, mapping: priced.mapping)
    await fixture.store.loadRegistrations()

    let spam = fixture.store.spamRegistrations
    #expect(spam.count == 1)
    #expect(spam.allSatisfy { $0.pricingStatus == .spam })
    #expect(spam.first?.instrument.ticker == "SPAM")
  }

  @Test("Empty store surfaces zero spam registrations")
  func emptyStoreYieldsZero() async throws {
    let fixture = try await makeFixture()
    await fixture.store.loadRegistrations()
    #expect(fixture.store.spamRegistrations.isEmpty)
  }

  // MARK: - Restore

  @Test("Restore (setStatus(.unpriced)) moves the row out of spamRegistrations")
  func restoreMovesRowOutOfSpamList() async throws {
    let fixture = try await makeFixture()
    let seeded = try await seed(
      in: fixture.registry, status: .spam,
      contractAddress: "0xcccccccccccccccccccccccccccccccccccccccc", symbol: "REST")
    await fixture.store.loadRegistrations()
    let registration = try #require(
      fixture.store.spamRegistrations.first { $0.id == seeded.id })

    await fixture.store.setStatus(.unpriced, for: registration)

    #expect(fixture.store.spamRegistrations.isEmpty)
    #expect(fixture.store.unpricedRegistrations.contains { $0.id == seeded.id })
  }

  @Test("Restore invalidates the conversion cache for the restored instrument")
  func restoreInvalidatesConversionCache() async throws {
    let fixture = try await makeFixture()
    let seeded = try await seed(
      in: fixture.registry, status: .spam,
      contractAddress: "0xdddddddddddddddddddddddddddddddddddddddd", symbol: "INV")
    await fixture.store.loadRegistrations()
    let registration = try #require(
      fixture.store.spamRegistrations.first { $0.id == seeded.id })

    await fixture.store.setStatus(.unpriced, for: registration)

    let invalidated = fixture.conversionService.invalidatedInstruments
    #expect(invalidated.contains { $0.id == seeded.instrument.id })
  }
}
