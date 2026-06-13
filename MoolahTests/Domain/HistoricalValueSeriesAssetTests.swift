import Foundation
import Testing

@testable import Moolah

@Suite
struct HistoricalValueSeriesAssetTests {
  @Test
  func sumsContributingSeriesByDate() throws {
    let series = HistoricalValueSeries(
      hostCurrency: .AUD, total: [],
      perInstrument: [
        "1:native": [point(1, 100, 80), point(2, 110, 80)],
        "10:native": [point(1, 20, 15), point(2, 25, 15)],
      ])
    let summed = series.series(forInstrumentIds: ["1:native", "10:native"])
    #expect(summed.count == 2)
    let first = try #require(summed.first)
    let second = try #require(summed.dropFirst().first)
    #expect(first.date == day(1))
    #expect(first.value == 120)
    #expect(first.cost == 95)
    #expect(second.value == 135)
  }

  @Test
  func dropsDatesNotPresentInEveryContributor() throws {
    // "1:native" has days 1,2,3; "10:native" has only day 2. Intersection = day 2.
    let series = HistoricalValueSeries(
      hostCurrency: .AUD, total: [],
      perInstrument: [
        "1:native": [point(1, 100, 80), point(2, 110, 80), point(3, 120, 80)],
        "10:native": [point(2, 25, 15)],
      ])
    let summed = series.series(forInstrumentIds: ["1:native", "10:native"])
    #expect(summed.count == 1)
    let only = try #require(summed.first)
    #expect(only.date == day(2))
    #expect(only.value == 135)
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

  @Test
  func emptyIdsYieldEmpty() {
    let series = HistoricalValueSeries(
      hostCurrency: .AUD, total: [], perInstrument: ["1:native": [point(1, 100, 80)]])
    #expect(series.series(forInstrumentIds: []).isEmpty)
  }
}

extension HistoricalValueSeriesAssetTests {
  private func day(_ offset: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(offset) * 86_400)
  }

  private func point(_ offset: Int, _ value: Decimal, _ cost: Decimal)
    -> HistoricalValueSeries.Point
  {
    .init(date: day(offset), value: value, cost: cost, contributions: nil)
  }
}
