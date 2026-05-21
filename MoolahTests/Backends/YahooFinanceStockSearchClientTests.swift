import Foundation
import Testing

@testable import Moolah

/// Class-based suite so `deinit` can deterministically clear the shared
/// `StubURLProtocol.handlers` map between tests. `.serialized` because that
/// map is process-wide global state.
@Suite("Yahoo Finance stock search", .serialized)
final class YahooFinanceStockSearchClientTests {
  deinit {
    StubURLProtocol.handlers = [:]
  }

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func loadFixture() throws -> Data {
    let bundle = Bundle(for: TestBundleMarker.self)
    let url = try #require(
      bundle.url(forResource: "yahoo-finance-search-apple", withExtension: "json"))
    return try Data(contentsOf: url)
  }

  @Test
  func returnsEquityEtfMutualFundOnly() async throws {
    let data = try loadFixture()
    StubURLProtocol.handlers["query1.finance.yahoo.com:/v1/finance/search"] = { _ in
      (HTTPURLResponse.ok(etag: ""), data)
    }
    let services = NetworkingServices(session: makeSession())
    let client = YahooFinanceStockSearchClient(
      http: services.client(forHost: "query1.finance.yahoo.com"))

    let hits = try await client.search(query: "apple")

    #expect(hits.map(\.symbol) == ["AAPL", "APC.DE", "APLE.TO", "FXAIX"])
  }

  @Test
  func namesAreTrimmed() async throws {
    let data = try loadFixture()
    StubURLProtocol.handlers["query1.finance.yahoo.com:/v1/finance/search"] = { _ in
      (HTTPURLResponse.ok(etag: ""), data)
    }
    let services = NetworkingServices(session: makeSession())
    let client = YahooFinanceStockSearchClient(
      http: services.client(forHost: "query1.finance.yahoo.com"))

    let hits = try await client.search(query: "apple")

    let trimmed = "Apple Inc.                    R".trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(hits.first { $0.symbol == "APC.DE" }?.name == trimmed)
  }

  @Test
  func queryParamsAreSentCorrectly() async throws {
    let data = try loadFixture()
    let captured = LockedBox<URL?>(nil)
    StubURLProtocol.handlers["query1.finance.yahoo.com:/v1/finance/search"] = { request in
      captured.set(request.url)
      return (HTTPURLResponse.ok(etag: ""), data)
    }
    let services = NetworkingServices(session: makeSession())
    let client = YahooFinanceStockSearchClient(
      http: services.client(forHost: "query1.finance.yahoo.com"))

    _ = try await client.search(query: "apple")

    let url = try #require(captured.get())
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let items =
      components?.queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
    #expect(items["q"] == "apple")
    #expect(items["quotesCount"] == "20")
    #expect(items["newsCount"] == "0")
  }
}
