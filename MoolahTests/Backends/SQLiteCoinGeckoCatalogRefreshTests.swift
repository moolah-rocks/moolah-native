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

  private func makeClient() -> RateLimitedHTTPClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: config)
    return NetworkingServices(session: session).client(forHost: "api.coingecko.com")
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

    let catalog = try SQLiteCoinGeckoCatalog.make(directory: tempDir, http: makeClient())
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
    let catalog = try SQLiteCoinGeckoCatalog.make(directory: tempDir, http: makeClient())
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
    let catalog = try SQLiteCoinGeckoCatalog.make(directory: tempDir, http: makeClient())
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
    let catalog = try SQLiteCoinGeckoCatalog.make(directory: tempDir, http: makeClient())
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
    let catalog = try SQLiteCoinGeckoCatalog.make(directory: tempDir, http: makeClient())
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
}
