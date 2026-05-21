// Reason: Swift Charts mark APIs (`AreaMark`, `LineMark`,
// `AxisMarks`, `AXDataSeriesDescriptor`, etc.) take long labelled
// argument lists where SwiftLint's multi-line arguments rule fights
// the natural call-site shape. Disabling at file scope rather than
// reformatting every Charts call site to one-arg-per-line.
// swiftlint:disable multiline_arguments

import Accessibility
import Charts
import SwiftUI

/// Chart of value (solid line + soft area) and cost basis (dashed step) over
/// the active time range. Driven by `PositionsViewInput.historicalValue`.
///
/// When `selectedInstrument` is non-nil, plots that instrument's series
/// instead of the aggregate (and shows a clearable filter chip in the
/// header).
struct PositionsChart: View {
  let input: PositionsViewInput
  @Binding var range: PositionsTimeRange
  @Binding var selectedInstrument: Instrument?

  #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      chartBody
      rangePicker
    }
    .padding(.horizontal)
  }

  // MARK: - Header

  @ViewBuilder private var header: some View {
    if let selectedInstrument {
      HStack(spacing: 6) {
        KindBadge(kind: selectedInstrument.kind)
        Text(selectedInstrument.displayLabel)
          .font(.caption.weight(.semibold))
        Button {
          self.selectedInstrument = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
            .imageScale(.medium)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Clear instrument filter, showing all positions")
        Spacer()
      }
    } else {
      Text("All positions")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Chart

  /// Source of truth for the gain/loss area opacity. Both the
  /// `AreaMark` fills inside the chart AND the legend swatch must
  /// reference this constant so a tuning pass in `#Preview` adjusts
  /// the legend preview at the same time as the chart, keeping the
  /// legend an accurate visual sample of the chart fill.
  private static let gainLossOpacity: Double = 0.20

  @ViewBuilder private var chartBody: some View {
    let points = visiblePoints
    if points.isEmpty {
      ContentUnavailableView {
        Label("No chart data yet", systemImage: "chart.line.uptrend.xyaxis")
      } description: {
        Text("Record a trade to start tracking value over time.")
      }
      .frame(minHeight: 200)
    } else {
      let mode: PositionsChartMode =
        (selectedInstrument == nil) ? .aggregate : .perInstrument
      let rows = PositionsChartBaselineResolver.resolve(points: points, mode: mode)
      Chart {
        ForEach(rows, id: \.date) { row in
          chartMarks(for: row)
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
          AxisGridLine()
          AxisTick()
          if let date = value.as(Date.self) {
            AxisValueLabel {
              Text(date, format: .dateTime.month(.abbreviated))
                .font(.caption2)
            }
          }
        }
      }
      .chartYAxis {
        AxisMarks { value in
          AxisGridLine()
          AxisValueLabel {
            if let amount = value.as(Double.self) {
              Text(amount, format: .number.notation(.compactName))
                .font(.caption2)
                .monospacedDigit()
            }
          }
        }
      }
      .frame(height: 220)
      .accessibilityChartDescriptor(self)

      PositionsChartLegendRow(
        rows: rows, mode: mode, gainLossOpacity: Self.gainLossOpacity)
    }
  }

  /// Per-row mark emission. Pure presentational logic, no state
  /// mutation.
  @ChartContentBuilder
  private func chartMarks(for row: PositionsChartRenderRow) -> some ChartContent {
    if let baseline = row.baseline {
      // Always emit BOTH gain and loss area marks (with explicit
      // `series:` identifiers) when a baseline is available. Each
      // series resolves to one continuous polygon that pinches to
      // zero height at every point on the wrong side of the
      // baseline. Without the `series:` discriminator, Swift Charts
      // groups all AreaMarks into a single shape and fills the
      // entire region one colour (green shading even where
      // value < invested).
      AreaMark(
        x: .value("Date", row.date),
        yStart: .value(
          "Baseline", Double(truncating: baseline as NSDecimalNumber)),
        yEnd: .value(
          "Top",
          Double(truncating: (baseline + row.gainSegment) as NSDecimalNumber)),
        series: .value("Series", "Gain")
      )
      .foregroundStyle(Color.chartGreen.opacity(Self.gainLossOpacity))

      AreaMark(
        x: .value("Date", row.date),
        yStart: .value(
          "Bottom",
          Double(truncating: (baseline - row.lossSegment) as NSDecimalNumber)),
        yEnd: .value(
          "Baseline", Double(truncating: baseline as NSDecimalNumber)),
        series: .value("Series", "Loss")
      )
      .foregroundStyle(Color.chartRed.opacity(Self.gainLossOpacity))
    }
    LineMark(
      x: .value("Date", row.date),
      y: .value("Value", Double(truncating: row.value as NSDecimalNumber)),
      series: .value("Series", "Value")
    )
    .foregroundStyle(Color.accentColor)
    .lineStyle(StrokeStyle(lineWidth: 2))
    .interpolationMethod(.linear)
    if let baseline = row.baseline {
      LineMark(
        x: .value("Date", row.date),
        y: .value("Baseline", Double(truncating: baseline as NSDecimalNumber)),
        series: .value("Series", "Baseline")
      )
      .foregroundStyle(.secondary)
      .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
      .interpolationMethod(.stepEnd)
    }
  }

  // MARK: - Range picker

  @ViewBuilder private var rangePicker: some View {
    let picker =
      Picker("Range", selection: $range) {
        ForEach(PositionsTimeRange.allCases) { option in
          Text(option.label)
            .accessibilityLabel(option.accessibilityLabel)
            .tag(option)
        }
      }
      .accessibilityLabel("Chart time range")
    #if os(macOS)
      picker.pickerStyle(.segmented)
    #else
      if sizeClass == .compact {
        picker.pickerStyle(.menu)
      } else {
        picker.pickerStyle(.segmented)
      }
    #endif
  }

  // MARK: - Data

  /// Filtered or aggregate slice for the current selection.
  private var visiblePoints: [HistoricalValueSeries.Point] {
    guard let series = input.historicalValue else { return [] }
    if let selectedInstrument {
      return series.series(for: selectedInstrument)
    }
    return input.showsAggregateChart ? series.totalSeries : []
  }
}

// MARK: - AXChartDescriptorRepresentable

extension PositionsChart: AXChartDescriptorRepresentable {
  nonisolated func makeChartDescriptor() -> AXChartDescriptor {
    let snapshot = MainActor.assumeIsolated { chartSnapshot() }
    return AXChartDescriptor(
      title: snapshot.title,
      summary: snapshot.summary,
      xAxis: AXCategoricalDataAxisDescriptor(
        title: "Date", categoryOrder: snapshot.dateLabels
      ),
      yAxis: AXNumericDataAxisDescriptor(
        title: snapshot.yTitle,
        range: snapshot.yMin...snapshot.yMax,
        gridlinePositions: []
      ) { value in
        String(format: "%.2f", value)
      },
      additionalAxes: [],
      series: snapshot.series
    )
  }

  /// Snapshot of view state for the descriptor.
  @MainActor
  private func chartSnapshot() -> ChartSnapshot {
    let points = visiblePoints
    let title =
      selectedInstrument.map { "Chart of \($0.displayLabel)" } ?? "Chart of all positions"

    let dateLabels = points.map { $0.date.formatted(.dateTime.month(.abbreviated).day().year()) }
    let valueDoubles = points.map { Double(truncating: $0.value as NSDecimalNumber) }

    // Pair each point with its baseline (or nil); drop nil-baseline rows
    // before they reach the AX descriptor so VoiceOver doesn't speak NaN.
    let baselinePairs: [(label: String, value: Double)] = points.compactMap { point in
      let baseline: Decimal? =
        selectedInstrument == nil ? point.contributions : point.cost
      guard let baseline else { return nil }
      return (
        point.date.formatted(.dateTime.month(.abbreviated).day().year()),
        Double(truncating: baseline as NSDecimalNumber)
      )
    }

    let allValues = valueDoubles + baselinePairs.map(\.value)
    let minVal = allValues.min() ?? 0
    let maxVal = allValues.max() ?? max(minVal + 1, 1)

    let valueSeries = AXDataSeriesDescriptor(
      name: "Value", isContinuous: true,
      dataPoints: zip(dateLabels, valueDoubles).map { date, val in
        AXDataPoint(x: date, y: val)
      }
    )
    let baselineName = selectedInstrument == nil ? "Invested amount" : "Cost basis"
    let baselineSeries = AXDataSeriesDescriptor(
      name: baselineName, isContinuous: true,
      dataPoints: baselinePairs.map { AXDataPoint(x: $0.label, y: $0.value) }
    )

    let summary: String? =
      points.isEmpty
      ? "No data"
      : "\(points.count) daily points, value range \(String(format: "%.0f", minVal)) to \(String(format: "%.0f", maxVal)) \(input.hostCurrency.id)"

    return ChartSnapshot(
      title: title,
      summary: summary,
      dateLabels: dateLabels,
      yTitle: "Value (\(input.hostCurrency.id))",
      yMin: minVal,
      yMax: max(minVal + 1, maxVal),
      series: [valueSeries, baselineSeries]
    )
  }

  private struct ChartSnapshot: @unchecked Sendable {
    let title: String
    let summary: String?
    let dateLabels: [String]
    let yTitle: String
    let yMin: Double
    let yMax: Double
    let series: [AXDataSeriesDescriptor]
  }
}

// MARK: - Previews

private func previewChartInput(days: Int, base: Decimal, step: Decimal, cost: Decimal)
  -> PositionsViewInput
{
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let aud = Instrument.AUD
  let calendar = Calendar(identifier: .gregorian)
  let now = Date()
  let points: [HistoricalValueSeries.Point] = (0..<days).map { offset in
    let date = calendar.date(byAdding: .day, value: -(days - 1) + offset, to: now) ?? now
    return HistoricalValueSeries.Point(
      date: date, value: base + Decimal(offset) * step, cost: cost,
      contributions: nil)
  }
  let series = HistoricalValueSeries(
    hostCurrency: aud, total: points, perInstrument: [bhp.id: points])
  return PositionsViewInput(
    title: "Brokerage", hostCurrency: aud,
    positions: [
      ValuedPosition(
        instrument: bhp, quantity: 100, unitPrice: nil,
        costBasis: InstrumentAmount(quantity: cost, instrument: aud),
        value: InstrumentAmount(quantity: points.last?.value ?? 0, instrument: aud))
    ],
    historicalValue: series)
}

#Preview("Chart - aggregate") {
  PositionsChart(
    input: previewChartInput(days: 60, base: 10_000, step: 30, cost: 9_500),
    range: .constant(.threeMonths),
    selectedInstrument: .constant(nil)
  )
  .frame(width: 600, height: 320)
  .padding()
}

#Preview("Chart - filtered to instrument") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  return PositionsChart(
    input: previewChartInput(days: 30, base: 4_500, step: 25, cost: 4_000),
    range: .constant(.oneMonth),
    selectedInstrument: .constant(bhp)
  )
  .frame(width: 600, height: 320)
  .padding()
}

#Preview("Chart - empty") {
  PositionsChart(
    input: PositionsViewInput(
      title: "x", hostCurrency: .AUD, positions: [], historicalValue: nil
    ),
    range: .constant(.oneMonth),
    selectedInstrument: .constant(nil)
  )
  .frame(width: 600, height: 320)
  .padding()
}
