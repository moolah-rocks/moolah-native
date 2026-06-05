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
    .frame(minWidth: 420, minHeight: 420)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: framingIcon)
        .foregroundStyle(framingColor)
        .accessibilityHidden(true)
      Text(headline)
        .font(.headline)
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
          Text(fact.value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.subheadline)
        .padding(.vertical, 8)
        Divider()
      }
    }
  }

  @ViewBuilder private var actions: some View {
    HStack(spacing: 12) {
      Button(role: .destructive) {
        onDismiss()
        dismiss()
      } label: {
        Label("Show less", systemImage: "hand.thumbsdown")
      }
      Spacer()
      if let target {
        Button {
          onNavigate(target)
          dismiss()
        } label: {
          Label("View", systemImage: "arrow.forward")
        }
        .keyboardShortcut(.defaultAction)
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
}
