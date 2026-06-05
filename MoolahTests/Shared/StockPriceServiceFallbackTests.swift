// MoolahTests/Shared/StockPriceServiceFallbackTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Behavior-preserving pin for the `StockPriceService` fallback semantics
/// (exact / gap-to-prior-trading-day / post-latest / pre-history-throws).
/// Mirrors the `StockPriceServiceTests` harness (`FixedStockPriceClient` +
/// `ProfileIndexDatabase.openInMemory()`); the plan's inline stub returned
/// the whole series regardless of range, but the real test double
/// range-filters like Yahoo does, so it is the more faithful pin.
@Suite("StockPriceService fallback semantics")
struct StockPriceServiceFallbackTests {
  nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withFullDate]
    return fmt
  }()

  /// Non-throwing parse used for the pinned `now` clock. The ISO literals
  /// here are compile-time constants; a `nil` is a programmer error.
  private static func parse(_ iso: String) -> Date {
    guard let result = isoFormatter.date(from: iso) else {
      preconditionFailure("Invalid ISO date literal: \(iso)")
    }
    return result
  }

  private func date(_ iso: String) throws -> Date {
    try #require(Self.isoFormatter.date(from: iso))
  }

  private func makeService(_ prices: [String: Decimal]) throws -> StockPriceService {
    let database = try ProfileIndexDatabase.openInMemory()
    let client = FixedStockPriceClient(
      responses: ["BHP.AX": StockPriceResponse(instrument: .AUD, prices: prices)]
    )
    // Pin to UTC so the cap's "yesterday" boundary is computed against the
    // same calendar the `YYYY-MM-DD` fixtures use, regardless of host zone.
    let utc = try #require(TimeZone(identifier: "UTC"))
    return StockPriceService(
      client: client,
      database: database,
      now: { Self.parse("2024-02-01") },
      timeZone: utc
    )
  }

  @Test("exact, gap (prior trading day), and post-latest all resolve")
  func behaviorMatrix() async throws {
    let svc = try makeService([
      "2024-01-15": dec("10"),
      "2024-01-16": dec("11"),
      "2024-01-17": dec("12"),
    ])
    _ = try await svc.price(ticker: "BHP.AX", on: try date("2024-01-17"))  // seed
    let exact = try await svc.price(ticker: "BHP.AX", on: try date("2024-01-16"))
    #expect(exact == dec("11"))  // exact
    let gap = try await svc.price(ticker: "BHP.AX", on: try date("2024-01-20"))
    #expect(gap == dec("12"))  // gap (prior trading day)
    let postLatest = try await svc.price(ticker: "BHP.AX", on: try date("2024-01-31"))
    #expect(postLatest == dec("12"))  // post-latest
  }

  @Test("pre-history date has no fallback")
  func preHistory() async throws {
    let svc = try makeService(["2024-01-15": dec("10")])
    _ = try await svc.price(ticker: "BHP.AX", on: try date("2024-01-15"))
    let preHistoryDate = try date("2024-01-01")
    await #expect(throws: (any Error).self) {
      _ = try await svc.price(ticker: "BHP.AX", on: preHistoryDate)
    }
  }
}
