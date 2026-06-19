import Foundation
import Testing

@testable import Moolah

@Suite("PositionsHistoryBuilder")
struct PositionsHistoryBuilderTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
  let accountId = UUID()

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
    instrument: Instrument, qty: Decimal, fiat: Decimal, daysAfterEpoch days: Int
  ) -> Transaction {
    Transaction(
      date: date(daysAfterEpoch: days),
      legs: [
        TransactionLeg(accountId: accountId, instrument: instrument, quantity: qty, type: .trade),
        TransactionLeg(accountId: accountId, instrument: aud, quantity: -fiat, type: .trade),
      ]
    )
  }

  @Test("value series emits one point per day in range; aggregate sums across instruments")
  func dailyValueSeries() async throws {
    let txns = [
      buy(instrument: bhp, qty: 100, fiat: 4_000, daysAfterEpoch: 1),
      buy(instrument: cba, qty: 50, fiat: 5_000, daysAfterEpoch: 2),
    ]
    let service = FixedConversionService(rates: [
      bhp.id: Decimal(50),
      cba.id: Decimal(110),
    ])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 5)
    let series = await builder.build(
      transactions: txns,
      accountId: accountId,
      hostCurrency: aud,
      range: .oneMonth,
      now: now
    )

    // Daily samples from cutoff (or first holding date) through `now`.
    // First holding is day 1 (BHP buy), so total range is days 1..5 = 5 points.
    #expect(series.totalSeries.count == 5)

    // Last day = both holdings priced.
    let last = try #require(series.totalSeries.last)
    #expect(last.value == 100 * Decimal(50) + 50 * Decimal(110))

    // Day 1 (only BHP held).
    let firstAggregate = try #require(series.totalSeries.first)
    #expect(firstAggregate.value == 100 * Decimal(50))
  }

  @Test("cost-basis points appear at every event plus a closing point")
  func costBasisIsExactStepFunction() async throws {
    let txns = [
      buy(instrument: bhp, qty: 100, fiat: 4_000, daysAfterEpoch: 1),
      buy(instrument: bhp, qty: 50, fiat: 2_500, daysAfterEpoch: 10),
    ]
    let service = FixedConversionService(rates: [bhp.id: Decimal(50)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 30)

    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths, now: now
    )

    // The per-instrument series is one point per day. Cost on each daily
    // point reflects the cumulative cost basis at that date — exact step
    // function: 4_000 from day 1, 6_500 from day 10 onwards.
    let bhpSeries = series.series(forInstrumentIds: [bhp.id])
    let day5 = try #require(
      bhpSeries.first {
        Calendar.utc.isDate($0.date, inSameDayAs: date(daysAfterEpoch: 5))
      })
    let day20 = try #require(
      bhpSeries.first {
        Calendar.utc.isDate($0.date, inSameDayAs: date(daysAfterEpoch: 20))
      })
    #expect(day5.cost == 4_000)
    #expect(day20.cost == 6_500)
  }

  @Test("aggregate point is omitted on days where any instrument's conversion fails")
  func aggregateSkipsOnPartialFailure() async {
    let txns = [
      buy(instrument: bhp, qty: 100, fiat: 4_000, daysAfterEpoch: 1),
      buy(instrument: cba, qty: 50, fiat: 5_000, daysAfterEpoch: 2),
    ]
    let service = FailingConversionService(
      rates: [bhp.id: Decimal(50)],
      failingInstrumentIds: [cba.id]
    )
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      now: date(daysAfterEpoch: 5)
    )
    // From day 2 onwards CBA is held; every aggregate point that includes
    // CBA must be skipped. Points are noon-UTC, so a day-1 noon point is
    // correctly < day-2 midnight (the date(daysAfterEpoch:) helper returns
    // midnight UTC, and noon < midnight+24h), making the < comparison safe.
    #expect(series.totalSeries.allSatisfy { $0.date < self.date(daysAfterEpoch: 2) })
    // Per-instrument BHP still has full daily coverage.
    #expect(series.series(forInstrumentIds: [bhp.id]).count == 5)
  }

  @Test("pre-fold: transactions before the visible range still seed cost basis at start")
  func preFoldHistoricalCostBasis() async throws {
    // Buy on day 0 (well before the .oneMonth cutoff for now=day 200).
    let txns = [buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 0)]
    let service = FixedConversionService(rates: [bhp.id: Decimal(60)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 200)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .oneMonth, now: now
    )

    // First visible point's cost should reflect the prior buy ($500), and
    // value should reflect 10 shares × $60 = $600.
    let bhpSeries = series.series(forInstrumentIds: [bhp.id])
    let firstPoint = try #require(bhpSeries.first)
    #expect(firstPoint.cost == 500)
    #expect(firstPoint.value == 600)
  }

  @Test("same-day multiple transactions: both reflected in the day's emitted point")
  func sameDayMultipleTransactions() async throws {
    let txns = [
      buy(instrument: bhp, qty: 100, fiat: 4_000, daysAfterEpoch: 1),
      buy(instrument: bhp, qty: 50, fiat: 2_500, daysAfterEpoch: 1),  // same day
    ]
    let service = FixedConversionService(rates: [bhp.id: Decimal(50)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 5)

    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths, now: now
    )

    let bhpSeries = series.series(forInstrumentIds: [bhp.id])
    let firstPoint = try #require(bhpSeries.first)
    // Both buys folded by end of day 1: 150 shares total cost 6500.
    #expect(firstPoint.value == 150 * Decimal(50))
    #expect(firstPoint.cost == 6_500)
  }

  @Test("empty transactions input returns an empty series")
  func emptyTransactions() async {
    let service = FixedConversionService(rates: [:])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: [], accountId: accountId,
      hostCurrency: aud, range: .oneMonth, now: Date()
    )
    #expect(series.totalSeries.isEmpty)
    #expect(series.instruments.isEmpty)
  }

  @Test("range cutoff drops samples earlier than the requested window")
  func rangeFilters() async throws {
    let txns = [
      buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 0)
    ]
    let service = FixedConversionService(rates: [bhp.id: Decimal(60)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 200)
    let oneMonth = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .oneMonth, now: now
    )
    let cutoff = try #require(PositionsTimeRange.oneMonth.cutoff(from: now))
    let cutoffDay = Calendar.utc.startOfDay(for: cutoff)
    // Points are anchored at noon UTC; compare by start-of-day so the noon
    // offset does not falsely fail the >= check against a midnight cutoff.
    #expect(
      oneMonth.totalSeries.allSatisfy {
        Calendar.utc.startOfDay(for: $0.date) >= cutoffDay
      })
  }

  /// Locks in Rule 5 of `guides/INSTRUMENT_CONVERSION_GUIDE.md`: every
  /// daily value point must be converted at that day's own rate, not at
  /// today's rate. The other tests in this suite use
  /// `FixedConversionService` (date-insensitive), which would silently
  /// pass a regression that swapped `on: day` for `on: Date()`. This
  /// test pins the per-day rate by using `DateBasedFixedConversionService`.
  @Test("each day's value uses that day's rate, not today's rate")
  func valueSeriesUsesPerDayRate() async {
    // Single buy on day 1; rate steps day-by-day so each daily point
    // exercises a different conversion rate.
    let txns = [buy(instrument: bhp, qty: 100, fiat: 4_000, daysAfterEpoch: 1)]
    let service = DateBasedFixedConversionService(rates: [
      date(daysAfterEpoch: 1): [bhp.id: Decimal(50)],
      date(daysAfterEpoch: 2): [bhp.id: Decimal(60)],
      date(daysAfterEpoch: 3): [bhp.id: Decimal(70)],
    ])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 3)
    let series = await builder.build(
      transactions: txns,
      accountId: accountId,
      hostCurrency: aud,
      range: .threeMonths,
      now: now
    )

    // Three points (days 1..3), each priced at that day's rate. A
    // regression to "always use today's rate" would emit three equal
    // values (all at day 3's rate of 70).
    let bhpSeries = series.series(forInstrumentIds: [bhp.id])
    #expect(bhpSeries.count == 3)
    #expect(bhpSeries[0].value == 100 * Decimal(50))
    #expect(bhpSeries[1].value == 100 * Decimal(60))
    #expect(bhpSeries[2].value == 100 * Decimal(70))

    // Aggregate series mirrors the per-instrument series for a single
    // non-host instrument account.
    #expect(series.totalSeries.count == 3)
    #expect(series.totalSeries[0].value == 100 * Decimal(50))
    #expect(series.totalSeries[1].value == 100 * Decimal(60))
    #expect(series.totalSeries[2].value == 100 * Decimal(70))
  }
}
