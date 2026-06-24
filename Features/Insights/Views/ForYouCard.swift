import SwiftUI

/// The "For You" dashboard panel: renders the ready-to-show insight batch — each
/// a single headline line (which states any signed impact inline), a "Show less"
/// control, and an optional deep-link. Pure presentational view: the store
/// resolves headlines,
/// caps the batch, and holds the whole batch until ready; this binds the
/// published `items` and dispatches the closures. `AnalysisView` renders it only
/// when `items` is non-empty, so this view assumes a non-empty list.
struct ForYouCard: View {
  let items: [ForYouItem]
  let onDismiss: (ForYouItem) -> Void
  let onNavigate: (SidebarSelection) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("For You")
        .font(.title2)
        .fontWeight(.semibold)
        // Identifier on the header leaf, NOT the card container: an
        // `.accessibilityIdentifier` on the outer VStack propagates to every
        // descendant element, clobbering each row/button's own identifier.
        .accessibilityIdentifier(UITestIdentifiers.ForYou.card)
      VStack(spacing: 8) {
        ForEach(items) { item in
          InsightRow(
            item: item,
            onDismiss: { onDismiss(item) },
            onNavigate: onNavigate)
        }
      }
    }
    .padding()
    .background(.background)
    .clipShape(.rect(cornerRadius: 12))
  }
}

private struct InsightRow: View {
  let item: ForYouItem
  let onDismiss: () -> Void
  let onNavigate: (SidebarSelection) -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var isZoomed = false

  private var insight: Insight { item.scored.insight }
  private var target: SidebarSelection? {
    InsightNavigationTarget.sidebarSelection(for: insight.references)
  }

