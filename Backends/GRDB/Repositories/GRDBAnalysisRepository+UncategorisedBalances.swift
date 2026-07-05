import Foundation
import GRDB

/// SQL aggregation + Swift assembly helpers for the "Uncategorised" row on
/// the Reports screen — the total of income/expense legs that carry no
/// `category_id`.
///
/// Mirrors `+CategoryBalances.swift`'s shape (SQL composed via `SQL` literal
/// interpolation, conversion resolved outside the `database.read` closure),
/// but the SQL groups by `(DATE(t.date), instrument_id)` only — there is no
/// category dimension to bucket by — and every row's contribution is
/// summed into a single `InstrumentAmount` rather than a per-category
/// dictionary. Only invoked from `fetchCategoryBalancesByType`; the
/// per-type `fetchCategoryBalances(...)` contract deliberately excludes
/// uncategorised legs and must not change (see
/// `plans/2026-07-05-reports-uncategorised-row-plan.md`, "Design decisions
/// (locked)").
extension GRDBAnalysisRepository {
  /// One row of the SQL aggregation that drives the uncategorised total.
  /// `day` is the ISO-8601 `YYYY-MM-DD` string returned by `DATE(t.date)` —
  /// parsed in Swift on the way out of the read closure, matching
  /// `CategoryBalancesRow`.
  struct UncategorisedBalancesRow: Sendable {
    let day: String
    let instrumentId: String
    let qty: Int64
  }

  /// Pair of SQL output rows and the instrument lookup, resolved the same
  /// way as `CategoryBalancesAggregation` — the instrument map comes from
  /// the canonical registry *before* the per-profile read snapshot opens.
  struct UncategorisedBalancesAggregation: Sendable {
    let rows: [UncategorisedBalancesRow]
    let instrumentMap: [String: Instrument]
  }

  /// Diagnostic context passed to the conversion-failure handler. Mirrors
  /// `CategoryBalancesFailureContext` minus `categoryId` — there is no
  /// category dimension here by construction.
  struct UncategorisedBalancesFailureContext: Sendable {
    let day: String
    let instrumentId: String
  }

  /// Bundle of per-row diagnostic callbacks used by
  /// `assembleUncategorisedBalances`. Matches `CategoryBalancesHandlers`.
  struct UncategorisedBalancesHandlers: Sendable {
    let handleUnparseableDay: @Sendable (String) -> Void
    let handleConversionFailure: @Sendable (Error, UncategorisedBalancesFailureContext) -> Void
  }

  /// Filter values for the uncategorised aggregation. Deliberately has no
  /// `categoryIds` field — the query already restricts to
  /// `leg.category_id IS NULL`, so a category filter would be a
  /// contradiction (and every current caller passes `filters?.categoryIds`
  /// empty for the Reports-wide fetch anyway).
  struct UncategorisedBalancesFilterArgs: Sendable {
    let dateRange: ClosedRange<Date>
    let transactionType: TransactionType
    let accountId: UUID?
    let earmarkId: UUID?
    let payee: String?
  }

  /// Runs the per-(day, instrument) SUM(quantity) aggregation restricted to
  /// legs with no category.
  static func fetchUncategorisedBalancesAggregation(
    database: any DatabaseReader,
    instruments: [String: Instrument],
    args: UncategorisedBalancesFilterArgs
  ) async throws -> UncategorisedBalancesAggregation {
    try await database.read { database -> UncategorisedBalancesAggregation in
      let request = Self.makeUncategorisedBalancesRequest(args: args)
      let sqlRows = try Row.fetchAll(database, request)
      var rows: [UncategorisedBalancesRow] = []
      rows.reserveCapacity(sqlRows.count)
      for row in sqlRows {
        guard let day: String = row["day"] else { continue }
        guard let instrumentId: String = row["instrument_id"] else { continue }
        guard let qty: Int64 = row["qty"] else { continue }
        rows.append(
          UncategorisedBalancesRow(day: day, instrumentId: instrumentId, qty: qty))
      }
      return UncategorisedBalancesAggregation(rows: rows, instrumentMap: instruments)
    }
  }

