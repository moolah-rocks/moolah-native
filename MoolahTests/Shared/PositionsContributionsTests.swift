import Foundation
import Testing

@testable import Moolah

/// Cumulative-contributions coverage for `PositionsHistoryBuilder`.
/// Lives in its own file rather than appending to the existing
/// `PositionsHistoryBuilderTests` because that file is already
/// near the SwiftLint type-body-length limit.
@Suite("PositionsHistoryBuilder contributions")
struct PositionsContributionsTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let accountId = UUID()

  /// Day 0 = 2026-01-01 UTC midnight. `days` may exceed month length;
  /// calendar arithmetic rolls over correctly. Optional `hour` lets callers
  /// produce non-midnight timestamps for Rule 5 / Rule 8 / Rule 10
  /// tests that need the conversion service to receive the original
  /// `transaction.date` (not a `startOfDay`-truncated copy).
  ///
  /// Uses `Calendar.utc` so that dates produced here align with the
  /// builder's UTC-midnight day boundaries (Point.date is anchored at
  /// noon UTC; `startOfDay(for:)` on a noon-UTC point yields the same
  /// UTC-midnight value as this helper).
  private func date(daysAfterEpoch days: Int, hour: Int = 0) throws -> Date {
    var epoch = DateComponents()
    epoch.year = 2026
    epoch.month = 1
    epoch.day = 1
    epoch.hour = hour
    let base = try #require(Calendar.utc.date(from: epoch))
    return try #require(Calendar.utc.date(byAdding: .day, value: days, to: base))
  }

  private func buy(
    instrument: Instrument, qty: Decimal, fiat: Decimal, daysAfterEpoch days: Int
  ) throws -> Transaction {
    Transaction(
      date: try date(daysAfterEpoch: days),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: instrument, quantity: qty, type: .trade),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -fiat, type: .trade),
      ]
    )
  }

  private func openingBalance(
    in instrument: Instrument, qty: Decimal, daysAfterEpoch days: Int, hour: Int = 0
  ) throws -> Transaction {
    Transaction(
      date: try date(daysAfterEpoch: days, hour: hour),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: instrument, quantity: qty,
          type: .openingBalance)
      ]
    )
  }

  private func transferIn(
    qty: Decimal, daysAfterEpoch days: Int, fromOther: UUID = UUID()
  ) throws -> Transaction {
    Transaction(
      date: try date(daysAfterEpoch: days),
      legs: [
        TransactionLeg(accountId: accountId, instrument: aud, quantity: qty, type: .income),
        TransactionLeg(accountId: fromOther, instrument: aud, quantity: -qty, type: .expense),
      ]
    )
  }

  private func transferOut(
    qty: Decimal, daysAfterEpoch days: Int, toOther: UUID = UUID()
  ) throws -> Transaction {
    Transaction(
      date: try date(daysAfterEpoch: days),
      legs: [
        TransactionLeg(accountId: accountId, instrument: aud, quantity: -qty, type: .expense),
        TransactionLeg(accountId: toOther, instrument: aud, quantity: qty, type: .income),
      ]
    )
  }

  // MARK: - Cumulative contributions

  @Test("opening balance establishes contributions baseline")
  func contributionsOpeningBalance() async throws {
    let txns = try [
      openingBalance(in: aud, qty: 1_000, daysAfterEpoch: 0),
      // The buy seeds a BHP holding so we can verify the opening-balance
      // contribution is carried on subsequent non-cash days too.
      buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
    ]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      now: try date(daysAfterEpoch: 5)
    )
    let firstAggregate = try #require(series.totalSeries.first)
    #expect(firstAggregate.contributions == 1_000)
  }

  @Test("external transfer in steps contributions up")
  func contributionsTransferInStep() async throws {
    let txns = try [
      openingBalance(in: aud, qty: 1_000, daysAfterEpoch: 0),
      buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
      transferIn(qty: 500, daysAfterEpoch: 3),
    ]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let day1Date = try date(daysAfterEpoch: 1)
    let day3Date = try date(daysAfterEpoch: 3)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      now: try date(daysAfterEpoch: 5)
    )
    let day1 = try #require(
      series.totalSeries.first { Calendar.utc.startOfDay(for: $0.date) == day1Date })
    let day3 = try #require(
      series.totalSeries.first { Calendar.utc.startOfDay(for: $0.date) == day3Date })
    #expect(day1.contributions == 1_000)
    #expect(day3.contributions == 1_500)
  }

  @Test("external transfer out steps contributions down")
  func contributionsTransferOutStep() async throws {
    let txns = try [
      openingBalance(in: aud, qty: 2_000, daysAfterEpoch: 0),
      buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
      transferOut(qty: 800, daysAfterEpoch: 3),
    ]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let day3Date = try date(daysAfterEpoch: 3)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      now: try date(daysAfterEpoch: 5)
    )
    let day3 = try #require(
      series.totalSeries.first { Calendar.utc.startOfDay(for: $0.date) == day3Date })
    #expect(day3.contributions == 1_200)
  }

  @Test("intra-account trade leaves contributions unchanged")
  func contributionsIntraAccountTrade() async throws {
    let txns = try [
      openingBalance(in: aud, qty: 1_000, daysAfterEpoch: 0),
      buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
      buy(instrument: bhp, qty: 5, fiat: 250, daysAfterEpoch: 3),
    ]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      now: try date(daysAfterEpoch: 5)
    )
    for point in series.totalSeries {
      #expect(point.contributions == 1_000)
    }
  }

  @Test("cross-currency contribution converts on transaction.date")
  func contributionsCrossCurrencyOnTxnDate() async throws {
    let usd = Instrument.USD
    let day0 = try date(daysAfterEpoch: 0)
    let day10 = try date(daysAfterEpoch: 10)
    // Two distinct rates: passing the wrong date would yield 1_400.
    let day0Rate = try #require(Decimal(string: "1.50"))
    let day10Rate = try #require(Decimal(string: "1.40"))
    let service = FakeConversionService.dateRates([
      day0: [usd.id: day0Rate, bhp.id: Decimal(50)],
      day10: [usd.id: day10Rate, bhp.id: Decimal(50)],
    ])
    let day1Date = try date(daysAfterEpoch: 1)
    let txns = try [
      openingBalance(in: usd, qty: 1_000, daysAfterEpoch: 0, hour: 14),
      buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
    ]
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      now: try date(daysAfterEpoch: 12)
    )
    let day1 = try #require(
      series.totalSeries.first { Calendar.utc.startOfDay(for: $0.date) == day1Date })
    #expect(day1.contributions == Decimal(1_500))
  }

  @Test("pre-fold contributes prior-window flows to day-1 of visible window")
  func contributionsPreFold() async throws {
    let txns = try [
      openingBalance(in: aud, qty: 5_000, daysAfterEpoch: 0),
      buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
      transferIn(qty: 1_000, daysAfterEpoch: 5),
    ]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    // now=day 50 with .oneMonth pushes the window cutoff to ~day 20,
    // so days 0/1/5 are all pre-window and the pre-fold path drives
    // the cumulative contributions seed for the first visible point.
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .oneMonth,
      now: try date(daysAfterEpoch: 50)
    )
    let firstVisible = try #require(series.totalSeries.first)
    #expect(firstVisible.contributions == 6_000)
  }

  @Test("conversion failure makes contributions sticky-nil for all subsequent emitted points")
  func contributionsStickyLatchOnFailure() async throws {
    let usd = Instrument.USD
    // failingInstruments throws .instrumentUnavailable for any conversion
    // involving an id in `failingInstrumentIds`; same-instrument
    // conversions short-circuit (Rule 8 fast path) and never throw.
    // BHP rate is configured so the per-day BHP value-conversion
    // path succeeds.
    //
    // Important: a USD income leg adds USD to `state.quantities`,
    // which means the per-day value-conversion path will also try
    // (and fail) to convert that USD position from day 3 onwards —
    // so the aggregate point is suppressed entirely. The
    // assertion is therefore: every emitted aggregate point on or
    // after the failure date carries `contributions == nil`,
    // regardless of how many actually emit.
    let service = FakeConversionService.failingInstruments(
      [usd.id],
      rates: [bhp.id: Decimal(50)]
    )
    let day3 = try date(daysAfterEpoch: 3)
    let txns = try [
      openingBalance(in: aud, qty: 1_000, daysAfterEpoch: 0),
      buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
      Transaction(
        date: day3,
        legs: [
          TransactionLeg(accountId: accountId, instrument: usd, quantity: 100, type: .income),
          TransactionLeg(accountId: UUID(), instrument: usd, quantity: -100, type: .expense),
        ]
      ),
    ]
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      now: try date(daysAfterEpoch: 5)
    )
    let day1Date = try date(daysAfterEpoch: 1)
    let day1 = try #require(
      series.totalSeries.first { Calendar.utc.startOfDay(for: $0.date) == day1Date })
    #expect(day1.contributions == 1_000)
    // Sticky-latch invariant: no aggregate point on or after day 3
    // carries a populated `contributions`, regardless of whether the
    // point actually emits (USD position blocks emission via the
    // value-conversion path).
    for point in series.totalSeries where Calendar.utc.startOfDay(for: point.date) >= day3 {
      #expect(point.contributions == nil)
    }
  }

  @Test("cancellation produces no aggregate point with stale contributions")
  func contributionsCancellation() async throws {
    // Service throws CancellationError on every call. The contribution
    // fold catches it, latches state.contributions = nil, and rethrows;
    // the build's per-day loop converts the throw into a partial-series
    // return. The primary assertions are:
    //   1. The function returns at all (no deadlock — the test would
    //      hang otherwise).
    //   2. No emitted aggregate point carries a populated `contributions`
    //      value. `allSatisfy` on an empty collection returns `true` —
    //      that is the correct outcome here, because cancellation
    //      mid-pre-fold legitimately produces zero emitted points and
    //      the latch invariant is then trivially satisfied.
    let service = FakeConversionService.perCall { _ in .failure(CancellationError()) }
    let txns = try [
      openingBalance(in: Instrument.USD, qty: 1_000, daysAfterEpoch: 0),
      buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
    ]
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      now: try date(daysAfterEpoch: 5)
    )
    #expect(series.totalSeries.allSatisfy { $0.contributions == nil })
  }
}
