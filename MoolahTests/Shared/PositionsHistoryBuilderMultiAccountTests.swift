import Foundation
import Testing

@testable import Moolah

@Suite("PositionsHistoryBuilder multi-account")
struct PositionsHistoryBuilderMultiAccountTests {
  let aud = Instrument.AUD
  let btc = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
  let accountA = UUID()
  let accountB = UUID()

  /// Day 0 = 2026-01-01. Uses `Calendar.utc` so the result is zone-invariant.
  private func date(daysAfterEpoch days: Int) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 1
    components.day = 1 + days
    guard let result = Calendar.utc.date(from: components) else {
      fatalError("Could not construct date \(days) days after 2026-01-01")
    }
    return result
  }

  private func buy(
    instrument: Instrument,
    qty: Decimal,
    fiat: Decimal,
    accountId: UUID,
    daysAfterEpoch days: Int
  ) -> Transaction {
    Transaction(
      date: date(daysAfterEpoch: days),
      legs: [
        TransactionLeg(accountId: accountId, instrument: instrument, quantity: qty, type: .trade),
        TransactionLeg(accountId: accountId, instrument: aud, quantity: -fiat, type: .trade),
      ]
    )
  }

  /// Two accounts each holding the same instrument: the aggregate value
  /// line equals the sum of both holdings converted on each day.
  @Test("aggregate value equals sum of holdings across two accounts")
  func aggregatesHoldingsAcrossTwoAccounts() async throws {
    // Account A buys 1 BTC on day 1, account B buys 2 BTC on day 1.
    let txns = [
      buy(instrument: btc, qty: 1, fiat: 10_000, accountId: accountA, daysAfterEpoch: 1),
      buy(instrument: btc, qty: 2, fiat: 20_000, accountId: accountB, daysAfterEpoch: 1),
    ]
    let service = FakeConversionService.fixedRates([btc.id: Decimal(15_000)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 3)
    let series = await builder.build(
      transactions: txns,
      accountIds: Set([accountA, accountB]),
      hostCurrency: aud,
      range: .threeMonths,
      now: now
    )

    // 3 days in range (days 1, 2, 3).
    #expect(series.totalSeries.count == 3)

    // Aggregate on any day = convert(3 BTC) = 3 × 15_000 = 45_000.
    let last = try #require(series.totalSeries.last)
    #expect(last.value == 3 * Decimal(15_000))
  }

  /// An internal transfer of the same instrument between two members nets
  /// to zero quantity change for the group — the group's value line is flat
  /// across the transfer date (no phantom buy/sell).
  @Test("internal transfer between members nets out: group quantity stays flat")
  func internalTransferBetweenMembersNetsOut() async throws {
    // Account A buys 1 BTC on day 0.
    // On day 1, A sends 1 BTC to B (one transaction, two legs — both in the group).
    let buyTxn = Transaction(
      date: date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(accountId: accountA, instrument: btc, quantity: 1, type: .trade),
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -10_000, type: .trade),
      ]
    )
    let transferTxn = Transaction(
      date: date(daysAfterEpoch: 1),
      legs: [
        TransactionLeg(accountId: accountA, instrument: btc, quantity: -1, type: .expense),
        TransactionLeg(accountId: accountB, instrument: btc, quantity: 1, type: .income),
      ]
    )
    let service = FakeConversionService.fixedRates([btc.id: Decimal(12_000)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 2)
    let series = await builder.build(
      transactions: [buyTxn, transferTxn],
      accountIds: Set([accountA, accountB]),
      hostCurrency: aud,
      range: .threeMonths,
      now: now
    )

    // All points should show 1 BTC (the group's total is unchanged by
    // the internal transfer).
    let expected = 1 * Decimal(12_000)
    #expect(series.totalSeries.count == 3)
    for point in series.totalSeries {
      #expect(point.value == expected)
    }
  }

  /// Locks in that the multi-account builder uses each day's own rate, not
  /// today's rate (Rule 5 of `guides/INSTRUMENT_CONVERSION_GUIDE.md`).
  ///
  /// Uses `DateBasedFixedConversionService` with DIFFERENT per-day rates so a
  /// regression that swapped `on: day` for `on: Date()` would produce three
  /// equal values (all at the "today" rate) instead of the three distinct
  /// values this test asserts.
  ///
  /// Rate keys use `Calendar.utc` — the same basis the builder uses for its
  /// `startOfDay` computation — so the `rateDate <= queryDate` comparison in
  /// `DateBasedFixedConversionService` always aligns regardless of the CI
  /// runner's local timezone.
  @Test("each day's value uses that day's rate across multiple accounts")
  func dateDependentConversionProducesCorrectValues() async {
    // Account A buys 1 BTC on day 1; account B buys 1 BTC on day 1.
    // Group total = 2 BTC; each day has its own rate.
    let txns = [
      Transaction(
        date: date(daysAfterEpoch: 1),
        legs: [
          TransactionLeg(accountId: accountA, instrument: btc, quantity: 1, type: .trade),
          TransactionLeg(accountId: accountA, instrument: aud, quantity: -10_000, type: .trade),
        ]
      ),
      Transaction(
        date: date(daysAfterEpoch: 1),
        legs: [
          TransactionLeg(accountId: accountB, instrument: btc, quantity: 1, type: .trade),
          TransactionLeg(accountId: accountB, instrument: aud, quantity: -10_000, type: .trade),
        ]
      ),
    ]
    let service = FakeConversionService.dateRates([
      date(daysAfterEpoch: 1): [btc.id: Decimal(10_000)],
      date(daysAfterEpoch: 2): [btc.id: Decimal(20_000)],
      date(daysAfterEpoch: 3): [btc.id: Decimal(30_000)],
    ])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 3)
    let series = await builder.build(
      transactions: txns,
      accountIds: Set([accountA, accountB]),
      hostCurrency: aud,
      range: .threeMonths,
      now: now
    )

    // Three points (days 1, 2, 3). Group holds 2 BTC on each day, but
    // the value steps up with each day's rate. A regression to "always use
    // today's rate" would produce three identical values of 2 × 30_000 = 60_000.
    #expect(series.totalSeries.count == 3)
    #expect(series.totalSeries[0].value == 2 * Decimal(10_000))
    #expect(series.totalSeries[1].value == 2 * Decimal(20_000))
    #expect(series.totalSeries[2].value == 2 * Decimal(30_000))
  }

  /// The single-account convenience overload still produces the same series
  /// as calling the set-based API with a single-element set.
  @Test("single-account convenience overload matches set-based API with singleton set")
  func singleAccountConvenienceMatches() async throws {
    let txns = [
      buy(instrument: btc, qty: 5, fiat: 50_000, accountId: accountA, daysAfterEpoch: 1)
    ]
    let service = FakeConversionService.fixedRates([btc.id: Decimal(11_000)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 3)

    let viaSingleId = await builder.build(
      transactions: txns, accountId: accountA,
      hostCurrency: aud, range: .threeMonths, now: now
    )
    let viaSet = await builder.build(
      transactions: txns, accountIds: Set([accountA]),
      hostCurrency: aud, range: .threeMonths, now: now
    )

    // Both should produce identical total-series counts and values.
    #expect(viaSingleId.totalSeries.count == viaSet.totalSeries.count)
    for (single, unified) in zip(viaSingleId.totalSeries, viaSet.totalSeries) {
      #expect(single.value == unified.value)
      #expect(single.cost == unified.cost)
    }
  }
}
