// MoolahTests/Shared/CryptoImport/AlchemyTestSupport.swift
import Foundation

@testable import Moolah

/// Sentinel URL used to construct synthetic HTTP responses without
/// force-unwrapping the request URL. `URL(fileURLWithPath:)` is total —
/// always returns a non-optional URL — so the helper avoids the
/// `force_unwrapping` lint while still producing a valid `HTTPURLResponse`.
enum AlchemyTestSupport {
  static let stubResponseURL = URL(fileURLWithPath: "/")

  /// Build a `LiveAlchemyClient` whose `URLSession` routes through the
  /// shared `AlchemyURLProtocolStub`. The handler closure controls every
  /// response; tests that only need a default response pass `.success(...)`.
  static func makeClient(
    apiKey: String = "test-key",
    permitsPerSecond: Double = 1_000,
    sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> LiveAlchemyClient {
    makeClient(
      apiKeyProvider: { apiKey },
      permitsPerSecond: permitsPerSecond,
      sleeper: sleeper,
      handler: handler)
  }

  /// Variant that takes a `@Sendable` closure provider so tests can mutate
  /// the returned key between calls (covering the key-set-after-launch
  /// case).
  static func makeClient(
    apiKeyProvider: @escaping @Sendable () -> String?,
    permitsPerSecond: Double = 1_000,
    sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> LiveAlchemyClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AlchemyURLProtocolStub.self]
    let session = URLSession(configuration: config)
    AlchemyURLProtocolStub.lastRequest = nil
    AlchemyURLProtocolStub.lastBodyJSON = [:]
    AlchemyURLProtocolStub.requestHandler = handler
    let limiter = RateLimiter(permitsPerSecond: permitsPerSecond)
    return LiveAlchemyClient(
      session: session,
      apiKeyProvider: apiKeyProvider,
      rateLimiter: limiter,
      sleeper: sleeper)
  }

  /// Build a 200 OK JSON response for the URL of an inbound request. The
  /// initialiser only fails on a malformed `httpVersion` — `"HTTP/1.1"` is a
  /// hardcoded literal, so a `nil` here would be a programmer error rather
  /// than a runtime failure. We surface it as a sentinel response built
  /// against `stubResponseURL` so tests stay deterministic on the unhappy
  /// path too.
  static func okResponse(for request: URLRequest) -> HTTPURLResponse {
    let url = request.url ?? stubResponseURL
    return HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    ) ?? fallbackResponse(statusCode: 200)
  }

  /// Build an arbitrary status response. See `okResponse(for:)` for why
  /// the initialiser is treated as total in practice.
  static func response(
    for request: URLRequest,
    statusCode: Int,
    headerFields: [String: String] = [:]
  ) -> HTTPURLResponse {
    let url = request.url ?? stubResponseURL
    return HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headerFields
    ) ?? fallbackResponse(statusCode: statusCode)
  }

  /// Defensive fallback if the optional `HTTPURLResponse` initialiser
  /// somehow fails — `URLResponse()` always succeeds and is downcastable.
  private static func fallbackResponse(statusCode: Int) -> HTTPURLResponse {
    // `HTTPURLResponse` instances built directly via `init()` lack a
    // status code, but `URLProtocol` clients only inspect `statusCode`
    // through the `HTTPURLResponse` accessor — so an out-of-band response
    // here would just look like a 0-status network failure. That's
    // acceptable for the "this should never happen" branch.
    HTTPURLResponse()
  }

  /// Loads a fixture file from the test bundle as `Data`. Throws an
  /// explicit `FixtureMissing` error rather than `fatalError` so the
  /// failing test fails cleanly with a useful message.
  static func loadFixture(_ name: String) throws -> Data {
    guard
      let url = Bundle(for: TestBundleMarker.self)
        .url(forResource: name, withExtension: "json")
    else {
      throw FixtureMissing(name: name)
    }
    return try Data(contentsOf: url)
  }

  struct FixtureMissing: Error { let name: String }
}

/// `URLProtocol` stub local to the `LiveAlchemyClient` suite — the existing
/// `URLProtocolStub` in `YahooFinanceClientTests` is module-private to that
/// file, so this stub is an isolated copy with its own static handler state.
class AlchemyURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
  nonisolated(unsafe) static var lastRequest: URLRequest?
  /// Decoded body of the most recent captured request — empty when no
  /// request has been captured yet, or when the body was non-JSON.
  /// Initialised to an empty dictionary rather than `nil` because
  /// SwiftLint disallows optional collections; tests assert on contents
  /// or on `isEmpty`, which is sufficient.
  nonisolated(unsafe) static var lastBodyJSON: [String: Any] = [:]

  /// Records the request that was just received and decodes its body
  /// (whether streamed or in-memory) into a JSON dictionary for later
  /// assertions. Tests opt-in by calling this from their handler closure.
  static func captureRequest(_ request: URLRequest) {
    lastRequest = request
    if let stream = request.httpBodyStream {
      lastBodyJSON = decodeBodyStream(stream)
    } else if let body = request.httpBody {
      lastBodyJSON = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    } else {
      lastBodyJSON = [:]
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = AlchemyURLProtocolStub.requestHandler else {
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

  private static func decodeBodyStream(_ stream: InputStream) -> [String: Any] {
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: bufferSize)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }
}

/// Records each captured request body as a deserialised dictionary so
/// tests can assert on the two-pass query shape across calls. Reference
/// type so the closure-captured stub can mutate it; lock-protected to
/// satisfy `Sendable`.
final class TestCallRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var bodies: [[String: Any]] = []

  func record(request: URLRequest) {
    lock.lock()
    defer { lock.unlock() }
    if let stream = request.httpBodyStream {
      bodies.append(decodeJSON(from: readAll(stream: stream)))
    } else if let data = request.httpBody {
      bodies.append(decodeJSON(from: data))
    } else {
      // Bodyless request (e.g. GET) — record an empty dict so captured.count reflects total requests.
      bodies.append([:])
    }
  }

  var captured: [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    return bodies
  }

  private func decodeJSON(from data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  private func readAll(stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: bufferSize)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
