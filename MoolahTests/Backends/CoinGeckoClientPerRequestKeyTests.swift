import Foundation
import Testing

@testable import Moolah

/// `CoinGeckoClient` resolves its key (and therefore its host) per request via
/// the injected provider, so a Pro key entered mid-session flips both the
/// request URL's host and the rate-limit gate on the next fetch without
/// reconstructing the client. Class-based + `.serialized` so the shared
/// `StubURLProtocol.handlers` map is reset in `deinit`.
@Suite("CoinGeckoClient per-request key", .serialized)
final class CoinGeckoClientPerRequestKeyTests {
  deinit {
    StubURLProtocol.handlers = [:]
  }

  private func makeNetworking() -> NetworkingServices {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return NetworkingServices(session: URLSession(configuration: config))
  }

  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: nil, binanceSymbol: nil)

  /// One mutable `apiKey` box drives the provider so a single client can be
  /// driven across the empty → Pro transition without reconstructing it.
  @Test
  func currentPricesFlipsHostAndKeyWhenProviderFlips() async throws {
    let priceJSON = #"{"ethereum":{"usd":1623.45}}"#
    let publicURL = LockedBox<URL?>(nil)
    let proURL = LockedBox<URL?>(nil)
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/simple/price"] = { request in
      publicURL.set(request.url)
      return (HTTPURLResponse.ok(etag: ""), Data(priceJSON.utf8))
    }
    StubURLProtocol.handlers["pro-api.coingecko.com:/api/v3/simple/price"] = { request in
      proURL.set(request.url)
      return (HTTPURLResponse.ok(etag: ""), Data(priceJSON.utf8))
    }

    let key = LockedBox<String?>("")
    let client = CoinGeckoClient(
      apiKeyProvider: { key.get() }, networking: makeNetworking())

    // Empty key → free public host, no auth query item.
    _ = try await client.currentPrices(for: [ethMapping])
    let firstURL = try #require(publicURL.get())
    let firstComponents = try #require(URLComponents(url: firstURL, resolvingAgainstBaseURL: false))
    #expect(firstComponents.host == "api.coingecko.com")
    let firstNames = Set((firstComponents.queryItems ?? []).map(\.name))
    #expect(!firstNames.contains("x_cg_pro_api_key"))

    // Flip the key in place — no reconstruction — and the next request must
    // target the Pro host with the auth query item.
    key.set("prokey")
    _ = try await client.currentPrices(for: [ethMapping])
    let secondURL = try #require(proURL.get())
    let secondComponents = try #require(
      URLComponents(url: secondURL, resolvingAgainstBaseURL: false))
    #expect(secondComponents.host == "pro-api.coingecko.com")
    let secondItems = try #require(secondComponents.queryItems)
    let secondQuery = Dictionary(secondItems.map { ($0.name, $0.value ?? "") }) { first, _ in first
    }
    #expect(secondQuery["x_cg_pro_api_key"] == "prokey")
  }
}
