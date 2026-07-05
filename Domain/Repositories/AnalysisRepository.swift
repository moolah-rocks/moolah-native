// swiftlint:disable multiline_arguments

import Foundation

/// Repository for fetching aggregated financial analysis data.
protocol AnalysisRepository: Sendable {
  /// Fetch daily balance snapshots for a date range, optionally including forecasts.
  ///
  /// - Parameters:
  ///   - after: Start date (inclusive). Nil = all history.
  ///   - forecastUntil: End date for forecast (inclusive). Nil = no forecast.
  /// - Returns: Array of DailyBalance (actual + forecast if requested).
  /// - Throws: BackendError on network/auth failure.
  func fetchDailyBalances(
    after: Date?,
    forecastUntil: Date?
  ) async throws -> [DailyBalance]

  /// Fetch expense breakdown by category for a date range.
  ///
  /// - Parameters:
  ///   - monthEnd: Day of month representing the user's financial month end (1–31).
  ///   - after: Start date (inclusive). Nil = all history.
  /// - Returns: Array of ExpenseBreakdown grouped by category and financial month.
  /// - Throws: BackendError on network/auth failure.
  func fetchExpenseBreakdown(
    monthEnd: Int,
    after: Date?
  ) async throws -> [ExpenseBreakdown]

  /// Fetch monthly income and expense summary for a date range.
  ///
  /// - Parameters:
  ///   - monthEnd: Day of month representing the user's financial month end (1–31).
  ///   - after: Start date (inclusive). Nil = all history.
  /// - Returns: Array of MonthlyIncomeExpense grouped by financial month.
  /// - Throws: BackendError on network/auth failure.
  func fetchIncomeAndExpense(
    monthEnd: Int,
    after: Date?
  ) async throws -> [MonthlyIncomeExpense]

  /// Fetch category balances (total amounts per category) for a date range and transaction type.
  ///
  /// A single aggregation covers both categorised and uncategorised legs: rows with a
  /// non-null category land in `CategoryBalances.byCategory`; rows with no category land in
  /// `CategoryBalances.uncategorised`. `byCategory` excludes uncategorised legs — that
  /// exclusion is its contract, unchanged from before this field existed. The client is
  /// responsible for grouping subcategories under root categories.
  ///
  /// - Parameters:
  ///   - dateRange: Date range to analyze (inclusive on both ends).
  ///   - transactionType: Filter to 'income' or 'expense' transactions.
  ///   - filters: Optional additional filters (account, earmark, payee, etc.).
  ///   - targetInstrument: Instrument to convert the aggregated amounts into. Callers that
  ///     filter by earmark should pass the earmark's instrument so the totals are directly
  ///     comparable to the earmark's budget items (see
  ///     `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 1/2). Single-instrument backends
  ///     require this to match the profile instrument.
  /// - Returns: `CategoryBalances` — `byCategory` maps category UUIDs to total
  ///   `InstrumentAmount`s in `targetInstrument`; `uncategorised` is the total of legs with
  ///   no category (`nil` when there are none).
  /// - Throws: BackendError on network/auth failure.
  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> CategoryBalances

  /// Fetch category balances for both income and expense in a single pass.
  ///
  /// The protocol-extension default below composes this from two `fetchCategoryBalances`
  /// calls (one per `TransactionType`) — every backend gets the combined uncategorised
  /// totals for free, with no backend-specific override needed.
  ///
  /// - Parameters:
  ///   - dateRange: Date range to analyze (inclusive on both ends).
  ///   - filters: Optional additional filters (account, earmark, payee, etc.).
  ///   - targetInstrument: Instrument the aggregated amounts are expressed in.
  /// - Returns: `CategoryBalancesByType` with per-category income/expense totals, plus
  ///   uncategorised totals (`nil` when there are no uncategorised legs of that type).
  /// - Throws: BackendError on network/auth failure.
  func fetchCategoryBalancesByType(
    dateRange: ClosedRange<Date>,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> CategoryBalancesByType

  /// Load all analysis data in a single batch, avoiding redundant fetches.
  ///
  /// Backends that compute locally (CloudKit/SwiftData) should override this to fetch
  /// shared data once. The default implementation calls the three individual methods.
  func loadAll(
    historyAfter: Date?,
    forecastUntil: Date?,
    monthEnd: Int
  ) async throws -> AnalysisData
}

/// Result of loading all analysis data in a single batch.
/// Used to avoid redundant data fetching in backends that compute locally (e.g. CloudKit).
struct AnalysisData: Sendable {
  let dailyBalances: [DailyBalance]
  let expenseBreakdown: [ExpenseBreakdown]
  let incomeAndExpense: [MonthlyIncomeExpense]
}

/// Result of `fetchCategoryBalances`: per-category totals for one transaction type, plus the
/// total of legs that carry no category.
///
/// `byCategory` **excludes** uncategorised legs — that exclusion is unconditional and
/// unaffected by whether any uncategorised legs exist in range. `uncategorised` is `nil`
/// when there are no such legs (rather than `.zero`) so callers can distinguish "no
/// uncategorised activity" from "an uncategorised total of zero" and omit UI for the
/// former.
struct CategoryBalances: Sendable {
  let byCategory: [UUID: InstrumentAmount]
  let uncategorised: InstrumentAmount?

