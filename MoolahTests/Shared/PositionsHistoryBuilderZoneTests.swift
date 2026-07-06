import Foundation
import Testing

@testable import Moolah

/// Zone-invariance test for `PositionsHistoryBuilder` chart-point dates.
///
/// The builder emits each day's point anchored at noon UTC so that a downstream
/// read — even one that uses a non-UTC calendar — still reports the correct
/// calendar month. This suite verifies that invariant across the full spread of
/// real-world zones. See `guides/DATE_TIME_GUIDE.md` §4 and §6.
@Suite("PositionsHistoryBuilder zone invariance")
struct PositionsHistoryBuilderZoneTests {
  let aud = Instrument.AUD
  let btc = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
  let accountId = UUID()

  /// A spread of zones either side of UTC: one strongly negative (the case that
  /// drifts a midnight-UTC instant into the prior day), UTC itself, and two
  /// strongly positive. Mirrors `TimezonelessDateTests`.
  private static let zones: [String] = [
    "America/Los_Angeles",  // UTC-8 / -7
    "UTC",
    "Australia/Brisbane",  // UTC+10, no DST
    "Pacific/Kiritimati",  // UTC+14, the extreme positive case
  ]

  private func calendar(_ identifier: String) throws -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = try #require(TimeZone(identifier: identifier))
    return cal
  }

  @Test("emitted point dates report April 2026 in every timezone")
  func pointDatesAreZoneInvariant() async throws {
    // Transaction on 2026-04-15 — mid-month is essential here. A first-of-month
    // date at midnight UTC (e.g. 2026-04-01T00:00:00Z) drifts into March 31 in
    // UTC-negative zones such as America/Los_Angeles. Mid-month dates are stable
    // across all real-world zones because ±14 h of offset cannot cross a month
    // boundary that is at least 14 days away. This confirms the noon-UTC anchor
    // in the builder works for the case (month boundary) that matters for the
    // chart axis; see DATE_TIME_GUIDE.md §4 and §6.
    var txnComponents = DateComponents()
    txnComponents.year = 2026
    txnComponents.month = 4
    txnComponents.day = 15
    let txnDate = try #require(Calendar.utc.date(from: txnComponents))

    let txn = Transaction(
      date: txnDate,
      legs: [
        TransactionLeg(accountId: accountId, instrument: btc, quantity: 1, type: .trade),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -50_000, type: .trade),
      ]
    )

    // Fixed `now` at noon UTC on 2026-04-20 so the series spans a few days in April.
    var nowComponents = DateComponents()
    nowComponents.year = 2026
    nowComponents.month = 4
    nowComponents.day = 20
    nowComponents.hour = 12
    let now = try #require(Calendar.utc.date(from: nowComponents))

    let service = FakeConversionService.fixedRates([btc.id: Decimal(50_000)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let ledger = try await HoldingsCostLedger.build(
      transactions: [txn], referenceCurrency: aud, conversionService: service)
    let series = await builder.build(
      transactions: [txn],
      accountId: accountId,
      hostCurrency: aud,
      range: .all,
      ledger: ledger,
      now: now
    )

    // Pick the first emitted point (2026-04-15). It must report month 4 in
    // every zone. Midnight UTC would drift to March 31 in America/Los_Angeles;
    // the noon-UTC anchor keeps it safely in April for all real-world zones.
    let firstPoint = try #require(series.totalSeries.first)
    for zone in Self.zones {
      let components = try calendar(zone).dateComponents([.year, .month], from: firstPoint.date)
      #expect(components.year == 2026, "year drifted in \(zone)")
      #expect(components.month == 4, "month drifted in \(zone)")
    }
  }

  /// The baseline VALUES — aggregate `invested` and per-instrument `cost`,
  /// both read from the shared ledger's change-points — must be identical
  /// across host time zones. Runs the whole `build(...)` pipeline with the
  /// ambient `NSTimeZone.default` toggled across the standard zone set; every
  /// internal boundary (`startOfDay`, the at-or-before change-point lookup)
  /// rides `Calendar.utc`, so neither baseline may drift with the host zone.
  @Test("aggregate invested and per-instrument cost are identical across time zones")
  func baselineValuesAreZoneInvariant() async throws {
    var txnComponents = DateComponents()
    txnComponents.year = 2026
    txnComponents.month = 4
    txnComponents.day = 15
    let txnDate = try #require(Calendar.utc.date(from: txnComponents))
    let txn = Transaction(
      date: txnDate,
      legs: [
        TransactionLeg(accountId: accountId, instrument: btc, quantity: 1, type: .trade),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -50_000, type: .trade),
      ]
    )
    var nowComponents = DateComponents()
    nowComponents.year = 2026
    nowComponents.month = 4
    nowComponents.day = 20
    nowComponents.hour = 12
    let now = try #require(Calendar.utc.date(from: nowComponents))

    let service = FakeConversionService.fixedRates([btc.id: Decimal(50_000)])
    // The ledger build itself is zone-invariant (uses `Calendar.utc`); build
    // it once, then vary only the ambient zone around the builder pass.
    let ledger = try await HoldingsCostLedger.build(
      transactions: [txn], referenceCurrency: aud, conversionService: service)
    let builder = PositionsHistoryBuilder(conversionService: service)

    let originalZone = NSTimeZone.default
    defer { NSTimeZone.default = originalZone }

    var investedPerZone: [String: Decimal?] = [:]
    var costPerZone: [String: Decimal?] = [:]
    for identifier in Self.zones {
      NSTimeZone.default = try #require(TimeZone(identifier: identifier))
      let series = await builder.build(
        transactions: [txn], accountId: accountId, hostCurrency: aud,
        range: .all, ledger: ledger, now: now)
      investedPerZone[identifier] = try #require(series.totalSeries.first).invested
      let btcSeries = series.series(forInstrumentIds: [btc.id])
      costPerZone[identifier] = try #require(btcSeries.first).cost
    }
    // 1 BTC bought for 50_000 AUD → aggregate invested and BTC cost are both
    // 50_000 in every host time zone (no zone-dependent drift).
    #expect(investedPerZone["UTC"] == 50_000)
    for identifier in Self.zones {
      #expect(investedPerZone[identifier] == 50_000, "invested drifted in \(identifier)")
      #expect(costPerZone[identifier] == 50_000, "per-instrument cost drifted in \(identifier)")
    }
  }
}
