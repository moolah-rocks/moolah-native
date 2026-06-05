// MoolahTests/Shared/ExchangeRateServiceFallbackTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the exact / gap / post-latest / identity / pre-history semantics of
/// `ExchangeRateService` so the `SortedDateSeries` migration is provably
/// behavior-preserving. Mirrors the real FX test harness
/// (`FixedRateClient` + `ProfileIndexDatabase.openInMemory()`).
@Suite("ExchangeRateService fallback semantics")
struct ExchangeRateServiceFallbackTests {
  private func makeService(
    _ rates: [String: [String: Decimal]]
  ) throws -> ExchangeRateService {
    let client = FixedRateClient(rates: rates)
    let database = try ProfileIndexDatabase.openInMemory()
    // Pin to UTC so the cap's "yesterday" boundary is computed against the
    // same calendar the `YYYY-MM-DD` fixtures use, regardless of host zone.
    let utc = try #require(TimeZone(identifier: "UTC"))
    return ExchangeRateService(
      client: client, database: database, now: { self.date("2024-02-01") }, timeZone: utc)
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let result = formatter.date(from: string) else {
      preconditionFailure("Invalid ISO date literal: \(string)")
    }
    return result
  }

  @Test("exact / gap / post-latest match prior-implementation semantics")
  func behaviorMatrix() async throws {
    let usd = Instrument.fiat(code: "USD")
    let aud = Instrument.fiat(code: "AUD")
    let service = try makeService([
      "2024-01-15": ["AUD": dec("1.50")],
      "2024-01-16": ["AUD": dec("1.51")],
      "2024-01-17": ["AUD": dec("1.52")],
    ])
    _ = try await service.rate(from: usd, to: aud, on: date("2024-01-17"))
    #expect(
      try await service.rate(from: usd, to: aud, on: date("2024-01-16"))
        == dec("1.51"))
    #expect(
      try await service.rate(from: usd, to: aud, on: date("2024-01-20"))
        == dec("1.52"))
    #expect(
      try await service.rate(from: usd, to: aud, on: date("2024-01-31"))
        == dec("1.52"))
  }

  /// Pins the IN-RANGE gap branch: a queried date that sits strictly
  /// between the cache's `earliestDate` and `latestDate` but is itself
  /// absent must be served from `fallbackRate` WITHOUT a network fetch
  /// (the day-step `floorKey` probe loop). Seeding mirrors
  /// the sibling `ExchangeRateServiceTests.inRangeMissUsesFallback...`:
  /// prime two dates that bracket a deliberate hole so the cached range
  /// spans the gap, then query the hole. The unchanged `fetchCount`
  /// after the gap query is the proof the in-range short-circuit
  /// (`dateString >= earliestDate && <= latestDate`) fired rather than
  /// the post-latest extension/fetch path.
  @Test("in-range gap resolves via fallback without fetching")
  func inRangeGapUsesFallback() async throws {
    let usd = Instrument.fiat(code: "USD")
    let aud = Instrument.fiat(code: "AUD")
    let client = CountingRateClient(
      FixedRateClient(rates: [
        "2024-01-15": ["AUD": dec("1.50")],
        "2024-01-17": ["AUD": dec("1.52")],
      ]))
    let database = try ProfileIndexDatabase.openInMemory()
    let utc = try #require(TimeZone(identifier: "UTC"))
    let service = ExchangeRateService(
      client: client, database: database, now: { self.date("2024-02-01") }, timeZone: utc)

    // Prime so the cached range brackets the hole: 2024-01-15 (cold
    // surrounding fetch) then 2024-01-17 (forward extension). 2024-01-16
    // is never seeded, so earliestDate == "2024-01-15" and
    // latestDate == "2024-01-17" with no row for the middle day.
    _ = try await service.rate(from: usd, to: aud, on: date("2024-01-15"))
    _ = try await service.rate(from: usd, to: aud, on: date("2024-01-17"))
    let primedFetches = client.fetchCount

    // 2024-01-16 is strictly inside ["2024-01-15", "2024-01-17"]. The
    // exact tuple is absent; the in-range short-circuit resolves it to
    // the newest cached day <= target carrying AUD, i.e. 2024-01-15.
    let gapRate = try await service.rate(
      from: usd, to: aud, on: date("2024-01-16"))

    #expect(gapRate == dec("1.50"))
    #expect(client.fetchCount == primedFetches)
  }

  @Test("identity rate is 1 and pre-history throws")
  func identityAndPreHistory() async throws {
    let usd = Instrument.fiat(code: "USD")
    let aud = Instrument.fiat(code: "AUD")
    let service = try makeService(["2024-01-15": ["AUD": dec("1.50")]])
    #expect(
      try await service.rate(from: usd, to: usd, on: date("2024-01-15")) == 1)
    _ = try await service.rate(from: usd, to: aud, on: date("2024-01-15"))
    await #expect(throws: (any Error).self) {
      _ = try await service.rate(from: usd, to: aud, on: self.date("2024-01-01"))
    }
  }
}
