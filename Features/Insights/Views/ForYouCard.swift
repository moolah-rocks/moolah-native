import SwiftUI

/// The "For You" dashboard panel: renders the ready-to-show insight batch — each
/// a single headline line with its signed impact, a "Show less" control, and an
/// optional deep-link. Pure presentational view: the store resolves headlines,
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
    // At accessibility type sizes the inline HStack (headline + impact +
    // controls) collides, so reflow to a VStack: the headline gets its own
    // line, then a row of impact and the controls. The non-accessibility
    // layout keeps everything inline.
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        // At accessibility sizes the inline 200pt chart would crowd the
        // already-stacked content, so the companion graph drops to the bottom
        // of the vertical stack (full width) rather than sitting inline.
        VStack(alignment: .leading, spacing: 6) {
          headlineLine
          HStack(spacing: 8) {
            impactText
            Spacer(minLength: 0)
            showLessButton
            viewButton
          }
          chartButton
        }
      } else {
        HStack(spacing: 8) {
          headlineLine
          impactText
          showLessButton
          viewButton
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

  /// The trailing companion graph: a fixed ~200pt inline chart that zooms to
  /// the detail sheet when tapped. Only present when the insight carries a
  /// chart, so graph-less rows render exactly as before.
  @ViewBuilder private var chartButton: some View {
    if let chart = insight.chart {
      Button {
        isZoomed = true
      } label: {
        InsightChartView(chart: chart, tint: framingColor, style: .inline)
          .frame(width: horizontalSizeClass == .compact ? 120 : 200, height: 48)
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

  @ViewBuilder private var impactText: some View {
    if let impact = insight.monetaryImpact {
      Text(impact.formatted)
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(impactColor(impact))
        .accessibilityLabel("Impact: \(impact.formatted)")
    }
  }

  @ViewBuilder private var viewButton: some View {
    if let target {
      // `.borderless` (not macOS-only `.link`) renders a tinted, tappable
      // control on both platforms — matches the dismiss button's style.
      Button("View") { onNavigate(target) }
        .buttonStyle(.borderless)
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

  private func impactColor(_ impact: InstrumentAmount) -> Color {
    if impact.isPositive { return .green }
    if impact.isNegative { return .red }
    return .secondary
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