  /// True when one or more rows contributing to this result could not be priced due to a
  /// transient conversion error (e.g. crypto prices not yet warmed — see
  /// `ConversionFailureClassifier.isTransient` and `guides/INSTRUMENT_CONVERSION_GUIDE.md`
  /// Rule 11). The skipped row's contribution is missing from both `byCategory` and
  /// `uncategorised`, so `byCategory` / `uncategorised` totals may be understated; callers
  /// should surface this state rather than presenting them as complete.
  ///
  /// This is a *whole-result* flag, not per-category: a transient skip on any one category
  /// marks the entire result unavailable. That is coarser than Rule 11's "keep independently
  /// computable sibling totals rendering" ideal (the sibling `ExpenseBreakdown` scopes its
  /// flag per-month). Refining to per-category unavailability requires reshaping this return
  /// type and the ReportingStore/view plumbing that consumes it, deferred to the later
  /// Reports-surfacing step; this data-layer step establishes the honest "something here is
  /// unavailable" signal first. `var` (not `let`) so
  /// the synthesized memberwise init keeps its default of `false` as a parameter default —
  /// a `let` with an inline default is fixed at that value and drops out of the
  /// memberwise init entirely, which would make every pre-existing call site un-updatable.
  var hasUnavailableData: Bool = false
}

/// Result of `fetchCategoryBalancesByType`: per-category income/expense totals for the
/// Reports screen, plus uncategorised totals.
///
/// `incomeUncategorised` / `expenseUncategorised` are `nil` when there are no uncategorised
/// legs of that type in range — the Reports screen omits the "Uncategorised" row in that
/// case, rather than treating `nil` as zero.
struct CategoryBalancesByType: Sendable {
  let income: [UUID: InstrumentAmount]
  let expense: [UUID: InstrumentAmount]
  let incomeUncategorised: InstrumentAmount?
  let expenseUncategorised: InstrumentAmount?

  /// Per-column mirrors of `CategoryBalances.hasUnavailableData` (Strict Rule 11, #1077) — set
  /// from the `income` / `expense` `fetchCategoryBalances` call respectively, so a transient
  /// conversion failure in one column doesn't mark the other unavailable. `var` (not `let`)
  /// for the same synthesized-memberwise-init reason as `CategoryBalances.hasUnavailableData`.
  var incomeHasUnavailableData: Bool = false
  var expenseHasUnavailableData: Bool = false
}

extension AnalysisRepository {
  func fetchCategoryBalancesByType(
    dateRange: ClosedRange<Date>,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> CategoryBalancesByType {
    async let incomeResult = fetchCategoryBalances(
      dateRange: dateRange, transactionType: .income, filters: filters,
      targetInstrument: targetInstrument)
    async let expenseResult = fetchCategoryBalances(
      dateRange: dateRange, transactionType: .expense, filters: filters,
      targetInstrument: targetInstrument)
    let (income, expense) = try await (incomeResult, expenseResult)
    return CategoryBalancesByType(
      income: income.byCategory,
      expense: expense.byCategory,
      incomeUncategorised: income.uncategorised,
      expenseUncategorised: expense.uncategorised,
      incomeHasUnavailableData: income.hasUnavailableData,
      expenseHasUnavailableData: expense.hasUnavailableData
    )
  }

  func loadAll(
    historyAfter: Date?,
    forecastUntil: Date?,
    monthEnd: Int
  ) async throws -> AnalysisData {
    async let balances = fetchDailyBalances(after: historyAfter, forecastUntil: forecastUntil)
    async let breakdown = fetchExpenseBreakdown(monthEnd: monthEnd, after: historyAfter)
    async let income = fetchIncomeAndExpense(monthEnd: monthEnd, after: historyAfter)

    return try await AnalysisData(
      dailyBalances: balances,
      expenseBreakdown: breakdown,
      incomeAndExpense: income
    )
  }
}
