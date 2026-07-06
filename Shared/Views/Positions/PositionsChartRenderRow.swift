import Foundation

/// Per-point rendering inputs computed by
/// `PositionsChartBaselineResolver.resolve`. The chart consumes
/// `baseline`, `gainSegment`, and `lossSegment` directly to emit
/// `AreaMark` / `LineMark` per row; `legendUnavailable` on the last
/// entry drives the legend swatch state.
///
/// Plain Swift with no SwiftUI dependency, so the resolver tests
/// cleanly without `@MainActor` machinery.
struct PositionsChartRenderRow: Sendable, Hashable {
  let date: Date
  let value: Decimal
  /// `nil` when the per-mode baseline is unavailable for this point
  /// (per-instrument: cost — but cost is non-optional, so this only
  /// happens in aggregate mode where `invested` can be `nil` when the
  /// ledger marks an in-scope key unavailable, Rule 11). When `nil`,
  /// the chart emits the value line only — no area, no baseline line
  /// for this row.
  let baseline: Decimal?
  /// `max(value - baseline, 0)` when baseline is non-nil, else 0.
  let gainSegment: Decimal
  /// `max(baseline - value, 0)` when baseline is non-nil, else 0.
  let lossSegment: Decimal
  /// True for every row whose `baseline == nil` AND the row is the
  /// last in the resolved sequence — drives the legend's
  /// "Profit/Loss unavailable" state. Always false on non-last rows
  /// (the chart's legend reads only the most recent point's value).
  let legendUnavailable: Bool
}
