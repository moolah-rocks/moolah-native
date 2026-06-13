import Foundation
import Testing

@testable import Moolah

@Suite("HistoricalValueSeries")
struct HistoricalValueSeriesTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")

  private func date(_ day: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
  }

  @Test("series(forInstrumentIds:) returns the per-instrument slice when present")
  func sliceLookup() {
    let series = HistoricalValueSeries(
      hostCurrency: aud,
      total: [
        HistoricalValueSeries.Point(date: date(1), value: 100, cost: 80, contributions: nil),
        HistoricalValueSeries.Point(date: date(2), value: 110, cost: 80, contributions: nil),
      ],
      perInstrument: [
        bhp.id: [
          HistoricalValueSeries.Point(date: date(1), value: 60, cost: 50, contributions: nil)
        ]
      ]
    )

    #expect(series.series(forInstrumentIds: [bhp.id]).count == 1)
    #expect(series.series(forInstrumentIds: [cba.id]).isEmpty)
    #expect(series.totalSeries.count == 2)
  }

  @Test("instruments lists every per-instrument key")
  func instrumentsReturnsKeys() {
    let series = HistoricalValueSeries(
      hostCurrency: aud,
      total: [],
      perInstrument: [
        bhp.id: [], cba.id: [],
      ]
    )
    #expect(Set(series.instruments) == Set([bhp.id, cba.id]))
  }

  @Test("totalSeries is empty when total is empty even when perInstrument has data")
  func totalEmptyWithPerInstrumentPopulated() {
    let series = HistoricalValueSeries(
      hostCurrency: aud,
      total: [],
      perInstrument: [
        bhp.id: [
          HistoricalValueSeries.Point(date: date(1), value: 60, cost: 50, contributions: nil)
        ]
      ]
    )
    #expect(series.totalSeries.isEmpty)
    #expect(series.series(forInstrumentIds: [bhp.id]).count == 1)
  }

  @Test("Point.contributions round-trips and participates in Hashable")
  func pointContributionsRoundTrip() {
    let day = date(1)
    let populated = HistoricalValueSeries.Point(
      date: day, value: 100, cost: 80, contributions: 50
    )
    let unavailable = HistoricalValueSeries.Point(
      date: day, value: 100, cost: 80, contributions: nil
    )
    #expect(populated.contributions == 50)
    #expect(unavailable.contributions == nil)
    #expect(populated != unavailable)
    #expect(Set([populated, unavailable]).count == 2)
  }
}
