import Foundation

/// Pre-aggregated, currency-normalised summaries plus a bounded
/// recent-candidate row window assembled by an `InsightDataSource`.
///
/// This is the SQL-backed alternative to loading the entire transaction
/// history into memory and converting every leg on each refresh. Every
/// field is `O(payees + categories + days + recent window)` — independent
/// of the *total* transaction count, so a profile with ten years of data
/// pays the same as one with one. See
/// `plans/2026-06-01-insights-integration-plan.md` §"Phase A".
///
/// Every monetary value is already reduced to `context.reportingCurrency`
/// via a per-`(day, instrument)` conversion (mirroring
/// `GRDBAnalysisRepository`); a leg whose conversion fails is dropped and
/// counted in `droppedLegCount` rather than guessed
/// (`guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11).
struct InsightDataSummary: Sendable {
  /// Per-UTC-calendar-day income / expense totals over all history. Drives
  /// the unusual-day and weekend-skew detectors. `O(active days)`.
  let dailyTotals: [DailySpendSummary]

  /// Per-category expense totals over a trailing window. Drives fee-spend
  /// and unbudgeted-category. `O(categories)`.
  let categorySpend: [CategorySpendSummary]

  /// Per-account expense totals over a trailing window. Drives
  /// group-spend-concentration once mapped through the membership map.
  /// `O(accounts)`.
  let accountSpend: [AccountSpendSummary]

  /// Per-normalized-payee cadence and totals over the bounded cadence
  /// window. Drives new-merchant, lapsed-merchant, and subscription
  /// detection. `O(payees + windowed occurrences)`.
  let payees: [PayeeSummary]

  /// Per-category recent expense-magnitude samples for the
  /// large-transaction MAD baseline. `O(categories × cap)`.
  let categorySamples: [CategorySpendSamples]

  /// Bounded recent-candidate window of projected legs, for detectors that
  /// must cite a specific `transactionId` (large-tx, windfall,
  /// new-merchant). `O(recent window)`.
  let recentCandidates: [InsightTransaction]

  /// Count of legs dropped because their currency conversion failed
  /// (Rule 11). A future "data incomplete" signal — never silently guessed.
  let droppedLegCount: Int

  init(
    dailyTotals: [DailySpendSummary] = [],
    categorySpend: [CategorySpendSummary] = [],
    accountSpend: [AccountSpendSummary] = [],
    payees: [PayeeSummary] = [],
    categorySamples: [CategorySpendSamples] = [],
    recentCandidates: [InsightTransaction] = [],
    droppedLegCount: Int = 0
  ) {
    self.dailyTotals = dailyTotals
    self.categorySpend = categorySpend
    self.accountSpend = accountSpend
    self.payees = payees
    self.categorySamples = categorySamples
    self.recentCandidates = recentCandidates
    self.droppedLegCount = droppedLegCount
  }
}

/// Income and expense totals for one UTC calendar day, reporting currency.
///
/// `expense` is the signed sum of the day's expense legs (negative for net
/// spend, but a net-refund day can be positive); `income` is the signed
/// sum of income legs. Detectors read `spendMagnitude` / `incomeMagnitude`
/// rather than `abs()`-ing, preserving the sign convention.
struct DailySpendSummary: Sendable, Hashable {
  let day: Date
  let expense: InstrumentAmount
  let income: InstrumentAmount

  /// Positive magnitude of money that left the account on this day, or `0`
  /// for a net-refund day.
  var spendMagnitude: Decimal {
    expense.quantity < 0 ? -expense.quantity : 0
  }

  /// Positive magnitude of money received on this day, or `0`.
  var incomeMagnitude: Decimal {
    income.quantity > 0 ? income.quantity : 0
  }
}

/// Trailing-window expense total for one category, reporting currency.
struct CategorySpendSummary: Sendable, Hashable {
  let categoryId: UUID?
  let categoryPath: String?
  /// Signed expense total over the window (negative for net spend).
  let total: InstrumentAmount
  /// Number of expense legs contributing to `total`.
  let legCount: Int
}

/// Trailing-window expense total for one account, reporting currency.
struct AccountSpendSummary: Sendable, Hashable {
  let accountId: UUID?
  /// Signed expense total over the window (negative for net spend).
  let total: InstrumentAmount
  let legCount: Int
}

/// A bounded sample of recent expense magnitudes for one category, the
/// baseline distribution the large-transaction MAD detector scores against.
struct CategorySpendSamples: Sendable, Hashable {
  let categoryId: UUID?
  /// Positive spend magnitudes in the reporting currency, most-recent
  /// first, capped per category.
  let magnitudes: [Decimal]
}

/// Cadence and totals for one normalized payee within the bounded cadence
/// window, the workhorse input for the merchant and subscription detectors.
struct PayeeSummary: Sendable, Hashable {
  let normalizedPayee: String
  /// A representative raw payee for narration (the most frequent raw
  /// spelling that normalized to `normalizedPayee`).
  let displayPayee: String
  /// `true` for an expense payee, `false` for an income stream. A payee
  /// that appears on both sides yields two summaries.
  let isExpense: Bool
  /// Occurrence count within the cadence window.
  let occurrenceCount: Int
  /// First / last occurrence date within the cadence window.
  let firstSeen: Date
  let lastSeen: Date
  /// Signed total over the cadence window, reporting currency.
  let windowedTotal: InstrumentAmount
  /// Projected occurrences within the cadence window, ascending by date —
  /// the per-occurrence detail cadence and amount-variability analysis read.
  let occurrences: [PayeeOccurrence]
}

/// One projected occurrence of a payee, reporting currency.
struct PayeeOccurrence: Sendable, Hashable {
  let date: Date
  /// Signed amount, reporting currency (income positive, expense negative).
  let amount: InstrumentAmount
  let categoryId: UUID?
  let accountId: UUID?
}
