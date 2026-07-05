// MoolahTests/Backends/GRDB/GRDBInstrumentMapResolvingTests.swift

import GRDB
import Testing

@testable import Moolah

@Suite("Shared registry resolves the full instrument map")
struct GRDBInstrumentMapResolvingTests {
  private func resolvedMap() async throws -> [String: Instrument] {
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: queue)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil))
    return try await (registry as any InstrumentMapResolving).instrumentMap()
  }

  @Test("stored crypto row appears in the map")
  func storedCryptoRowAppearsInMap() async throws {
    let map = try await resolvedMap()
    #expect(map["1:native"]?.kind == .cryptoToken)
  }

  @Test("ambient ISO fiat is supplemented in the map")
  func ambientFiatIsSupplemented() async throws {
    let map = try await resolvedMap()
    #expect(map["USD"]?.kind == .fiatCurrency)
  }
}
