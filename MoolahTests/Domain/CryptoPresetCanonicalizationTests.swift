// MoolahTests/Domain/CryptoPresetCanonicalizationTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("builtInPresets — canonical only")
struct CryptoPresetCanonicalizationTests {
  @Test("no L2 native ETH presets remain")
  func noL2NativePresets() {
    let ids = Set(CryptoRegistration.builtInPresets.map(\.instrument.id))
    #expect(ids.contains("1:native"))
    #expect(!ids.contains("10:native"))
    #expect(!ids.contains("8453:native"))
  }

  @Test("preset skipped when a same-assetKey canonical registration exists")
  func skipsByAssetKey() async throws {
    let registry = StubInstrumentRegistry()
    // Seed canonical mainnet ETH already registered.
    try await registry.registerCrypto(
      .crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ethereum",
        binanceSymbol: "ETHUSDT"))
    // A hypothetical non-canonical same-asset preset must NOT be minted.
    await registry.registerBuiltInPresetsIfMissing(
      presets: [
        CryptoRegistration(
          instrument: .crypto(
            chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
          mapping: CryptoProviderMapping(
            instrumentId: "10:native", coingeckoId: "ethereum",
            binanceSymbol: "ETHUSDT"))
      ])
    #expect(try await registry.cryptoRegistration(byId: "10:native") == nil)
  }

  @Test("preset with unique assetKey is still registered")
  func uniqueAssetKeyPresetRegisters() async throws {
    let registry = StubInstrumentRegistry()
    // A no-key preset's assetKey falls back to its own id — distinct from anything else.
    await registry.registerBuiltInPresetsIfMissing(
      presets: [
        CryptoRegistration(
          instrument: .crypto(
            chainId: 1,
            contractAddress: "0x1234567890abcdef1234567890abcdef12345678",
            symbol: "WTF", name: "Weird Token", decimals: 18),
          mapping: CryptoProviderMapping(
            instrumentId: "1:0x1234567890abcdef1234567890abcdef12345678",
            coingeckoId: nil, binanceSymbol: nil))
      ])
    #expect(
      try await registry.cryptoRegistration(
        byId: "1:0x1234567890abcdef1234567890abcdef12345678") != nil)
  }
}
