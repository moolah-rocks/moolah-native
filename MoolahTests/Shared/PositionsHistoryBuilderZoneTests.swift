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
    // Transaction on 2026-04-15 — mid-month to avoid any ±1-day zone drift
    // crossing a month boundary. The chart axis labels months, so month
    // stability is the invariant that matters.
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

    let service = FixedConversionService(rates: [btc.id: Decimal(50_000)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: [txn],
      accountId: accountId,
      hostCurrency: aud,
      range: .all,
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
}
