// MoolahTests/Shared/CryptoPriceServiceTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoPriceService")
struct CryptoPriceServiceTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    binanceSymbol: "ETHUSDT"
  )

  private let btcInstrument = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
  )
  private let btcMapping = CryptoProviderMapping(
    instrumentId: "0:native", coingeckoId: "bitcoin",
    binanceSymbol: "BTCUSDT"
  )

  private var ethRegistration: CryptoRegistration {
    CryptoRegistration(instrument: ethInstrument, mapping: ethMapping)
  }
  private var btcRegistration: CryptoRegistration {
    CryptoRegistration(instrument: btcInstrument, mapping: btcMapping)
  }

  private func makeService(
    clients: [CryptoPriceClient] = [],
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    database: DatabaseQueue? = nil,
    resolutionClient: (any TokenResolutionClient)? = nil,
    now: @Sendable @escaping () -> Date = { Date() }
  ) throws -> CryptoPriceService {
    let clientList =
      clients.isEmpty
      ? [FixedCryptoPriceClient(prices: prices, shouldFail: shouldFail)]
      : clients
    let resolved = try database ?? ProfileIndexDatabase.openInMemory()
    return CryptoPriceService(
      clients: clientList,
      database: resolved,
      resolutionClient: resolutionClient,
      now: now
    )
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let result = formatter.date(from: string) else {
      fatalError("Could not parse ISO8601 full-date string: \(string)")
    }
    return result
  }

  // MARK: - Cache miss and hit

  @Test
  func cacheMissFetchesFromClient() async throws {
    let service = try makeService(prices: [
      "1:native": ["2026-04-10": dec("1623.45")]
    ])
    let price = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    #expect(price == dec("1623.45"))
  }

  @Test
  func cacheHitDoesNotRefetch() async throws {
    let service = try makeService(prices: [
      "1:native": ["2026-04-10": dec("1623.45")]
    ])
    let first = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    let second = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    #expect(first == second)
  }

  // MARK: - Provider fallback

  @Test
  func firstClientFailsFallsToSecond() async throws {
    let failing = FixedCryptoPriceClient(shouldFail: true)
    let working = FixedCryptoPriceClient(prices: [
      "1:native": ["2026-04-10": dec("1623.45")]
    ])
    let service = try makeService(clients: [failing, working])
    let price = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    #expect(price == dec("1623.45"))
  }

  @Test
  func allClientsFail_fallsBackToCachedPriorDate() async throws {
    let working = FixedCryptoPriceClient(prices: [
      "1:native": ["2026-04-09": dec("1600.00")]
    ])
    let service = try makeService(clients: [working])
    _ = try await service.price(for: ethInstrument, mapping: ethMapping, on: date("2026-04-09"))

    // Request a later date — client has no data for it, triggering fallback
    let price = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    #expect(price == dec("1600.00"))
  }

  @Test
  func allClientsFailWithEmptyCacheThrows() async throws {
    let service = try makeService(shouldFail: true)
    await #expect(throws: (any Error).self) {
      try await service.price(
        for: self.ethInstrument, mapping: self.ethMapping, on: self.date("2026-04-10"))
    }
  }

  @Test
  func coldCacheMissingCurrentDateFallsBackToPriorDay() async throws {
    // Mirrors the stock-side cold-cache fix: when the provider has no data
    // for the requested date but does have data for prior days, a cold-start
    // lookup must populate cache with a wider window and fall back instead
    // of throwing.
    let working = FixedCryptoPriceClient(prices: [
      "1:native": ["2026-04-09": dec("1600.00")]  // 2026-04-10 deliberately absent
    ])
    let service = try makeService(clients: [working])
    let price = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    #expect(price == dec("1600.00"))
  }

  // MARK: - Fallback never uses future dates

  @Test
  func fallbackNeverUsesFutureDate() async throws {
    let working = FixedCryptoPriceClient(prices: [
      "1:native": ["2026-04-15": dec("1700.00")]
    ])
    let service = try makeService(clients: [working])
    _ = try await service.price(for: ethInstrument, mapping: ethMapping, on: date("2026-04-15"))

    await #expect(throws: (any Error).self) {
      try await service.price(
        for: self.ethInstrument, mapping: self.ethMapping, on: self.date("2026-04-10"))
    }
  }

  // MARK: - Date range

  @Test
  func rangeFetchReturnsPricesForEachDay() async throws {
    let service = try makeService(prices: [
      "1:native": [
        "2026-04-07": dec("1600.00"),
        "2026-04-08": dec("1610.00"),
        "2026-04-09": dec("1620.00"),
      ]
    ])
    let results = try await service.prices(
      for: ethInstrument, mapping: ethMapping, in: date("2026-04-07")...date("2026-04-09")
    )
    #expect(results.count == 3)
    #expect(results[0].price == dec("1600.00"))
    #expect(results[2].price == dec("1620.00"))
  }

  @Test
  func rangeFetchOnlyRequestsMissingSegments() async throws {
    let service = try makeService(prices: [
      "1:native": [
        "2026-04-07": dec("1600.00"),
        "2026-04-08": dec("1610.00"),
        "2026-04-09": dec("1620.00"),
        "2026-04-10": dec("1630.00"),
        "2026-04-11": dec("1640.00"),
      ]
    ])
    _ = try await service.prices(
      for: ethInstrument, mapping: ethMapping, in: date("2026-04-08")...date("2026-04-09"))
    let results = try await service.prices(
      for: ethInstrument, mapping: ethMapping, in: date("2026-04-07")...date("2026-04-11")
    )
    #expect(results.count == 5)
    #expect(results[0].price == dec("1600.00"))
    #expect(results[4].price == dec("1640.00"))
  }

  @Test
  func rangeFillsWeekendGapsWithLastKnownPrice() async throws {
    let service = try makeService(prices: [
      "1:native": [
        "2026-04-10": dec("1630.00")
      ]
    ])
    let results = try await service.prices(
      for: ethInstrument, mapping: ethMapping, in: date("2026-04-10")...date("2026-04-12")
    )
    #expect(results.count == 3)
    #expect(results[1].price == dec("1630.00"))
    #expect(results[2].price == dec("1630.00"))
  }

  // MARK: - Batch current prices

  @Test
  func currentPricesFetchesForAllMappings() async throws {
    let service = try makeService(prices: [
      "1:native": ["2026-04-11": dec("1640.00")],
      "0:native": ["2026-04-11": dec("67890.00")],
    ])
    let prices = try await service.currentPrices(for: [ethMapping, btcMapping])
    #expect(prices["1:native"] == dec("1640.00"))
    #expect(prices["0:native"] == dec("67890.00"))
  }

  // MARK: - purgeCache

  /// `purgeCache` clears both the in-memory entry and the SQL rows for the
  /// supplied instrument id. After purge a fresh service against the same
  /// database must throw when the network is unavailable, proving no row
  /// or meta entry survived.
  @Test("purgeCache removes the in-memory cache entry and SQL rows")
  func purgeCacheRemovesInMemoryAndSQL() async throws {
    let database = try ProfileIndexDatabase.openInMemory()

    let service = try makeService(
      prices: ["1:native": ["2026-04-10": dec("1623.45")]],
      database: database
    )

    _ = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))

    let beforeRows = try await database.read { database in
      try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == "1:native")
        .fetchCount(database)
    }
    #expect(beforeRows > 0)

    await service.purgeCache(instrumentId: ethInstrument.id)

    let afterRows = try await database.read { database in
      try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == "1:native")
        .fetchCount(database)
    }
    let afterMeta = try await database.read { database in
      try CryptoTokenMetaRecord
        .filter(CryptoTokenMetaRecord.Columns.tokenId == "1:native")
        .fetchCount(database)
    }
    #expect(afterRows == 0)
    #expect(afterMeta == 0)

    let freshService = try makeService(shouldFail: true, database: database)
    await #expect(throws: (any Error).self) {
      try await freshService.price(
        for: self.ethInstrument, mapping: self.ethMapping, on: self.date("2026-04-10"))
    }
  }

  // Rollback contract for `persistDelta` lives in `CryptoPriceServiceTestsMore.swift`
  // and cap-at-yesterday tests live in `CryptoPriceServiceCapTests.swift`.
}
