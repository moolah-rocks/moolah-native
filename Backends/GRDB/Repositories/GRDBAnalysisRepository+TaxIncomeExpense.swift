import Foundation
import GRDB

extension GRDBAnalysisRepository {
  struct TaxIncomeExpenseRow: Sendable {
    let day: String
    let categoryId: UUID
    let instrumentId: String
    let type: TransactionType
    let ownerIds: [UUID]
    let qty: Int64
  }

  struct TaxIncomeExpenseAggregation: Sendable {
    let rows: [TaxIncomeExpenseRow]
    let instrumentMap: [String: Instrument]
  }

  struct TaxIncomeExpenseFailureContext: Sendable {
    let day: String
    let instrumentId: String
    let ownerIds: [UUID]
  }

  struct TaxIncomeExpenseHandlers: Sendable {
    let handleUnparseableDay: @Sendable (String) -> Void
    let handleConversionFailure: @Sendable (Error, TaxIncomeExpenseFailureContext) -> Void
  }

  struct TaxIncomeExpenseDetailSelection: Sendable {
    let ownerId: UUID?
    let type: TransactionType
  }

  static func fetchTaxIncomeExpenseAggregation(
    database: any DatabaseReader,
    instruments: [String: Instrument],
    dateInterval: Range<Date>,
    defaultTaxOwnerId: UUID
  ) async throws -> TaxIncomeExpenseAggregation {
    try await database.read { database -> TaxIncomeExpenseAggregation in
      let request = makeTaxIncomeExpenseRequest(
        dateInterval: dateInterval,
        defaultTaxOwnerId: defaultTaxOwnerId)
      let sqlRows = try Row.fetchAll(database, request)
      let rows = Self.mapTaxIncomeExpenseRows(sqlRows)
      return TaxIncomeExpenseAggregation(rows: rows, instrumentMap: instruments)
    }
  }

  static func mapTaxIncomeExpenseRows(_ rows: [Row]) -> [TaxIncomeExpenseRow] {
    var buckets: [TaxIncomeExpenseAggregationKey: Int64] = [:]
    for row in rows {
      guard let transactionDate: Date = row["transaction_date"] else { continue }
      guard let instrumentId: String = row["instrument_id"] else { continue }
      guard let typeRaw: String = row["type"] else { continue }
      guard let type = TransactionType(rawValue: typeRaw) else { continue }
      guard let qty: Int64 = row["qty"] else { continue }
      guard let categoryId: UUID = row["category_id"] else { continue }
      let key = TaxIncomeExpenseAggregationKey(
        day: australianTaxDayString(for: transactionDate),
        categoryId: categoryId,
        instrumentId: instrumentId,
        type: type,
        ownerIds: TaxOwnerIDListCoding.decode(row["owner_ids"]))
      buckets[key, default: 0] += qty
    }
    let mappedRows = buckets.map { key, qty in
      TaxIncomeExpenseRow(
        day: key.day,
        categoryId: key.categoryId,
        instrumentId: key.instrumentId,
        type: key.type,
        ownerIds: key.ownerIds,
        qty: qty)
    }
    return mappedRows.sorted(by: taxIncomeExpenseRowSort)
  }

  private static func taxIncomeExpenseRowSort(
    _ lhs: TaxIncomeExpenseRow,
    _ rhs: TaxIncomeExpenseRow
  ) -> Bool {
    if lhs.day != rhs.day { return lhs.day < rhs.day }
    if lhs.categoryId != rhs.categoryId {
      return lhs.categoryId.uuidString < rhs.categoryId.uuidString
    }
    if lhs.type.rawValue != rhs.type.rawValue {
      return lhs.type.rawValue < rhs.type.rawValue
    }
    if lhs.instrumentId != rhs.instrumentId { return lhs.instrumentId < rhs.instrumentId }
    return lhs.ownerIds.map(\.uuidString).joined(separator: ",")
      < rhs.ownerIds.map(\.uuidString).joined(separator: ",")
  }

  private struct TaxIncomeExpenseAggregationKey: Hashable {
    let day: String
    let categoryId: UUID
    let instrumentId: String
    let type: TransactionType
    let ownerIds: [UUID]
  }

