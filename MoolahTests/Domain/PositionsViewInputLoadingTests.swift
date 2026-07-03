import Foundation
import Testing

@testable import Moolah

@Suite("PositionsViewInput loading state")
struct PositionsViewInputLoadingTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  private var oneRow: [ValuedPosition] {
    [
      ValuedPosition(
        instrument: bhp, quantity: 100,
        unitPrice: InstrumentAmount(quantity: 50, instrument: aud),
        costBasis: nil, value: InstrumentAmount(quantity: 5_000, instrument: aud))
    ]
  }

  @Test("isHistoryLoading defaults to false")
  func defaultsFalse() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: oneRow, historicalValue: nil)
    #expect(input.isHistoryLoading == false)
    #expect(input.showsChartLoadingPlaceholder == false)
  }

  @Test("loading + no series + rows present shows the placeholder, not the chart")
  func placeholderWhileLoading() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: oneRow, historicalValue: nil,
      isHistoryLoading: true)
    #expect(input.showsChart == false)
    #expect(input.showsChartLoadingPlaceholder == true)
    #expect(input.rendersNothing == false)
  }

  @Test("once the series arrives the chart shows and the placeholder does not")
  func placeholderClearsWhenLoaded() {
    let point = HistoricalValueSeries.Point(
      date: Date(), value: 5_000, cost: 4_000, contributions: nil)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: oneRow,
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [bhp.id: [point]]),
      isHistoryLoading: true)
    #expect(input.showsChart == true)
    #expect(input.showsChartLoadingPlaceholder == false)
  }
}
