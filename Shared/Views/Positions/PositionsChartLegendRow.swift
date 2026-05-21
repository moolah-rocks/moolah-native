import SwiftUI

/// Legend row + swatch helpers for `PositionsChart`. Private to the
/// legend's rendering; not reused elsewhere.
struct PositionsChartLegendRow: View {
  let rows: [PositionsChartRenderRow]
  let mode: PositionsChartMode
  /// Source of truth for the gain/loss area opacity. Both the
  /// `AreaMark` fills inside the chart AND the legend swatch
  /// reference this constant so a tuning pass adjusts the legend
  /// preview at the same time as the chart, keeping the legend an
  /// accurate visual sample of the chart fill.
  let gainLossOpacity: Double

  var body: some View {
    let baselineLabel = (mode == .aggregate) ? "Invested amount" : "Cost basis"
    let unavailable = rows.last?.legendUnavailable == true
    HStack(spacing: 16) {
      PositionsChartLegendItem(color: .accentColor, label: "Value", dashed: false)
      PositionsChartLegendItem(color: .secondary, label: baselineLabel, dashed: true)
      ProfitLossLegendSwatch(unavailable: unavailable, opacity: gainLossOpacity)
      Spacer()
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }
}

private struct PositionsChartLegendItem: View {
  let color: Color
  let label: String
  let dashed: Bool

  var body: some View {
    HStack(spacing: 4) {
      if dashed {
        DashedLineSwatch(color: color)
      } else {
        Capsule()
          .fill(color)
          .frame(width: 14, height: 2)
      }
      Text(label)
    }
    .accessibilityElement(children: .combine)
    // Append the line-style cue so VoiceOver can disambiguate two
    // entries that differ only in solid-vs-dashed (the legend's
    // "Value" line is solid; the baseline line is dashed). Color
    // alone never carries information per UI_GUIDE.md §5.
    .accessibilityLabel(dashed ? "\(label), dashed line" : "\(label), solid line")
  }
}

private struct DashedLineSwatch: View {
  let color: Color
  var body: some View {
    GeometryReader { _ in
      Path { path in
        path.move(to: .init(x: 0, y: 1))
        path.addLine(to: .init(x: 14, y: 1))
      }
      .stroke(style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
      .foregroundStyle(color)
    }
    .frame(width: 14, height: 2)
  }
}

/// Two-tone gain/loss swatch + label. UI_GUIDE.md §5 — colour is
/// never the sole differentiator: the label "Profit/Loss" is the
/// non-color pairing. Inner colour blocks are
/// `.accessibilityHidden(true)` and the combined element carries a
/// single descriptive `.accessibilityLabel`.
private struct ProfitLossLegendSwatch: View {
  let unavailable: Bool
  let opacity: Double

  var body: some View {
    HStack(spacing: 4) {
      VStack(spacing: 1) {
        Rectangle()
          .fill(
            unavailable
              ? Color.gray.opacity(opacity)
              : Color.chartGreen.opacity(opacity)
          )
          .frame(width: 14, height: 4)
        Rectangle()
          .fill(
            unavailable
              ? Color.gray.opacity(opacity)
              : Color.chartRed.opacity(opacity)
          )
          .frame(width: 14, height: 4)
      }
      .accessibilityHidden(true)
      Text(unavailable ? "Profit/Loss unavailable" : "Profit/Loss")
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      unavailable ? "Profit and Loss area, unavailable" : "Profit and Loss area"
    )
  }
}
