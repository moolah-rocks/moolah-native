import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Instrument Registration")
@MainActor
struct AutomationServiceInstrumentsTests {

  @Test("registerCryptoInstrument registers a priced token resolvable from the registry")
  func registerToken() async throws {
    let (service, session) = try await AutomationTestSession.make()

    let instrument = try await service.registerCryptoInstrument(
      profileIdentifier: "Test",
      spec: CryptoInstrumentSpec(
        chainId: 1,
        contractAddress: "0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766",
        symbol: "STRK",
        name: "Starknet",
        decimals: 18,
        coingeckoId: "starknet",
        binanceSymbol: nil))

    // Id is chain:lowercased-contract.
    #expect(instrument.id == "1:0xca14007eff0db1f8135f4c25b34de49ab0d42766")
    #expect(instrument.kind == .cryptoToken)
    #expect(instrument.ticker == "STRK")

    let registry = try #require(session.instrumentRegistry)
    let all = try await registry.all()
    #expect(all.contains { $0.id == instrument.id })

    let registration = try await registry.cryptoRegistration(byId: instrument.id)
    #expect(registration?.mapping.coingeckoId == "starknet")
  }

  @Test("registerCryptoInstrument derives chain:native when no contract is given")
  func nativeTokenId() async throws {
    let (service, _) = try await AutomationTestSession.make()

    let instrument = try await service.registerCryptoInstrument(
      profileIdentifier: "Test",
      spec: CryptoInstrumentSpec(
        chainId: 324, contractAddress: nil, symbol: "ZK", name: "ZKsync",
        decimals: 18, coingeckoId: "zksync", binanceSymbol: nil))

    #expect(instrument.id == "324:native")
  }

  @Test("registerCryptoInstrument treats a blank contract as native")
  func blankContractIsNative() async throws {
    let (service, _) = try await AutomationTestSession.make()

    let instrument = try await service.registerCryptoInstrument(
      profileIdentifier: "Test",
      spec: CryptoInstrumentSpec(
        chainId: 9999, contractAddress: "   ", symbol: "FUEL", name: "Fuel Network",
        decimals: 9, coingeckoId: "fuel-network", binanceSymbol: nil))

    #expect(instrument.id == "9999:native")
  }

  @Test("registerCryptoInstrument throws when no price source is supplied")
  func noPriceSourceThrows() async throws {
    let (service, _) = try await AutomationTestSession.make()

    await #expect(throws: AutomationError.self) {
      try await service.registerCryptoInstrument(
        profileIdentifier: "Test",
        spec: CryptoInstrumentSpec(
          chainId: 1, contractAddress: nil, symbol: "FOO", name: "Foo",
          decimals: 18, coingeckoId: nil, binanceSymbol: nil))
    }
  }

  @Test("registerCryptoInstrument throws when symbol is empty")
  func emptySymbolThrows() async throws {
    let (service, _) = try await AutomationTestSession.make()

    await #expect(throws: AutomationError.self) {
      try await service.registerCryptoInstrument(
        profileIdentifier: "Test",
        spec: CryptoInstrumentSpec(
          chainId: 1, contractAddress: nil, symbol: "  ", name: "Foo",
          decimals: 18, coingeckoId: "foo", binanceSymbol: nil))
    }
  }

  @Test("re-registering an id upserts its mapping rather than duplicating")
  func reRegisterUpserts() async throws {
    let (service, session) = try await AutomationTestSession.make()

    _ = try await service.registerCryptoInstrument(
      profileIdentifier: "Test",
      spec: CryptoInstrumentSpec(
        chainId: 1, contractAddress: "0xABC", symbol: "TIA", name: "Celestia",
        decimals: 6, coingeckoId: "celestia", binanceSymbol: nil))
    // Re-register same id (lowercased address) with a binanceSymbol added.
    // The upsert should merge: coingeckoId preserved, binanceSymbol added.
    let second = try await service.registerCryptoInstrument(
      profileIdentifier: "Test",
      spec: CryptoInstrumentSpec(
        chainId: 1, contractAddress: "0xabc", symbol: "TIA", name: "Celestia",
        decimals: 6, coingeckoId: nil, binanceSymbol: "TIAUSDT"))

    let registry = try #require(session.instrumentRegistry)
    let matches = try await registry.all().filter { $0.id == second.id }
    #expect(matches.count == 1)
    let registration = try await registry.cryptoRegistration(byId: second.id)
    // coingeckoId from the first call is preserved through the upsert.
    #expect(registration?.mapping.coingeckoId == "celestia")
    // binanceSymbol from the second call is added.
    #expect(registration?.mapping.binanceSymbol == "TIAUSDT")
  }
}
