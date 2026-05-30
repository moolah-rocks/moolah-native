// MoolahTests/Shared/ExchangeRateServiceCapTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Cap-at-yesterday rule for `ExchangeRateService`. See
/// `Shared/PriceCacheCap.swift` for the rationale and `Shared/
/// ExchangeRateService.swift` for the rate-fetching path under test.
@Suite("ExchangeRateService — cap at yesterday")
struct ExchangeRateServiceCapTests {
  private func makeService(
    rates: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    database: DatabaseQueue? = nil,
    now: @Sendable @escaping () -> Date
  ) throws -> ExchangeRateService {
    let client = FixedRateClient(rates: rates, shouldFail: shouldFail)
    let resolved = try database ?? ProfileIndexDatabase.openInMemory()
    // Pin to UTC so the `YYYY-MM-DD` labels in the fixtures below match
    // the cap's output regardless of the host machine's local zone.
    let utc = try #require(TimeZone(identifier: "UTC"))
    return ExchangeRateService(
      client: client, database: resolved, now: now, timeZone: utc)
  }

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  @Test
  func todayRequestRoutesToYesterday() async throws {
    let frozen = try self.date("2025-01-20")
    let service = try makeService(
      rates: ["2025-01-19": ["USD": dec("0.6510")]],
      now: { frozen })
    let rate = try await service.rate(from: .AUD, to: .USD, on: frozen)
    #expect(rate == dec("0.6510"))
  }

  @Test
  func todayHitsCacheWithoutNetworkFetch() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = try self.date("2025-01-20")
    let writer = try makeService(
      rates: ["2025-01-19": ["USD": dec("0.6510")]],
      database: database,
      now: { frozen })
    _ = try await writer.rate(from: .AUD, to: .USD, on: try self.date("2025-01-19"))

    let reader = try makeService(
      shouldFail: true,
      database: database,
      now: { frozen })
    let rate = try await reader.rate(from: .AUD, to: .USD, on: frozen)
    #expect(rate == dec("0.6510"))
  }

  @Test
  func forwardExtensionOverwritesStaleLatest() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let initial: [String: [String: Decimal]] = ["2025-01-17": ["USD": dec("0.6500")]]
    let revised: [String: [String: Decimal]] = [
      "2025-01-17": ["USD": dec("0.6555")],
      "2025-01-18": ["USD": dec("0.6560")],
      "2025-01-19": ["USD": dec("0.6570")],
    ]

    let frozenInitial = try self.date("2025-01-18")
    let pre = try makeService(rates: initial, database: database, now: { frozenInitial })
    _ = try await pre.rate(from: .AUD, to: .USD, on: try self.date("2025-01-17"))

    let frozenLater = try self.date("2025-01-20")
    let post = try makeService(rates: revised, database: database, now: { frozenLater })
    _ = try await post.rate(from: .AUD, to: .USD, on: try self.date("2025-01-19"))

    let revisedAt17 = try await post.rate(
      from: .AUD, to: .USD, on: try self.date("2025-01-17"))
    #expect(revisedAt17 == dec("0.6555"))
  }

  @Test
  func rangeEndingTodayCarriesForwardYesterday() async throws {
    let frozen = try self.date("2025-01-20")
    let service = try makeService(
      rates: [
        "2025-01-17": ["USD": dec("0.6500")],
        "2025-01-19": ["USD": dec("0.6510")],
      ],
      now: { frozen })
    let results = try await service.rates(
      from: .AUD, to: .USD,
      in: try self.date("2025-01-17")...frozen)
    #expect(results.count == 4)
    #expect(results.last?.rate == dec("0.6510"))
  }
}
