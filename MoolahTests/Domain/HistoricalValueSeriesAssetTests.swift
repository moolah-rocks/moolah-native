import Foundation
import Testing

@testable import Moolah

@Suite
struct HistoricalValueSeriesAssetTests {
  private func day(_ offset: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(offset) * 86_400)
  }

  private func point(_ offset: Int, _ value: Decimal, _ cost: Decimal)
    -> HistoricalValueSeries.Point
  {
    .init(date: day(offset), value: value, cost: cost, contributions: nil)
  }

  @Test
  func sumsContributingSeriesByDate() {
    let series = HistoricalValueSeries(
      hostCurrency: .AUD, total: [],
      perInstrument: [
        "1:native": [point(1, 100, 80), point(2, 110, 80)],
        "10:native": [point(1, 20, 15), point(2, 25, 15)],
      ])
    let summed = series.series(forInstrumentIds: ["1:native", "10:native"])
    #expect(summed.count == 2)
    #expect(summed[0].date == day(1))
    #expect(summed[0].value == 120)
    #expect(summed[0].cost == 95)
    #expect(summed[1].value == 135)
  }

  @Test
  func dropsDatesNotPresentInEveryContributor() {
    // "1:native" has days 1,2,3; "10:native" has only day 2. Intersection = day 2.
    let series = HistoricalValueSeries(
      hostCurrency: .AUD, total: [],
      perInstrument: [
        "1:native": [point(1, 100, 80), point(2, 110, 80), point(3, 120, 80)],
        "10:native": [point(2, 25, 15)],
      ])
    let summed = series.series(forInstrumentIds: ["1:native", "10:native"])
    #expect(summed.count == 1)
    #expect(summed[0].date == day(2))
    #expect(summed[0].value == 135)
  }

  @Test
  func singleIdMatchesSeriesForInstrument() {
    let points = [point(1, 100, 80)]
    let series = HistoricalValueSeries(
      hostCurrency: .AUD, total: [], perInstrument: ["1:native": points])
    #expect(series.series(forInstrumentIds: ["1:native"]) == points)
  }

  @Test
  func unknownIdsYieldEmpty() {
    let series = HistoricalValueSeries(hostCurrency: .AUD, total: [], perInstrument: [:])
    #expect(series.series(forInstrumentIds: ["nope"]).isEmpty)
  }
}
