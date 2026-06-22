import Foundation
import GRDB

/// Swift assembly helpers and shared types for `fetchIncomeAndExpense`.
/// The SQL aggregation itself lives in the sibling
/// `+IncomeAndExpenseAggregation.swift`; this file fans the
/// per-`(day, instrument)` rows it produces out into per-month
/// income/expense buckets.
///
/// Mirrors the `+ExpenseBreakdown.swift` and `+CategoryBalances.swift`
/// shapes: static helpers take their dependencies as parameters so
/// this sibling-file extension doesn't reach into the main class's
/// `private` storage.
///
/// Per-row conversion runs in Swift so the per-day rate-cache
/// equivalence (Rule 5 of `INSTRUMENT_CONVERSION_GUIDE.md`) holds.
///
/// **Column assignment.** `income`/`trade` legs feed the income column,
/// `expense`/`transfer` legs the expense column. Because both legs of a
/// transfer or trade share a column, their opposite signs cancel — a
/// plain transfer nets to zero, a trade/FX conversion to its realised
/// gain — so transfers never inflate the totals. Pinned by
/// `AnalysisIncomeExpenseTests.investmentTransferClassification`.
extension GRDBAnalysisRepository {
  /// One row of the SQL aggregation that drives `fetchIncomeAndExpense`.
  /// Each row carries four conditional sums for one `(day, instrument)`
  /// tuple. `day` is the ISO-8601 `YYYY-MM-DD` string returned by
  /// `DATE(t.date)` — parsed in Swift on the way out of the read
  /// closure so the `Database` reference doesn't escape into the
  /// conversion service.
  struct IncomeAndExpenseRow: Sendable {
    let day: String
    let instrumentId: String
    /// Available-funds base income: income/trade legs on current
    /// accounts, minus the earmark amount of any income/trade earmark leg.
    let incomeQty: Int64
    /// Available-funds base expense: expense/transfer legs on current
    /// accounts, minus the earmark amount of any expense/transfer earmark
    /// leg.
    let expenseQty: Int64
    /// Investment layer, income side: income/trade legs on
    /// investment-like accounts.
    let investmentIncomeQty: Int64
    /// Investment layer, expense side: expense/transfer legs on
    /// investment-like accounts.
    let investmentExpenseQty: Int64
  }

  /// Pair of SQL output rows and the instrument lookup. The lookup is
  /// resolved via the injected `InstrumentMapResolving` *before* the
  /// per-profile read snapshot opens (the canonical registry is a
  /// separate database, so it can't be joined into this transaction);
  /// the SQL rows come from the snapshot. Instrument identity is
  /// immutable lookup data, so the non-atomic pairing is safe and
  /// intended. Mirrors `GRDBTransactionRepository`'s hoisted-map shape.
  struct IncomeAndExpenseAggregation: Sendable {
    let rows: [IncomeAndExpenseRow]
    let instrumentMap: [String: Instrument]
  }

  /// Diagnostic context passed to the conversion-failure handler so
  /// the caller's logger can identify which `(day, instrument)` tuple
  /// failed without coupling this helper to a `Logger` instance.
  struct IncomeAndExpenseFailureContext: Sendable {
    let day: String
    let instrumentId: String
  }

  /// Bundle of per-row diagnostic callbacks used by
  /// `assembleIncomeAndExpense`. Matches the
  /// `ExpenseBreakdownHandlers` / `CategoryBalancesHandlers` shape so
  /// future analysis methods can share the same handler pattern.
  struct IncomeAndExpenseHandlers: Sendable {
    let handleUnparseableDay: @Sendable (String) -> Void
    let handleConversionFailure: @Sendable (Error, IncomeAndExpenseFailureContext) -> Void
  }

  /// Mutable per-month accumulator used during assembly. Stored
  /// outside `MonthlyIncomeExpense` (which has only `let` fields) so
  /// the loop can `+=` into each bucket without rebuilding the value
  /// type on every leg. `start` / `end` track the min/max parsed-day
  /// `Date` so the resulting `MonthlyIncomeExpense` carries the
  /// expected display range.
  private struct MonthBucket {
    var start: Date
    var end: Date
    var income: InstrumentAmount
    var expense: InstrumentAmount
    var investmentIncome: InstrumentAmount
    var investmentExpense: InstrumentAmount
    var investmentProfit: InstrumentAmount
  }

