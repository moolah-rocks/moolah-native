import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins `StablecoinPriceClient`'s role as the *last-resort* member of the
/// price-service provider chain: it fills a recognised stablecoin with $1 only
/// when every earlier provider declines, and is never consulted once an earlier
/// provider returns real data.
@Suite("CryptoPriceService — stablecoin peg fallback")
struct CryptoPriceServiceStablecoinTests {
  private let usdtInstrument = Instrument.crypto(
    chainId: 1, contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7",
    symbol: "USDT", name: "Tether", decimals: 6
  )
  private let usdtMapping = CryptoProviderMapping(
    instrumentId: "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
    coingeckoId: "tether", cryptocompareSymbol: "USDT", binanceSymbol: nil
  )

  private func makeService(
    clients: [CryptoPriceClient],
    database: DatabaseQueue,
    now: @Sendable @escaping () -> Date
  ) throws -> CryptoPriceService {
    let utc = try #require(TimeZone(identifier: "UTC"))
    return CryptoPriceService(
      clients: clients, database: database, resolutionClient: nil, now: now, timeZone: utc)
  }

  private func midnight(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  @Test("Peg fills a deep range when every earlier provider fails")
  func pegFillsRangeWhenProvidersFail() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = try midnight("2024-03-01")
    let failingStub = FixedCryptoPriceClient(
      shouldFail: true, failureError: URLError(.notConnectedToInternet),
      syncProvider: .cryptoCompare)
    let service = try makeService(
      clients: [failingStub, StablecoinPriceClient()], database: database, now: { frozen })

    let start = try midnight("2024-01-01")
    let end = try midnight("2024-01-05")
    let series = try await service.prices(
      for: usdtInstrument, mapping: usdtMapping, in: start...end)

    #expect(series.count == 5)
    #expect(series.allSatisfy { $0.price == Decimal(1) })
  }

  @Test("Peg is not consulted once an earlier provider returns real data")
  func pegNotConsultedWhenProviderReturnsData() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = try midnight("2024-03-01")
    let realStub = FixedCryptoPriceClient(
      prices: [
        "1:0xdac17f958d2ee523a2206206994597c13d831ec7": [
          "2024-01-01": dec("0.88"),
          "2024-01-02": dec("0.88"),
          "2024-01-03": dec("0.88"),
        ]
      ],
      syncProvider: .cryptoCompare)
    let service = try makeService(
      clients: [realStub, StablecoinPriceClient()], database: database, now: { frozen })

    let start = try midnight("2024-01-01")
    let end = try midnight("2024-01-03")
    let series = try await service.prices(
      for: usdtInstrument, mapping: usdtMapping, in: start...end)

    #expect(series.count == 3)
    #expect(series.allSatisfy { $0.price == dec("0.88") })
    #expect(series.allSatisfy { $0.price != Decimal(1) })
  }
}
