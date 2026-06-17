import Foundation
import Testing

@testable import Moolah

/// Class-based suite so `deinit` deterministically clears the shared
/// `StubURLProtocol` handlers map and the per-test temp directory. Each
/// `@Test` instantiates a fresh suite, so handlers don't leak across tests.
@Suite("BinanceTokenCache", .serialized)
final class BinanceTokenCacheTests {
  private let tempDir: URL

  /// Binance `/api/v3/exchangeInfo` wire shape: RPLUSDT is an active USDT
  /// pair, FOOBTC is a non-USDT pair, and BARUSDT is a USDT pair that is not
  /// trading (`BREAK`). Only RPLUSDT should survive the parser's filter.
  private static let exchangeInfoJSON = """
    {
      "symbols": [
        { "symbol": "RPLUSDT", "baseAsset": "RPL", "quoteAsset": "USDT", "status": "TRADING" },
        { "symbol": "FOOBTC", "baseAsset": "FOO", "quoteAsset": "BTC", "status": "TRADING" },
        { "symbol": "BARUSDT", "baseAsset": "BAR", "quoteAsset": "USDT", "status": "BREAK" }
      ]
    }
    """

  private let host = "api.binance.com"
  private let path = "/api/v3/exchangeInfo"

  init() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("binance-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  deinit {
    StubURLProtocol.handlers = [:]
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func makeNetworking() -> NetworkingServices {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return NetworkingServices(session: URLSession(configuration: config))
  }

  private func makeCache() throws -> BinanceTokenCache {
    try BinanceTokenCache.make(directory: tempDir, networking: makeNetworking())
  }

  private func installExchangeInfo(requestCount: LockedBox<Int>? = nil) {
    let key = "\(host):\(path)"
    let json = Self.exchangeInfoJSON
    StubURLProtocol.handlers[key] = { _ in
      requestCount.map { $0.set($0.get() + 1) }
      let data = Data(json.utf8)
      return (HTTPURLResponse.ok(etag: "W/\"bn1\""), data)
    }
  }

  @Test
  func refreshPopulatesOnlyActiveUsdtPairs() async throws {
    installExchangeInfo()
    let cache = try makeCache()
    await cache.refreshIfStale()

    let rpl = await cache.hasUsdtPair(base: "RPL")
    #expect(rpl == true)
    let foo = await cache.hasUsdtPair(base: "FOO")
    #expect(foo == false)
    let bar = await cache.hasUsdtPair(base: "BAR")
    #expect(bar == false)

    let pairs = await cache.usdtPairs()
    #expect(pairs == ["RPLUSDT"])

    // Base lookup is case-insensitive.
    let lowercased = await cache.hasUsdtPair(base: "rpl")
    #expect(lowercased == true)
  }

  @Test
  func fetchOnMissTriggersExactlyOneRequest() async throws {
    let count = LockedBox<Int>(0)
    installExchangeInfo(requestCount: count)
    // Fresh cache, no explicit refresh: the first query must download once.
    let cache = try makeCache()

    let first = await cache.hasUsdtPair(base: "RPL")
    #expect(first == true)
    #expect(count.get() == 1)

    // A warm cache adds zero further requests.
    _ = await cache.usdtPairs()
    _ = await cache.hasUsdtPair(base: "FOO")
    #expect(count.get() == 1)
  }

  @Test
  func freshV1CacheOpensAndRoundTrips() async throws {
    let cache = try makeCache()
    try await cache.replaceAllForTesting(pairs: ["RPLUSDT", "BARUSDT"])
    let count = try await cache.countForTesting()
    #expect(count == 2)

    let pairs = await cache.usdtPairs()
    #expect(pairs == ["RPLUSDT", "BARUSDT"])
  }
}
