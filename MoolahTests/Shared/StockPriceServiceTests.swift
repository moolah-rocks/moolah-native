// MoolahTests/Shared/StockPriceServiceTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("StockPriceService")
struct StockPriceServiceTests {
  private func makeService(
    responses: [String: StockPriceResponse] = [:],
    shouldFail: Bool = false,
    database: DatabaseQueue? = nil,
    now: @Sendable @escaping () -> Date = { Date() }
  ) throws -> StockPriceService {
    let client = FixedStockPriceClient(responses: responses, shouldFail: shouldFail)
    let resolved = try database ?? ProfileIndexDatabase.openInMemory()
    // Pin to UTC so the `YYYY-MM-DD` labels in the fixtures below match the
    // cap's "yesterday" output regardless of the host machine's local zone.
    // (Mirrors `CryptoPriceServiceCapTests` / `ExchangeRateServiceCapTests`.)
    let utc = try #require(TimeZone(identifier: "UTC"))
    return StockPriceService(client: client, database: resolved, now: now, timeZone: utc)
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let result = formatter.date(from: string) else {
      fatalError("Could not parse ISO8601 full-date string: \(string)")
    }
    return result
  }

  private func bhpResponse() -> StockPriceResponse {
    StockPriceResponse(
      instrument: .AUD,
      prices: [
        "2026-04-07": dec("38.50"),
        "2026-04-08": dec("38.75"),
        "2026-04-09": dec("39.00"),
        "2026-04-10": dec("38.25"),
        "2026-04-11": dec("38.60"),
      ])
  }

  // MARK: - Cache miss and cache hit

  @Test
  func cacheMissFetchesFromClient() async throws {
    let service = try makeService(responses: ["BHP.AX": bhpResponse()])
    let price = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    #expect(price == dec("38.50"))
  }

  @Test
  func cacheHitDoesNotRefetch() async throws {
    let service = try makeService(responses: ["BHP.AX": bhpResponse()])
    let first = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    let second = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    #expect(first == second)
    #expect(first == dec("38.50"))
  }

  // MARK: - Currency discovery

  @Test
  func currencyDiscoveredFromFirstFetch() async throws {
    let service = try makeService(responses: ["BHP.AX": bhpResponse()])
    _ = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    let instrument = try await service.instrument(for: "BHP.AX")
    #expect(instrument == .AUD)
  }

