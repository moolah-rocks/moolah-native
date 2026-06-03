import SwiftUI

/// The "For You" dashboard panel: renders the top-ranked insights with a
/// dismiss affordance and an optional deep-link. Pure presentational view —
/// all state and logic live in `InsightStore`; this binds the published
/// insights and dispatches the closures. `AnalysisView` renders it only
/// when there are insights, so this view assumes a non-empty list.
struct ForYouCard: View {
  let insights: [ScoredInsight]
  var maxVisible: Int = 3
  let availability: ModelAvailability
  let narration: [String: NarrationState]
  let onDismiss: (ScoredInsight) -> Void
  let onNavigate: (SidebarSelection) -> Void
  let onNarrate: (ScoredInsight) -> Void
  let onCancelNarrate: (ScoredInsight) -> Void

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
        ForEach(insights.prefix(maxVisible)) { scored in
          InsightRow(
            scored: scored,
            availability: availability,
            narrationState: narration[scored.id] ?? .idle,
            onDismiss: { onDismiss(scored) },
            onNavigate: onNavigate,
            onNarrate: { onNarrate(scored) },
            onCancelNarrate: { onCancelNarrate(scored) })
        }
      }
    }
    .padding()
    .background(.background)
    .clipShape(.rect(cornerRadius: 12))
  }
}

private struct InsightRow: View {
  let scored: ScoredInsight
  let availability: ModelAvailability
  let narrationState: NarrationState
  let onDismiss: () -> Void
  let onNavigate: (SidebarSelection) -> Void
  let onNarrate: () -> Void
  let onCancelNarrate: () -> Void

