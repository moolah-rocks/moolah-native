import Foundation
import Testing

@testable import Moolah

@Suite("PositionsChart data shape")
struct PositionsChartDataTests {
  let aud = Instrument.AUD

  private func point(
    day: Int, value: Decimal, cost: Decimal, contributions: Decimal?
  ) throws -> HistoricalValueSeries.Point {
    let calendar = Calendar(identifier: .gregorian)
    var epoch = DateComponents()
    epoch.year = 2026
    epoch.month = 1
    epoch.day = 1
    let base = try #require(calendar.date(from: epoch))
    let date = try #require(calendar.date(byAdding: .day, value: day, to: base))
    return HistoricalValueSeries.Point(
      date: date, value: value, cost: cost, contributions: contributions
    )
  }

  @Test("aggregate mode picks point.contributions as baseline")
  func aggregateBaselineIsContributions() throws {
    let points = try [
      point(day: 0, value: 1_100, cost: 800, contributions: 1_000),
      point(day: 1, value: 1_150, cost: 800, contributions: 1_000),
    ]
    let resolved = PositionsChartBaselineResolver.resolve(
      points: points, mode: .aggregate, showBaseline: true
    )
    #expect(resolved.map(\.baseline) == [1_000, 1_000])
    #expect(resolved.map(\.gainSegment) == [100, 150])
    #expect(resolved.map(\.lossSegment) == [0, 0])
    #expect(resolved.last?.legendUnavailable == false)
  }

  @Test("per-instrument mode picks point.cost as baseline")
  func perInstrumentBaselineIsCost() throws {
    let points = try [
      point(day: 0, value: 850, cost: 800, contributions: nil),
      point(day: 1, value: 900, cost: 800, contributions: nil),
    ]
    let resolved = PositionsChartBaselineResolver.resolve(
      points: points, mode: .perInstrument, showBaseline: true
    )
    #expect(resolved.map(\.baseline) == [800, 800])
    #expect(resolved.map(\.gainSegment) == [50, 100])
  }

  @Test("loss segments are emitted when value < baseline")
  func lossSegments() throws {
    let points = try [point(day: 0, value: 950, cost: 1_000, contributions: nil)]
    let resolved = PositionsChartBaselineResolver.resolve(
      points: points, mode: .perInstrument, showBaseline: true
    )
    #expect(resolved[0].gainSegment == 0)
    #expect(resolved[0].lossSegment == 50)
  }

  @Test("nil baseline produces a no-area entry; value-line still renderable")
  func nilBaselineSuppressesArea() throws {
    let points = try [
      point(day: 0, value: 1_100, cost: 800, contributions: 1_000),
      point(day: 1, value: 1_150, cost: 800, contributions: nil),
    ]
    let resolved = PositionsChartBaselineResolver.resolve(
      points: points, mode: .aggregate, showBaseline: true
    )
    #expect(resolved[0].baseline != nil)
    #expect(resolved[1].baseline == nil)
    #expect(resolved[1].gainSegment == 0)
    #expect(resolved[1].lossSegment == 0)
  }

  @Test("most-recent point with nil baseline triggers legend-unavailable signal")
  func legendUnavailableWhenLatestNil() throws {
    let points = try [
      point(day: 0, value: 1_100, cost: 800, contributions: 1_000),
      point(day: 1, value: 1_150, cost: 800, contributions: nil),
    ]
    let resolved = PositionsChartBaselineResolver.resolve(
      points: points, mode: .aggregate, showBaseline: true
    )
    #expect(resolved.last?.legendUnavailable == true)
  }

  @Test("showBaseline:false suppresses baseline for all rows regardless of mode")
  func showBaselineFalseSuppressesAllBaselines() throws {
    let points = try [
      point(day: 0, value: 1_100, cost: 800, contributions: 1_000),
      point(day: 1, value: 1_200, cost: 850, contributions: 1_050),
    ]
    // Both aggregate and perInstrument modes should yield nil baseline when showBaseline is false.
    for mode in [PositionsChartMode.aggregate, PositionsChartMode.perInstrument] {
      let resolved = PositionsChartBaselineResolver.resolve(
        points: points, mode: mode, showBaseline: false
      )
      #expect(resolved.map(\.baseline) == [nil, nil], "baseline should be nil for mode \(mode)")
      #expect(resolved.map(\.gainSegment) == [0, 0], "gain should be zero for mode \(mode)")
      #expect(resolved.map(\.lossSegment) == [0, 0], "loss should be zero for mode \(mode)")
      #expect(
        resolved.last?.legendUnavailable == true,
        "last row legendUnavailable when baseline suppressed for mode \(mode)")
    }
  }

  @Test("showBaseline:false renders value line even when cost data is present")
  func showBaselineFalsePreservesValueLine() throws {
    let points = try [
      point(day: 0, value: 500, cost: 400, contributions: 450),
      point(day: 1, value: 600, cost: 400, contributions: 450),
    ]
    let resolved = PositionsChartBaselineResolver.resolve(
      points: points, mode: .aggregate, showBaseline: false
    )
    #expect(resolved.map(\.value) == [500, 600], "value series is preserved")
    #expect(resolved.map(\.baseline) == [nil, nil], "baseline remains suppressed")
  }

  // MARK: - showsBaseline(points:mode:)

  @Test("showsBaseline aggregate: true when contributions has a non-zero value")
  func showsBaselineAggregateTrueWhenContributionsNonZero() throws {
    let points = try [
      point(day: 0, value: 1_100, cost: 800, contributions: nil),
      point(day: 1, value: 1_200, cost: 900, contributions: 1_000),
    ]
    #expect(
      PositionsChartBaselineResolver.showsBaseline(points: points, mode: .aggregate),
      "aggregate mode returns true when at least one point has non-zero contributions"
    )
  }

  @Test("showsBaseline aggregate: false when all contributions are nil or zero")
  func showsBaselineAggregateFalseWhenContributionsAllNilOrZero() throws {
    let points = try [
      point(day: 0, value: 500, cost: 0, contributions: nil),
      point(day: 1, value: 600, cost: 0, contributions: 0),
    ]
    #expect(
      !PositionsChartBaselineResolver.showsBaseline(points: points, mode: .aggregate),
      "aggregate mode returns false when all contributions are nil or zero"
    )
  }

  @Test("showsBaseline perInstrument: true when cost has a non-zero value")
  func showsBaselinePerInstrumentTrueWhenCostNonZero() throws {
    let points = try [
      point(day: 0, value: 850, cost: 800, contributions: nil),
      point(day: 1, value: 900, cost: 800, contributions: nil),
    ]
    #expect(
      PositionsChartBaselineResolver.showsBaseline(points: points, mode: .perInstrument),
      "perInstrument mode returns true when at least one point has non-zero cost"
    )
  }

  @Test("showsBaseline perInstrument: false when all cost values are zero")
  func showsBaselinePerInstrumentFalseWhenCostAllZero() throws {
    let points = try [
      point(day: 0, value: 500, cost: 0, contributions: nil),
      point(day: 1, value: 600, cost: 0, contributions: nil),
    ]
    #expect(
      !PositionsChartBaselineResolver.showsBaseline(points: points, mode: .perInstrument),
      "perInstrument mode returns false when all cost values are zero"
    )
  }
}
