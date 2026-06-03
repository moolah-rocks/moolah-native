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

  private var insight: Insight { item.scored.insight }
  private var target: SidebarSelection? {
    InsightNavigationTarget.sidebarSelection(for: insight.references)
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: framingIcon)
        .foregroundStyle(framingColor)
        .accessibilityHidden(true)
      Text(item.headline)
        .font(.subheadline)
        .fontWeight(.medium)
        // Wrap rather than truncate: an AI headline is a full sentence.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(UITestIdentifiers.ForYou.headline(item.id))
      if let impact = insight.monetaryImpact {
        Text(impact.formatted)
          .font(.subheadline)
          .monospacedDigit()
          .foregroundStyle(impactColor(impact))
          .accessibilityHidden(true)
      }
      showLessButton
      if let target {
        // `.borderless` (not macOS-only `.link`) renders a tinted, tappable
        // control on both platforms — matches the dismiss button's style.
        Button("View") { onNavigate(target) }
          .buttonStyle(.borderless)
          .accessibilityLabel("View \(item.headline)")
          .accessibilityIdentifier(UITestIdentifiers.ForYou.viewButton(insight.id))
      }
    }
    // Grouped under the row identifier so a UI test can assert the row's
    // presence/removal; children (headline Text, "Show less", "View") stay
    // independently addressable for their own identifiers and as separate
    // VoiceOver elements.
    .accessibilityElement(children: .contain)
    .accessibilityLabel(rowAccessibilityLabel)
    .accessibilityIdentifier(UITestIdentifiers.ForYou.row(insight.id))
  }

  /// "Show less" replaces the old dismiss ✕ — a thumbs-down that records a
  /// per-kind fatigue bump rather than a generic dismissal.
  private var showLessButton: some View {
    Button(action: onDismiss) {
      Label("Show less", systemImage: "hand.thumbsdown")
        .labelStyle(.iconOnly)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    #if os(iOS)
      .frame(minWidth: 44, minHeight: 44)
    #endif
    .help("Show fewer insights like this")
    .accessibilityLabel("Show fewer insights like this: \(item.headline)")
    .accessibilityIdentifier(UITestIdentifiers.ForYou.showLess(item.id))
  }

  private var rowAccessibilityLabel: String {
    var parts = [framingDescription, item.headline]
    if let impact = insight.monetaryImpact {
      parts.append(impact.formatted)
    }
    return parts.joined(separator: ", ")
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
              references: InsightReferences(accountIds: [accountId])),
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
