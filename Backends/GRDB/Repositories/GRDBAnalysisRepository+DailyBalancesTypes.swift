import Foundation

/// Row, bundle, handler, and context types shared by the
/// `fetchDailyBalances` assembly (`+DailyBalances.swift`) and its sibling
/// folds (`+DailyBalancesAggregation.swift`, `+DailyBalancesForecast.swift`,
/// …): the per-(day, account/earmark,
/// instrument, type) SUM rows, the `database.read`-snapshot input bundle,
/// the per-day diagnostic handlers, and the fixed per-walk context.
extension GRDBAnalysisRepository {

  // MARK: - Row types

  /// One row of the per-(day, account, instrument, type) SUM that
  /// drives the historic span of `fetchDailyBalances`.
  ///
  /// `day` is the ISO-8601 `YYYY-MM-DD` string returned by
  /// `DATE(t.date)` (UTC calendar day) — kept for diagnostics and as
  /// the failure-callback context. The actual day-key passed to
  /// `PositionBook.dailyBalance(...)` comes from `sampleDate` (a raw
  /// `t.date` instant inside the group) so `Calendar.current.startOfDay`
  /// produces the *local* day-key the contract tests expect — UTC-day
  /// grouping diverges from local-day at TZ boundaries, which is fine
  /// for indexing but wrong for the result key.
  struct DailyBalanceAccountRow: Sendable {
    let day: String
    let sampleDate: Date
    let accountId: UUID
    let instrumentId: String
    /// Raw value of `TransactionType` (`"income"`, `"expense"`,
    /// `"transfer"`, `"openingBalance"`, `"trade"`). Pinned by the
    /// `transaction_leg.type` CHECK constraint.
    let type: String
    let qty: Int64
  }

  /// One row of the per-(day, earmark, instrument, type) SUM. Same
  /// shape as `DailyBalanceAccountRow` but keyed by `earmark_id`
  /// instead of `account_id` — the earmark dimension drives the
  /// `earmarks` map inside `PositionBook` and is fetched by a sibling
  /// query so the leg-side index stays covering on
  /// `leg_analysis_by_earmark_type`.
  struct DailyBalanceEarmarkRow: Sendable {
    let day: String
    let sampleDate: Date
    let earmarkId: UUID
    let instrumentId: String
    let type: String
    let qty: Int64
  }

  // MARK: - Assembly input bundle

  /// Bundle of inputs for `assembleDailyBalances` — every value that
  /// crosses the `database.read` boundary fits inside this single
  /// `Sendable` aggregation so the read closure surfaces one MVCC
  /// snapshot to the converter.
  ///
  /// - `priorAccountRows` / `priorEarmarkRows` seed the `PositionBook`
  ///   with pre-`after` legs under the `asStartingBalance: true`
  ///   semantics in the primary per-account position book.
  /// - `accountRows` / `earmarkRows` carry the post-`after` deltas.
  /// - `scheduled` carries the scheduled `[Transaction]` for the
  ///   forecast extrapolation — the forecast path stays Swift-only
  ///   because SQL can't extrapolate recurring patterns.
  struct DailyBalancesAggregation: Sendable {
    let priorAccountRows: [DailyBalanceAccountRow]
    let priorEarmarkRows: [DailyBalanceEarmarkRow]
    let accountRows: [DailyBalanceAccountRow]
    let earmarkRows: [DailyBalanceEarmarkRow]
    /// Account ids of every investment-like account. Drives the per-day
    /// position-valuation fold regardless of the persisted legacy mode.
    let investmentAccountIds: Set<UUID>
    /// Pre-cutoff `transaction_leg` SUM rows filtered to investment-like
    /// accounts. Pre-fold seed for the cumulative position dictionary.
    let priorInvestmentAccountRows: [DailyBalanceAccountRow]
    /// Post-cutoff `transaction_leg` SUM rows filtered to investment-like accounts.
    let investmentAccountRows: [DailyBalanceAccountRow]
    let scheduled: [Transaction]
    let instrumentMap: [String: Instrument]
    let forecastUntil: Date?
  }

  // MARK: - Handler and context types

  /// Diagnostic context passed to the conversion-failure handler so
  /// the caller's logger can identify which day failed without
  /// coupling this helper to a `Logger` instance.
  struct DailyBalancesFailureContext: Sendable {
    let day: String
  }

  /// Bundle of per-day diagnostic callbacks used by
  /// `assembleDailyBalances`. Matches the
  /// `ExpenseBreakdownHandlers` / `CategoryBalancesHandlers` /
  /// `IncomeAndExpenseHandlers` shape so future analysis methods can
  /// share the same handler pattern. Position-valuation failures use their
  /// own callback because they fire after the primary daily-balance walk.
  struct DailyBalancesHandlers: Sendable {
    let handleUnparseableDay: @Sendable (String) -> Void
    let handleConversionFailure: @Sendable (Error, DailyBalancesFailureContext) -> Void
    let handlePositionValuationFailure: @Sendable (Error, Date) -> Void
  }

  /// Fixed inputs that stay constant across every per-day call inside
  /// `walkDays` and the investment-position fold. Lifts the
  /// investment account ids, `instrumentMap`, `profileInstrument`, and the
  /// `conversionService` reference out of every helper signature so
  /// each function fits SwiftLint's `function_parameter_count` budget.
  struct DailyBalancesAssemblyContext: Sendable {
    /// Account ids of every investment-like account — read by
    /// `applyInvestmentPositionValuations` to early-exit when the
    /// profile has none. Investment accounts contribute through the
    /// position fold, not through `accountsFromTransfers`.
    let investmentAccountIds: Set<UUID>
    let instrumentMap: [String: Instrument]
    let profileInstrument: Instrument
    let conversionService: any InstrumentConversionService
  }
}
