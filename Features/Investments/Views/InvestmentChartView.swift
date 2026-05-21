import Charts
import SwiftUI

/// Multi-series investment chart with value, invested amount, and profit/loss.
struct InvestmentChartView: View {
  let dataPoints: [InvestmentChartDataPoint]
  let instrument: Instrument

  @State private var selectedDate: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if dataPoints.isEmpty {
        emptyState
      } else {
        ExpandableChart(title: "Investment Performance") {
          chartContent
        }
        legend
      }
    }
    .padding()
    .background(.background)
    .cornerRadius(12)
  }

  private var emptyState: some View {
    Text("Not enough data for chart")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .frame(height: 250)
  }

  private var chartContent: some View {
    VStack(spacing: 8) {
      chart

      // Selection detail overlay
      if let selectedDate, let point = closestPoint(to: selectedDate) {
        selectionDetail(point: point)
      }
    }
  }

  @ChartContentBuilder
  private func marks(for point: InvestmentChartDataPoint) -> some ChartContent {
    // Profit/Loss area (orange)
    if let profitLoss = point.profitLoss {
      AreaMark(
        x: .value("Date", point.date),
        y: .value("Profit/Loss", Double(truncating: profitLoss as NSDecimalNumber))
      )
      .foregroundStyle(Color.chartOrange.opacity(0.2))
      .interpolationMethod(.catmullRom)
    }
    // Investment Value line (blue)
    if let value = point.value {
      LineMark(
        x: .value("Date", point.date),
        y: .value("Value", Double(truncating: value as NSDecimalNumber)),
        series: .value("Series", "Value")
      )
      .foregroundStyle(Color.chartBlue)
      .lineStyle(StrokeStyle(lineWidth: 2))
      .interpolationMethod(.catmullRom)
    }
    // Invested Amount line (gray, step interpolation)
    if let balance = point.balance {
      LineMark(
        x: .value("Date", point.date),
        y: .value("Balance", Double(truncating: balance as NSDecimalNumber)),
        series: .value("Series", "Balance")
      )
      .foregroundStyle(.gray)
      .lineStyle(StrokeStyle(lineWidth: 2))
      .interpolationMethod(.stepEnd)
    }
  }

  private var chart: some View {
    Chart {
      ForEach(dataPoints) { point in
        marks(for: point)
      }
      // Selection rule
      if let selectedDate {
        RuleMark(x: .value("Selected", selectedDate))
          .foregroundStyle(.gray.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1))
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 6)) { value in
        AxisGridLine()
        AxisTick()
        if let date = value.as(Date.self) {
          AxisValueLabel {
            Text(date, format: .dateTime.month(.abbreviated).year(.twoDigits))
              .font(.caption)
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            Text(
              InstrumentAmount(quantity: Decimal(amount), instrument: instrument).formatNoSymbol
            )
            .monospacedDigit()
            .font(.caption)
          }
        }
      }
    }
    .chartXSelection(value: $selectedDate)
    .chartLegend(.hidden)
    .frame(height: 250)
    .accessibilityLabel(
      "Investment chart showing value, invested amount, and profit or loss over time")
  }

  @ViewBuilder
  private func selectionDetail(point: InvestmentChartDataPoint) -> some View {
    HStack(spacing: 16) {
      Text(point.date, format: .dateTime.day().month(.abbreviated).year())
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()

      if let value = point.value {
        detailItem(
          label: "Value",
          amount: InstrumentAmount(quantity: value, instrument: instrument),
          color: .chartBlue)
      }

      if let balance = point.balance {
        detailItem(
          label: "Invested",
          amount: InstrumentAmount(quantity: balance, instrument: instrument),
          color: .gray)
      }

      if let profitLoss = point.profitLoss {
        detailItem(
          label: "P/L",
          amount: InstrumentAmount(quantity: profitLoss, instrument: instrument),
          color: .chartOrange)
      }
    }
    .font(.caption)
    .padding(.horizontal)
  }

  private func detailItem(label: String, amount: InstrumentAmount, color: Color) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text(label)
        .foregroundStyle(.secondary)
      InstrumentAmountView(amount: amount, font: .caption)
    }
    .accessibilityElement(children: .combine)
  }

  private var legend: some View {
    HStack(spacing: 16) {
      LegendItem(color: .chartBlue, label: "Investment Value")
      LegendItem(color: .gray, label: "Invested Amount")
      LegendItem(color: .chartOrange, label: "Profit/Loss")
    }
    .font(.caption)
  }

  private func closestPoint(to date: Date) -> InvestmentChartDataPoint? {
    dataPoints.min(by: {
      abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
    })
  }
}

#Preview {
  let calendar = Calendar.current
  let points: [InvestmentChartDataPoint] = (0..<12).reversed().map { monthsAgo in
    let date = calendar.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date()
    let balance: Decimal = 10_000 + Decimal(12 - monthsAgo) * 500
    let value: Decimal = balance + Decimal(Double.random(in: -1_000...2_500))
    return InvestmentChartDataPoint(
      date: date,
      value: value,
      balance: balance,
      profitLoss: value - balance
    )
  }
  InvestmentChartView(dataPoints: points, instrument: .AUD)
    .frame(width: 560, height: 320)
    .padding()
}

#Preview("Empty") {
  InvestmentChartView(dataPoints: [], instrument: .AUD)
    .frame(width: 560, height: 320)
    .padding()
}
