import Foundation
import Testing

@testable import Moolah

@Suite("API HTTP privacy")
struct APIHTTPSessionTests {
  @Test("API sessions cannot access or accept stored cookies")
  func cookiesAreDisabled() {
    let configuration = APIHTTPSession.shared.configuration
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.httpCookieAcceptPolicy == .never)
    #expect(!configuration.httpShouldSetCookies)
    #expect(NetworkingServices().underlyingSession === APIHTTPSession.shared)
  }

  @Test("A provider's Set-Cookie response is not replayed on later requests")
  func responseCookiesAreNotReplayed() async throws {
    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "https://cookie-test.invalid/api"))
    _ = try await session.data(from: url)
    let (data, _) = try await session.data(from: url)
    #expect(String(data: data, encoding: .utf8) == "no-cookie")
  }

  @Test("Cookie-free requests preserve bearer tokens and API keys")
  func explicitAuthenticationIsPreserved() async throws {
    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "https://cookie-test.invalid/auth?api_key=synthetic-key"))
    var request = URLRequest(url: url)
    request.setValue("Bearer synthetic-token", forHTTPHeaderField: "Authorization")
    let (data, _) = try await session.data(for: request)
    #expect(String(data: data, encoding: .utf8) == "Bearer synthetic-token|api_key=synthetic-key")
  }

  private func makeSession() -> URLSession {
    let configuration = APIHTTPSession.shared.configuration
    configuration.protocolClasses = [CookieResponseProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private final class CookieResponseProtocol: URLProtocol {
  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Set-Cookie": "tracking=synthetic; Path=/; Secure"])
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let body: String
    if url.path == "/auth" {
      body = "\(request.value(forHTTPHeaderField: "Authorization") ?? "missing")|\(url.query ?? "")"
    } else {
      body = request.value(forHTTPHeaderField: "Cookie") ?? "no-cookie"
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
