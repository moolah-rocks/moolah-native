import Foundation

/// An insight paired with its computed ranking score. Returned by the ranker
/// so callers can show "why this is here" diagnostics if they want.
struct ScoredInsight: Sendable, Identifiable, Hashable {
  let insight: Insight
  let score: Double
  var id: String { insight.id }
}

/// Scores and orders candidate insights, the single most important
/// anti-fatigue lever in the design (§"Insight Ranking & Fatigue"). Without
/// a ranker the feature becomes a notification spambot.
///
/// `score = w_surprise·surprise + w_action·actionability +
/// w_magnitude·log(|$|+1) + w_recency·decay + w_interest·interest −
/// w_fatigue·recentDismissals`.
struct InsightRanker: Sendable {
  /// Tunable term weights. Defaults are the design's hand-tuned starting
  /// point — "revisit once we have dismissal telemetry".
  struct Weights: Sendable {
    var surprise: Double = 1.0
    var action: Double = 1.2
    var magnitude: Double = 0.5
    var recency: Double = 0.8
    var interest: Double = 0.7
    var fatigue: Double = 1.5

    init() {}
  }

  /// Categories / earmarks the user has pinned — boosts their insights.
  struct DeclaredInterests: Sendable {
    var categoryIds: Set<UUID>
    var earmarkIds: Set<UUID>

    init(categoryIds: Set<UUID> = [], earmarkIds: Set<UUID> = []) {
      self.categoryIds = categoryIds
      self.earmarkIds = earmarkIds
    }
  }

  var weights: Weights
  /// Recency decay time-constant τ (days). Design suggests ≈7.
  var recencyHalfLife: Double
  var calendar: Calendar

  init(
    weights: Weights = Weights(),
    recencyHalfLife: Double = 7,
    calendar: Calendar = InsightContext.defaultCalendar
  ) {
    self.weights = weights
    self.recencyHalfLife = recencyHalfLife
    self.calendar = calendar
  }

  /// Score one insight. `dismissals` is the count of recent dismissals for
  /// that insight kind (the fatigue penalty).
  func score(
    _ insight: Insight,
    now: Date,
    dismissals: [InsightKind: Int] = [:],
    interests: DeclaredInterests = DeclaredInterests()
  ) -> Double {
    let magnitude = insight.monetaryImpact
      .map { abs(Double(truncating: $0.quantity as NSDecimalNumber)) } ?? 0
    let magnitudeTerm = log(magnitude + 1)

    let ageDays = max(0, Double(calendar.dateComponents([.day], from: insight.date, to: now).day ?? 0))
    let recencyTerm = exp(-ageDays / recencyHalfLife)

    let interestTerm = matchesInterest(insight, interests: interests) ? 1.0 : 0.0
    let fatiguePenalty = Double(dismissals[insight.kind] ?? 0)

    return weights.surprise * clamp(insight.surprise)
      + weights.action * insight.actionability.weight
      + weights.magnitude * magnitudeTerm
      + weights.recency * recencyTerm
      + weights.interest * interestTerm
      - weights.fatigue * fatiguePenalty
  }

  /// Rank candidates: de-duplicate by id, score, sort descending, then apply
  /// the display cap. When `guaranteePositive` is set and the capped set has
  /// no positive-framed insight, the lowest-ranked slot is swapped for the
  /// best available positive one — the design's "guarantee one positive
  /// insight per week".
  func rank(
    _ insights: [Insight],
    now: Date,
    dismissals: [InsightKind: Int] = [:],
    interests: DeclaredInterests = DeclaredInterests(),
    displayCap: Int = 5,
    guaranteePositive: Bool = true
  ) -> [ScoredInsight] {
    let deduped = deduplicate(insights)
    let scored = deduped
      .map { ScoredInsight(insight: $0, score: score($0, now: now, dismissals: dismissals, interests: interests)) }
      .sorted { $0.score > $1.score }

    guard displayCap > 0 else { return [] }
    var top = Array(scored.prefix(displayCap))
    if guaranteePositive {
      top = ensurePositive(in: top, from: scored)
    }
    return top
  }

  // MARK: - Helpers

  /// Keep the highest-scoring instance of each id. Detectors are designed to
  /// produce stable ids, but a defensive de-dup avoids double-showing.
  private func deduplicate(_ insights: [Insight]) -> [Insight] {
    var seen: Set<String> = []
    var result: [Insight] = []
    for insight in insights where !seen.contains(insight.id) {
      seen.insert(insight.id)
      result.append(insight)
    }
    return result
  }

  private func ensurePositive(in top: [ScoredInsight], from scored: [ScoredInsight]) -> [ScoredInsight] {
    guard !top.contains(where: { $0.insight.framing == .positive }) else { return top }
    guard let bestPositive = scored.first(where: { $0.insight.framing == .positive }),
      !top.contains(where: { $0.id == bestPositive.id }),
      !top.isEmpty
    else { return top }
    var adjusted = top
    adjusted[adjusted.count - 1] = bestPositive
    return adjusted.sorted { $0.score > $1.score }
  }

  private func matchesInterest(_ insight: Insight, interests: DeclaredInterests) -> Bool {
    if insight.references.categoryIds.contains(where: interests.categoryIds.contains) {
      return true
    }
    return insight.references.earmarkIds.contains(where: interests.earmarkIds.contains)
  }

  private func clamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
  }
}
