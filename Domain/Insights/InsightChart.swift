import Foundation

/// A companion graph a detector attaches to an `Insight` to visualise the
/// behaviour it detected. Pure data: the detector computes it (off the main
/// actor, alongside the `Insight`) and the view renders it — no charting
/// logic lives in views, mirroring how `InsightFact` is the single source of
/// truth for any rendered number.
struct InsightChart: Sendable, Hashable {
  /// How the primary series is drawn.
  enum Kind: Sendable, Hashable {
    case line
    case bar
  }

  /// The unit of the y values, driving axis/label formatting. `currency`
  /// carries the reporting instrument so the view can format without a
  /// global currency.
  enum Unit: Sendable, Hashable {
    case currency(Instrument)
    case percent
    case count
  }

  /// The role a series plays, driving its visual treatment.
  enum SeriesRole: Sendable, Hashable {
    /// The actual measured series (solid, tinted).
    case primary
    /// A forward projection (dashed, lighter).
    case projected
    /// A reference line such as a budget or best-fit (grey, dashed).
    case baseline
  }

  /// X-axis tick granularity.
  enum XAxisStyle: Sendable, Hashable {
    case monthly
    case daily
  }

  /// A single (date, value) sample. `value` is in the chart's `unit`
  /// (reporting-currency amount, a 0...1 fraction for `percent`, or a count).
  struct Point: Sendable, Hashable {
    let date: Date
    let value: Double
  }

  /// A named sequence of `Point`s with a visual role. `id` is a stable
  /// detector-assigned key for SwiftUI diffing.
  struct Series: Sendable, Hashable, Identifiable {
    let id: String
    let label: String
    let role: SeriesRole
    let points: [Point]
  }

  let kind: Kind
  let unit: Unit
  let series: [Series]
  /// The point/period to mark (the anomaly, trough, or latest reading).
  let highlight: Point?
  let xAxis: XAxisStyle
}