  /// Builds the `SQLRequest<Row>` for the uncategorised-balances
  /// aggregation. Same `SQL` literal interpolation approach as
  /// `makeCategoryBalancesRequest` (`DATABASE_CODE_GUIDE.md` §4) — every
  /// optional filter clause renders as either an `AND <predicate>`
  /// fragment or an empty `SQL("")` placeholder. There is no
  /// `categoryIds` clause: the `leg.category_id IS NULL` guard in the
  /// base WHERE already selects the uncategorised slice.
  private static func makeUncategorisedBalancesRequest(
    args: UncategorisedBalancesFilterArgs
  ) -> SQLRequest<Row> {
    let lower = args.dateRange.lowerBound
    let upper = args.dateRange.upperBound
    let typeRaw = args.transactionType.rawValue

    let accountClause: SQL =
      args.accountId.map { SQL("AND leg.account_id = \($0)") } ?? SQL("")
    let earmarkClause: SQL =
      args.earmarkId.map { SQL("AND leg.earmark_id = \($0)") } ?? SQL("")
    let payeeClause: SQL =
      args.payee.map { SQL("AND t.payee = \($0)") } ?? SQL("")

    // Columns are table-qualified defensively, matching
    // `makeCategoryBalancesRequest`'s rationale.
    let literal: SQL = """
      SELECT DATE(t.date)        AS day,
             leg.instrument_id   AS instrument_id,
             SUM(leg.quantity)   AS qty
      FROM transaction_leg leg
      JOIN "transaction"    t ON leg.transaction_id = t.id
      WHERE t.recur_period IS NULL
        AND t.date >= \(lower) AND t.date <= \(upper)
        AND leg.type = \(typeRaw)
        AND leg.category_id IS NULL
        \(accountClause)
        \(earmarkClause)
        \(payeeClause)
      GROUP BY DATE(t.date), leg.instrument_id
      ORDER BY DATE(t.date) ASC
      """
    return SQLRequest<Row>(literal: literal)
  }

  /// The batch plan for the uncategorised-balances walk: the rows that
  /// parsed, the flat request list, and the day-strings that failed to
  /// parse. Mirrors `CategoryBalancesPlan`.
  private struct UncategorisedBalancesPlan {
    let parsedRows: [UncategorisedBalancesRow]
    let requests: [BatchConversionRequest]
    let unparseableDays: [String]
  }

  /// Walks the SQL aggregation rows, converts each `(qty, instrument)` to
  /// the target instrument on its own day, and sums every row into a
  /// single total. Returns `nil` when there are no rows at all — the
  /// Reports screen uses `nil` (rather than `.zero`) to decide whether to
  /// render the "Uncategorised" row.
  ///
  /// Mirrors `assembleCategoryBalances`'s per-row error contract:
  /// `handleUnparseableDay` and `handleConversionFailure` fire per failing
  /// row, the walk continues over the remaining rows, and the first
  /// conversion error is rethrown after the walk (Rule 11 of
  /// `INSTRUMENT_CONVERSION_GUIDE.md`). A `CancellationError` propagates
  /// straight out of the batch call and is never folded into the
  /// conversion-failure path.
  @concurrent
  static func assembleUncategorisedBalances(
    aggregation: UncategorisedBalancesAggregation,
    targetInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    handlers: UncategorisedBalancesHandlers
  ) async throws -> InstrumentAmount? {
    let plan = Self.planUncategorisedBalances(
      aggregation: aggregation, targetInstrument: targetInstrument)
    for dayString in plan.unparseableDays {
      handlers.handleUnparseableDay(dayString)
    }
    guard !plan.requests.isEmpty else { return nil }

    // One batched conversion for every parseable row; `CancellationError`
    // propagates straight out (never reaching the per-row failure path).
    let outcomes = try await conversionService.convertResultBatch(plan.requests)

    var total: InstrumentAmount = .zero(instrument: targetInstrument)
    var firstConversionError: Error?
    for (row, outcome) in zip(plan.parsedRows, outcomes) {
      let amount: InstrumentAmount
      switch outcome {
      case .value(let converted):
        amount = converted
      case .knownZero:
        // Issue #790: an `.unpriced` / `.spam` source folds to zero in
        // the target rather than failing the row.
        amount = .zero(instrument: targetInstrument)
      case .failure(let error):
        let context = UncategorisedBalancesFailureContext(
          day: row.day, instrumentId: row.instrumentId)
        handlers.handleConversionFailure(error, context)
        if firstConversionError == nil {
          firstConversionError = error
        }
        continue
      }
      total += amount
    }
    if let firstConversionError {
      // Preserve the existing "throws on first conversion error" contract
      // while having logged every per-row failure.
      throw firstConversionError
    }
    return total
  }

  /// Parse every row's day, resolve its source instrument, and build the
  /// flat batch request list. Mirrors `planCategoryBalances`.
  private static func planUncategorisedBalances(
    aggregation: UncategorisedBalancesAggregation,
    targetInstrument: Instrument
  ) -> UncategorisedBalancesPlan {
    var parsedRows: [UncategorisedBalancesRow] = []
    var requests: [BatchConversionRequest] = []
    var unparseableDays: [String] = []
    for row in aggregation.rows {
      guard let day = Self.parseDayString(row.day) else {
        unparseableDays.append(row.day)
        continue
      }
      let instrument =
        aggregation.instrumentMap[row.instrumentId]
        ?? Instrument.fiat(code: row.instrumentId)
      parsedRows.append(row)
      requests.append(
        BatchConversionRequest(
          amount: InstrumentAmount(storageValue: row.qty, instrument: instrument),
          target: targetInstrument,
          date: day))
    }
    return UncategorisedBalancesPlan(
      parsedRows: parsedRows, requests: requests, unparseableDays: unparseableDays)
  }
}
