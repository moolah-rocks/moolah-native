import Foundation
import Testing

@testable import Moolah

/// Tests for the chart-visibility predicates on `PositionsViewInput`
/// (`showsChart`, `showsAggregateChart`, `hasHistoricalSeries`).
@Suite("PositionsViewInput chart visibility")
struct PositionsViewInputChartTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let fixedTestDate = Date(timeIntervalSinceReferenceDate: 0)

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: aud)
  }

  @Test("showsChart is false when historicalValue is nil")
  func chartHiddenWithoutSeries() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60))
      ],
      historicalValue: nil
    )
    #expect(!input.showsChart)
  }

  // Previously "chartHiddenWithoutAnyCostBasis" — the product decision in Task 7
  // relaxed this: a non-empty series is now sufficient to show the chart even
  // when no position carries a cost basis (e.g. transfer-in / airdrop wallets).
  // The chart renders value-only; the baseline is now data-driven via
  // `PositionsChartBaselineResolver.showsBaseline(points:mode:)` — `showsCostBaseline`
  // has been removed from `PositionsViewInput`. `showsPLPill` remains gated on
  // cost basis.
  @Test("showsChart is true for held non-host positions with a series but no cost basis")
  func chartVisibleWithoutAnyCostBasis() {
    let point = HistoricalValueSeries.Point(
      date: fixedTestDate, value: 60, cost: 0, contributions: nil)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(100))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:])
    )
    #expect(input.showsChart, "non-empty series justifies chart even without cost basis")
    #expect(!input.showsPLPill, "P&L pill still requires at least one cost-bearing position")
  }

  @Test("showsAggregateChart is false when any row's value is nil")
  func aggregateChartHiddenOnFailure() {
    let point = HistoricalValueSeries.Point(
      date: fixedTestDate, value: 60, cost: 50, contributions: 50)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60)),
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(40), value: nil),
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:])
    )
    #expect(!input.showsAggregateChart)
    #expect(input.showsChart)  // chart can still render for working instruments
  }

  @Test(
    "showsChart is true when historicalValue has points and at least one row carries cost basis")
  func chartVisibleWithSeriesAndCostBasis() {
    let point = HistoricalValueSeries.Point(
      date: fixedTestDate, value: 60, cost: 50, contributions: 50)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:])
    )
    #expect(input.showsChart)
  }

  @Test("hasHistoricalSeries is false when historicalValue is nil")
  func historicalSeriesAbsentWhenNoSeries() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [], historicalValue: nil)
    #expect(!input.hasHistoricalSeries)
  }

  @Test("hasHistoricalSeries is false when total is empty")
  func historicalSeriesAbsentWhenTotalEmpty() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:]))
    #expect(!input.hasHistoricalSeries)
  }

  @Test("hasHistoricalSeries is true when total has at least one point")
  func historicalSeriesPresentWhenTotalHasPoints() {
    let point = HistoricalValueSeries.Point(
      date: fixedTestDate, value: 100, cost: 80, contributions: 80)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:]))
    #expect(input.hasHistoricalSeries)
  }

  @Test("showsChart is true when all positions are in host currency but history has points")
  func chartVisibleForHostCurrencyOnlyPositionsWithHistory() {
    let point = HistoricalValueSeries.Point(
      date: fixedTestDate, value: 100, cost: 80, contributions: 80)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        // AUD position (host currency) — `shouldHide` fires via the
        // host-currency-only branch, NOT via `positions.isEmpty`.
        ValuedPosition(
          instrument: aud, quantity: 5_000, unitPrice: nil,
          costBasis: nil, value: amount(5_000))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:]))
    #expect(input.shouldHide)
    #expect(input.showsChart)
  }

  @Test("showsChart is true when positions is empty but historical total has points")
  func chartVisibleForEmptyPositionsWithHistory() {
    let point = HistoricalValueSeries.Point(
      date: fixedTestDate, value: 100, cost: 80, contributions: 80)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:]))
    #expect(input.showsChart)
  }

  @Test("showsChart is false when positions is empty and historical total is empty")
  func chartHiddenForEmptyPositionsWithoutHistory() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:]))
    #expect(!input.showsChart)
  }

  @Test("showsChart is false when positions has cost basis but historical total is empty")
  func chartHiddenWhenCostBasisButNoHistoricalPoints() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:]))
    #expect(!input.showsChart)
  }

}
