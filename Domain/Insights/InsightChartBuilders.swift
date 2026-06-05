import Foundation

/// Pure functions that turn detector-side aggregates into an `InsightChart`.
/// Each returns `nil` when the data is too sparse to chart meaningfully (fewer
/// than two points), so the insight falls back to a graph-less row.
enum InsightChartBuilders {
  /// Minimum points before a series is worth drawing.
  private static let minimumPoints = 2

  private static func point(from balance: DailyBalance) -> InsightChart.Point {
    InsightChart.Point(date: balance.date, value: balance.balance.doubleValue)
  }

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
      series.append(
        InsightChart.Series(
          id: "actual",
          label: "Balance",
          role: .primary,
          points: actual.map(point(from:))))
    }
    if !forecast.isEmpty {
      // Prepend the last actual point so the dashed projection visually
      // continues from the solid line.
      let bridge = actual.last.map { [point(from: $0)] } ?? []
      series.append(
        InsightChart.Series(
          id: "projected",
          label: "Projected",
          role: .projected,
          points: bridge + forecast.map(point(from:))))
    }
    guard !series.isEmpty else { return nil }

    let highlightPoint = highlight.flatMap { date in
      ordered.first { $0.date == date }.map(point(from:))
    }
    return InsightChart(
      kind: .line,
      unit: .currency(reportingCurrency),
      series: series,
      highlight: highlightPoint,
      xAxis: .daily)
  }

  /// Net worth over time (actual entries only), highlighting the latest
  /// reading. Adds a grey best-fit baseline when every actual entry carries
  /// one.
  static func netWorthTrend(
    _ balances: [DailyBalance],
    reportingCurrency: Instrument
  ) -> InsightChart? {
    let actual = balances.filter { !$0.isForecast }.sorted { $0.date < $1.date }
    guard actual.count >= minimumPoints else { return nil }

    var series = [
      InsightChart.Series(
        id: "networth",
        label: "Net worth",
        role: .primary,
        points: actual.map { InsightChart.Point(date: $0.date, value: $0.netWorth.doubleValue) })
    ]
    let fits = actual.compactMap(\.bestFit)
    if fits.count == actual.count {
      series.append(
        InsightChart.Series(
          id: "bestfit",
          label: "Trend",
          role: .baseline,
          points: zip(actual, fits).map { balance, fit in
            InsightChart.Point(date: balance.date, value: fit.doubleValue)
          }))
    }
    let last = actual[actual.count - 1]
    return InsightChart(
      kind: .line,
      unit: .currency(reportingCurrency),
      series: series,
      highlight: InsightChart.Point(date: last.date, value: last.netWorth.doubleValue),
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