  @Test
  func instrumentThrowsForUnknownTicker() async throws {
    let service = try makeService()
    await #expect(throws: (any Error).self) {
      try await service.instrument(for: "UNKNOWN.AX")
    }
  }

  // MARK: - Date fallback (weekends/holidays)

  @Test
  func weekendFallsBackToFriday() async throws {
    let service = try makeService(responses: ["BHP.AX": bhpResponse()])
    _ = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    let price = try await service.price(ticker: "BHP.AX", on: date("2026-04-12"))
    #expect(price == dec("38.60"))
  }

  @Test
  func fallbackNeverUsesFutureDate() async throws {
    let futureOnly = StockPriceResponse(
      instrument: .AUD,
      prices: [
        "2026-04-10": dec("38.25")
      ])
    let service = try makeService(responses: ["BHP.AX": futureOnly])
    _ = try await service.price(ticker: "BHP.AX", on: date("2026-04-10"))
    await #expect(throws: (any Error).self) {
      try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    }
  }

  // MARK: - Cold-cache non-trading-day fallback

  @Test
  func coldCacheNonTradingDayFallsBackToPriorTradingDay() async throws {
    // Reproduces the "Yahoo error 2 / noData" failure: opening the app on a
    // Sunday for an uncached ticker. The provider has no data for the
    // requested Sunday but has data for the prior trading day; the service
    // should populate cache with a wide cold-start window and fall back.
    let weekdayPrices = StockPriceResponse(
      instrument: .AUD,
      prices: [
        "2026-04-09": dec("39.00"),  // Thursday
        "2026-04-10": dec("38.25"),  // Friday — last trading day before request
        // Sat 2026-04-11 and Sun 2026-04-12 deliberately absent
      ]
    )
    let service = try makeService(responses: ["BHP.AX": weekdayPrices])
    let price = try await service.price(ticker: "BHP.AX", on: date("2026-04-12"))
    #expect(price == dec("38.25"))
  }

  // MARK: - Network failure

  @Test
  func networkFailureWithCacheReturnsCachedData() async throws {
    let database = try ProfileIndexDatabase.openInMemory()

    let service1 = try makeService(responses: ["BHP.AX": bhpResponse()], database: database)
    _ = try await service1.price(ticker: "BHP.AX", on: date("2026-04-07"))

    let service2 = try makeService(shouldFail: true, database: database)
    let price = try await service2.price(ticker: "BHP.AX", on: date("2026-04-07"))
    #expect(price == dec("38.50"))
  }

  @Test
  func networkFailureWithEmptyCacheThrows() async throws {
    let service = try makeService(shouldFail: true)
    await #expect(throws: (any Error).self) {
      try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    }
  }

  // MARK: - Date range lookup

  @Test
  func rangeReturnsOrderedPrices() async throws {
    let service = try makeService(responses: ["BHP.AX": bhpResponse()])
    let results = try await service.prices(
      ticker: "BHP.AX",
      in: date("2026-04-07")...date("2026-04-09")
    )
    #expect(results.count == 3)
    #expect(results[0].price == dec("38.50"))
    #expect(results[1].price == dec("38.75"))
    #expect(results[2].price == dec("39.00"))
  }

  @Test
  func rangeExpandsFetchForMissingDates() async throws {
    let service = try makeService(responses: ["BHP.AX": bhpResponse()])
    _ = try await service.prices(
      ticker: "BHP.AX",
      in: date("2026-04-08")...date("2026-04-09")
    )
    let results = try await service.prices(
      ticker: "BHP.AX",
      in: date("2026-04-07")...date("2026-04-11")
    )
    #expect(results.count == 5)
    #expect(results[0].price == dec("38.50"))
    #expect(results[4].price == dec("38.60"))
  }

  @Test
  func rangeFillsWeekendsWithLastKnownPrice() async throws {
    let service = try makeService(responses: ["BHP.AX": bhpResponse()])
    let results = try await service.prices(
      ticker: "BHP.AX",
      in: date("2026-04-10")...date("2026-04-12")
    )
    #expect(results.count == 3)
    #expect(results[0].price == dec("38.25"))
    #expect(results[1].price == dec("38.60"))
    #expect(results[2].price == dec("38.60"))
  }

  // SQL persistence tests (round-trip + rollback + delta-write contracts)
  // live in `StockPriceServicePersistenceTests`.

  // MARK: - Cap-at-yesterday rule

  @Test
  func todayRequestRoutesToYesterday() async throws {
    // Pin "today" at 2026-04-12 so "yesterday" is 2026-04-11. bhpResponse
    // has 2026-04-11 = 38.60. The request for "today" should fall back.
    let frozen = self.date("2026-04-12")
    let service = try makeService(
      responses: ["BHP.AX": bhpResponse()], now: { frozen })
    let price = try await service.price(ticker: "BHP.AX", on: frozen)
    #expect(price == dec("38.60"))
  }

  @Test
  func todayHitsCacheWithoutNetworkFetch() async throws {
    // Seed yesterday via a writeable client, then re-issue the same query
    // with a failing client — if the cap routes "today" to "yesterday" and
    // yesterday is in the cache, no fetch is needed.
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = self.date("2026-04-12")
    let writer = try makeService(
      responses: ["BHP.AX": bhpResponse()],
      database: database,
      now: { frozen })
    _ = try await writer.price(ticker: "BHP.AX", on: self.date("2026-04-11"))

    let reader = try makeService(
      shouldFail: true,
      database: database,
      now: { frozen })
    let price = try await reader.price(ticker: "BHP.AX", on: frozen)
    #expect(price == dec("38.60"))
  }

  @Test
  func forwardExtensionOverwritesStaleLatest() async throws {
    // First service caches a value for 2026-04-11; second returns a
    // *different* value for the same date. Asking for a later date should
    // trigger a forward extension that overlaps 2026-04-11 and overwrites.
    let database = try ProfileIndexDatabase.openInMemory()
    let initial = StockPriceResponse(
      instrument: .AUD,
      prices: ["2026-04-11": dec("38.60")])
    let revised = StockPriceResponse(
      instrument: .AUD,
      prices: [
        "2026-04-11": dec("38.99"),
        "2026-04-13": dec("39.10"),
        "2026-04-14": dec("39.20"),
      ])

    let frozenInitial = self.date("2026-04-12")
    let pre = try makeService(
      responses: ["BHP.AX": initial],
      database: database,
      now: { frozenInitial })
    _ = try await pre.price(ticker: "BHP.AX", on: self.date("2026-04-11"))

    let frozenLater = self.date("2026-04-15")
    let post = try makeService(
      responses: ["BHP.AX": revised],
      database: database,
      now: { frozenLater })
    _ = try await post.price(ticker: "BHP.AX", on: self.date("2026-04-14"))

    let revisedAt11 = try await post.price(ticker: "BHP.AX", on: self.date("2026-04-11"))
    #expect(revisedAt11 == dec("38.99"))
  }

  @Test
  func rangeEndingTodayCarriesForwardYesterday() async throws {
    let frozen = self.date("2026-04-12")
    let service = try makeService(
      responses: ["BHP.AX": bhpResponse()],
      now: { frozen })
    let results = try await service.prices(
      ticker: "BHP.AX",
      in: self.date("2026-04-10")...frozen)
    #expect(results.count == 3)
    #expect(results.last?.price == dec("38.60"))
  }

  // MARK: - Multiple tickers

  @Test
  func differentTickersAreCachedIndependently() async throws {
    let cbaResponse = StockPriceResponse(
      instrument: .AUD,
      prices: [
        "2026-04-07": dec("115.20")
      ])
    let service = try makeService(responses: [
      "BHP.AX": bhpResponse(),
      "CBA.AX": cbaResponse,
    ])
    let bhp = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
    let cba = try await service.price(ticker: "CBA.AX", on: date("2026-04-07"))
    #expect(bhp == dec("38.50"))
    #expect(cba == dec("115.20"))
  }
}
