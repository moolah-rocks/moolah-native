import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoPriceService.warmRange")
struct CryptoPriceServiceWarmRangeTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )

  private func makeService(
    clients: [CryptoPriceClient] = [],
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    database: DatabaseQueue? = nil,
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

  @Test("cooldown is surfaced with its deadline")
  func cooldownSurfaced() async throws {
    let deadline = date("2026-06-07")
    let client = FixedCryptoPriceClient(
      prices: [:], shouldFail: true,
      failureError: RateLimitGateError.cooldown(until: deadline),
      syncProvider: .binance)
    let service = try makeService(clients: [client], now: { self.date("2026-06-01") })
    let from = date("2026-01-01")
    let to = date("2026-05-31")

    let outcome = await service.warmRange(
      for: ethInstrument, mapping: ethMapping, in: from...to)

    #expect(outcome == .cooledDown(until: deadline))
  }

  @Test("a fillable range returns .filled and populates the cache")
  func fillableReturnsFilled() async throws {
    let prices = ["1:native": ["2026-01-01": dec("100"), "2026-01-02": dec("110")]]
    let database = try ProfileIndexDatabase.openInMemory()
    let service = try makeService(
      prices: prices, database: database, now: { self.date("2026-02-01") })
    let from = date("2026-01-01")
    let to = date("2026-01-02")

    let outcome = await service.warmRange(for: ethInstrument, mapping: ethMapping, in: from...to)
    #expect(outcome == .filled)

    // A fresh reader over the same DB now serves the cached price with no fetch.
    let reader = try makeService(
      clients: [FixedCryptoPriceClient(prices: [:], shouldFail: true)],
      database: database, now: { self.date("2026-02-01") })
    let price = try await reader.price(for: ethInstrument, mapping: ethMapping, on: from)
    #expect(price == dec("100"))
  }

  @Test("an already-cached range is a no-op (no extra fetch)")
  func idempotentNoRefetch() async throws {
    let inner = FixedCryptoPriceClient(
      prices: ["1:native": ["2026-01-01": dec("100"), "2026-01-02": dec("110")]])
    let counting = CountingCryptoPriceClient(inner)
    let database = try ProfileIndexDatabase.openInMemory()
    let service = try makeService(
      clients: [counting], database: database, now: { self.date("2026-02-01") })
    let range = date("2026-01-01")...date("2026-01-02")

    _ = await service.warmRange(for: ethInstrument, mapping: ethMapping, in: range)
    let afterFirst = counting.fetchCount
    let outcome = await service.warmRange(for: ethInstrument, mapping: ethMapping, in: range)

    #expect(outcome == .filled)
    #expect(counting.fetchCount == afterFirst)  // second warm fetched nothing
  }

  @Test("no provider data and no cooldown returns .unavailable")
  func emptyReturnsUnavailable() async throws {
    let client = FixedCryptoPriceClient(prices: [:])  // returns empty dict, no throw
    let service = try makeService(clients: [client], now: { self.date("2026-02-01") })
    let outcome = await service.warmRange(
      for: ethInstrument, mapping: ethMapping,
      in: date("2026-01-01")...date("2026-01-02"))
    #expect(outcome == .unavailable)
  }
}
