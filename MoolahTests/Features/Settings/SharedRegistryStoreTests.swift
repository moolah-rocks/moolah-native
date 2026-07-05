// MoolahTests/Features/Settings/SharedRegistryStoreTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Confirms `SharedRegistryStore` reads, mutates, and observes the
/// registry correctly. Errors propagate to the caller; the
/// observation task auto-refreshes on every registry mutation.
@MainActor
@Suite("SharedRegistryStore")
struct SharedRegistryStoreTests {

  @Test("loadRegistrations populates registrations and providerMappings")
  func loadRegistrationsPopulatesPublishedFields() async throws {
    // ProfileIndexDatabase.openInMemory() runs ProfileIndexSchema's
    // migrator, which from v3 onward creates the `instrument` table.
    // GRDBInstrumentRegistryRepository operates over that table.
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: queue)
    let store = makeStore(registry: registry)

    try await registry.registerCrypto(
      Instrument.crypto(
        chainId: 1,
        contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        symbol: "USDC",
        name: "USD Coin",
        decimals: 6),
      mapping: CryptoProviderMapping(
        instrumentId:
          "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        coingeckoId: "usd-coin",
        binanceSymbol: nil))

    await store.loadRegistrations()
    #expect(store.registrations.contains { $0.instrument.id.hasPrefix("1:") })
    #expect(store.providerMappings.values.contains { $0.coingeckoId == "usd-coin" })
    #expect(store.registrationsVersion == 0)  // loadRegistrations doesn't bump
  }

  @Test("setStatus throws when the registration is not in the registry")
  func setStatusThrowsForUnknownRegistration() async throws {
    // ProfileIndexDatabase.openInMemory() runs ProfileIndexSchema's
    // migrator, which from v3 onward creates the `instrument` table.
    // GRDBInstrumentRegistryRepository operates over that table.
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: queue)
    let store = makeStore(registry: registry)

    let registration = CryptoRegistration(
      instrument: Instrument.crypto(
        chainId: 1,
        contractAddress: "0xnotregistered",
        symbol: "NOPE",
        name: "Not Registered",
        decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xnotregistered",
        coingeckoId: nil,
        binanceSymbol: nil))

    await #expect(throws: BackendError.self) {
      try await store.setStatus(.spam, for: registration)
    }
  }

  @Test("setStatus updates the registration in-memory and bumps the version")
  func setStatusUpdatesInMemoryAndBumpsVersion() async throws {
    // ProfileIndexDatabase.openInMemory() runs ProfileIndexSchema's
    // migrator, which from v3 onward creates the `instrument` table.
    // GRDBInstrumentRegistryRepository operates over that table.
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: queue)
    let store = makeStore(registry: registry)

    try await registry.registerCrypto(
      Instrument.crypto(
        chainId: 1,
        contractAddress: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
        symbol: "WETH",
        name: "Wrapped Ether",
        decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId:
          "1:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
        coingeckoId: "weth",
        binanceSymbol: nil))
    await store.loadRegistrations()
    let initialVersion = store.registrationsVersion

    let registration = try #require(store.registrations.first)
    try await store.setStatus(.spam, for: registration)

    let updated = try #require(store.registrations.first)
    #expect(updated.pricingStatus == .spam)
    #expect(store.registrationsVersion == initialVersion &+ 1)
  }

  @Test(
    "removeRegistration drops the row from registrations / instruments / providerMappings and bumps the version"
  )
  func removeRegistrationDropsRowAndBumpsVersion() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: queue)
    let store = makeStore(registry: registry)

    let id = "1:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
    try await registry.registerCrypto(
      Instrument.crypto(
        chainId: 1,
        contractAddress: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
        symbol: "WETH",
        name: "Wrapped Ether",
        decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: id,
        coingeckoId: "weth",
        binanceSymbol: nil))
    await store.loadRegistrations()
    let initialVersion = store.registrationsVersion
    let registration = try #require(store.registrations.first)

    try await store.removeRegistration(registration)

    #expect(store.registrations.isEmpty)
    #expect(store.instruments.isEmpty)
    #expect(store.providerMappings[id] == nil)
    #expect(store.registrationsVersion == initialVersion &+ 1)
  }

  @Test("removeInstrument is a no-op when the instrument id is not registered")
  func removeInstrumentNoOpsForUnknownInstrument() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: queue)
    let store = makeStore(registry: registry)

    let initialVersion = store.registrationsVersion
    // No prior registration: removeInstrument should silently succeed
    // without throwing or bumping the version.
    try await store.removeInstrument(
      Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP Group"))
    #expect(store.registrations.isEmpty)
    #expect(store.registrationsVersion == initialVersion)
  }

  // MARK: - Helpers

  // `@MainActor` propagates from the enclosing `@Suite` struct.
  private func makeStore(
    registry: any InstrumentRegistryRepository
  ) -> SharedRegistryStore {
    SharedRegistryStore(registry: registry)
  }
}
