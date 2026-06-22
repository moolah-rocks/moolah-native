// MoolahTests/Features/CryptoTokenStoreTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoTokenStore")
@MainActor
struct CryptoTokenStoreTests {
  private func makeStore(
    registrations: [CryptoRegistration] = []
  ) async -> (CryptoTokenStore, GRDBInstrumentRegistryRepository) {
    // Seeding in-memory data cannot fail in practice; trap on any error so
    // the test fixture remains a one-liner without threading `throws`
    // through every caller.
    // swiftlint:disable:next force_try
    let database = try! ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    for reg in registrations {
      // swiftlint:disable:next force_try
      try! await registry.registerCrypto(reg.instrument, mapping: reg.mapping)
    }
    let service = CryptoPriceService(
      clients: [FixedCryptoPriceClient()],
      database: database
    )
    let store = CryptoTokenStore(
      registry: registry,
      cryptoPriceService: service,
      conversionService: FakeConversionService.passthrough)
    return (store, registry)
  }

  @Test("Store is constructible from the trimmed dependency set")
  func initializerAcceptsTrimmedDependencies() async {
    let (store, _) = await makeStore()
    #expect(store.isLoading == false)
    #expect(store.error == nil)
    #expect(store.registrations.isEmpty)
    #expect(store.instruments.isEmpty)
    #expect(store.providerMappings.isEmpty)
  }

  @Test
  func loadRegistrations_populatesList() async {
    let presets = Array(CryptoRegistration.builtInPresets.prefix(2))
    let (store, _) = await makeStore(registrations: presets)
    await store.loadRegistrations()
    #expect(store.registrations.count == 2)
  }

  @Test
  func loadRegistrations_populatesInstruments() async {
    let presets = Array(CryptoRegistration.builtInPresets.prefix(2))
    let (store, _) = await makeStore(registrations: presets)
    await store.loadRegistrations()
    #expect(store.instruments.count == 2)
    #expect(store.instruments.allSatisfy { $0.kind == .cryptoToken })
  }

  @Test
  func loadRegistrations_populatesProviderMappings() async {
    let presets = Array(CryptoRegistration.builtInPresets.prefix(2))
    let (store, _) = await makeStore(registrations: presets)
    await store.loadRegistrations()
    #expect(store.providerMappings.count == 2)
    let btcMapping = store.providerMappings["0:native"]
    #expect(btcMapping?.coingeckoId == "bitcoin")
  }

  @Test("loadRegistrations surfaces registry failure into error")
  func loadRegistrationsSurfacesError() async {
    let failing = FailingRegistry()
    // swiftlint:disable:next force_try
    let priceDatabase = try! ProfileIndexDatabase.openInMemory()
    let service = CryptoPriceService(clients: [], database: priceDatabase)
    let store = CryptoTokenStore(
      registry: failing,
      cryptoPriceService: service,
      conversionService: FakeConversionService.passthrough)
    await store.loadRegistrations()
    #expect(store.error != nil)
    #expect(store.registrations.isEmpty)
  }

  @Test("removeRegistration delegates to the registry and trims local state")
  func removeRegistration_removesFromList() async throws {
    let presets = Array(CryptoRegistration.builtInPresets.prefix(2))
    let (store, _) = await makeStore(registrations: presets)
    await store.loadRegistrations()
    let registration = try #require(store.registrations.first)
    await store.removeRegistration(registration)
    #expect(store.registrations.count == 1)
    #expect(store.instruments.count == 1)
    #expect(store.registrations.allSatisfy { $0.id != registration.id })
    #expect(store.providerMappings[registration.id] == nil)
  }

  @Test
  func removeInstrument_removesFromAllCollections() async {
    let presets = Array(CryptoRegistration.builtInPresets.prefix(2))
    let (store, _) = await makeStore(registrations: presets)
    await store.loadRegistrations()
    let instrumentToRemove = store.instruments[0]
    await store.removeInstrument(instrumentToRemove)
    #expect(store.registrations.count == 1)
    #expect(store.instruments.count == 1)
    #expect(store.providerMappings[instrumentToRemove.id] == nil)
  }

  // MARK: - Multi-instrument / cross-chain

  @Test
  func loadRegistrations_preservesMultipleChainsWithSamePrefix() async {
    // All presets should load — presets include Bitcoin (chainId 0), Ethereum (1),
    // Optimism (10), and ERC20s on Ethereum. Store keeps them distinct.
    let (store, _) = await makeStore(registrations: CryptoRegistration.builtInPresets)
    await store.loadRegistrations()
    #expect(store.registrations.count == CryptoRegistration.builtInPresets.count)
    let chainIds = Set(store.instruments.compactMap(\.chainId))
    // Presets span at least chain 0 (BTC), 1 (ETH/UNI/ENS), 10 (OP).
    #expect(chainIds.contains(0))
    #expect(chainIds.contains(1))
    #expect(chainIds.contains(10))
  }

  @Test
  func loadRegistrations_keepsNativeAndErc20OnSameChainDistinct() async {
    // builtInPresets contains ETH (chainId 1, native) and UNI/ENS (chainId 1, ERC20).
    let (store, _) = await makeStore(registrations: CryptoRegistration.builtInPresets)
    await store.loadRegistrations()
    let chain1 = store.instruments.filter { $0.chainId == 1 }
    let natives = chain1.filter { $0.contractAddress == nil }
    let erc20s = chain1.filter { $0.contractAddress != nil }
    #expect(!natives.isEmpty)
    #expect(!erc20s.isEmpty)
  }
}

// MARK: - Test doubles

private struct FailingRegistry: InstrumentRegistryRepository, @unchecked Sendable {
  struct BoomError: Error {}
  func all() async throws -> [Instrument] { throw BoomError() }
  func allCryptoRegistrations() async throws -> [CryptoRegistration] { throw BoomError() }
  func cryptoRegistration(byId id: String) async throws -> CryptoRegistration? {
    throw BoomError()
  }
  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws { throw BoomError() }
  func registerCrypto(
    _ instrument: Instrument,
    mapping: CryptoProviderMapping,
    forcingStatus status: TokenPricingStatus
  ) async throws { throw BoomError() }
  func registerStock(_ instrument: Instrument) async throws { throw BoomError() }
  func update(_ registration: CryptoRegistration) async throws { throw BoomError() }
  func remove(id: String) async throws { throw BoomError() }
  @MainActor
  func observeChanges() -> AsyncStream<Void> { AsyncStream { _ in } }
}
