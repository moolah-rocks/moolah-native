import Foundation
import Testing

@testable import Moolah

/// The resolver reads its CoinGecko key per request through the injected
/// provider, so a Pro key entered mid-session routes the asset-platforms and
/// contract-lookup round-trips to the Pro host on the next resolution — no
/// reconstruction. Class-based + `.serialized` so the shared
/// `StubURLProtocol.handlers` map is reset in `deinit`.
@Suite("CompositeTokenResolutionClient pro key", .serialized)
final class CompositeTokenResolutionProKeyTests {
  deinit {
    StubURLProtocol.handlers = [:]
  }

  private func makeNetworking() -> NetworkingServices {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return NetworkingServices(session: URLSession(configuration: config))
  }

  @Test
  func resolveWithProKeyTargetsProHostWithKey() async throws {
    let capturedURLs = LockedBox<[URL]>([])
    StubURLProtocol.handlers["pro-api.coingecko.com:/api/v3/asset_platforms"] = { request in
      if let url = request.url { capturedURLs.set(capturedURLs.get() + [url]) }
      return (
        HTTPURLResponse.ok(etag: ""),
        Data(#"[{"id":"ethereum","chain_identifier":1,"name":"Ethereum"}]"#.utf8)
      )
    }
    let contractKey =
      "pro-api.coingecko.com:/api/v3/coins/ethereum/contract/"
      + "0xdac17f958d2ee523a2206206994597c13d831ec7"
    StubURLProtocol.handlers[contractKey] = { request in
      if let url = request.url { capturedURLs.set(capturedURLs.get() + [url]) }
      return (
        HTTPURLResponse.ok(etag: ""),
        Data(#"{"id":"tether","symbol":"usdt","name":"Tether","detail_platforms":{}}"#.utf8)
      )
    }

    let client = CompositeTokenResolutionClient(
      exchangeInfoData: Data(#"{ "symbols": [] }"#.utf8),
      coinGeckoApiKeyProvider: { "prokey" },
      networking: makeNetworking()
    )
    let result = try await client.resolve(
      chainId: 1,
      contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7",
      symbol: "USDT",
      isNative: false
    )

    #expect(result.coingeckoId == "tether")
    let hosts = Set(capturedURLs.get().compactMap(\.host))
    #expect(hosts == ["pro-api.coingecko.com"])
    let allKeyed = capturedURLs.get().allSatisfy { url in
      URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.contains { $0.name == "x_cg_pro_api_key" && $0.value == "prokey" } ?? false
    }
    #expect(allKeyed)
  }
}
