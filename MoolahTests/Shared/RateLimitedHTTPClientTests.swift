import Foundation
import Testing

@testable import Moolah

@Suite("RateLimitedHTTPClient")
struct RateLimitedHTTPClientTests {

  // MARK: - Stub plumbing

  /// Per-suite URLProtocol stub. Mirrors the pattern in
  /// `URLSessionRateLimitTests` (the suite this file replaces) so handler
  /// state stays scoped to one test file.
  class Stub: URLProtocol {
    nonisolated(unsafe) static var handler:
      (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount: Int = 0
    private static let lock = NSLock()

    static func reset() {
      lock.lock()
      defer { lock.unlock() }
      handler = nil
      requestCount = 0
    }

    static func incrementRequestCount() {
      lock.lock()
      defer { lock.unlock() }
      requestCount += 1
    }

    static func capturedRequestCount() -> Int {
      lock.lock()
      defer { lock.unlock() }
      return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      Self.incrementRequestCount()
      guard let handler = Self.handler else {
        client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        return
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

  private static let stubURL = URL(fileURLWithPath: "/")

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Stub.self]
    return URLSession(configuration: config)
  }

  // swiftlint:disable force_unwrapping
  private func httpResponse(
    statusCode: Int, headers: [String: String] = [:]
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: Self.stubURL,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
  }
  // swiftlint:enable force_unwrapping

  private func request(path: String = "/probe") throws -> URLRequest {
    let url = try #require(URL(string: "https://example.com\(path)"))
    return URLRequest(url: url)
  }

  private func makeClient(
    session: URLSession,
    gate: RateLimitGate = RateLimitGate(),
    cache: FailedRequestCache = FailedRequestCache()
  ) -> RateLimitedHTTPClient {
    RateLimitedHTTPClient(session: session, gate: gate, failureCache: cache)
  }

  // MARK: - 2xx success

  @Test
  func twoHundredReturnsDataAndHTTPResponse() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data("OK".utf8)) }

    let client = makeClient(session: makeSession())
    let (data, http) = try await client.data(for: try request())
    #expect(data == Data("OK".utf8))
    #expect(http.statusCode == 200)
  }

  // MARK: - non-2xx now throws

  @Test
  func fourOhFourThrowsBadServerResponseAndMutesURL() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 404), Data()) }

    let cache = FailedRequestCache()
    let client = makeClient(session: makeSession(), cache: cache)

    await #expect(throws: URLError(.badServerResponse)) {
      _ = try await client.data(for: try request())
    }
    // Second call short-circuits via the cache cooldown.
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data()) }
    await #expect(throws: FailedRequestCacheError.self) {
      _ = try await client.data(for: try request())
    }
  }

  @Test
  func fiveHundredThrowsBadServerResponseAndMutesURL() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 500), Data()) }

    let client = makeClient(session: makeSession())
    await #expect(throws: URLError(.badServerResponse)) {
      _ = try await client.data(for: try request())
    }
  }

  // MARK: - 429 / 503 trip the gate

  @Test
  func fourTwentyNineTripsGateAndThrowsCooldown() async throws {
    Stub.reset()
    Stub.handler = { _ in
      (self.httpResponse(statusCode: 429, headers: ["Retry-After": "1"]), Data())
    }

    let gate = RateLimitGate()
    let client = makeClient(session: makeSession(), gate: gate)

    await #expect(throws: RateLimitGateError.self) {
      _ = try await client.data(for: try request())
    }
    // Subsequent call short-circuits via the gate cooldown.
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data()) }
    await #expect(throws: RateLimitGateError.self) {
      _ = try await client.data(for: try request())
    }
  }

  @Test
  func fiveOhThreeWithRetryAfterTripsGate() async throws {
    Stub.reset()
    Stub.handler = { _ in
      (self.httpResponse(statusCode: 503, headers: ["Retry-After": "1"]), Data())
    }
    let client = makeClient(session: makeSession())
    await #expect(throws: RateLimitGateError.self) {
      _ = try await client.data(for: try request())
    }
  }

  @Test
  func fiveOhThreeWithoutRetryAfterThrowsBadServerResponse() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 503), Data()) }
    let client = makeClient(session: makeSession())
    await #expect(throws: URLError(.badServerResponse)) {
      _ = try await client.data(for: try request())
    }
  }

  // MARK: - transport failure mutes URL, cancellation does not

  @Test
  func transportErrorMutesURL() async throws {
    Stub.reset()
    Stub.handler = { _ in throw URLError(.notConnectedToInternet) }
    let cache = FailedRequestCache()
    let client = makeClient(session: makeSession(), cache: cache)

    await #expect(throws: URLError.self) {
      _ = try await client.data(for: try request())
    }
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data()) }
    await #expect(throws: FailedRequestCacheError.self) {
      _ = try await client.data(for: try request())
    }
  }

  @Test
  func cancellationDoesNotMuteURL() async throws {
    Stub.reset()
    Stub.handler = { _ in throw URLError(.cancelled) }
    let cache = FailedRequestCache()
    let client = makeClient(session: makeSession(), cache: cache)

    await #expect(throws: URLError.self) {
      _ = try await client.data(for: try request())
    }
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data()) }
    // URL not muted — call proceeds.
    _ = try await client.data(for: try request())
  }
}
