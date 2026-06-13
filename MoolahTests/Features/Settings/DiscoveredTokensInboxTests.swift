// MoolahTests/Features/Settings/DiscoveredTokensInboxTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for the data the Discovered Tokens inbox renders. The view
/// itself is a thin SwiftUI shell (per CLAUDE.md "Thin Views, Testable
/// Stores") — the testable surface is:
///
/// 1. `CryptoTokenStore.unpricedRegistrations` filters by status.
/// 2. `CryptoTokenStore.setStatus(.spam, for:)` removes the row from
///    the inbox.
/// 3. `CryptoTokenDiscoveryService.reResolve(_:chain:)` flips an
///    `.unpriced` row to a non-unpriced status when resolution
///    succeeds, which makes the row drop out of the inbox after the
///    store reloads.
@Suite("Discovered Tokens inbox — data behaviour")
@MainActor
struct DiscoveredTokensInboxTests {
  /// Bundle so tests can address every collaborator without re-deriving
  /// it from the store. Mirrors `CryptoTokenStoreSetStatusTests.Fixture`.
  private struct Fixture {
    let store: CryptoTokenStore
    let registry: GRDBInstrumentRegistryRepository
    let resolver: CountingRegistrationResolver
    let discovery: CryptoTokenDiscoveryService
  }

  /// Builds a store + registry + discovery actor sharing a single
  /// in-memory GRDB database, so a write through any of them is visible
  /// to the others — the same coupling the production wiring has.
  private func makeFixture() async throws -> Fixture {
    // Registry + price cache live on the profile-index DB.
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let priceService = CryptoPriceService(
      clients: [FixedCryptoPriceClient()], database: database)
    let store = CryptoTokenStore(
      registry: registry,
      cryptoPriceService: priceService,
      conversionService: RecordingConversionService())
    let resolver = CountingRegistrationResolver()
    let discovery = CryptoTokenDiscoveryService(
      registry: registry, resolver: resolver)
    return Fixture(
      store: store, registry: registry, resolver: resolver,
      discovery: discovery)
  }

  /// Seeds an unpriced registration directly through the registry — no
  /// provider mappings, status forced to `.unpriced` via the
  /// `update(_:)` path.
  @discardableResult
  private func seedUnpriced(
    in registry: GRDBInstrumentRegistryRepository,
    chainId: Int = 1,
    contractAddress: String = "0xabcdef0123456789abcdef0123456789abcdef01",
    symbol: String = "JUNK"
  ) async throws -> CryptoRegistration {
    let instrument = Instrument.crypto(
      chainId: chainId, contractAddress: contractAddress,
      symbol: symbol, name: symbol, decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: instrument.id, coingeckoId: nil,
      cryptocompareSymbol: nil, binanceSymbol: nil)
    try await registry.registerCrypto(instrument, mapping: mapping)
    let registration = CryptoRegistration(
      instrument: instrument, mapping: mapping, pricingStatus: .unpriced)
    try await registry.update(registration)
    return registration
  }

  // MARK: - Filtering

  @Test("unpricedRegistrations surfaces only .unpriced rows")
  func surfacesOnlyUnpricedRows() async throws {
    let fixture = try await makeFixture()
    // Seed one .unpriced + one .priced (a built-in preset).
    _ = try await seedUnpriced(in: fixture.registry)
    let priced = CryptoRegistration.builtInPresets[1]  // ETH preset
    try await fixture.registry.registerCrypto(priced.instrument, mapping: priced.mapping)
    await fixture.store.loadRegistrations()

    let inbox = fixture.store.unpricedRegistrations
    #expect(inbox.count == 1)
    #expect(inbox.allSatisfy { $0.pricingStatus == .unpriced })
  }

