import Foundation
import Testing

@testable import Moolah

@Suite("DefiLlamaSupportCache", .serialized)
final class DefiLlamaSupportCacheTests {
  private let tempDir: URL

  init() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dl-support-\(UUID().uuidString)", isDirectory: true)
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

  private func makeCache() throws -> DefiLlamaSupportCache {
    try DefiLlamaSupportCache.make(directory: tempDir, networking: makeNetworking())
  }

  @Test("upsert then read returns the stored support row")
  func upsertRead() async throws {
    let cache = try makeCache()
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    await cache.upsert(
      instrumentId: "1:0xabc", supported: true, earliestDate: "2020-01-01", lastChecked: when)
    let row = await cache.support(for: "1:0xabc")
    #expect(row == DefiLlamaSupport(supported: true, earliestDate: "2020-01-01", lastChecked: when))
  }

  @Test("absent token reads nil")
  func absentNil() async throws {
    let cache = try makeCache()
    #expect(await cache.support(for: "1:0xmissing") == nil)
  }

  @Test("upsert overwrites an existing row")
  func upsertOverwrites() async throws {
    let cache = try makeCache()
    await cache.upsert(
      instrumentId: "1:0xabc", supported: false, earliestDate: nil,
      lastChecked: Date(timeIntervalSince1970: 1))
    let later = Date(timeIntervalSince1970: 2)
    await cache.upsert(
      instrumentId: "1:0xabc", supported: true, earliestDate: "2021-06-01", lastChecked: later)
    let row = await cache.support(for: "1:0xabc")
    #expect(row?.supported == true)
    #expect(row?.earliestDate == "2021-06-01")
    #expect(row?.lastChecked == later)
  }

  @Test("schema version bump drops and recreates the file")
  func schemaBumpRecreates() async throws {
    let networking = makeNetworking()
    let dbURL = tempDir.appendingPathComponent("defillama-support.sqlite")
    // Write a v0-shaped meta so the real schema version mismatches and triggers
    // drop-and-recreate. Open the real cache and confirm it starts empty.
    let stale = try CatalogDatabase.open(
      dbURL: dbURL, schemaVersion: 0,
      schemaStatements: CatalogDatabase.baseSchemaStatements(schemaVersion: 0))
    stale.close()
    let cache = try DefiLlamaSupportCache.make(directory: tempDir, networking: networking)
    #expect(await cache.support(for: "1:0xabc") == nil)
  }
}
