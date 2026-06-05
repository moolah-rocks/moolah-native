// MoolahTests/Shared/CryptoPriceServiceFallbackTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Behavior-preserving pin for the `CryptoPriceService` fallback semantics
/// (exact / in-range gap-to-prior-day / post-latest / pre-history-throws).
/// Mirrors the `CryptoPriceServiceCapTests` harness (`FixedCryptoPriceClient`
/// + `ProfileIndexDatabase.openInMemory()` + injected `now` clock) — the
/// real test double range-filters like the live providers do, so it is the
/// faithful pin. Mirrors the intent/behaviour-matrix of
/// `StockPriceServiceFallbackTests`.
@Suite("CryptoPriceService fallback semantics")
struct CryptoPriceServiceFallbackTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  private func makeService(
    _ tokenPrices: [String: Decimal],
    now: @Sendable @escaping () -> Date
  ) throws -> CryptoPriceService {
    let database = try ProfileIndexDatabase.openInMemory()
    let client = FixedCryptoPriceClient(prices: ["1:native": tokenPrices], shouldFail: false)
    // Pin to UTC so the cap's "yesterday" boundary is computed against the
    // same calendar the `YYYY-MM-DD` fixtures use, regardless of host zone.
    let utc = try #require(TimeZone(identifier: "UTC"))
    return CryptoPriceService(
      clients: [client],
      database: database,
      resolutionClient: nil,
      now: now,
      timeZone: utc)
  }

  /// `exact` returns that day's price; an in-range gap (a date with no row,
  /// bracketed by cached dates) falls back to the most recent prior cached
  /// price; a post-latest date resolves to the latest cached price (the
  /// service caps the fetch at yesterday).
  @Test("exact, in-range gap (prior day), and post-latest all resolve")
  func behaviorMatrix() async throws {
    let frozen = try date("2024-02-01")
    let svc = try makeService(
      [
        "2024-01-15": dec("10"),
        "2024-01-16": dec("11"),
        "2024-01-20": dec("12"),
      ],
      now: { frozen })

    // Seed the cache by requesting the latest date first: the cold-cache
    // extension window is a 30-day window ending at the requested date, so
    // requesting 2024-01-20 pulls all three rows into the cache and pins
    // earliestDate=2024-01-15 / latestDate=2024-01-20.
    let latest = try await svc.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2024-01-20"))
    #expect(latest == dec("12"))  // exact (latest)

    let exact = try await svc.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2024-01-16"))
    #expect(exact == dec("11"))  // exact

    // True in-range gap: 2024-01-18 has no row but sits strictly between
    // cached 2024-01-16 and 2024-01-20 — falls back to the prior day.
    let gap = try await svc.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2024-01-18"))
    #expect(gap == dec("11"))  // in-range gap → most recent prior cached price

    // Post-latest: 2024-01-31 is after the latest cached row; the service
    // caps the fetch at yesterday so it resolves to the latest cached price.
    let postLatest = try await svc.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2024-01-31"))
    #expect(postLatest == dec("12"))  // post-latest
  }

  @Test("pre-history date has no fallback")
  func preHistory() async throws {
    let frozen = try date("2024-02-01")
    let svc = try makeService(["2024-01-15": dec("10")], now: { frozen })
    _ = try await svc.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2024-01-15"))
    let preHistoryDate = try date("2024-01-01")
    await #expect(throws: (any Error).self) {
      _ = try await svc.price(
        for: ethInstrument, mapping: ethMapping, on: preHistoryDate)
    }
  }
}