  private static func australianTaxDayString(for date: Date) -> String {
    let components = AustralianTaxCalendar.calendar.dateComponents(
      [.year, .month, .day],
      from: date)
    guard
      let year = components.year,
      let month = components.month,
      let day = components.day
    else { return "" }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }

  private static func parseAustralianTaxDayString(_ day: String) -> Date? {
    let fields = day.split(separator: "-", omittingEmptySubsequences: false)
    guard fields.count == 3,
      let year = Int(fields[0]), let month = Int(fields[1]), let dayOfMonth = Int(fields[2])
    else { return nil }
    return Calendar.utc.date(
      from: DateComponents(year: year, month: month, day: dayOfMonth))
  }

  static func makeTaxIncomeExpenseRequest(
    dateInterval: Range<Date>,
    defaultTaxOwnerId: UUID
  ) -> SQLRequest<Row> {
    let lower = dateInterval.lowerBound
    let upper = dateInterval.upperBound
    let ownerIds = GRDBTaxOwnerSQL.effectiveOwnerIdsExpression(
      defaultTaxOwnerId: defaultTaxOwnerId)
    let literal: SQL = """
      SELECT t.date AS transaction_date,
             leg.category_id AS category_id,
             leg.instrument_id AS instrument_id,
             leg.type AS type,
             \(ownerIds) AS owner_ids,
             SUM(leg.quantity) AS qty
      FROM transaction_leg leg
      JOIN "transaction" t ON leg.transaction_id = t.id
      JOIN category c ON leg.category_id = c.id
      LEFT JOIN account a ON leg.account_id = a.id
      WHERE t.recur_period IS NULL
        AND t.date >= \(lower) AND t.date < \(upper)
        AND c.is_tax_reportable = 1
        AND leg.type IN ('income', 'expense')
      GROUP BY t.date, leg.category_id, leg.instrument_id, leg.type, owner_ids
      ORDER BY t.date ASC, leg.category_id ASC, leg.type ASC
      """
    return SQLRequest<Row>(literal: literal)
  }

  @concurrent
  static func assembleTaxIncomeExpenseSummaries(
    aggregation: TaxIncomeExpenseAggregation,
    targetInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    handlers: TaxIncomeExpenseHandlers
  ) async throws -> [TaxIncomeExpenseSummary] {
    let plan = planTaxIncomeExpense(
      aggregation: aggregation,
      targetInstrument: targetInstrument)
    for dayString in plan.unparseableDays {
      handlers.handleUnparseableDay(dayString)
    }
    let outcomes = try await conversionService.convertResultBatch(plan.requests)

    var buckets: [UUID: (income: InstrumentAmount, deductions: InstrumentAmount)] = [:]
    var unavailableOwnerIds: Set<UUID> = []
    for planned in plan.rows {
      do {
        let amount =
          try planned.convertedAmount
          ?? Self.convertedTaxIncomeExpenseAmount(
            outcome: conversionOutcome(for: planned, in: outcomes),
            targetInstrument: targetInstrument)
        Self.applyTaxIncomeExpenseAmount(
          amount,
          row: planned.row,
          targetInstrument: targetInstrument,
          buckets: &buckets)
      } catch {
        let context = TaxIncomeExpenseFailureContext(
          day: planned.row.day,
          instrumentId: planned.row.instrumentId,
          ownerIds: planned.row.ownerIds)
        handlers.handleConversionFailure(error, context)
        unavailableOwnerIds.formUnion(planned.row.ownerIds)
      }
    }
    unavailableOwnerIds.formUnion(
      plan.unavailableRows.flatMap { $0.ownerIds })
    return Set(buckets.keys).union(unavailableOwnerIds)
      .map { ownerId in
        let bucket =
          buckets[ownerId] ?? (
            income: .zero(instrument: targetInstrument),
            deductions: .zero(instrument: targetInstrument)
          )
        return TaxIncomeExpenseSummary(
          ownerId: ownerId,
          taxableIncome: bucket.income,
          deductibleExpenses: bucket.deductions,
          hasUnavailableData: unavailableOwnerIds.contains(ownerId))
      }
      .sorted { $0.ownerId.uuidString < $1.ownerId.uuidString }
  }

