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
  ///   semantics (every leg type on an investment account contributes
  ///   to `accountsFromTransfers`, matching the
  ///   `investmentTransfersOnly: false` baseline applied before the
  ///   cutoff).
  /// - `accountRows` / `earmarkRows` carry the post-`after` deltas.
  /// - `investmentValues` carries every `investment_value` row — all
  ///   historical snapshots are loaded so the cursor walk in
  ///   `applyInvestmentValues` can carry the most recent pre-window
  ///   value forward into the first in-window day.
  /// - `scheduled` carries the scheduled `[Transaction]` for the
  ///   forecast extrapolation — the forecast path stays Swift-only
  ///   because SQL can't extrapolate recurring patterns.
  struct DailyBalancesAggregation: Sendable {
    let priorAccountRows: [DailyBalanceAccountRow]
    let priorEarmarkRows: [DailyBalanceEarmarkRow]
    let accountRows: [DailyBalanceAccountRow]
    let earmarkRows: [DailyBalanceEarmarkRow]
    let investmentValues: [InvestmentValueSnapshot]
    let investmentAccountIds: Set<UUID>
    /// Account ids of trades-mode investment accounts. Drives the new
    /// per-day position-valuation fold; recorded-value accounts are
    /// carried in `investmentAccountIds` and drive the snapshot fold.
    let tradesModeInvestmentAccountIds: Set<UUID>
    /// Pre-cutoff `transaction_leg` SUM rows filtered to trades-mode
    /// investment accounts only. Pre-fold seed for the new fold's
    /// cumulative position dict.
    let priorTradesModeAccountRows: [DailyBalanceAccountRow]
    /// Post-cutoff `transaction_leg` SUM rows filtered to trades-mode
    /// investment accounts only.
    let tradesModeAccountRows: [DailyBalanceAccountRow]
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
  /// share the same handler pattern. Investment-value failures use
  /// their own callback because they fire at the post-loop fold-in
  /// step and carry per-account context — folding them into
  /// `handleConversionFailure` would dilute the per-day signal.
  struct DailyBalancesHandlers: Sendable {
    let handleUnparseableDay: @Sendable (String) -> Void
    let handleConversionFailure: @Sendable (Error, DailyBalancesFailureContext) -> Void
    let handleInvestmentValueFailure: @Sendable (Error, Date) -> Void
  }

  /// Fixed inputs that stay constant across every per-day call inside
  /// `walkDays` and the investment-value fold-in. Lifts the
  /// `investmentAccountIds`, `instrumentMap`, `profileInstrument`, and
  /// `conversionService` references out of every helper signature so
  /// each function fits SwiftLint's `function_parameter_count` budget.
  struct DailyBalancesAssemblyContext: Sendable {
    let investmentAccountIds: Set<UUID>
    /// Account ids of trades-mode investment accounts — read by
    /// `applyTradesModePositionValuations` to early-exit when the
    /// profile has none. None of the seed/walk helpers consult this
    /// field; trades-mode accounts contribute through the new fold,
    /// not through `accountsFromTransfers`.
    let tradesModeInvestmentAccountIds: Set<UUID>
    let instrumentMap: [String: Instrument]
    let profileInstrument: Instrument
    let conversionService: any InstrumentConversionService
  }
}
