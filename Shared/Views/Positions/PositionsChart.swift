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
/// When `selection` is non-nil, plots that asset's combined series instead of
/// the aggregate (and shows a clearable filter chip in the header).
struct PositionsChart: View {
  let input: PositionsViewInput
  @Binding var range: PositionsTimeRange
  @Binding var selection: PositionSelection?

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
    if let selection {
      HStack(spacing: 6) {
        KindBadge(kind: selection.kind)
        Text(selection.displayLabel)
          .font(.caption.weight(.semibold))
        Button {
          self.selection = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
            .imageScale(.medium)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        #if os(macOS)
          .frame(minWidth: 44, minHeight: 44)
        #else
          // Pin to exactly 44×44 on iOS: with only a `minWidth`/`minHeight`
          // a constrained header `HStack` can still compress the hit area
          // below the HIG touch minimum. The `maxWidth`/`maxHeight` clamp
          // makes the 44pt target non-compressible.
          .frame(minWidth: 44, maxWidth: 44, minHeight: 44, maxHeight: 44)
        #endif
        .contentShape(Rectangle())
        .accessibilityLabel("Clear \(selection.displayLabel) filter")
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
        Text("Record your first trade and we'll start charting its value over time.")
      }
      .frame(minHeight: 200)
    } else {
      let mode: PositionsChartMode =
        (selection == nil) ? .aggregate : .perInstrument
      let showBaseline = PositionsChartBaselineResolver.showsBaseline(points: points, mode: mode)
      let rows = PositionsChartBaselineResolver.resolve(
        points: points, mode: mode, showBaseline: showBaseline)
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
        rows: rows, mode: mode, gainLossOpacity: Self.gainLossOpacity,
        showBaseline: showBaseline)
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
    if let selection {
      return series.series(forInstrumentIds: selection.instrumentIds)
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
      selection.map { "Chart of \($0.displayLabel)" } ?? "Chart of all positions"

    let dateLabels = points.map { $0.date.formatted(.dateTime.month(.abbreviated).day().year()) }
    let valueDoubles = points.map { Double(truncating: $0.value as NSDecimalNumber) }

    // Derive the chart mode from whether a specific instrument is selected,
    // then let the data decide whether a baseline is meaningful. This mirrors
    // the data-driven decision in `chartBody` so VoiceOver and the visual chart
    // agree: when the series carries no cost/contribution data (e.g. a wallet
    // of transfer-in / airdrop tokens), neither the chart nor the AX descriptor
    // exposes a phantom zero baseline.
    let mode: PositionsChartMode = selection == nil ? .aggregate : .perInstrument
    let showBaseline = PositionsChartBaselineResolver.showsBaseline(points: points, mode: mode)

    // Pair each point with its baseline (or nil); drop nil-baseline rows
    // before they reach the AX descriptor so VoiceOver doesn't speak NaN.
    let baselinePairs: [(label: String, value: Double)] =
      showBaseline
      ? points.compactMap { point in
        let baseline: Decimal? =
          selection == nil ? point.contributions : point.cost
        guard let baseline else { return nil }
        return (
          point.date.formatted(.dateTime.month(.abbreviated).day().year()),
          Double(truncating: baseline as NSDecimalNumber)
        )
      }
      : []

    let allValues = valueDoubles + baselinePairs.map(\.value)
    let minVal = allValues.min() ?? 0
    let maxVal = allValues.max() ?? max(minVal + 1, 1)

    let valueSeries = AXDataSeriesDescriptor(
      name: "Value", isContinuous: true,
      dataPoints: zip(dateLabels, valueDoubles).map { date, val in
        AXDataPoint(x: date, y: val)
      }
    )

    var series: [AXDataSeriesDescriptor] = [valueSeries]
    if showBaseline {
      let baselineName = selection == nil ? "Invested amount" : "Cost basis"
      let baselineSeries = AXDataSeriesDescriptor(
        name: baselineName, isContinuous: true,
        dataPoints: baselinePairs.map { AXDataPoint(x: $0.label, y: $0.value) }
      )
      series.append(baselineSeries)
    }

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
      series: series
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
    selection: .constant(nil)
  )
  .frame(width: 600, height: 320)
  .padding()
}

#Preview("Chart - filtered to instrument") {
  let bhp = AssetHolding(
    id: "ASX:BHP.AX", kind: .stock, name: "BHP", displayLabel: "BHP.AX", decimals: 0,
    currencyCode: nil, chainId: nil, exchange: "ASX", quantity: 100, unitPrice: nil,
    costBasis: nil, value: nil, contributingInstrumentIds: ["ASX:BHP.AX"],
    contributingChainIds: [])
  return PositionsChart(
    input: previewChartInput(days: 30, base: 4_500, step: 25, cost: 4_000),
    range: .constant(.oneMonth),
    selection: .constant(bhp.positionSelection)
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
    selection: .constant(nil)
  )
  .frame(width: 600, height: 320)
  .padding()
}
