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
  var accessibilityLabel: String = ""

  var body: some View {
    if style == .inline {
      baseChart
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 72)
        // Inline sparkline: keep marks inside the declared frame so a mark at the
        // plot edge can't bleed into the panel's text column beside it.
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .dynamicTypeSize(.medium ... .accessibility1)
    } else {
      baseChart
        .chartXAxis { xAxisMarks }
        .chartYAxis { yAxisMarks }
        .frame(minHeight: 200, idealHeight: 240)
        .accessibilityLabel(
          accessibilityLabel.isEmpty
            ? chart.series.map(\.label).joined(separator: ", ")
            : accessibilityLabel)
    }
  }

  private var baseChart: some View {
    Chart {
      ForEach(chart.series) { series in
        // Positional identity: two points in a series can share a date (e.g. a
        // burndown's current/start landing on the same day), so `\.date` is not
        // a unique key.
        ForEach(Array(series.points.enumerated()), id: \.offset) { _, point in
          marks(for: point, in: series)
        }
      }
      if let highlight = chart.highlight {
        PointMark(
          x: .value("Date", highlight.date),
          y: .value("Value", highlight.value)
        )
        .foregroundStyle(tint)
        .symbolSize(style == .inline ? 18 : 60)
        if style == .expanded {
          RuleMark(x: .value("Date", highlight.date))
            .foregroundStyle(tint.opacity(0.25))
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
    case .line:
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
    case .baseline: .secondary
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
    AxisMarks(values: .automatic(desiredCount: 5)) { value in
      AxisGridLine()
      AxisTick()
      AxisValueLabel {
        if let date = value.as(Date.self) {
          switch chart.xAxis {
          case .monthly: Text(date, format: .dateTime.month(.abbreviated)).monospacedDigit()
          case .daily: Text(date, format: .dateTime.month(.abbreviated).day()).monospacedDigit()
          }
        }
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

private func previewMonth(_ offset: Int) -> Date {
  Calendar.current.date(byAdding: .month, value: -5 + offset, to: Date()) ?? Date()
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
            InsightChart.Point(date: previewMonth($0), value: Double(100 + $0 * 40))
          })
      ],
      highlight: InsightChart.Point(date: previewMonth(5), value: 300),
      xAxis: .monthly),
    tint: .orange,
    style: .inline
  )
  .padding()
  .frame(width: 220)
}

#Preview("Inline · Dark") {
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
            InsightChart.Point(date: previewMonth($0), value: Double(100 + $0 * 40))
          })
      ],
      highlight: InsightChart.Point(date: previewMonth(5), value: 300),
      xAxis: .monthly),
    tint: .orange,
    style: .inline
  )
  .padding()
  .frame(width: 220)
  .preferredColorScheme(.dark)
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
            InsightChart.Point(date: previewMonth($0), value: 0.1 + Double($0) * 0.02)
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
