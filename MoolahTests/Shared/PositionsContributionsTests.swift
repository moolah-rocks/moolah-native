import Foundation
import Testing

@testable import Moolah

/// Remaining-amount-invested (chart baseline) coverage for
/// `PositionsHistoryBuilder` — the ledger-sourced `Point.invested`.
/// Lives in its own file rather than appending to the existing
/// `PositionsHistoryBuilderTests` because that file is already
/// near the SwiftLint type-body-length limit.
@Suite("PositionsHistoryBuilder invested")
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

  private func sell(
    instrument: Instrument, qty: Decimal, proceeds: Decimal, daysAfterEpoch days: Int
  ) throws -> Transaction {
    Transaction(
      date: try date(daysAfterEpoch: days),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: instrument, quantity: -qty, type: .trade),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: proceeds, type: .trade),
      ]
    )
  }

  private func ledger(
    for txns: [Transaction], service: any InstrumentConversionService
  ) async throws -> HoldingsCostLedger {
    try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud, conversionService: service)
  }

  // MARK: - Remaining amount invested (baseline)

  /// Symptom 1: a fiat-only account holds no lots, so remaining amount
  /// invested is `0` on every point and the aggregate baseline is suppressed
  /// (fiat income / opening balances are non-events — cash is not "invested").
  @Test("fiat-only account: invested is 0 and the baseline is suppressed")
  func fiatOnlyAccountHasZeroInvestedNoBaseline() async throws {
    let txns = try [
      openingBalance(in: aud, qty: 1_000, daysAfterEpoch: 0),
      transferIn(qty: 500, daysAfterEpoch: 3),
    ]
    let service = FakeConversionService.fixedRates([:])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      ledger: try await ledger(for: txns, service: service),
      now: try date(daysAfterEpoch: 5)
    )
    #expect(!series.totalSeries.isEmpty)
    #expect(series.totalSeries.allSatisfy { $0.invested == 0 })
    #expect(
      !PositionsChartBaselineResolver.showsBaseline(
        points: series.totalSeries, mode: .aggregate))
  }

  /// A fiat-paired buy establishes remaining amount invested at its cost basis
  /// and carries it forward on subsequent (no-event) days.
  @Test("fiat-paired buy: invested equals cost basis, carried forward")
  func fiatPairedBuyInvestedEqualsCostBasis() async throws {
    let txns = try [buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1)]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      ledger: try await ledger(for: txns, service: service),
      now: try date(daysAfterEpoch: 5)
    )
    #expect(series.totalSeries.last?.invested == 500)
    #expect(
      PositionsChartBaselineResolver.showsBaseline(
        points: series.totalSeries, mode: .aggregate))
  }

  /// A second buy steps remaining amount invested up on its event day.
  @Test("second buy: invested steps up on the acquisition day")
  func secondBuyStepsInvestedUp() async throws {
    let txns = try [
      buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
      buy(instrument: bhp, qty: 5, fiat: 250, daysAfterEpoch: 3),
    ]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let day1Date = try date(daysAfterEpoch: 1)
    let day3Date = try date(daysAfterEpoch: 3)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      ledger: try await ledger(for: txns, service: service),
      now: try date(daysAfterEpoch: 5)
    )
    let day1 = try #require(
      series.totalSeries.first { Calendar.utc.startOfDay(for: $0.date) == day1Date })
    let day3 = try #require(
      series.totalSeries.first { Calendar.utc.startOfDay(for: $0.date) == day3Date })
    #expect(day1.invested == 500)
    #expect(day3.invested == 750)
  }

  /// A partial sell reduces remaining amount invested FIFO (5 of 10 shares
  /// @ 50 cost → invested drops from 500 to 250).
  @Test("partial sell: invested drops FIFO by the consumed lots' cost")
  func partialSellReducesInvestedFIFO() async throws {
    let txns = try [
      buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1),
      sell(instrument: bhp, qty: 5, proceeds: 300, daysAfterEpoch: 3),
    ]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(60)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let day1Date = try date(daysAfterEpoch: 1)
    let day4Date = try date(daysAfterEpoch: 4)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      ledger: try await ledger(for: txns, service: service),
      now: try date(daysAfterEpoch: 5)
    )
    let day1 = try #require(
      series.totalSeries.first { Calendar.utc.startOfDay(for: $0.date) == day1Date })
    let day4 = try #require(
      series.totalSeries.first { Calendar.utc.startOfDay(for: $0.date) == day4Date })
    #expect(day1.invested == 500)
    #expect(day4.invested == 250)
  }

  /// A non-fiat opening balance is an acquisition at market value, so
  /// remaining amount invested reflects that market value.
  @Test("non-fiat opening balance: invested at market value")
  func nonFiatOpeningBalanceInvestedAtMarketValue() async throws {
    let txns = try [openingBalance(in: bhp, qty: 10, daysAfterEpoch: 0)]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      ledger: try await ledger(for: txns, service: service),
      now: try date(daysAfterEpoch: 5)
    )
    // 10 shares × 50 market = 500 invested.
    #expect(series.totalSeries.last?.invested == 500)
  }

  /// Rule 11 / genuine provider failure: a `nil` ledger (the shared provider's
  /// build failed) suppresses the baseline — every `Point.invested` is `nil` —
  /// while the value line still renders. A failure must never surface as a
  /// computed-looking `0` invested.
  @Test("nil ledger (provider failure): baseline suppressed, value line renders")
  func nilLedgerSuppressesBaselineButValueRenders() async throws {
    let txns = try [buy(instrument: bhp, qty: 10, fiat: 500, daysAfterEpoch: 1)]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId,
      hostCurrency: aud, range: .threeMonths,
      ledger: nil,
      now: try date(daysAfterEpoch: 5)
    )
    // Value line still renders (quantities fold is independent of the ledger).
    #expect(!series.totalSeries.isEmpty)
    #expect(series.totalSeries.last?.value == 10 * Decimal(50) - 500)
    // Baseline unavailable → every invested is nil (never a coalesced 0).
    #expect(series.totalSeries.allSatisfy { $0.invested == nil })
    #expect(
      !PositionsChartBaselineResolver.showsBaseline(
        points: series.totalSeries, mode: .aggregate))
  }
}