  @State private var isExpanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var insight: Insight { scored.insight }
  private var target: SidebarSelection? {
    InsightNavigationTarget.sidebarSelection(for: insight.references)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        expandToggle
        dismissButton
      }
      if isExpanded {
        expandedContent
      }
    }
  }

  /// The header is itself the expand/collapse control. Keeping the dismiss
  /// button a sibling (below) — not a child of this button — avoids the
  /// macOS conflict where a control inside a disclosure label fights the
  /// expand gesture, and keeps dismiss independently reachable by VoiceOver.
  private var expandToggle: some View {
    Button {
      withAnimation(reduceMotion ? nil : .snappy) { isExpanded.toggle() }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: framingIcon)
          .foregroundStyle(framingColor)
          .accessibilityHidden(true)
        Text(insight.title)
          .font(.subheadline)
          .fontWeight(.medium)
        Spacer(minLength: 8)
        if let impact = insight.monetaryImpact {
          Text(impact.formatted)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(impactColor(impact))
        }
        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(headerAccessibilityLabel)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityHint("Shows details")
    .accessibilityIdentifier(UITestIdentifiers.ForYou.row(insight.id))
  }

  private var dismissButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark.circle.fill")
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    #if os(iOS)
      .frame(minWidth: 44, minHeight: 44)
    #endif
    .help("Dismiss this insight")
    .accessibilityLabel("Dismiss \(insight.title)")
    .accessibilityIdentifier(UITestIdentifiers.ForYou.dismissButton(insight.id))
  }

  @ViewBuilder private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      if availability.isUsable {
        narrationAffordance
      }
      ForEach(insight.facts) { fact in
        HStack {
          Text(fact.label)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Text(fact.value)
            .monospacedDigit()
        }
        .font(.caption)
      }
      if let target {
        // `.borderless` (not macOS-only `.link`) renders a tinted, tappable
        // control on both platforms — matches the dismiss button's style.
        Button("View") { onNavigate(target) }
          .buttonStyle(.borderless)
          .accessibilityLabel("View \(insight.title)")
          .accessibilityIdentifier(UITestIdentifiers.ForYou.viewButton(insight.id))
      }
    }
    .padding(.top, 4)
  }

  /// Narration affordance rendered when `availability.isUsable`. Switches on
  /// `narrationState` to show the "Why?" button, streaming partial text, or
  /// the completed narration. `.fellBackToTemplate` is visually identical to
  /// `.done` — the template fallback is invisible to the user by design.
  @ViewBuilder private var narrationAffordance: some View {
    if case .idle = narrationState {
      Button("Why?") { onNarrate() }
        .buttonStyle(.borderless)
        .accessibilityLabel("Why? — explain \(insight.title)")
        .accessibilityHint("Generates a plain-language explanation on your device")
        .accessibilityIdentifier(UITestIdentifiers.ForYou.whyButton(insight.id))
    } else {
      // One stable text element across `.streaming` → `.done`: keeping the
      // narration `Text` in the same structural position (rather than two
      // separate switch arms) preserves its identity so its content updates
      // in place — both for SwiftUI animation and so a UI test observing the
      // element sees the label transition rather than a replaced element.
      VStack(alignment: .leading, spacing: 4) {
        Text(narrationText)
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.updatesFrequently)
          .accessibilityIdentifier(UITestIdentifiers.ForYou.narrationText(insight.id))
        if case .streaming = narrationState {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Generating explanation…")
            Button("Cancel") { onCancelNarrate() }
              .buttonStyle(.borderless)
          }
        }
      }
    }
  }

  /// The text to display for the current narration state. Empty while idle or
  /// at the start of streaming; the partial or completed prose otherwise.
  /// `.fellBackToTemplate` reads identically to `.done` — the template fallback
  /// is invisible to the user by design.
  private var narrationText: String {
    switch narrationState {
    case .idle: return ""
    case .streaming(let text), .done(let text), .fellBackToTemplate(let text): return text
    }
  }

  private var headerAccessibilityLabel: String {
    var parts = [framingDescription, insight.title]
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
  extension [ScoredInsight] {
    /// Preview/iteration fixtures covering each framing, with/without impact,
    /// and with/without a navigation target.
    static var forYouPreviewFixtures: [ScoredInsight] {
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      let accountId = UUID()
      return [
        ScoredInsight(
          insight: Insight(
            id: "p-large",
            kind: .largeTransactionAnomaly,
            title: "Large purchase at the Apple Store",
            date: now,
            framing: .negative,
            actionability: .review,
            surprise: 0.8,
            monetaryImpact: InstrumentAmount(quantity: -2499, instrument: .AUD),
            facts: [InsightFact("Amount", "−$2,499.00"), InsightFact("Typical", "$120.00")],
            references: InsightReferences(accountIds: [accountId])),
          score: 4.2),
        ScoredInsight(
          insight: Insight(
            id: "p-netflix",
            kind: .subscriptionPriceHike,
            title: "Netflix raised its monthly price",
            date: now,
            framing: .negative,
            actionability: .act,
            surprise: 0.5,
            monetaryImpact: InstrumentAmount(quantity: -3, instrument: .AUD),
            facts: [InsightFact("New price", "$22.99"), InsightFact("Was", "$19.99")]),
          score: 3.1),
        ScoredInsight(
          insight: Insight(
            id: "p-milestone",
            kind: .netWorthMilestone,
            title: "Net worth crossed $100k",
            date: now,
            framing: .positive,
            actionability: .informational,
            surprise: 0.3),
          score: 2.0),
      ]
    }
  }

  #Preview("Collapsed rows") {
    ForYouCard(
      insights: .forYouPreviewFixtures,
      availability: .available,
      narration: [
        "p-large": .streaming("You spent a lot at the Apple Store…"),
        "p-netflix": .done("Netflix raised its monthly price by $3.00, up from $19.99 to $22.99."),
      ],
      onDismiss: { _ in },
      onNavigate: { _ in },
      onNarrate: { _ in },
      onCancelNarrate: { _ in }
    )
    .padding()
    .frame(width: 420)
  }

  /// Shows narration affordance states (streaming + done + fallback) in the
  /// full card with all narration states wired so expanding any row reveals them.
  #Preview("Expanded narration states") {
    ForYouCard(
      insights: .forYouPreviewFixtures,
      availability: .available,
      narration: [
        "p-large": .streaming("You spent a lot at the Apple Store this month…"),
        "p-netflix": .done(
          "Netflix raised its monthly price by $3.00, up from $19.99 to $22.99."),
        "p-milestone": .fellBackToTemplate("Net worth crossed $100k — a new high."),
      ],
      onDismiss: { _ in },
      onNavigate: { _ in },
      onNarrate: { _ in },
      onCancelNarrate: { _ in }
    )
    .padding()
    .frame(width: 420)
  }
#endif
