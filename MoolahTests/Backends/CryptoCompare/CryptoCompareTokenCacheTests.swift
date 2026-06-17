import Foundation
import Testing

@testable import Moolah

/// Class-based suite so `deinit` deterministically clears the shared
/// `StubURLProtocol` handlers map and the per-test temp directory. Each
/// `@Test` instantiates a fresh suite, so handlers don't leak across tests.
@Suite("CryptoCompareTokenCache", .serialized)
final class CryptoCompareTokenCacheTests {
  private let tempDir: URL

  /// CryptoCompare's `/data/all/coinlist?summary=true` wire shape: RPL carries
  /// a contract, BTC's contract is the literal "N/A" (native), and USDT omits
  /// the field entirely (chain-agnostic stablecoin listing).
  private static let coinListJSON = """
    {
      "Data": {
        "RPL": { "Symbol": "RPL", "SmartContractAddress": "0xD33526068D116cE69F19A9ee46F0bd304F21A51f" },
        "BTC": { "Symbol": "BTC", "SmartContractAddress": "N/A" },
        "USDT": { "Symbol": "USDT" }
      }
    }
    """

  private let coinListHost = "min-api.cryptocompare.com"
  private let coinListPath = "/data/all/coinlist"

  init() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("cc-cache-\(UUID().uuidString)", isDirectory: true)
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

  private func makeCache(apiKey: String = "test-key") throws -> CryptoCompareTokenCache {
    try CryptoCompareTokenCache.make(
      directory: tempDir,
      apiKeyProvider: { apiKey },
      networking: makeNetworking())
  }

  private func installCoinList(
    requestCount: LockedBox<Int>? = nil,
    capturedURL: LockedBox<URL?>? = nil
  ) {
    let key = "\(coinListHost):\(coinListPath)"
    let json = Self.coinListJSON
    StubURLProtocol.handlers[key] = { request in
      requestCount.map { $0.set($0.get() + 1) }
      capturedURL?.set(request.url)
      let data = Data(json.utf8)
      return (HTTPURLResponse.ok(etag: "W/\"cc1\""), data)
    }
  }

  @Test
  func refreshPopulatesContractNativeAndAllSymbols() async throws {
    installCoinList()
    let cache = try makeCache()
    await cache.refreshIfStale()

    // Contract lookup is case-insensitive on the address.
    let rpl = await cache.symbol(forContract: "0xd33526068d116ce69f19a9ee46f0bd304f21a51f")
    #expect(rpl == "RPL")

    let native = await cache.nativeSymbols()
    #expect(native.contains("BTC"))
    #expect(native.contains("USDT"))  // no contract field → native/symbol-only

    let all = await cache.allSymbols()
    #expect(all.isSuperset(of: ["RPL", "BTC", "USDT"]))
  }

  @Test
  func fetchOnMissTriggersExactlyOneRequest() async throws {
    let count = LockedBox<Int>(0)
    installCoinList(requestCount: count)
    // Fresh cache, no explicit refresh: the first query must download once.
    let cache = try makeCache()

    let first = await cache.symbol(forContract: "0xd33526068d116ce69f19a9ee46f0bd304f21a51f")
    #expect(first == "RPL")
    #expect(count.get() == 1)

    // A warm cache adds zero further requests.
    _ = await cache.nativeSymbols()
    _ = await cache.allSymbols()
    #expect(count.get() == 1)
  }

  @Test
  func refreshRequestCarriesApiKey() async throws {
    let capturedURL = LockedBox<URL?>(nil)
    installCoinList(capturedURL: capturedURL)
    let cache = try makeCache(apiKey: "secret-key")
    await cache.refreshIfStale()

    let url = try #require(capturedURL.get())
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = components.queryItems ?? []
    #expect(items.first { $0.name == "api_key" }?.value == "secret-key")
    #expect(items.first { $0.name == "summary" }?.value == "true")
  }

  @Test
  func freshV1CacheOpensAndRoundTrips() async throws {
    let cache = try makeCache()
    try await cache.replaceAllForTesting(rows: [
      CryptoCompareTokenCache.Row(symbol: "RPL", contractAddress: "0xabc"),
      CryptoCompareTokenCache.Row(symbol: "BTC", contractAddress: nil),
    ])
    let count = try await cache.countForTesting()
    #expect(count == 2)

    let rpl = await cache.symbol(forContract: "0xabc")
    #expect(rpl == "RPL")
    let native = await cache.nativeSymbols()
    #expect(native == ["BTC"])
  }
}
