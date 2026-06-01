import Foundation

/// One detected, narratable observation about the user's finances.
///
/// An `Insight` is the unit produced by the deterministic detectors and
/// consumed by the ranker and the UI. It carries:
/// - a stable `id` (used to de-duplicate across refreshes and to key the
///   fatigue table),
/// - template-string narration (`title` / `detail`) that needs no LLM,
/// - the structured `facts` a Foundation Models layer would narrate from
///   *without inventing numbers* (every number the LLM may print is here),
/// - the ranking signals (`surprise`, `monetaryImpact`, `actionability`,
///   `framing`, `date`),
/// - `references` so the UI can deep-link to the underlying account,
///   category, earmark, instrument, or transaction.
///
/// `Insight` is a pure value type — it never reaches into a store or a
/// backend. Detectors build it; the wiring layer renders it.
struct Insight: Sendable, Identifiable, Hashable {
  let id: String
  let kind: InsightKind
  let title: String
  let detail: String
  let date: Date
  let framing: InsightFraming
  let actionability: InsightActionability

  /// Normalised statistical strength in `0...1`. Higher means more
  /// surprising relative to the detector's own baseline (a normalised
  /// MAD-z, trend-test z, or burndown overshoot). Drives `w_surprise`.
  let surprise: Double

  /// Signed dollar impact in the reporting currency, when the insight has
  /// one. Magnitude (not sign) feeds `w_magnitude`; the sign is preserved
  /// for display and never `abs()`-ed away (`guides/CODE_GUIDE.md` §16).
  let monetaryImpact: InstrumentAmount?

  /// Structured evidence. The single source of truth for any number a
  /// narration layer is allowed to render. Order is presentation order.
  let facts: [InsightFact]

  /// Deep-link handles for the UI.
  let references: InsightReferences

  init(
    id: String,
    kind: InsightKind,
    title: String,
    detail: String,
    date: Date,
    framing: InsightFraming,
    actionability: InsightActionability,
    surprise: Double,
    monetaryImpact: InstrumentAmount? = nil,
    facts: [InsightFact] = [],
    references: InsightReferences = InsightReferences()
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.detail = detail
    self.date = date
    self.framing = framing
    self.actionability = actionability
    self.surprise = surprise
    self.monetaryImpact = monetaryImpact
    self.facts = facts
    self.references = references
  }
}

/// Emotional framing of an insight. The ranker uses `.positive` to honour
/// the design's "guarantee one positive-framed insight per week" rule so
/// the feature never reads as a scold (`guides`/design §"Ranking & Fatigue").
enum InsightFraming: String, Sendable, Hashable {
  case positive
  case neutral
  case negative
}

/// How much the user can *do* about an insight. The single biggest fatigue
/// lever in the design: non-actionable insights are scored down hard.
enum InsightActionability: String, Sendable, Hashable {
  /// A clear next step ("cancel this duplicate", "cover this bill").
  case act
  /// Worth a look, no obvious one-tap action ("dining is trending up").
  case review
  /// Noted for awareness only ("net worth crossed $100k").
  case informational

  /// Weight contributed to the ranking score. Matches the design's
  /// `1 / 0.5 / 0` scale.
  var weight: Double {
    switch self {
    case .act: return 1
    case .review: return 0.5
    case .informational: return 0
    }
  }
}

/// A single labelled, pre-formatted fact. Detectors format the value in the
/// reporting currency / locale so the narration layer never does arithmetic.
struct InsightFact: Sendable, Hashable {
  let label: String
  let value: String

  init(_ label: String, _ value: String) {
    self.label = label
    self.value = value
  }
}

/// Identifiers an insight relates to, so the UI can navigate to the source.
/// Every field defaults empty; detectors populate only what applies.
struct InsightReferences: Sendable, Hashable {
  var accountIds: [UUID]
  var categoryIds: [UUID]
  var earmarkIds: [UUID]
  var instrumentIds: [String]
  var transactionIds: [UUID]

  init(
    accountIds: [UUID] = [],
    categoryIds: [UUID] = [],
    earmarkIds: [UUID] = [],
    instrumentIds: [String] = [],
    transactionIds: [UUID] = []
  ) {
    self.accountIds = accountIds
    self.categoryIds = categoryIds
    self.earmarkIds = earmarkIds
    self.instrumentIds = instrumentIds
    self.transactionIds = transactionIds
  }
}
