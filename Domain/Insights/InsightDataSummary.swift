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
/// marked unavailable rather than guessed
/// (`guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11).
struct InsightDataSummary: Sendable {
  struct Availability: Sendable {
    var dailyTotals = true
    var categorySpend = true
    var unbudgetedCategorySpend = true
    var accountSpend = true
    var payees = true
    var categorySamples = true
    var incomeSourceSamples = true
    var recentCandidates = true

    var isComplete: Bool {
      dailyTotals && categorySpend && unbudgetedCategorySpend && accountSpend && payees
        && categorySamples && incomeSourceSamples && recentCandidates
    }
  }

  /// Per-UTC-calendar-day income / expense totals over all history. Drives
  /// the unusual-day and weekend-skew detectors. `O(active days)`.
  let dailyTotals: [DailySpendSummary]

  /// Per-category expense totals over a trailing window. Drives fee-spend
  /// and unbudgeted-category. `O(categories)`.
  let categorySpend: [CategorySpendSummary]
  let unbudgetedCategorySpend: [CategorySpendSummary]

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
  let incomeSourceSamples: [IncomeSourceSamples]

  /// Bounded recent-candidate window of projected legs, for detectors that
  /// must cite a specific `transactionId` (large-tx, windfall,
  /// new-merchant). `O(recent window)`.
  let recentCandidates: [InsightTransaction]

  let availability: Availability

  init(
    dailyTotals: [DailySpendSummary] = [],
    categorySpend: [CategorySpendSummary] = [],
    unbudgetedCategorySpend: [CategorySpendSummary] = [],
    accountSpend: [AccountSpendSummary] = [],
    payees: [PayeeSummary] = [],
    categorySamples: [CategorySpendSamples] = [],
    incomeSourceSamples: [IncomeSourceSamples] = [],
    recentCandidates: [InsightTransaction] = [],
    availability: Availability = Availability()
  ) {
    self.dailyTotals = dailyTotals
    self.categorySpend = categorySpend
    self.unbudgetedCategorySpend = unbudgetedCategorySpend
    self.accountSpend = accountSpend
    self.payees = payees
    self.categorySamples = categorySamples
    self.incomeSourceSamples = incomeSourceSamples
    self.recentCandidates = recentCandidates
    self.availability = availability
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
  let hasUnavailableData: Bool

  init(
    categoryId: UUID?,
    categoryPath: String?,
    total: InstrumentAmount,
    legCount: Int,
    hasUnavailableData: Bool = false
  ) {
    self.categoryId = categoryId
    self.categoryPath = categoryPath
    self.total = total
    self.legCount = legCount
    self.hasUnavailableData = hasUnavailableData
  }
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
  let hasUnavailableData: Bool

  init(
    categoryId: UUID?,
    magnitudes: [Decimal],
    hasUnavailableData: Bool = false
  ) {
    self.categoryId = categoryId
    self.magnitudes = magnitudes
    self.hasUnavailableData = hasUnavailableData
  }
}

/// A bounded sample of recent income magnitudes for one source (normalized
/// payee), the baseline distribution the windfall detector scores a deposit
/// against. Grouping per source keeps the reported "typical" honest: a
/// regular salary is compared against *that source's* prior deposits, not the
/// median of every income stream pooled together.
struct IncomeSourceSamples: Sendable, Hashable {
  /// The `PayeeNormalizer` key the deposits clustered under. Empty for income
  /// with no payee.
  let normalizedPayee: String
  /// Positive income magnitudes in the reporting currency, most-recent first.
  let magnitudes: [Decimal]
  let hasUnavailableData: Bool

  init(
    normalizedPayee: String,
    magnitudes: [Decimal],
    hasUnavailableData: Bool = false
  ) {
    self.normalizedPayee = normalizedPayee
    self.magnitudes = magnitudes
    self.hasUnavailableData = hasUnavailableData
  }
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
  /// At least one occurrence for this payee and direction could not be
  /// converted. Detectors may still use unrelated complete payee summaries.
  let hasUnavailableData: Bool

  init(
    normalizedPayee: String,
    displayPayee: String,
    isExpense: Bool,
    occurrenceCount: Int,
    firstSeen: Date,
    lastSeen: Date,
    windowedTotal: InstrumentAmount,
    occurrences: [PayeeOccurrence],
    hasUnavailableData: Bool = false
  ) {
    self.normalizedPayee = normalizedPayee
    self.displayPayee = displayPayee
    self.isExpense = isExpense
    self.occurrenceCount = occurrenceCount
    self.firstSeen = firstSeen
    self.lastSeen = lastSeen
    self.windowedTotal = windowedTotal
    self.occurrences = occurrences
    self.hasUnavailableData = hasUnavailableData
  }
}

/// One projected occurrence of a payee, reporting currency.
struct PayeeOccurrence: Sendable, Hashable {
  let date: Date
  /// Signed amount, reporting currency (income positive, expense negative).
  let amount: InstrumentAmount
  let categoryId: UUID?
  let accountId: UUID?
}
