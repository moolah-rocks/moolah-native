import Foundation
import Testing

@testable import Moolah

/// Offline resolution of a token's CoinGecko id from its on-chain
/// `(chainId, contractAddress)` against the bundled / cached catalog. This is
/// what lets a known token (e.g. canonical USDC) be priced immediately without
/// a network round-trip. Class-based suite so `deinit` removes the temp dir.
@Suite("SQLiteCoinGeckoCatalog contract lookup")
final class CoinGeckoCatalogContractLookupTests {
  private let tempDir: URL
  private let catalog: SQLiteCoinGeckoCatalog

  init() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("contract-lookup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir,
      http: NetworkingServices().client(forHost: "api.coingecko.com"))
  }

  deinit {
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func seedFixture() async throws {
    let coins: [SQLiteCoinGeckoCatalog.RawCoin] = [
      .init(
        id: "usd-coin", symbol: "USDC", name: "USDC",
        platforms: [
          "ethereum": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
          "polygon-pos": "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359",
        ]
      ),
      .init(
        id: "uniswap", symbol: "UNI", name: "Uniswap",
        platforms: ["ethereum": "0x1F9840a85d5aF5bf1D1762F925BDADdC4201F984"]
      ),
    ]
    let platforms: [SQLiteCoinGeckoCatalog.RawPlatform] = [
      .init(slug: "ethereum", chainId: 1, name: "Ethereum"),
      .init(slug: "polygon-pos", chainId: 137, name: "Polygon"),
    ]
    try await catalog.replaceAllForTesting(coins: coins, platforms: platforms)
  }

  @Test("Resolves the CoinGecko mapping for a known (chain, contract)")
  func resolvesKnownContract() async throws {
    try await seedFixture()
    let match = await catalog.localContractMatch(
      chainId: 1, contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(match?.coingeckoId == "usd-coin")
    #expect(match?.symbol == "USDC")
    #expect(match?.name == "USDC")
  }

  @Test("Contract matching is case-insensitive")
  func contractMatchIsCaseInsensitive() async throws {
    try await seedFixture()
    let match = await catalog.localContractMatch(
      chainId: 1, contractAddress: "0xA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48")
    #expect(match?.coingeckoId == "usd-coin")
  }

  @Test("The same contract on a different chain does not match")
  func differentChainDoesNotMatch() async throws {
    try await seedFixture()
    // USDC's Ethereum address queried on Polygon (137) must not resolve.
    let match = await catalog.localContractMatch(
      chainId: 137, contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(match == nil)
  }

  @Test("An unknown contract resolves to nil")
  func unknownContractIsNil() async throws {
    try await seedFixture()
    let match = await catalog.localContractMatch(
      chainId: 1, contractAddress: "0xdeadbeef00000000000000000000000000000001")
    #expect(match == nil)
  }
}