  @Test("unpricedCount mirrors unpricedRegistrations count")
  func unpricedCountMatchesArrayCount() async throws {
    let fixture = try await makeFixture()
    _ = try await seedUnpriced(
      in: fixture.registry, contractAddress: "0x0000000000000000000000000000000000000001")
    _ = try await seedUnpriced(
      in: fixture.registry, contractAddress: "0x0000000000000000000000000000000000000002")
    await fixture.store.loadRegistrations()

    #expect(fixture.store.unpricedCount == 2)
    #expect(fixture.store.unpricedCount == fixture.store.unpricedRegistrations.count)
  }

  @Test("Empty store surfaces zero unpriced registrations")
  func emptyStoreYieldsZero() async throws {
    let fixture = try await makeFixture()
    await fixture.store.loadRegistrations()
    #expect(fixture.store.unpricedRegistrations.isEmpty)
    #expect(fixture.store.unpricedCount == 0)
  }

  // MARK: - Mark as spam

  @Test("Marking spam removes the row from unpricedRegistrations")
  func markSpamRemovesFromInbox() async throws {
    let fixture = try await makeFixture()
    let seeded = try await seedUnpriced(in: fixture.registry)
    await fixture.store.loadRegistrations()
    let registration = try #require(
      fixture.store.unpricedRegistrations.first { $0.id == seeded.id })

    await fixture.store.setStatus(.spam, for: registration)

    #expect(fixture.store.unpricedRegistrations.isEmpty)
    #expect(fixture.store.spamRegistrations.contains { $0.id == seeded.id })
  }

  // MARK: - Re-resolve

  @Test("reResolve transitions an .unpriced row to .priced on resolver success")
  func reResolveTransitionsUnpricedToPriced() async throws {
    let fixture = try await makeFixture()
    let seeded = try await seedUnpriced(in: fixture.registry, symbol: "RESOLVE")
    await fixture.store.loadRegistrations()

    // Script the resolver to succeed for this address.
    let key = CountingRegistrationResolver.Key(
      chainId: 1, contractAddress: seeded.instrument.contractAddress?.lowercased())
    fixture.resolver.script(
      key,
      .success(coingecko: "resolve-ok", cryptocompare: nil, binance: nil))

    let resolved = try await fixture.discovery.reResolve(seeded, chain: .ethereum)

    #expect(resolved.pricingStatus == .priced)
    // The store hasn't reloaded yet — confirm the registry reflects the
    // change so the next `loadRegistrations()` call drops the row from
    // the inbox.
    let reloaded = try await fixture.registry.allCryptoRegistrations()
    let updated = try #require(reloaded.first { $0.id == seeded.id })
    #expect(updated.pricingStatus == .priced)
  }

  @Test("reResolve keeps the row .unpriced when no provider resolves it")
  func reResolveLeavesUnpricedOnFailure() async throws {
    let fixture = try await makeFixture()
    let seeded = try await seedUnpriced(in: fixture.registry, symbol: "STILL")
    await fixture.store.loadRegistrations()
    fixture.resolver.setDefault(.failure(StubResolverFailure()))

    let resolved = try await fixture.discovery.reResolve(seeded, chain: .ethereum)
    #expect(resolved.pricingStatus == .unpriced)
  }

  @Test("reResolve issues exactly one resolver call per invocation")
  func reResolveCallsResolverOnce() async throws {
    let fixture = try await makeFixture()
    let seeded = try await seedUnpriced(in: fixture.registry, symbol: "ONCE")
    await fixture.store.loadRegistrations()

    _ = try await fixture.discovery.reResolve(seeded, chain: .ethereum)

    let key = CountingRegistrationResolver.Key(
      chainId: 1, contractAddress: seeded.instrument.contractAddress?.lowercased())
    #expect(fixture.resolver.callCount(for: key) == 1)
  }

  /// Locally-defined error type so tests don't depend on a particular
  /// resolver-internal failure shape; `CountingRegistrationResolver`
  /// rethrows whatever it's scripted with.
  private struct StubResolverFailure: Error {}
}
