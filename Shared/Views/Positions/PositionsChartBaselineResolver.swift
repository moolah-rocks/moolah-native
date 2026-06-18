import Foundation

/// Caseless `enum` (CODE_GUIDE.md §5 — pure namespace) that turns a
/// `[HistoricalValueSeries.Point]` into the per-row rendering inputs
/// the chart consumes. Pure function with no SwiftUI dependency so
/// the data-shape tests can exercise the rendering decisions
/// without spinning up a view harness.
enum PositionsChartBaselineResolver {
  /// `true` iff the series carries a non-zero baseline to plot for `mode`
  /// (aggregate → `point.contributions`; per-instrument → `point.cost`).
  ///
  /// `false` for a wallet of transfer-in/airdrop tokens whose baseline is
  /// uniformly zero/absent — plotting a zero baseline would misleadingly
  /// render the whole holding as gain.
  static func showsBaseline(points: [HistoricalValueSeries.Point], mode: PositionsChartMode) -> Bool
  {
    points.contains { point in
      let baseline: Decimal? = (mode == .aggregate) ? point.contributions : point.cost
      return (baseline ?? 0) != 0
    }
  }

  /// Turns a `[HistoricalValueSeries.Point]` into the per-row rendering inputs
  /// the chart consumes.
  ///
  /// - Parameters:
  ///   - points: Raw data points from `HistoricalValueSeries`.
  ///   - mode: Aggregate (uses `point.contributions`) or per-instrument (uses
  ///     `point.cost`).
  ///   - showBaseline: When `false`, `baseline` is forced to `nil` for every
  ///     row, suppressing gain/loss shading and the dashed baseline line. Pass
  ///     `false` when no position in the account carries a cost basis — a zero
  ///     baseline would render the entire holding as gain, which is misleading
  ///     for transfer-in or airdrop tokens.
  static func resolve(
    points: [HistoricalValueSeries.Point],
    mode: PositionsChartMode,
    showBaseline: Bool
  ) -> [PositionsChartRenderRow] {
    guard !points.isEmpty else { return [] }
    let lastIndex = points.count - 1
    return points.enumerated().map { index, point in
      let baseline: Decimal?
      if showBaseline {
        switch mode {
        case .aggregate: baseline = point.contributions
        case .perInstrument: baseline = point.cost
        }
      } else {
        baseline = nil
      }
      let gain = baseline.map { max(point.value - $0, 0) } ?? 0
      let loss = baseline.map { max($0 - point.value, 0) } ?? 0
      let isLast = (index == lastIndex)
      return PositionsChartRenderRow(
        date: point.date,
        value: point.value,
        baseline: baseline,
        gainSegment: gain,
        lossSegment: loss,
        legendUnavailable: isLast && baseline == nil
      )
    }
  }
}
