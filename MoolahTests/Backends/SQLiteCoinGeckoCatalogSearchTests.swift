import Foundation
import Testing

@testable import Moolah

/// Class-based suite so `deinit` can deterministically remove the per-test
/// temp directory. Each `@Test` method runs on its own instance, mirroring
/// the XCTest setUp/tearDown pattern from the plan.
@Suite("SQLiteCoinGeckoCatalog search")
final class SQLiteCoinGeckoCatalogSearchTests {
  private let tempDir: URL
  private let catalog: SQLiteCoinGeckoCatalog

  init() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("search-\(UUID().uuidString)", isDirectory: true)
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
      .init(id: "bitcoin", symbol: "BTC", name: "Bitcoin", platforms: [:]),
      .init(id: "ethereum", symbol: "ETH", name: "Ethereum", platforms: [:]),
      .init(
        id: "uniswap", symbol: "UNI", name: "Uniswap",
        platforms: [
          "ethereum": "0x1F9840a85d5aF5bf1D1762F925BDADdC4201F984",
          "polygon-pos": "0xb33EaAd8d922B1083446DC23f610c2567fB5180f",
        ]
      ),
      .init(id: "tether", symbol: "USDT", name: "Tether", platforms: [:]),
      .init(id: "blockstack", symbol: "STX", name: "Stacks", platforms: [:]),
      .init(id: "eos", symbol: "EOS", name: "EOS", platforms: [:]),
      .init(id: "electroneum", symbol: "ETN", name: "Electroneum", platforms: [:]),
    ]
    let platforms: [SQLiteCoinGeckoCatalog.RawPlatform] = [
      .init(slug: "ethereum", chainId: 1, name: "Ethereum"),
      .init(slug: "polygon-pos", chainId: 137, name: "Polygon"),
    ]
    try await catalog.replaceAllForTesting(coins: coins, platforms: platforms)
  }

  @Test
  func symbolPrefixHits() async throws {
    try await seedFixture()
    let results = await catalog.search(query: "btc", limit: 10)
    #expect(results.first?.coingeckoId == "bitcoin")
  }

  @Test
  func nameTokenHits() async throws {
    try await seedFixture()
    let results = await catalog.search(query: "uniswap", limit: 10)
    #expect(results.first?.coingeckoId == "uniswap")
  }

  @Test
  func platformsAttachedToHit() async throws {
    try await seedFixture()
    let results = await catalog.search(query: "uni", limit: 10)
    let uni = try #require(results.first { $0.coingeckoId == "uniswap" })
    #expect(uni.platforms.first?.slug == "ethereum")
    #expect(uni.platforms.first?.chainId == 1)
    #expect(
      uni.platforms.first?.contractAddress
        == "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
    )
    #expect(uni.platforms.contains { $0.slug == "polygon-pos" })
  }

  @Test
  func platformOrderingHonoursPriority() async throws {
    try await seedFixture()
    let results = await catalog.search(query: "uni", limit: 10)
    let uni = try #require(results.first { $0.coingeckoId == "uniswap" })
    #expect(uni.platforms.map(\.slug) == ["ethereum", "polygon-pos"])
  }

  @Test
  func emptyQueryReturnsEmpty() async throws {
    try await seedFixture()
    let results = await catalog.search(query: "", limit: 10)
    #expect(results.isEmpty)
  }

  @Test
  func limitIsRespected() async throws {
    try await seedFixture()
    let results = await catalog.search(query: "e", limit: 2)
    #expect(results.count == 2)
  }
}
