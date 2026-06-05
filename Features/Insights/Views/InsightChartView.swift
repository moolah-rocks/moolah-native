import Charts
import SwiftUI

/// Renders an `InsightChart` at one of two sizes. The detector computed the
/// data; this view only draws it (thin-view discipline).
struct InsightChartView: View {
  enum Style {
    case inline
    case expanded
  }

  let chart: InsightChart
  let tint: Color
  var style: Style = .inline

  var body: some View {
    if style == .inline {
      baseChart
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 48)
        .allowsHitTesting(false)
    } else {
      baseChart
        .chartXAxis { xAxisMarks }
        .chartYAxis { yAxisMarks }
        .frame(height: 240)
    }
  }

  private var baseChart: some View {
    Chart {
      ForEach(chart.series) { series in
        ForEach(series.points, id: \.date) { point in
          marks(for: point, in: series)
        }
      }
      if let highlight = chart.highlight {
        PointMark(
          x: .value("Date", highlight.date),
          y: .value("Value", highlight.value)
        )
        .foregroundStyle(.red)
        .symbolSize(style == .inline ? 18 : 60)
        if style == .expanded {
          RuleMark(x: .value("Date", highlight.date))
            .foregroundStyle(.red.opacity(0.25))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
      }
    }
  }

  @ChartContentBuilder
  private func marks(
    for point: InsightChart.Point, in series: InsightChart.Series
  ) -> some ChartContent {
    switch chart.kind {
    case .bar:
      BarMark(
        x: .value("Date", point.date),
        y: .value("Value", point.value)
      )
      .foregroundStyle(color(for: series.role).opacity(series.role == .primary ? 1 : 0.5))
    case .line, .area:
      LineMark(
        x: .value("Date", point.date),
        y: .value("Value", point.value),
        series: .value("Series", series.id)
      )
      .foregroundStyle(color(for: series.role))
      .lineStyle(strokeStyle(for: series.role))
      .interpolationMethod(.monotone)
    }
  }

  private func color(for role: InsightChart.SeriesRole) -> Color {
    switch role {
    case .primary: tint
    case .projected: tint.opacity(0.5)
    case .baseline: .gray
    }
  }

  private func strokeStyle(for role: InsightChart.SeriesRole) -> StrokeStyle {
    switch role {
    case .primary: StrokeStyle(lineWidth: 2)
    case .projected: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
    case .baseline: StrokeStyle(lineWidth: 1, dash: [2, 3])
    }
  }

  @AxisContentBuilder private var xAxisMarks: some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
      AxisGridLine()
      AxisTick()
      switch chart.xAxis {
      case .monthly: AxisValueLabel(format: .dateTime.month(.abbreviated))
      case .daily: AxisValueLabel(format: .dateTime.month(.abbreviated).day())
      }
    }
  }

  @AxisContentBuilder private var yAxisMarks: some AxisContent {
    AxisMarks { value in
      AxisGridLine()
      AxisValueLabel {
        if let raw = value.as(Double.self) {
          Text(formattedY(raw)).monospacedDigit()
        }
      }
    }
  }

  private func formattedY(_ raw: Double) -> String {
    switch chart.unit {
    case .currency(let instrument):
      return InstrumentAmount(quantity: Decimal(raw), instrument: instrument).formatNoSymbol
    case .percent:
      return raw.formatted(.percent.precision(.fractionLength(0)))
    case .count:
      return Int(raw.rounded()).formatted()
    }
  }
}

#Preview("Inline") {
  InsightChartView(
    chart: InsightChart(
      kind: .bar,
      unit: .currency(.AUD),
      series: [
        InsightChart.Series(
          id: "spend",
          label: "Spend",
          role: .primary,
          points: (0..<6).map {
            InsightChart.Point(
              date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 2_600_000),
              value: Double(100 + $0 * 40))
          })
      ],
      highlight: InsightChart.Point(
        date: Date(timeIntervalSince1970: 1_700_000_000 + 5 * 2_600_000), value: 300),
      xAxis: .monthly),
    tint: .orange,
    style: .inline
  )
  .padding()
  .frame(width: 220)
}

#Preview("Expanded") {
  InsightChartView(
    chart: InsightChart(
      kind: .line,
      unit: .percent,
      series: [
        InsightChart.Series(
          id: "rate",
          label: "Savings rate",
          role: .primary,
          points: (0..<6).map {
            InsightChart.Point(
              date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 2_600_000),
              value: 0.1 + Double($0) * 0.02)
          })
      ],
      highlight: nil,
      xAxis: .monthly),
    tint: .green,
    style: .expanded
  )
  .padding()
  .frame(width: 480)
}
