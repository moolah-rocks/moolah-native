// MoolahTests/Shared/ContiguousExtensionFXTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite
struct ContiguousExtensionFXTests {

  /// Serves a weekday rate for every day in the requested range that is
  /// within `horizonDays` of `today`; older days and weekends return empty.
  /// Mimics Frankfurter's behaviour: FX markets are closed on weekends and
  /// data may only be available for a rolling window.
  struct WeekdayHorizonRateClient: ExchangeRateClient, Sendable {
    let today: Date
    let horizonDays: Int

    func fetchRates(
      base: String, from: Date, to: Date
    ) async throws -> [String: [String: Decimal]] {
      let cal = Calendar.utc
      guard let cutoff = cal.date(byAdding: .day, value: -horizonDays, to: today) else {
        return [:]
      }
      let fmt = ISO8601DateFormatter()
      fmt.formatOptions = [.withFullDate]
      fmt.timeZone = .utc
      var out: [String: [String: Decimal]] = [:]
      var day = from
      while day <= to {
        let weekday = cal.component(.weekday, from: day)
        // weekday 1 = Sunday, 7 = Saturday
        if day >= cutoff && weekday != 1 && weekday != 7 {
          out[fmt.string(from: day)] = ["AUD": 1.5]
        }
        guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
      }
      return out
    }
  }

  /// Serves weekday rates for any date without restriction.
  struct AllServingWeekdayRateClient: ExchangeRateClient, Sendable {
    func fetchRates(
      base: String, from: Date, to: Date
    ) async throws -> [String: [String: Decimal]] {
      let cal = Calendar.utc
      let fmt = ISO8601DateFormatter()
      fmt.formatOptions = [.withFullDate]
      fmt.timeZone = .utc
      var out: [String: [String: Decimal]] = [:]
      var day = from
      while day <= to {
        let weekday = cal.component(.weekday, from: day)
        if weekday != 1 && weekday != 7 {
          out[fmt.string(from: day)] = ["AUD": 1.5]
        }
        guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
      }
      return out
    }
  }

  private func makeService(
    client: any ExchangeRateClient,
    database: any DatabaseWriter,
    now: Date
  ) -> ExchangeRateService {
    ExchangeRateService(
      client: client,
      database: database,
      now: { now },
      timeZone: .utc
    )
  }

  // MARK: - Contiguity tests

  /// Reproduces the interior-gap bug for exchange rates: a horizon-restricted
  /// client causes the unbounded forward-extension fetch to produce a large
  /// interior void.
  ///
  /// Trigger sequence:
  ///   1. Seed far-back date (2024-07-12) using an all-serving client so the
  ///      cache has earliest≈2024-06-12, latest=2024-07-12.
  ///   2. Request today (2026-06-17) with a horizon-restricted client
  ///      (serves only the past 365 days, i.e. ≥ 2025-06-17).
  ///      Old logic: forward extension = unbounded [2024-07-12…today] in
  ///      year-sized chunks. Chunk 1 (2024-07-12…2025-07-12) returns data
  ///      from 2025-06-17 onward; merge advances `latest` to 2025-07-12,
  ///      leaving a ~11-month void (2024-07-12…2025-06-17).
  ///      New logic: extension bounded to 30-day windows; bounds only advance
  ///      across data that was actually returned.
  ///
  /// FX markets are closed weekends, so genuine 1–2 day gaps between
  /// consecutive data points are expected. The invariant is that no
  /// interior gap exceeds 4 days (a long weekend), never a multi-week void.
  @Test
  func farBackSeedThenTodayRequestLeavesOnlyWeekendGaps() async throws {
    let today = utcDay("2026-06-17")
    let database = try ProfileIndexDatabase.openInMemory()

    // Step 1: Seed a far-back date using an all-serving client.
    // This populates earliest≈2024-06-12, latest=2024-07-12.
    let seeder = makeService(
      client: AllServingWeekdayRateClient(),
      database: database,
      now: today
    )
    _ = try? await seeder.rate(from: .USD, to: .AUD, on: utcDay("2024-07-12"))

    // Step 2: Fresh service with a horizon-restricted client (only ≤ 365 days back).
    // Request today → forward extension from 2024-07-12 to 2026-06-16 (yesterday).
    // Old unbounded logic issues this in year-sized chunks; the first chunk
    // (2024-07-12 → 2025-07-12) returns data only from 2025-06-17 onward,
    // leaving a ~11-month interior void between the seeded latest and first
    // served day.
    let service = makeService(
      client: WeekdayHorizonRateClient(today: today, horizonDays: 365),
      database: database,
      now: today
    )
    _ = try? await service.rate(from: .USD, to: .AUD, on: today)

    // The largest gap between consecutive cached rates must not exceed a
    // long-weekend span (4 days). A multi-week void indicates the
    // bounded-loop invariant was violated.
    let maxGap = await service.debugMaxInteriorGapDays(base: "USD")
    #expect(maxGap <= 4)  // weekend/holiday only; never a multi-week void
  }

  // MARK: - Range contiguity

  /// A `rates(from:to:in:)` range request using a horizon-restricted client
  /// must not create an interior hole larger than a long weekend.
  @Test
  func rangeRequestLeavesOnlyWeekendGaps() async throws {
    let today = utcDay("2026-06-17")
    let database = try ProfileIndexDatabase.openInMemory()

    // Seed today's data so the cache has a recent bound.
    let seeder = makeService(
      client: AllServingWeekdayRateClient(),
      database: database,
      now: today
    )
    _ = try? await seeder.rate(from: .USD, to: .AUD, on: today)

    // Request a range far back using a horizon-restricted client.
    let service = makeService(
      client: WeekdayHorizonRateClient(today: today, horizonDays: 365),
      database: database,
      now: today
    )
    let rangeStart = utcDay("2024-01-01")
    _ = try? await service.rates(from: .USD, to: .AUD, in: rangeStart...today)

    let maxGap = await service.debugMaxInteriorGapDays(base: "USD")
    #expect(maxGap <= 4)  // weekend/holiday only; never a multi-week void
  }
}
