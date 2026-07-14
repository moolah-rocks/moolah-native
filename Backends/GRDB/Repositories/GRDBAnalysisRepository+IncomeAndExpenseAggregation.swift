import Foundation
import GRDB

/// SQL-side helpers for the `fetchIncomeAndExpense` aggregation. Holds
/// the query string, the row decoder, and the `database.read` entry
/// point. The Swift assembly path (the per-row conversion +
/// month-bucket fold) lives in `+IncomeAndExpense.swift`.
extension GRDBAnalysisRepository {
  /// Comma-separated, SQL-quoted list of the `AccountType` raw values
  /// that are investment-like (`AccountType.isInvestmentLike`), e.g.
  /// `'investment', 'crypto', 'exchange'`. Derived from
  /// `AccountType.allCases`, so adding a new investment-like account
  /// type updates every aggregation (and its plan-pinning mirror) from
  /// this one place — there is nothing to keep in sync.
  ///
  /// Safe to interpolate directly into SQL: every element is a
  /// compile-time enum raw value, never user input, so there is no
  /// injection surface. Exposed (not file-private) so tests can
  /// reference the same value rather than duplicating the literal.
  static let investmentLikeTypesSQLList: String =
    AccountType.allCases
    .filter(\.isInvestmentLike)
    .map { "'\($0.rawValue)'" }
    .joined(separator: ", ")

  /// Runs the per-(day, instrument) conditional-sum aggregation
  /// pinned by
  /// `AnalysisAggregationPlanPinningTests.fetchIncomeAndExpenseUsesTypeAccountIndex`.
  ///
  /// **LEFT JOIN account.** Every branch reads `account.type` to split
  /// legs by where the money lives (`a.type` is NULL for
  /// nil-`account_id` legs).
  ///
  /// **Column assignment by leg type.** `income` and `trade` legs land in
  /// the Income column; `expense` and `transfer` legs land in the Expense
  /// column; `openingBalance` is excluded. Putting *both* legs of a
  /// transfer (or trade) in the same column means their opposite signs
  /// cancel, so a transfer between two accounts never inflates a column —
  /// it nets to zero (plain transfer) or to the realised gain (a trade /
  /// FX conversion priced at each leg's own day-rate). Trades are treated
  /// as income (you expect to gain), transfers as expense.
  ///
  /// - `income_qty` / `expense_qty` are the **available-funds base** (the
  ///   figure shown with the investments toggle off). Per leg this is
  ///   `(current-account amount) − (earmark amount)`: a current-account
  ///   leg counts (`+`), and every earmark leg subtracts its amount
  ///   (`−`) — so earmark reserve movements are *always* applied. A leg
  ///   on both a current account and an earmark nets to zero (cash
  ///   arrived but is reserved), and an account-less earmark leg flips
  ///   sign (setting money aside reads as a reduction, releasing it as a
  ///   gain). Investment-account legs are excluded here.
  /// - `investment_income_qty` / `investment_expense_qty` are the
  ///   **investment layer** added by the "Include Investments" toggle:
  ///   all legs on investment-like accounts (dividends, staking, token
  ///   unlocks, fees, plus the investment side of contributions /
  ///   withdrawals / trades).
  ///
  /// The investment-like set comes from `AccountType.isInvestmentLike`
  /// via `investmentLikeTypesSQLList`, so every investment-like account
  /// type is treated the same way.
  ///
  /// **Why four aggregates in one query.** A single pass over the leg
  /// index keeps all four sums consistent with one MVCC snapshot —
  /// separate queries could surface inconsistent totals if a writer
  /// commits between them.
  static func fetchIncomeAndExpenseAggregation(
    database: any DatabaseReader,
    instruments: [String: Instrument],
    after: Date?
  ) async throws -> IncomeAndExpenseAggregation {
    try await database.read { database -> IncomeAndExpenseAggregation in
      let arguments: StatementArguments = ["after": after]
      let sqlRows = try Row.fetchAll(
        database, sql: incomeAndExpenseAggregationSQL, arguments: arguments)
      let rows = sqlRows.compactMap(Self.mapAggregationRow(_:))
      return IncomeAndExpenseAggregation(rows: rows, instrumentMap: instruments)
    }
  }

  /// Decode one `EXPLAIN`-pinned aggregation row, returning `nil` for
  /// malformed rows (e.g. NULL `day` / `instrument_id`) so the loop
  /// skips them without breaking the rest of the snapshot.
  static func mapAggregationRow(_ row: Row) -> IncomeAndExpenseRow? {
    guard let day: String = row["day"] else { return nil }
    guard let instrumentId: String = row["instrument_id"] else { return nil }
    return IncomeAndExpenseRow(
      day: day,
      instrumentId: instrumentId,
      incomeQty: row["income_qty"] ?? 0,
      expenseQty: row["expense_qty"] ?? 0,
      investmentIncomeQty: row["investment_income_qty"] ?? 0,
      investmentExpenseQty: row["investment_expense_qty"] ?? 0)
  }
}

/// File-private SQL for the per-(day, instrument) aggregation. The
/// query's plan shape (index usage, absence of full-table scans) is
/// pinned by
/// `AnalysisAggregationPlanPinningTests.fetchIncomeAndExpenseUsesTypeAccountIndex`;
/// structural changes here (WHERE predicates, JOIN reorders, GROUP BY)
/// should be reflected in that test so the plan stays under EXPLAIN.
private let incomeAndExpenseAggregationSQL = """
  SELECT
      DATE(t.date)         AS day,
      leg.instrument_id    AS instrument_id,
      SUM(
          (CASE WHEN leg.type IN ('income', 'trade')
                 AND a.type IS NOT NULL
                 AND a.type NOT IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
                THEN leg.quantity ELSE 0 END)
        - (CASE WHEN leg.type IN ('income', 'trade')
                 AND leg.earmark_id IS NOT NULL
                THEN leg.quantity ELSE 0 END)
      )                                              AS income_qty,
      SUM(
          (CASE WHEN leg.type IN ('expense', 'transfer')
                 AND a.type IS NOT NULL
                 AND a.type NOT IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
                THEN leg.quantity ELSE 0 END)
        - (CASE WHEN leg.type IN ('expense', 'transfer')
                 AND leg.earmark_id IS NOT NULL
                THEN leg.quantity ELSE 0 END)
      )                                              AS expense_qty,
      SUM(CASE WHEN leg.type IN ('income', 'trade')
                AND a.type IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
               THEN leg.quantity ELSE 0 END)        AS investment_income_qty,
      SUM(CASE WHEN leg.type IN ('expense', 'transfer')
                AND a.type IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
               THEN leg.quantity ELSE 0 END)        AS investment_expense_qty
  FROM transaction_leg leg
  JOIN "transaction"    t ON leg.transaction_id = t.id
  LEFT JOIN account     a ON leg.account_id = a.id
  WHERE t.recur_period IS NULL
    AND (:after IS NULL OR t.date >= :after)
  GROUP BY day, leg.instrument_id
  ORDER BY day ASC
  """
