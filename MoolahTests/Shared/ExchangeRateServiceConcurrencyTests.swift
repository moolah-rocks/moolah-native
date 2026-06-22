import Foundation
import Testing
import os

@testable import Moolah

/// Regression coverage for the actor-reentrancy hazard in
/// `ExchangeRateService`'s cache-extension path.
///
/// `rate(from:to:on:)` extends the in-memory cache across several `await`
/// points (`loadCache`, `client.fetchRates`, `persistDelta`). Without
/// serialisation, two concurrent calls for the same base can both observe
/// the cold cache and merge **non-adjacent** fetch windows. That unions
/// `[earliestDate, latestDate]` over an interior region neither window
/// fetched, breaking the contiguity invariant the in-range short-circuit
/// relies on — a later request for an interior day then carries forward an
/// earlier day's rate (returning a wrong-but-plausible value, e.g. day 8's
/// quote resolving to day 6's). The per-base cache-extension gate restores
/// contiguity. This suite pins that two concurrent cold requests for
/// non-adjacent days each resolve to their OWN exact rate.
@Suite("ExchangeRateService concurrency")
struct ExchangeRateServiceConcurrencyTests {
  private let usd = Instrument.fiat(code: "USD")
  private let aud = Instrument.fiat(code: "AUD")

  /// Serves rates from a fixed map but holds the **first** fetch with a real
  /// suspension (`Task.sleep`) long enough for any concurrently-admitted
  /// second fetch to reach the client too. Records the peak number of
  /// fetches in flight at once.
  ///
  /// - Bug (no gate): both cold extensions are admitted, so while the first
  ///   sleeps the second reaches `fetchRates`; the two **non-adjacent**
  ///   windows then merge, leaving an unfetched interior, and the interior
  ///   day mis-resolves via carry-forward. `peakInFlight` reaches 2.
  /// - Fix (per-base gate): the second extension blocks before the client,
  ///   so only one fetch is ever in flight; the first proceeds alone after
  ///   its sleep and fetches a contiguous window. `peakInFlight` stays 1.
  ///
  /// The sleep yields the CPU (unlike a hot spin), so the second task makes
  /// progress under the bug without relying on background load — making the
  /// reproduction deterministic.
  private final class HoldingRateClient: ExchangeRateClient, Sendable {
    private let inner: FixedRateClient
    private let state = OSAllocatedUnfairLock<(inFlight: Int, peak: Int)>(
      initialState: (0, 0))

    init(_ inner: FixedRateClient) {
      self.inner = inner
    }

    var peakInFlight: Int {
      state.withLock { $0.peak }
    }

    func fetchRates(
      base: String, from: Date, to: Date
    ) async throws -> [String: [String: Decimal]] {
      let arrival = state.withLock { value -> Int in
        value.inFlight += 1
        value.peak = max(value.peak, value.inFlight)
        return value.inFlight
      }
      // Only the first concurrent arrival holds — long enough for a second
      // admitted extension to reach this point. Held with a true suspension
      // so the other task gets CPU.
      if arrival == 1 {
        try? await Task.sleep(for: .milliseconds(40))
      }
      defer { state.withLock { $0.inFlight -= 1 } }
      return try await inner.fetchRates(base: base, from: from, to: to)
    }
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let result = formatter.date(from: string) else {
      preconditionFailure("Invalid ISO date literal: \(string)")
    }
    return result
  }

  /// Two concurrent cold requests whose days sit far enough apart that no
  /// single 30-day window covers both: cache extension must stay
  /// single-flight per base, and both days resolve to their own exact rate.
  ///
  /// Rates are dense (every calendar day present), mirroring a real FX
  /// series, so each fetch window always makes progress — isolating the
  /// concurrency hazard (a non-contiguous merge over an unfetched interior)
  /// from sparse-provider fetch-planning edges.
  @Test("concurrent cold fetches stay serialised and resolve exactly")
  func concurrentColdFetchesResolveExactly() async throws {
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let utc = try #require(TimeZone(identifier: "UTC"))
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]

    // 60 dense daily rates so a forward/backward window always advances.
    let base = date("2025-01-01")
    var rates: [String: [String: Decimal]] = [:]
    var rateByOffset: [Int: Decimal] = [:]
    for offset in 0..<60 {
      let onDate = try #require(utcCalendar.date(byAdding: .day, value: offset, to: base))
      let rate = (Decimal(offset) / Decimal(100)) + dec("1.00")  // 1.00 … 1.59
      rates[formatter.string(from: onDate)] = ["AUD": rate]
      rateByOffset[offset] = rate
    }
    // Day 5 and day 50 are 45 days apart — beyond one 30-day window.
    let earlyDay = try #require(utcCalendar.date(byAdding: .day, value: 5, to: base))
    let lateDay = try #require(utcCalendar.date(byAdding: .day, value: 50, to: base))
    // An interior day between the two cold windows — the slot a
    // non-contiguous merge would mis-resolve via carry-forward.
    let interiorDay = try #require(utcCalendar.date(byAdding: .day, value: 28, to: base))

    let client = HoldingRateClient(FixedRateClient(rates: rates))
    let database = try ProfileIndexDatabase.openInMemory()
    let service = ExchangeRateService(
      client: client, database: database,
      now: { self.date("2025-06-01") }, timeZone: utc)

    async let early = service.rate(from: usd, to: aud, on: earlyDay)
    async let late = service.rate(from: usd, to: aud, on: lateDay)
    let (earlyRate, lateRate) = try await (early, late)

    #expect(earlyRate == rateByOffset[5])
    #expect(lateRate == rateByOffset[50])
    // The gate must keep cache extension single-flight per base.
    #expect(client.peakInFlight == 1)

    // The interior day resolves to its OWN exact rate — a non-contiguous
    // merge would carry forward an earlier day's value here.
    let interiorRate = try await service.rate(from: usd, to: aud, on: interiorDay)
    #expect(interiorRate == rateByOffset[28])
  }
}