  /// Walks the SQL aggregation rows, converts each row's four sums to
  /// the profile instrument on the row's own day, and accumulates
  /// into per-financial-month buckets. Conversion runs outside the
  /// `database.read` closure (in this async helper) so the `Database`
  /// reference stays inside the snapshot.
  ///
  /// Mirrors `assembleExpenseBreakdown`'s per-row error contract:
  /// `handleUnparseableDay` and `handleConversionFailure` are invoked
  /// per failing row so each failure surfaces individually in
  /// diagnostics; the loop continues processing remaining rows then
  /// re-throws the first conversion error after the walk so the
  /// function preserves its existing "throws on conversion error"
  /// contract while still delivering the per-row detail required by
  /// `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11. A `CancellationError`
  /// is rethrown immediately and never folded into the
  /// conversion-failure path.
  ///
  /// Each row carries four already-signed sums (base income/expense and
  /// the investment-layer income/expense); the fold simply accumulates
  /// them, with `investmentProfit` as the signed sum of the two
  /// investment columns.
  @concurrent
  static func assembleIncomeAndExpense(
    aggregation: IncomeAndExpenseAggregation,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    monthEnd: Int,
    handlers: IncomeAndExpenseHandlers
  ) async throws -> [MonthlyIncomeExpense] {
    let plan = Self.planIncomeAndExpense(
      aggregation: aggregation, profileInstrument: profileInstrument)
    for dayString in plan.unparseableDays {
      handlers.handleUnparseableDay(dayString)
    }
    // One batched conversion for every parseable row's non-zero columns;
    // `CancellationError` propagates straight out (never reaching the
    // per-row failure path).
    let outcomes = try await conversionService.convertResultBatch(plan.requests)

    var buckets: [String: MonthBucket] = [:]
    var firstConversionError: Error?
    // Strict Rule 11 (#1077): a financial month with ANY transient
    // (price-unavailable) skip is marked unavailable — even if other
    // rows in the month converted — and a month whose rows ALL skipped
    // still emits a zeroed placeholder bucket spanning the failing days.
    var unavailable = UnavailableMonthTracker()
    var cursor = 0
    for planned in plan.parsedRows {
      let row = planned.row
      let day = planned.day
      let slice = Array(outcomes[cursor..<cursor + planned.tags.count])
      cursor += planned.tags.count
      let converted: ConvertedRowSums
      do {
        converted = try Self.assembleConvertedRowSums(
          tags: planned.tags,
          outcomes: slice,
          day: day,
          profileInstrument: profileInstrument)
      } catch {
        let context = IncomeAndExpenseFailureContext(
          day: row.day, instrumentId: row.instrumentId)
        handlers.handleConversionFailure(error, context)
        // Issue #1075: transient price failures degrade per-row; only a
        // structural failure preserves the loud rethrow. Strict Rule 11
        // (#1077): a transient skip flags its month unavailable.
        if ConversionFailureClassifier.isTransient(error) {
          unavailable.record(
            month: Self.financialMonth(for: day, monthEnd: monthEnd), day: day)
        } else if firstConversionError == nil {
          firstConversionError = error
        }
        continue
      }
      let month = Self.financialMonth(for: day, monthEnd: monthEnd)
      var bucket =
        buckets[month]
        ?? Self.makeEmptyMonthBucket(day: day, instrument: profileInstrument)
      Self.applyConvertedRow(converted, into: &bucket)
      buckets[month] = bucket
    }
    if let firstConversionError {
      // Preserve the existing observable behaviour (throws on the
      // first conversion error) while having logged every per-row
      // failure.
      throw firstConversionError
    }
    Self.insertUnavailablePlaceholders(
      into: &buckets, tracker: unavailable, profileInstrument: profileInstrument)
    return Self.flattenIncomeAndExpenseBuckets(
      buckets, incompleteMonths: unavailable.months)
  }

