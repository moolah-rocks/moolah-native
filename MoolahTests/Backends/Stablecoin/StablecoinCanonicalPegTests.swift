// MoolahTests/Backends/Stablecoin/StablecoinCanonicalPegTests.swift

import Foundation
import Testing

@testable import Moolah

/// Precondition for the unified-identity resolver (design §1): the $1 peg must
/// resolve for the CANONICAL mainnet stablecoin id, because the resolver
/// collapses every L2 USDC/USDT onto its mainnet contract id. If the mainnet
/// contract were missing from `CanonicalTokenRegistry`, the collapsed id would
/// silently lose its peg. This suite fails loudly if that ever regresses.
@Suite("Stablecoin peg resolves for the canonical mainnet id")
struct StablecoinCanonicalPegTests {
  // Canonical mainnet deployments (from CanonicalTokenRegistry+Bundled, chain 1).
  private let mainnetUSDC = "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  private let mainnetUSDT = "1:0xdac17f958d2ee523a2206206994597c13d831ec7"

  private func mapping(_ id: String) -> CryptoProviderMapping {
    CryptoProviderMapping(
      instrumentId: id, coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil)
  }

  @Test("CanonicalTokenRegistry recognises the mainnet USDC/USDT contracts")
  func mainnetContractsRecognised() {
    #expect(
      CanonicalTokenRegistry.symbol(
        chainId: 1, contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48") == "USDC")
    #expect(
      CanonicalTokenRegistry.symbol(
        chainId: 1, contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7") == "USDT")
  }

  @Test("peg returns $1 for the canonical mainnet USDC and USDT ids")
  func pegHoldsForCanonicalIds() async throws {
    let client = StablecoinPriceClient()
    let prices = try await client.currentPrices(
      for: [mapping(mainnetUSDC), mapping(mainnetUSDT)])
    #expect(prices[mainnetUSDC] == 1)
    #expect(prices[mainnetUSDT] == 1)
  }

  @Test("a native id is not pegged")
  func nativeIdNotPegged() async throws {
    let client = StablecoinPriceClient()
    let prices = try await client.currentPrices(for: [mapping("1:native")])
    #expect(prices["1:native"] == nil)
  }
}
