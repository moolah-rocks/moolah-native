import Foundation

/// Window sizes (in days) and sample caps the insight summaries are
/// assembled with. Defaults mirror the thresholds the deterministic
/// detectors use so `assemble(window:categories:context:)` produces a
/// summary every raw-row detector can read.
struct InsightDataWindow: Sendable {
  /// Recent-candidate projection window — the detectors that cite a
  /// specific `transactionId` (large-tx, windfall, new-merchant) look back
  /// at most this far.
  var recentCandidateDays: Int
  /// Per-category spend-sum window (fee-spend looks back a year).
  var categorySpendDays: Int
  /// Per-account spend-sum window (group concentration is a recent skew).
  var accountSpendDays: Int
  /// Per-payee cadence window — ~13 months so an annual subscription still
  /// shows two occurrences.
  var payeeCadenceDays: Int
  /// MAD-baseline sample window and per-category cap.
  var sampleDays: Int
  var maxSamplesPerCategory: Int

  init(
    recentCandidateDays: Int = 30,
    categorySpendDays: Int = 365,
    accountSpendDays: Int = 30,
    payeeCadenceDays: Int = 395,
    sampleDays: Int = 365,
    maxSamplesPerCategory: Int = 200
  ) {
    self.recentCandidateDays = recentCandidateDays
    self.categorySpendDays = categorySpendDays
    self.accountSpendDays = accountSpendDays
    self.payeeCadenceDays = payeeCadenceDays
    self.sampleDays = sampleDays
    self.maxSamplesPerCategory = maxSamplesPerCategory
  }
}

/// Produces the pre-aggregated `InsightDataSummary` an `InsightEngine`
/// needs without ever materialising the full transaction history.
///
/// Every method drives a SQL aggregation (or a bounded projection) and
/// converts the result to `context.reportingCurrency` on each row's own
/// `(day, instrument)` bucket — the same shape as `AnalysisRepository`.
/// Memory stays `O(payees + categories + days + window)`, independent of
/// total transaction count. See
/// `plans/2026-06-01-insights-integration-plan.md` §"Phase A".
///
/// A leg whose conversion fails is dropped, never guessed
/// (`guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11); the projection
/// methods surface the count through `InsightDataSummary.droppedLegCount`.
protocol InsightDataSource: Sendable {
  /// Per-UTC-day income / expense totals over all history. `O(active days)`.
  func dailyTotals(context: InsightContext) async throws -> [DailySpendSummary]

  /// Per-category expense totals over the trailing `windowDays`.
  /// `O(categories)`.
  func categorySpend(
    windowDays: Int,
    categories: Categories,
    context: InsightContext
  ) async throws -> [CategorySpendSummary]

  /// Per-account expense totals over the trailing `windowDays`.
  /// `O(accounts)`.
  func accountSpend(
    windowDays: Int,
    context: InsightContext
  ) async throws -> [AccountSpendSummary]

  /// Per-normalized-payee cadence + totals over the trailing `windowDays`.
  /// `O(payees + windowed occurrences)`.
  func payeeSummaries(
    windowDays: Int,
    context: InsightContext
  ) async throws -> [PayeeSummary]

  /// Per-category recent expense-magnitude samples (most-recent first,
  /// capped at `maxPerCategory`) for the MAD baseline.
  /// `O(categories × cap)`.
  func categorySamples(
    windowDays: Int,
    maxPerCategory: Int,
    context: InsightContext
  ) async throws -> [CategorySpendSamples]

  /// A bounded, most-recent-first sample of income magnitudes (positive,
  /// reporting currency) over the trailing `windowDays`, capped at
  /// `maxCount`. The baseline distribution the windfall detector scores a
  /// recent deposit against. `O(maxCount)`.
  func incomeSamples(
    windowDays: Int,
    maxCount: Int,
    context: InsightContext
  ) async throws -> [Decimal]

  /// Bounded recent-candidate window of projected legs over the trailing
  /// `windowDays`, already in the reporting currency. `O(window)`.
  func recentCandidates(
    windowDays: Int,
    categories: Categories,
    context: InsightContext
  ) async throws -> [InsightTransaction]

  /// Assemble every summary into one `InsightDataSummary` with the given
  /// window configuration.
  func assemble(
    window: InsightDataWindow,
    categories: Categories,
    context: InsightContext
  ) async throws -> InsightDataSummary
}