  /// Tracks, for strict Rule 11 (#1077), which financial months had ≥1
  /// transient (price-unavailable) conversion skip and the span of the
  /// failing-row days within each — so the assembler can mark every
  /// emitted bucket for those months unavailable and synthesise a
  /// placeholder bucket for any month whose rows ALL skipped.
  private struct UnavailableMonthTracker {
    private(set) var months: Set<String> = []
    private(set) var dayRanges: [String: (start: Date, end: Date)] = [:]

    mutating func record(month: String, day: Date) {
      months.insert(month)
      let existing = dayRanges[month]
      dayRanges[month] = (
        start: min(existing?.start ?? day, day),
        end: max(existing?.end ?? day, day)
      )
    }
  }

  /// Emit a zeroed placeholder bucket for any month whose rows ALL
  /// transient-skipped (no converted row created a bucket) so the month
  /// still appears in the result — flagged unavailable downstream and
  /// spanning its failing-row days. Months that already have a bucket
  /// (at least one row converted) keep their converted totals; the
  /// unavailable flag is applied separately at flatten time.
  private static func insertUnavailablePlaceholders(
    into buckets: inout [String: MonthBucket],
    tracker: UnavailableMonthTracker,
    profileInstrument: Instrument
  ) {
    for month in tracker.months where buckets[month] == nil {
      let range = tracker.dayRanges[month]
      var bucket = Self.makeEmptyMonthBucket(
        day: range?.start ?? Date(), instrument: profileInstrument)
      if let range {
        bucket.start = range.start
        bucket.end = range.end
      }
      buckets[month] = bucket
    }
  }

  /// Build a fresh `MonthBucket` seeded with the row's day as both
  /// `start` and `end`. Subsequent rows widen the range via
  /// `applyConvertedRow`.
  private static func makeEmptyMonthBucket(
    day: Date,
    instrument: Instrument
  ) -> MonthBucket {
    MonthBucket(
      start: day,
      end: day,
      income: .zero(instrument: instrument),
      expense: .zero(instrument: instrument),
      investmentIncome: .zero(instrument: instrument),
      investmentExpense: .zero(instrument: instrument),
      investmentProfit: .zero(instrument: instrument))
  }

  /// Apply one converted row's four sums into a month bucket.
  ///
  /// `income`/`expense` are the available-funds base (the SQL has already
  /// folded in the earmark reserve adjustment, so a refund — a
  /// positive-quantity `.expense` leg — still reduces the negative expense
  /// total; see `AnalysisIncomeExpenseTests.expenseRefundsReduceTotal`).
  /// `investmentIncome`/`investmentExpense` are the investment layer.
  /// Both legs of a transfer/trade already carry their own sign in the
  /// SQL sums, so they net within their column with no extra handling.
  private static func applyConvertedRow(
    _ row: ConvertedRowSums,
    into bucket: inout MonthBucket
  ) {
    bucket.start = min(bucket.start, row.day)
    bucket.end = max(bucket.end, row.day)
    bucket.income += row.income
    bucket.expense += row.expense
    bucket.investmentIncome += row.investmentIncome
    bucket.investmentExpense += row.investmentExpense
    bucket.investmentProfit += row.investmentIncome + row.investmentExpense
  }

  /// Emits one `MonthlyIncomeExpense` per non-empty bucket and sorts
  /// months descending — matching the CloudKit-era contract pinned
  /// by the income/expense contract suite. `profit = income + expense`
  /// is a derived signed-sum here rather than a separately-tracked
  /// accumulator because every leg that contributes to `profit`
  /// already contributes to `income` or `expense` with the same
  /// conditions.
  private static func flattenIncomeAndExpenseBuckets(
    _ buckets: [String: MonthBucket],
    incompleteMonths: Set<String>
  ) -> [MonthlyIncomeExpense] {
    var results: [MonthlyIncomeExpense] = []
    results.reserveCapacity(buckets.count)
    for (month, bucket) in buckets {
      results.append(
        MonthlyIncomeExpense(
          month: month,
          start: bucket.start,
          end: bucket.end,
          income: bucket.income,
          expense: bucket.expense,
          profit: bucket.income + bucket.expense,
          investmentIncome: bucket.investmentIncome,
          investmentExpense: bucket.investmentExpense,
          investmentProfit: bucket.investmentProfit,
          hasUnavailableData: incompleteMonths.contains(month)))
    }
    return results.sorted { $0.month > $1.month }
  }
}