  var body: some View {
    // The panel is a two-column layout: the textual content (headline + impact +
    // controls) forms a flexible left column that takes all remaining width, and
    // the companion graph is a fixed-size sibling pinned to the right. Keeping the
    // graph out of the text's HStack is what stops the fixed-width chart from
    // overrunning the row and collapsing the headline into a sliver. At
    // accessibility type sizes the inline graph would crowd the stacked content,
    // so it drops to the bottom of the left column (full width) instead.
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          textColumn
          chartButton
        }
      } else {
        HStack(alignment: .center, spacing: 12) {
          textColumn
          chartButton
        }
      }
    }
    // Grouped under the row identifier so a UI test can assert the row's
    // presence/removal; children (headline Text, "Show less", "View") stay
    // independently addressable for their own identifiers and as separate
    // VoiceOver elements.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(UITestIdentifiers.ForYou.row(insight.id))
    .sheet(isPresented: $isZoomed) {
      InsightChartDetailSheet(
        insight: insight,
        headline: item.headline,
        onNavigate: onNavigate,
        onDismiss: onDismiss)
    }
  }

  // MARK: - Layout

  /// Claims all the width the companion graph doesn't, so the headline wraps in
  /// generous space. Without `maxWidth: .infinity` the fixed-width graph would
  /// push this column down to a sliver — the bug this layout exists to fix.
  private var textColumn: some View {
    VStack(alignment: .leading, spacing: 6) {
      headlineLine
      controls
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The row's controls, left-aligned under the headline. The signed impact
  /// amount lives in the headline sentence itself ("…about $67,849.60 more
  /// than…"), so the row carries no separate amount line — just "Show less"
  /// and "View".
  private var controls: some View {
    HStack(spacing: 8) {
      showLessButton
      viewButton
      Spacer(minLength: 0)
    }
  }

  /// The trailing companion graph: a fixed ~200×72 inline sparkline that zooms
  /// to the detail sheet when tapped. Only present when the insight carries a
  /// chart, so graph-less rows render as a plain left column with no graph.
  @ViewBuilder private var chartButton: some View {
    if let chart = insight.chart {
      Button {
        isZoomed = true
      } label: {
        InsightChartView(chart: chart, tint: framingColor, style: .inline)
          .frame(width: horizontalSizeClass == .compact ? 120 : 200, height: 72)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(UITestIdentifiers.ForYou.chart(insight.id))
      .accessibilityLabel("Show \(item.headline) chart")
      .accessibilityHint("Opens a larger chart view")
      .help("Show \(item.headline) chart in detail")
    }
  }

  private var headlineLine: some View {
    HStack(spacing: 8) {
      // The framing icon carries the framing for VoiceOver ("Heads up"/"Good
      // news"/"Note"), announced before the headline. Keeping the framing on
      // the icon — rather than folding it into the headline's label — leaves
      // the headline `Text` with no `.accessibilityLabel` override, so its raw
      // content surfaces in `XCUIElement.value` for the UI test to match.
      Image(systemName: framingIcon)
        .foregroundStyle(framingColor)
        .accessibilityLabel(framingDescription)
      Text(item.headline)
        .font(.subheadline)
        .fontWeight(.medium)
        // Wrap rather than truncate: an AI headline is a full sentence.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(UITestIdentifiers.ForYou.headline(item.id))
    }
  }

  // MARK: - Leaves and styling

  @ViewBuilder private var viewButton: some View {
    if let target {
      // `.borderless` (not macOS-only `.link`) renders a tinted, tappable
      // control on both platforms — matches the dismiss button's style.
      Button("View") { onNavigate(target) }
        .buttonStyle(.borderless)
        // Keep the label intact when the impact row is tight — it should wrap to
        // a new line as a whole control, never break mid-word.
        .fixedSize()
        #if os(iOS)
          .frame(minHeight: 44)
        #endif
        .accessibilityLabel("View \(item.headline)")
        .accessibilityIdentifier(UITestIdentifiers.ForYou.viewButton(insight.id))
    }
  }

  /// "Show less" replaces the old dismiss ✕ — a thumbs-down that records a
  /// per-kind fatigue bump rather than a generic dismissal. The visible text
  /// label keeps the intent ("show fewer like this") unmistakable.
  private var showLessButton: some View {
    Button(action: onDismiss) {
      Label("Show less", systemImage: "hand.thumbsdown")
        .font(.caption)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    // Keep the label intact when the impact row is tight — it should wrap to a
    // new line as a whole control, never break mid-word ("Sho w less").
    .fixedSize()
    .foregroundStyle(.secondary)
    #if os(iOS)
      .frame(minHeight: 44)
    #endif
    #if os(macOS)
      .frame(minHeight: 20)
    #endif
    .help("Show fewer insights like this")
    .accessibilityLabel("Show fewer insights like this: \(item.headline)")
    .accessibilityIdentifier(UITestIdentifiers.ForYou.showLess(item.id))
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
  extension [ForYouItem] {
    /// Preview/iteration fixtures covering each framing, an AI-style headline
    /// vs a plain detector title, ±impact, and ±navigation target.
    static var forYouPreviewFixtures: [ForYouItem] {
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      let accountId = UUID()
      return [
        ForYouItem(
          scored: ScoredInsight(
            insight: Insight(
              id: "p-large",
              kind: .largeTransactionAnomaly,
              title: "Large purchase at the Apple Store",
              date: now,
              framing: .negative,
              actionability: .review,
              surprise: 0.8,
              monetaryImpact: InstrumentAmount(quantity: -2499, instrument: .AUD),
              references: InsightReferences(accountIds: [accountId]),
              chart: InsightChart(
                kind: .bar,
                unit: .currency(.AUD),
                series: [
                  InsightChart.Series(
                    id: "spend",
                    label: "Spending",
                    role: .primary,
                    points: (0..<6).map { offset in
                      InsightChart.Point(
                        date: now.addingTimeInterval(Double(offset) * 86_400 * 30),
                        value: offset == 5 ? 2499 : Double.random(in: 80...160))
                    })
                ],
                highlight: InsightChart.Point(
                  date: now.addingTimeInterval(5 * 86_400 * 30), value: 2499),
                xAxis: .monthly)),
            score: 4.2),
          headline: "You spent $2,499 at the Apple Store, far above your usual $120."),
        ForYouItem(
          scored: ScoredInsight(
            insight: Insight(
              id: "p-netflix",
              kind: .subscriptionPriceHike,
              title: "Netflix raised its monthly price",
              date: now,
              framing: .negative,
              actionability: .act,
              surprise: 0.5,
              monetaryImpact: InstrumentAmount(quantity: -3, instrument: .AUD)),
            score: 3.1),
          headline: "Netflix raised its monthly price from $19.99 to $22.99."),
        ForYouItem(
          scored: ScoredInsight(
            insight: Insight(
              id: "p-milestone",
              kind: .netWorthMilestone,
              title: "Net worth crossed $100k",
              date: now,
              framing: .positive,
              actionability: .informational,
              surprise: 0.3),
            score: 2.0),
          // Plain detector title (model unavailable / fell back).
          headline: "Net worth crossed $100k"),
      ]
    }
  }

  #Preview("For You headlines") {
    ForYouCard(
      items: .forYouPreviewFixtures,
      onDismiss: { _ in },
      onNavigate: { _ in }
    )
    .padding()
    .frame(width: 420)
  }
#endif
