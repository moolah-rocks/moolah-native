import Foundation

/// Pure functions that turn detector-side aggregates into an `InsightChart`.
/// Each returns `nil` when the data is too sparse to chart meaningfully (fewer
/// than two points), so the insight falls back to a graph-less row.
enum InsightChartBuilders {
  /// Minimum points before a series is worth drawing.
  private static let minimumPoints = 2

  /// Daily current-funds balance: the actual tail solid, the forecast tail
  /// dashed, with `highlight` marking the trough or projected month-end day.
  /// The two tails are joined at the boundary so the projection continues the
  /// actual line rather than starting from zero.
  static func balanceForecast(
    _ balances: [DailyBalance],
    reportingCurrency: Instrument,
    highlight: Date?
  ) -> InsightChart? {
    let ordered = balances.sorted { $0.date < $1.date }
    guard ordered.count >= minimumPoints else { return nil }

    let actual = ordered.filter { !$0.isForecast }
    let forecast = ordered.filter(\.isForecast)
    var series: [InsightChart.Series] = []
    if !actual.isEmpty {
      let actualPoints = actual.map {
        InsightChart.Point(date: $0.date, value: $0.balance.doubleValue)
      }
      series.append(
        InsightChart.Series(
          id: "actual",
          label: "Balance",
          role: .primary,
          points: actualPoints))
    }
    if !forecast.isEmpty {
      // Prepend the last actual point so the dashed projection visually
      // continues from the solid line.
      let bridge =
        actual.last.map {
          [InsightChart.Point(date: $0.date, value: $0.balance.doubleValue)]
        } ?? []
      let forecastPoints = forecast.map {
        InsightChart.Point(date: $0.date, value: $0.balance.doubleValue)
      }
      series.append(
        InsightChart.Series(
          id: "projected",
          label: "Projected",
          role: .projected,
          points: bridge + forecastPoints))
    }
    guard !series.isEmpty else { return nil }

    let highlightPoint = highlight.flatMap { date in
      ordered.first { $0.date == date }
        .map { InsightChart.Point(date: $0.date, value: $0.balance.doubleValue) }
    }
    return InsightChart(
      kind: .line,
      unit: .currency(reportingCurrency),
      series: series,
      highlight: highlightPoint,
      xAxis: .daily)
  }

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
