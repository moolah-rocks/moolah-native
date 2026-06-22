import Foundation

/// Batch-conversion planning and outcome-reassembly helpers for
/// `assembleIncomeAndExpense`. Split from the main
/// `+IncomeAndExpense.swift` assembly file: the per-row walk there
/// drives `planIncomeAndExpense` once up front to flatten every row's
/// non-zero columns into a single `convertResultBatch(_:)` request list,
/// then `assembleConvertedRowSums` to rebuild each row's four-column
/// `ConvertedRowSums` from its outcome slice.
extension GRDBAnalysisRepository {
  /// Bundle of converted per-row sums fed into a month bucket, so the
  /// bucket-update helper takes one parameter instead of many.
  struct ConvertedRowSums {
    let day: Date
    let income: InstrumentAmount
    let expense: InstrumentAmount
    let investmentIncome: InstrumentAmount
    let investmentExpense: InstrumentAmount
  }

  /// Which of the four `ConvertedRowSums` columns a batch request fills.
  /// Only non-zero columns produce a request (and therefore a tag), so a
  /// row's tag list mirrors exactly the conversion-service hits the
  /// pre-batch `convertRowSums` would have made — keeping the per-row
  /// counter invariants asserted by `GRDBIncomeAndExpenseAssembleTests`.
  enum IncomeExpenseColumn {
    case income
    case expense
    case investmentIncome
    case investmentExpense
  }

  /// One parseable row paired with its parsed day and the `(column)` tags
  /// whose outcomes reassemble into a `ConvertedRowSums`. The tag count
  /// equals the number of requests this row contributed to the flat list.
  struct IncomeExpenseRowPlan {
    let row: IncomeAndExpenseRow
    let day: Date
    let tags: [IncomeExpenseColumn]
  }

  /// Flat batch plan across every parseable row: per-row plans plus the
  /// index-aligned flat request list and the day-strings that failed to
  /// parse.
  struct IncomeAndExpensePlan {
    let parsedRows: [IncomeExpenseRowPlan]
    let requests: [BatchConversionRequest]
    let unparseableDays: [String]
  }

  /// Parse every row's day, resolve its source instrument, and build the
  /// flat batch request list across all four columns of every row. A
  /// zero-value column emits no request (it folds to `.zero` at assembly
  /// time) so the conversion-service hit count stays tied to the non-zero
  /// column count rather than four-times the row count. Same-instrument
  /// non-zero columns still emit a request; the batch's same-instrument
  /// fast path resolves them to `.value` without a service hit, matching
  /// `convertedQuantity`'s short circuit.
  static func planIncomeAndExpense(
    aggregation: IncomeAndExpenseAggregation,
    profileInstrument: Instrument
  ) -> IncomeAndExpensePlan {
    var parsedRows: [IncomeExpenseRowPlan] = []
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
      let columns: [(IncomeExpenseColumn, Int64)] = [
        (.income, row.incomeQty),
        (.expense, row.expenseQty),
        (.investmentIncome, row.investmentIncomeQty),
        (.investmentExpense, row.investmentExpenseQty),
      ]
      var tags: [IncomeExpenseColumn] = []
      for (column, value) in columns where value != 0 {
        tags.append(column)
        requests.append(
          BatchConversionRequest(
            amount: InstrumentAmount(storageValue: value, instrument: instrument),
            target: profileInstrument,
            date: day))
      }
      parsedRows.append(IncomeExpenseRowPlan(row: row, day: day, tags: tags))
    }
    return IncomeAndExpensePlan(
      parsedRows: parsedRows, requests: requests, unparseableDays: unparseableDays)
  }

  /// Reassemble one row's `ConvertedRowSums` from its `(column, outcome)`
  /// slice. Every column starts at `.zero(profileInstrument)` so the
  /// zero-value columns the plan skipped contribute zero. The batch
  /// resolves all of the row's non-zero columns up front; this walk
  /// surfaces the first `.failure` in the slice so the row degrades as a
  /// unit, throwing that column's error. `.knownZero` folds to zero
  /// (issue #790).
  static func assembleConvertedRowSums(
    tags: [IncomeExpenseColumn],
    outcomes: [BatchConversionOutcome],
    day: Date,
    profileInstrument: Instrument
  ) throws -> ConvertedRowSums {
    var income = InstrumentAmount.zero(instrument: profileInstrument)
    var expense = InstrumentAmount.zero(instrument: profileInstrument)
    var investmentIncome = InstrumentAmount.zero(instrument: profileInstrument)
    var investmentExpense = InstrumentAmount.zero(instrument: profileInstrument)
    for (column, outcome) in zip(tags, outcomes) {
      let amount: InstrumentAmount
      switch outcome {
      case .value(let converted):
        amount = converted
      case .knownZero:
        amount = .zero(instrument: profileInstrument)
      case .failure(let error):
        throw error
      }
      // Direct assignment (not accumulation) is safe: each column tag
      // appears at most once per row, and the targets are zero-initialized.
      switch column {
      case .income: income = amount
      case .expense: expense = amount
      case .investmentIncome: investmentIncome = amount
      case .investmentExpense: investmentExpense = amount
      }
    }
    return ConvertedRowSums(
      day: day,
      income: income,
      expense: expense,
      investmentIncome: investmentIncome,
      investmentExpense: investmentExpense)
  }
}
