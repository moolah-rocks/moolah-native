import SwiftUI

/// The zoomed companion-graph view, presented as a centered sheet when the
/// user taps an insight's inline chart. Reads only what the `Insight` already
/// carries — no recompute.
struct InsightChartDetailSheet: View {
  let insight: Insight
  let headline: String
  let onNavigate: (SidebarSelection) -> Void
  let onDismiss: () -> Void

  @Environment(\.dismiss) private var dismiss

  private var target: SidebarSelection? {
    InsightNavigationTarget.sidebarSelection(for: insight.references)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      if let chart = insight.chart {
        InsightChartView(
          chart: chart, tint: framingColor, style: .expanded, accessibilityLabel: headline
        )
        .accessibilityIdentifier(UITestIdentifiers.ForYou.chartDetail)
      }
      if !insight.facts.isEmpty {
        factsList
      }
      Spacer(minLength: 0)
      actions
    }
    .padding(24)
    .dynamicTypeSize(.medium ... .accessibility3)
    #if os(macOS)
      .frame(minWidth: 420, minHeight: 420)
    #endif
    #if os(iOS)
      .presentationDetents([.medium, .large])
    #endif
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: framingIcon)
        .foregroundStyle(framingColor)
        .accessibilityLabel(framingDescription)
      Text(headline)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close")
    }
  }

  private var factsList: some View {
    VStack(spacing: 0) {
      ForEach(insight.facts) { fact in
        HStack {
          Text(fact.label).foregroundStyle(.secondary)
          Spacer()
          // `.monospacedDigit()` aligns numeric fact values (the common case)
          // and is harmless on the occasional text-only value.
          Text(fact.value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.subheadline)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        Divider()
      }
    }
  }

  @ViewBuilder private var actions: some View {
    HStack(spacing: 12) {
      Button {
        onDismiss()
        dismiss()
      } label: {
        Label("Show less", systemImage: "hand.thumbsdown")
          .font(.caption)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help("Show fewer insights like this")
      .accessibilityLabel("Show fewer insights like this: \(headline)")
      Spacer()
      if let target {
        Button {
          onNavigate(target)
          dismiss()
        } label: {
          Label("View", systemImage: "arrow.forward")
        }
        .help("View \(headline)")
        .accessibilityLabel("View \(headline)")
      }
    }
  }

  private var framingColor: Color {
    switch insight.framing {
    case .positive: return .green
    case .negative: return .orange
    case .neutral: return .secondary
    }
  }

  private var framingIcon: String {
    switch insight.framing {
    case .positive: return "checkmark.seal.fill"
    case .negative: return "exclamationmark.triangle.fill"
    case .neutral: return "info.circle.fill"
    }
  }

  private var framingDescription: String {
    switch insight.framing {
    case .positive: return "Good news"
    case .negative: return "Heads up"
    case .neutral: return "Note"
    }
  }
}

#if DEBUG
  extension Insight {
    /// A negative-framed insight with a bar chart and three facts, for previews.
    static var previewDiningAnomaly: Insight {
      let points = (0..<6).map { offset -> InsightChart.Point in
        let date = Calendar.current.date(byAdding: .month, value: -5 + offset, to: Date()) ?? Date()
        return InsightChart.Point(date: date, value: Double(100 + offset * 60))
      }
      let chart = InsightChart(
        kind: .bar,
        unit: .currency(.AUD),
        series: [InsightChart.Series(id: "spend", label: "Spend", role: .primary, points: points)],
        highlight: nil,
        xAxis: .monthly)
      return Insight(
        id: "preview",
        kind: .categorySpendingAnomaly,
        title: "Dining up 62%",
        date: Date(),
        framing: .negative,
        actionability: .review,
        surprise: 0.8,
        facts: [
          InsightFact("Category", "Dining"),
          InsightFact("This month", "$742"),
          InsightFact("Expected", "$458"),
        ],
        chart: chart)
    }

    /// A positive-framed, chart-less insight with no references (so no "View").
    static var previewNetWorthMilestone: Insight {
      Insight(
        id: "preview2",
        kind: .netWorthMilestone,
        title: "Net worth passed $100k",
        date: Date(),
        framing: .positive,
        actionability: .informational,
        surprise: 0.5,
        facts: [InsightFact("Net worth", "$101,000")])
    }
  }

  #Preview("Negative · chart + facts") {
    InsightChartDetailSheet(
      insight: .previewDiningAnomaly,
      headline: "Dining out is up 62% this month",
      onNavigate: { _ in },
      onDismiss: {})
  }

  #Preview("Positive · no chart, no View button") {
    InsightChartDetailSheet(
      insight: .previewNetWorthMilestone,
      headline: "Net worth crossed $100k",
      onNavigate: { _ in },
      onDismiss: {})
  }
#endif
