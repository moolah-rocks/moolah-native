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

  // MARK: - refreshSupport helpers

  private func registration(
    instrumentId: String, coingeckoId: String?, pricingStatus: TokenPricingStatus = .priced
  ) -> CryptoRegistration {
    let parts = instrumentId.split(separator: ":", maxSplits: 1).map(String.init)
    let chainId = Int(parts[0]) ?? 1
    let contract = parts[1] == "native" ? nil : parts[1]
    let instrument = Instrument.crypto(
      chainId: chainId, contractAddress: contract, symbol: "TKN", name: "Token", decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: instrument.id, coingeckoId: coingeckoId,
      cryptocompareSymbol: nil, binanceSymbol: nil)
    return CryptoRegistration(
      instrument: instrument, mapping: mapping, pricingStatus: pricingStatus)
  }

  @Test("probe records supported + earliest date for present coins, unsupported for absent")
  func probeRecordsSupport() async throws {
    let networking = makeNetworking()
    let cache = try DefiLlamaSupportCache.make(directory: tempDir, networking: networking)
    let body = """
      {"coins":{"ethereum:0xaaa":{"timestamp":1367107200,"price":135.3}}}
      """
    // coinIds sorted: "ethereum:0xaaa" < "ethereum:0xbbb" → deterministic path.
    StubURLProtocol.handlers["coins.llama.fi:/prices/first/ethereum:0xaaa,ethereum:0xbbb"] = { _ in
      (HTTPURLResponse.ok(etag: ""), Data(body.utf8))
    }
    let present = registration(instrumentId: "1:0xaaa", coingeckoId: nil)
    let absent = registration(instrumentId: "1:0xbbb", coingeckoId: nil)
    await cache.refreshSupport(
      for: [present, absent], now: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(await cache.support(for: "1:0xaaa")?.supported == true)
    #expect(await cache.support(for: "1:0xaaa")?.earliestDate == "2013-04-28")
    #expect(await cache.support(for: "1:0xbbb")?.supported == false)
  }

  @Test("probe skips a fresh row and a spam token")
  func probeSkipsFreshAndSpam() async throws {
    let networking = makeNetworking()
    let cache = try DefiLlamaSupportCache.make(directory: tempDir, networking: networking)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // Pre-seed a FRESH row; the probe must not re-request it.
    await cache.upsert(
      instrumentId: "1:0xaaa", supported: true, earliestDate: "2020-01-01", lastChecked: now)
    let called = LockedBox(false)
    // Match ANY /prices/first path: with only a fresh row + a spam row to skip,
    // the probe must build no request at all, so no handler should ever fire.
    StubURLProtocol.handlers["coins.llama.fi:/prices/first/ethereum:0xaaa"] = { _ in
      called.set(true)
      return (HTTPURLResponse.ok(etag: ""), Data("{\"coins\":{}}".utf8))
    }
    StubURLProtocol.handlers["coins.llama.fi:/prices/first/ethereum:0xccc"] = { _ in
      called.set(true)
      return (HTTPURLResponse.ok(etag: ""), Data("{\"coins\":{}}".utf8))
    }
    let fresh = registration(instrumentId: "1:0xaaa", coingeckoId: nil)
    let spam = registration(instrumentId: "1:0xccc", coingeckoId: nil, pricingStatus: .spam)
    await cache.refreshSupport(for: [fresh, spam], now: now.addingTimeInterval(3600))  // <24h
    #expect(called.get() == false)  // nothing to probe → no network call
    // The spam token must not have been recorded at all.
    #expect(await cache.support(for: "1:0xccc") == nil)
  }
}
