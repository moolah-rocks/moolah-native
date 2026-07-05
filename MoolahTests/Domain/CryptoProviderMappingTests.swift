import Foundation
import Testing

@testable import Moolah

@Suite("CryptoProviderMapping")
struct CryptoProviderMappingTests {
  @Test
  func initStoresAllFields() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native",
      coingeckoId: "ethereum",
      binanceSymbol: "ETHUSDT"
    )
    #expect(mapping.instrumentId == "1:native")
    #expect(mapping.coingeckoId == "ethereum")
    #expect(mapping.binanceSymbol == "ETHUSDT")
  }

  @Test
  func nilProviderFieldsAllowed() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native",
      coingeckoId: nil,
      binanceSymbol: nil
    )
    #expect(mapping.coingeckoId == nil)
  }

  @Test
  func codableRoundTrip() throws {
    let original = CryptoProviderMapping(
      instrumentId: "10:0x4200000000000000000000000000000000000042",
      coingeckoId: "optimism",
      binanceSymbol: "OPUSDT"
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CryptoProviderMapping.self, from: data)
    #expect(decoded == original)
  }

  @Test
  func identityBasedOnInstrumentId() {
    let first = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "ethereum",
      binanceSymbol: "ETHUSDT"
    )
    let second = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "eth-changed",
      binanceSymbol: nil
    )
    #expect(first.id == second.id)
  }

  // MARK: - Built-in presets

  @Test
  func builtInPresetsContainExpectedTokens() throws {
    let presets = CryptoProviderMapping.builtInPresets

    let btc = try #require(presets.first { $0.instrumentId == "0:native" })
    #expect(btc.coingeckoId == "bitcoin")
    #expect(btc.binanceSymbol == "BTCUSDT")

    // The canonical mainnet ETH and Polygon native gas instruments carry a
    // real provider mapping so transaction detail / running-balance /
    // aggregation resolves them from session start (issue #791).
    // L2 ETH variants (10:native, 8453:native) are omitted from presets:
    // ChainConfig aliases them to the canonical 1:native.
    for id in ["1:native", "137:native"] {
      let preset = try #require(presets.first { $0.instrumentId == id })
      #expect(preset.binanceSymbol != nil, "missing Binance mapping for \(id)")
    }
  }
}

@Suite("CryptoProviderMapping.merging")
struct CryptoProviderMappingMergingTests {
  @Test("fills nil columns from other, never downgrades populated ones")
  func mergeFillsNilsOnly() {
    let stored = CryptoProviderMapping(
      instrumentId: "1:0xrpl", coingeckoId: "rocket-pool",
      binanceSymbol: nil)
    let extra = CryptoProviderMapping(
      instrumentId: "1:0xrpl", coingeckoId: "WRONG",
      binanceSymbol: "RPLUSDT")
    let merged = stored.merging(extra)
    #expect(merged.coingeckoId == "rocket-pool")
    #expect(merged.binanceSymbol == "RPLUSDT")
    #expect(merged.instrumentId == "1:0xrpl")
  }

  @Test("no-op merge equals self")
  func noOp() {
    let full = CryptoProviderMapping(
      instrumentId: "1:0xrpl", coingeckoId: "rocket-pool",
      binanceSymbol: "RPLUSDT")
    #expect(
      full.merging(
        .init(
          instrumentId: "1:0xrpl", coingeckoId: nil,
          binanceSymbol: nil)) == full)
  }

  @Test("does not mutate instrumentId even if other differs")
  func keepsOwnInstrumentId() {
    let stored = CryptoProviderMapping(
      instrumentId: "1:0xrpl", coingeckoId: nil,
      binanceSymbol: "RPLUSDT")
    let other = CryptoProviderMapping(
      instrumentId: "999:0xother", coingeckoId: "rocket-pool",
      binanceSymbol: "WRONGUSDT")
    let merged = stored.merging(other)
    #expect(merged.instrumentId == "1:0xrpl")
    #expect(merged.binanceSymbol == "RPLUSDT")  // own populated value kept
    #expect(merged.coingeckoId == "rocket-pool")  // nil filled from other
  }
}
