// MoolahTests/Shared/CryptoPriceServiceCapTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Cap-at-yesterday rule for `CryptoPriceService`. See
/// `Shared/PriceCacheCap.swift` for the rationale and `Shared/
/// CryptoPriceService.swift` for the price-fetching path under test.
@Suite("CryptoPriceService — cap at yesterday")
struct CryptoPriceServiceCapTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )

  private func makeService(
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    database: DatabaseQueue? = nil,
    now: @Sendable @escaping () -> Date
  ) throws -> CryptoPriceService {
    let client = FixedCryptoPriceClient(prices: prices, shouldFail: shouldFail)
    let resolved = try database ?? ProfileIndexDatabase.openInMemory()
    // Pin to UTC so the `YYYY-MM-DD` labels in the fixtures below match
    // the cap's output regardless of the host machine's local zone.
    let utc = try #require(TimeZone(identifier: "UTC"))
    return CryptoPriceService(
      clients: [client],
      database: resolved,
      resolutionClient: nil,
      now: now,
      timeZone: utc)
  }

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  @Test
  func todayRequestRoutesToYesterday() async throws {
    let frozen = try self.date("2026-04-12")
    let service = try makeService(
      prices: ["1:native": ["2026-04-11": dec("1640.00")]],
      now: { frozen })
    let price = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: frozen)
    #expect(price == dec("1640.00"))
  }

  @Test
  func todayHitsCacheWithoutNetworkFetch() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = try self.date("2026-04-12")
    let writer = try makeService(
      prices: ["1:native": ["2026-04-11": dec("1640.00")]],
      database: database,
      now: { frozen })
    _ = try await writer.price(
      for: ethInstrument, mapping: ethMapping, on: try self.date("2026-04-11"))

    let reader = try makeService(
      shouldFail: true,
      database: database,
      now: { frozen })
    let price = try await reader.price(
      for: ethInstrument, mapping: ethMapping, on: frozen)
    #expect(price == dec("1640.00"))
  }

  @Test
  func forwardExtensionOverwritesStaleLatest() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let initial: [String: [String: Decimal]] = [
      "1:native": ["2026-04-11": dec("1640.00")]
    ]
    let revised: [String: [String: Decimal]] = [
      "1:native": [
        "2026-04-11": dec("1655.00"),
        "2026-04-13": dec("1670.00"),
        "2026-04-14": dec("1675.00"),
      ]
    ]

    let frozenInitial = try self.date("2026-04-12")
    let pre = try makeService(prices: initial, database: database, now: { frozenInitial })
    _ = try await pre.price(
      for: ethInstrument, mapping: ethMapping, on: try self.date("2026-04-11"))

    let frozenLater = try self.date("2026-04-15")
    let post = try makeService(prices: revised, database: database, now: { frozenLater })
    _ = try await post.price(
      for: ethInstrument, mapping: ethMapping, on: try self.date("2026-04-14"))

    let revisedAt11 = try await post.price(
      for: ethInstrument, mapping: ethMapping, on: try self.date("2026-04-11"))
    #expect(revisedAt11 == dec("1655.00"))
  }

  @Test
  func rangeEndingTodayCarriesForwardYesterday() async throws {
    let frozen = try self.date("2026-04-12")
    let service = try makeService(
      prices: [
        "1:native": [
          "2026-04-10": dec("1620.00"),
          "2026-04-11": dec("1640.00"),
        ]
      ],
      now: { frozen })
    let results = try await service.prices(
      for: ethInstrument, mapping: ethMapping,
      in: try self.date("2026-04-10")...frozen)
    #expect(results.count == 3)
    // Today carries forward yesterday's close, not an intraday tick.
    #expect(results.last?.price == dec("1640.00"))
  }
}
