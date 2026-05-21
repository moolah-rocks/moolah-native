import Foundation
import Testing

@testable import Moolah

@Suite("YahooFinanceClient")
struct YahooFinanceClientTests {
  private func loadFixture(_ name: String) throws -> Data {
    guard
      let url = Bundle(for: TestBundleMarker.self)
        .url(forResource: name, withExtension: "json")
    else {
      fatalError("Could not find \(name).json fixture")
    }
    return try Data(contentsOf: url)
  }

  private func makeClient(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> (YahooFinanceClient, URLSession) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let services = NetworkingServices(session: session)
    let client = YahooFinanceClient(
      http: services.client(forHost: "query2.finance.yahoo.com"))
    URLProtocolStub.lastRequest = nil
    URLProtocolStub.requestHandler = handler
    return (client, session)
  }

  private func stubResponse(
    for request: URLRequest,
    statusCode: Int,
    headerFields: [String: String] = [:]
  ) throws -> HTTPURLResponse {
    let requestURL = try #require(request.url)
    return try #require(
      HTTPURLResponse(
        url: requestURL, statusCode: statusCode, httpVersion: nil,
        headerFields: headerFields))
  }

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  @Test
  func requestURLContainsTickerAndDateRange() async throws {
    let fixtureData = try loadFixture("yahoo-finance-chart-response")

    let (client, _) = makeClient { request in
      URLProtocolStub.lastRequest = request
      let requestURL = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(
          url: requestURL, statusCode: 200, httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]))
      return (response, fixtureData)
    }

    _ = try await client.fetchDailyPrices(
      ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))

    let url = try #require(URLProtocolStub.lastRequest?.url)
    #expect(url.path().contains("BHP.AX"))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = components.queryItems ?? []
    #expect(queryItems.contains { $0.name == "interval" && $0.value == "1d" })
    #expect(queryItems.contains { $0.name == "period1" })
    #expect(queryItems.contains { $0.name == "period2" })
  }

  @Test
  func requestIncludesUserAgentHeader() async throws {
    let fixtureData = try loadFixture("yahoo-finance-chart-response")

    let (client, _) = makeClient { request in
      URLProtocolStub.lastRequest = request
      let requestURL = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(
          url: requestURL, statusCode: 200, httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]))
      return (response, fixtureData)
    }

    _ = try await client.fetchDailyPrices(
      ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))

    let lastRequest = try #require(URLProtocolStub.lastRequest)
    let userAgent = lastRequest.value(forHTTPHeaderField: "User-Agent")
    #expect(userAgent != nil)
    #expect(try #require(userAgent).isEmpty == false)
  }

  @Test
  func parsesAdjustedCloseAndCurrency() async throws {
    let fixtureData = try loadFixture("yahoo-finance-chart-response")

    let (client, _) = makeClient { request in
      let response = try stubResponse(
        for: request, statusCode: 200,
        headerFields: ["Content-Type": "application/json"])
      return (response, fixtureData)
    }

    let result = try await client.fetchDailyPrices(
      ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))

    #expect(result.instrument == .AUD)
    // Two entries (third has null adjclose and should be skipped)
    #expect(result.prices.count == 2)
    #expect(result.prices["2022-04-05"] == dec("37.80"))
    #expect(result.prices["2022-04-06"] == dec("38.10"))
  }

  @Test
  func skipsNullAdjcloseValues() async throws {
    let fixtureData = try loadFixture("yahoo-finance-chart-response")

    let (client, _) = makeClient { request in
      let response = try stubResponse(
        for: request, statusCode: 200,
        headerFields: ["Content-Type": "application/json"])
      return (response, fixtureData)
    }

    let result = try await client.fetchDailyPrices(
      ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))

    // Third timestamp has null adjclose — should not appear
    #expect(result.prices["2022-04-07"] == nil)
  }

  @Test
  func errorResponseThrows() async throws {
    let fixtureData = try loadFixture("yahoo-finance-error-response")

    let (client, _) = makeClient { request in
      let response = try stubResponse(
        for: request, statusCode: 200,
        headerFields: ["Content-Type": "application/json"])
      return (response, fixtureData)
    }

    await #expect(throws: (any Error).self) {
      try await client.fetchDailyPrices(
        ticker: "INVALID.AX", from: date("2022-04-05"), to: date("2022-04-07"))
    }
  }

  @Test
  func httpErrorThrows() async throws {
    let (client, _) = makeClient { request in
      let response = try stubResponse(for: request, statusCode: 404)
      return (response, Data())
    }

    await #expect(throws: (any Error).self) {
      try await client.fetchDailyPrices(
        ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))
    }
  }
}

// MARK: - URLProtocol stub (same pattern as RemoteAccountRepositoryTests)

private class URLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
  nonisolated(unsafe) static var lastRequest: URLRequest?

  static func register() {
    URLProtocol.registerClass(URLProtocolStub.self)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = URLProtocolStub.requestHandler else {
      fatalError("Handler is not set.")
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