  static func convertedTaxIncomeExpenseAmount(
    outcome: BatchConversionOutcome,
    targetInstrument: Instrument
  ) throws -> InstrumentAmount {
    switch outcome {
    case .value(let converted):
      return converted
    case .knownZero:
      return .zero(instrument: targetInstrument)
    case .failure(let error):
      throw error
    }
  }

  private enum TaxIncomeExpensePlanError: Error {
    case missingConversionOutcome
  }

  static func conversionOutcome(
    for planned: PlannedTaxIncomeExpenseRow,
    in outcomes: [BatchConversionOutcome]
  ) throws -> BatchConversionOutcome {
    guard let requestIndex = planned.requestIndex, outcomes.indices.contains(requestIndex) else {
      throw TaxIncomeExpensePlanError.missingConversionOutcome
    }
    return outcomes[requestIndex]
  }

  private static func applyTaxIncomeExpenseAmount(
    _ amount: InstrumentAmount,
    row: TaxIncomeExpenseRow,
    targetInstrument: Instrument,
    buckets: inout [UUID: (income: InstrumentAmount, deductions: InstrumentAmount)]
  ) {
    guard !row.ownerIds.isEmpty else { return }
    for ownerId in row.ownerIds {
      var bucket =
        buckets[ownerId] ?? (
          income: .zero(instrument: targetInstrument),
          deductions: .zero(instrument: targetInstrument)
        )
      let allocated = InstrumentAmount(
        quantity: amount.quantity / Decimal(row.ownerIds.count),
        instrument: targetInstrument)
      switch row.type {
      case .income:
        bucket.income += allocated
      case .expense:
        bucket.deductions -= allocated
      case .transfer, .openingBalance, .trade:
        break
      }
      buckets[ownerId] = bucket
    }
  }

  struct PlannedTaxIncomeExpenseRow {
    let row: TaxIncomeExpenseRow
    let day: Date
    let instrument: Instrument
    let convertedAmount: InstrumentAmount?
    let requestIndex: Int?
  }

  struct TaxIncomeExpensePlan {
    let rows: [PlannedTaxIncomeExpenseRow]
    let requests: [BatchConversionRequest]
    let unparseableDays: [String]
    let unavailableRows: [TaxIncomeExpenseRow]
  }

  static func planTaxIncomeExpense(
    aggregation: TaxIncomeExpenseAggregation,
    targetInstrument: Instrument
  ) -> TaxIncomeExpensePlan {
    var rows: [PlannedTaxIncomeExpenseRow] = []
    var requests: [BatchConversionRequest] = []
    var unparseableDays: [String] = []
    var unavailableRows: [TaxIncomeExpenseRow] = []
    for row in aggregation.rows {
      guard let day = parseAustralianTaxDayString(row.day) else {
        unparseableDays.append(row.day)
        unavailableRows.append(row)
        continue
      }
      let instrument =
        aggregation.instrumentMap[row.instrumentId]
        ?? Instrument.fiat(code: row.instrumentId)
      if instrument == targetInstrument {
        rows.append(
          PlannedTaxIncomeExpenseRow(
            row: row,
            day: day,
            instrument: instrument,
            convertedAmount: InstrumentAmount(storageValue: row.qty, instrument: targetInstrument),
            requestIndex: nil))
      } else {
        let requestIndex = requests.count
        rows.append(
          PlannedTaxIncomeExpenseRow(
            row: row,
            day: day,
            instrument: instrument,
            convertedAmount: nil,
            requestIndex: requestIndex))
        requests.append(
          BatchConversionRequest(
            amount: InstrumentAmount(storageValue: row.qty, instrument: instrument),
            target: targetInstrument,
            date: day))
      }
    }
    return TaxIncomeExpensePlan(
      rows: rows,
      requests: requests,
      unparseableDays: unparseableDays,
      unavailableRows: unavailableRows)
  }
}
