import Foundation
import Testing

@testable import Moolah

/// Class-based suite so `deinit` can deterministically clean up the per-test
/// temp directory and the shared `StubURLProtocol` handlers map. Each `@Test`
/// instantiates a fresh suite, so handlers don't leak across tests.
@Suite("CatalogRefresh", .serialized)
final class CatalogRefreshTests {
  private let tempDir: URL

  init() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("catalog-refresh-\(UUID().uuidString)", isDirectory: true)
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

  private func makeDatabase() throws -> CatalogDatabase {
    let dbURL = tempDir.appendingPathComponent("catalog.sqlite")
    return try CatalogDatabase.open(
      dbURL: dbURL,
      schemaVersion: 1,
      schemaStatements: CatalogDatabase.baseSchemaStatements(schemaVersion: 1)
    )
  }

  /// A real reachable endpoint served by `StubURLProtocol` keyed on
  /// `<host>:<path>`.
  private func stubEndpoint(host: String, path: String, key: String) -> CatalogEndpoint {
    guard let url = URL(string: "https://\(host)\(path)") else {
      fatalError("invalid stub URL")
    }
    return CatalogEndpoint(key: key, url: url)
  }

  @Test
  func fetchPopulatesApplyAndPersistsEtag() async throws {
    let endpoint = stubEndpoint(host: "example.test", path: "/coins", key: "coins")
    let body = Data("[1,2,3]".utf8)
    StubURLProtocol.handlers["example.test:/coins"] = { _ in
      (HTTPURLResponse.ok(etag: "v1"), body)
    }

    let database = try makeDatabase()
    let http = makeNetworking().client(forHost: "example.test")
    let now = Date()
    let applied = LockedBox<Bool>(false)
    let captured = LockedBox<[String: Data]>([:])

    try await CatalogRefresh.run(
      database: database,
      endpoints: [endpoint],
      http: http,
      now: now
    ) { bodies in
      applied.set(true)
      captured.set(bodies)
    }

    #expect(applied.get())
    #expect(captured.get()[endpoint.key] == body)
    #expect(database.readEtag(key: endpoint.key) == "v1")
    let lastFetched = try #require(database.readLastFetched())
    #expect(abs(lastFetched.timeIntervalSince(now)) < 1)
  }

  @Test
  func withinMaxAgePerformsNoNetworkAndNoApply() async throws {
    let endpoint = stubEndpoint(host: "example.test", path: "/coins", key: "coins")
    let callCount = LockedBox<Int>(0)
    StubURLProtocol.handlers["example.test:/coins"] = { _ in
      callCount.set(callCount.get() + 1)
      return (HTTPURLResponse.ok(etag: "v1"), Data("[]".utf8))
    }

    let database = try makeDatabase()
    let http = makeNetworking().client(forHost: "example.test")
    let now = Date()
    try database.writeLastFetched(now)

    let appliedCount = LockedBox<Int>(0)
    try await CatalogRefresh.run(
      database: database,
      endpoints: [endpoint],
      http: http,
      now: now.addingTimeInterval(60)
    ) { _ in
      appliedCount.set(appliedCount.get() + 1)
    }

    #expect(callCount.get() == 0)
    #expect(appliedCount.get() == 0)
  }

  @Test
  func notModifiedBumpsLastFetchedAndKeepsEtag() async throws {
    let endpoint = stubEndpoint(host: "example.test", path: "/coins", key: "coins")
    StubURLProtocol.handlers["example.test:/coins"] = { _ in
      (HTTPURLResponse.notModified(), Data())
    }

    let database = try makeDatabase()
    try database.writeEtag(key: endpoint.key, value: "seed")
    let http = makeNetworking().client(forHost: "example.test")
    let now = Date()
    let applied = LockedBox<Bool>(false)
    let captured = LockedBox<[String: Data]>([:])

    try await CatalogRefresh.run(
      database: database,
      endpoints: [endpoint],
      http: http,
      now: now
    ) { bodies in
      applied.set(true)
      captured.set(bodies)
    }

    #expect(applied.get())
    #expect(captured.get()[endpoint.key] == nil)
    #expect(database.readEtag(key: endpoint.key) == "seed")
    let lastFetched = try #require(database.readLastFetched())
    #expect(abs(lastFetched.timeIntervalSince(now)) < 1)
  }

  @Test
  func errorPropagatesAndLeavesLastFetchedUntouched() async throws {
    let endpoint = stubEndpoint(host: "example.test", path: "/coins", key: "coins")
    StubURLProtocol.handlers["example.test:/coins"] = { _ in
      (HTTPURLResponse.serverError(), Data())
    }

    let database = try makeDatabase()
    let priorFetch = Date(timeIntervalSince1970: 1_000_000)
    try database.writeLastFetched(priorFetch)
    let http = makeNetworking().client(forHost: "example.test")
    let applyCalled = LockedBox<Bool>(false)

    await #expect(throws: (any Error).self) {
      try await CatalogRefresh.run(
        database: database,
        endpoints: [endpoint],
        http: http,
        now: priorFetch.addingTimeInterval(48 * 3600)
      ) { _ in
        applyCalled.set(true)
      }
    }

    #expect(applyCalled.get() == false)
    let lastFetched = try #require(database.readLastFetched())
    #expect(abs(lastFetched.timeIntervalSince(priorFetch)) < 1)
  }
}

extension HTTPURLResponse {
  // swiftlint:disable force_unwrapping
  // `HTTPURLResponse(url:statusCode:httpVersion:headerFields:)` only fails on
  // a malformed `httpVersion`, and `"HTTP/1.1"` is a hardcoded literal, so the
  // force-unwrap is provably safe — same justification as the `ok`/
  // `notModified` helpers in `StubURLProtocol`.

  /// 500 Internal Server Error for the error-propagation path.
  static func serverError() -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(fileURLWithPath: "/"),
      statusCode: 500,
      httpVersion: "HTTP/1.1",
      headerFields: [:]
    )!
  }
  // swiftlint:enable force_unwrapping
}
