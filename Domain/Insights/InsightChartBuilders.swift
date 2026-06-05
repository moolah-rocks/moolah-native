import Foundation

/// Pure functions that turn detector-side aggregates into an `InsightChart`.
/// Each returns `nil` when the data is too sparse to chart meaningfully (fewer
/// than two points), so the insight falls back to a graph-less row.
enum InsightChartBuilders {
  /// Minimum points before a series is worth drawing.
  private static let minimumPoints = 2

  /// A category's monthly spend (positive magnitudes), as a bar chart with the
  /// anomalous / latest financial month highlighted.
  static func categorySpend(
    points: [MonthlySpendPoint],
    reportingCurrency: Instrument,
    highlightMonth: String
  ) -> InsightChart? {
    guard points.count >= minimumPoints else { return nil }
    let ordered = points.sorted { $0.date < $1.date }
    let chartPoints = ordered.map { InsightChart.Point(date: $0.date, value: $0.magnitude) }
    let highlight = ordered.first { $0.month == highlightMonth }
      .map { InsightChart.Point(date: $0.date, value: $0.magnitude) }
    return InsightChart(
      kind: .bar,
      unit: .currency(reportingCurrency),
      series: [
        InsightChart.Series(
          id: "spend", label: "Spend", role: .primary, points: chartPoints)
      ],
      highlight: highlight,
      xAxis: .monthly)
  }
}
