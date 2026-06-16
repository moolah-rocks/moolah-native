import Foundation
import Testing

@testable import Moolah

/// Class-based suite so `deinit` can deterministically clean up the per-test
/// temp directory and the shared `StubURLProtocol` handlers map. Each
/// `@Test` instantiates a fresh suite, so handlers don't leak across tests.
@Suite("SQLiteCoinGeckoCatalog refresh", .serialized)
final class SQLiteCoinGeckoCatalogRefreshTests {
  private let tempDir: URL

  init() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("refresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  deinit {
    StubURLProtocol.handlers = [:]
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func makeNetworking() -> NetworkingServices {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: config)
    return NetworkingServices(session: session)
  }

  private func loadFixture(_ name: String) throws -> Data {
    let bundle = Bundle(for: TestBundleMarker.self)
    let url = try #require(bundle.url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
  }

  @Test
  func refreshDownloadsAndPopulates() async throws {
    let coinsData = try loadFixture("coingecko-coins-list-small")
    let platformsData = try loadFixture("coingecko-asset-platforms")
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"a1\""), coinsData)
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"p1\""), platformsData)
    }

    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir, apiKeyProvider: { "" }, networking: makeNetworking())
    await catalog.refreshIfStale()

    let count = try await catalog.coinCountForTesting()
    #expect(count == 3)
    let platforms = try await catalog.platformCountForTesting()
    #expect(platforms == 3)
    let meta = try await catalog.readMetaForTesting()
    #expect(meta.coinsEtag == "W/\"a1\"")
    #expect(meta.platformsEtag == "W/\"p1\"")
    #expect(meta.lastFetched != nil)
  }

  @Test
  func refreshSendsIfNoneMatchOnSubsequentCall() async throws {
    let coinsData = try loadFixture("coingecko-coins-list-small")
    let platformsData = try loadFixture("coingecko-asset-platforms")
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"a1\""), coinsData)
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"p1\""), platformsData)
    }
    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir, apiKeyProvider: { "" }, networking: makeNetworking())
    await catalog.refreshIfStale()

    // Fast-forward `last_fetched` so the next call is "stale".
    try await catalog.bumpLastFetchedBackwardForTesting(by: 25 * 3600)

    let capturedHeaders = LockedBox<[String: String]>([:])
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { request in
      capturedHeaders.set(request.allHTTPHeaderFields ?? [:])
      return (HTTPURLResponse.notModified(), Data())
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.notModified(), Data())
    }
    await catalog.refreshIfStale()

    #expect(capturedHeaders.get()["If-None-Match"] == "W/\"a1\"")

    let meta = try await catalog.readMetaForTesting()
    let lastFetched = try #require(meta.lastFetched)
    // 304/304 round-trip should bump last_fetched forward (within the last few
    // seconds) — without this, a regression that skipped `writeMeta` on the
    // all-304 path would let the catalog re-fetch on every launch.
    #expect(lastFetched.timeIntervalSinceNow > -60)
  }

  @Test
  func refreshSkippedWhenWithinMaxAge() async throws {
    let coinsData = try loadFixture("coingecko-coins-list-small")
    let platformsData = try loadFixture("coingecko-asset-platforms")
    let coinsCallCount = LockedBox<Int>(0)
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      coinsCallCount.set(coinsCallCount.get() + 1)
      return (HTTPURLResponse.ok(etag: "W/\"a1\""), coinsData)
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"p1\""), platformsData)
    }
    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir, apiKeyProvider: { "" }, networking: makeNetworking())
    await catalog.refreshIfStale()
    await catalog.refreshIfStale()

    #expect(coinsCallCount.get() == 1)
  }

  @Test
  func refreshOnNetworkErrorPreservesPriorSnapshot() async throws {
    let coinsData = try loadFixture("coingecko-coins-list-small")
    let platformsData = try loadFixture("coingecko-asset-platforms")
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"a1\""), coinsData)
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"p1\""), platformsData)
    }
    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir, apiKeyProvider: { "" }, networking: makeNetworking())
    await catalog.refreshIfStale()
    try await catalog.bumpLastFetchedBackwardForTesting(by: 25 * 3600)

    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      throw URLError(.notConnectedToInternet)
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      throw URLError(.notConnectedToInternet)
    }
    await catalog.refreshIfStale()

    let count = try await catalog.coinCountForTesting()
    #expect(count == 3)  // unchanged
  }

  @Test
  func refreshAcceptsUpdatedSnapshot() async throws {
    let firstCoins = try loadFixture("coingecko-coins-list-small")
    let secondCoins = try loadFixture("coingecko-coins-list-small-updated")
    let platforms = try loadFixture("coingecko-asset-platforms")
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"a1\""), firstCoins)
    }
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"p1\""), platforms)
    }
    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir, apiKeyProvider: { "" }, networking: makeNetworking())
    await catalog.refreshIfStale()
    try await catalog.bumpLastFetchedBackwardForTesting(by: 25 * 3600)

    StubURLProtocol.handlers["api.coingecko.com:/api/v3/coins/list"] = { _ in
      (HTTPURLResponse.ok(etag: "W/\"a2\""), secondCoins)
    }
    await catalog.refreshIfStale()

    let count = try await catalog.coinCountForTesting()
    #expect(count == 4)
    let pepe = await catalog.search(query: "pepe", limit: 5)
    #expect(pepe.first?.coingeckoId == "pepe")
    let meta = try await catalog.readMetaForTesting()
    #expect(meta.coinsEtag == "W/\"a2\"")
  }

  /// A provider returning a Pro key must route the refresh to the Pro host
  /// with the `x_cg_pro_api_key` query item — and still carry
  /// `include_platform=true` on the coins-list request. Guards the key-aware
  /// host/auth selection now that the catalog reads its key per refresh.
  @Test
  func refreshWithProKeyTargetsProHostWithKey() async throws {
    let coinsData = try loadFixture("coingecko-coins-list-small")
    let platformsData = try loadFixture("coingecko-asset-platforms")
    let coinsURL = LockedBox<URL?>(nil)
    let platformsURL = LockedBox<URL?>(nil)
    StubURLProtocol.handlers["pro-api.coingecko.com:/api/v3/coins/list"] = { request in
      coinsURL.set(request.url)
      return (HTTPURLResponse.ok(etag: "W/\"a1\""), coinsData)
    }
    StubURLProtocol.handlers["pro-api.coingecko.com:/api/v3/asset_platforms"] = { request in
      platformsURL.set(request.url)
      return (HTTPURLResponse.ok(etag: "W/\"p1\""), platformsData)
    }
    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir, apiKeyProvider: { "prokey" }, networking: makeNetworking())
    await catalog.refreshIfStale()

    let coins = try #require(coinsURL.get())
    let coinsComponents = try #require(URLComponents(url: coins, resolvingAgainstBaseURL: false))
    #expect(coinsComponents.host == "pro-api.coingecko.com")
    #expect(queryValue(coinsComponents, "x_cg_pro_api_key") == "prokey")
    #expect(queryValue(coinsComponents, "include_platform") == "true")

    let platforms = try #require(platformsURL.get())
    let platformsComponents = try #require(
      URLComponents(url: platforms, resolvingAgainstBaseURL: false))
    #expect(platformsComponents.host == "pro-api.coingecko.com")
    #expect(queryValue(platformsComponents, "x_cg_pro_api_key") == "prokey")

    let coinCount = try await catalog.coinCountForTesting()
    #expect(coinCount == 3)
  }

  private func queryValue(_ components: URLComponents, _ name: String) -> String? {
    components.queryItems?.first { $0.name == name }?.value
  }
}
