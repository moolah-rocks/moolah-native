import Foundation
import GRDB

extension GRDBAnalysisRepository {
  struct TaxIncomeExpenseRow: Sendable {
    let day: String
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
      let rows = sqlRows.compactMap(Self.mapTaxIncomeExpenseRow(_:))
      return TaxIncomeExpenseAggregation(rows: rows, instrumentMap: instruments)
    }
  }

  static func mapTaxIncomeExpenseRow(_ row: Row) -> TaxIncomeExpenseRow? {
    guard let day: String = row["day"] else { return nil }
    guard let instrumentId: String = row["instrument_id"] else { return nil }
    guard let typeRaw: String = row["type"] else { return nil }
    guard let type = TransactionType(rawValue: typeRaw) else { return nil }
    guard let qty: Int64 = row["qty"] else { return nil }
    return TaxIncomeExpenseRow(
      day: day,
      instrumentId: instrumentId,
      type: type,
      ownerIds: TaxOwnerIDListCoding.decode(row["owner_ids"]),
      qty: qty)
  }

  static func makeTaxIncomeExpenseRequest(
    dateInterval: Range<Date>,
    defaultTaxOwnerId: UUID
  ) -> SQLRequest<Row> {
    let lower = dateInterval.lowerBound
    let upper = dateInterval.upperBound
    let defaultOwner = defaultTaxOwnerId.uuidString
    let localDay = "DATE(t.date)"
    let literal: SQL = """
      SELECT \(sql: localDay) AS day,
             leg.instrument_id AS instrument_id,
             leg.type AS type,
             COALESCE(
               NULLIF(c.tax_owner_ids_encoded, ''),
               NULLIF(a.tax_owner_ids_encoded, ''),
               \(defaultOwner)
             ) AS owner_ids,
             SUM(leg.quantity) AS qty
      FROM transaction_leg leg
      JOIN "transaction" t ON leg.transaction_id = t.id
      JOIN category c ON leg.category_id = c.id
      LEFT JOIN account a ON leg.account_id = a.id
      WHERE t.recur_period IS NULL
        AND t.date >= \(lower) AND t.date < \(upper)
        AND c.is_tax_reportable = 1
        AND leg.type IN ('income', 'expense')
      GROUP BY \(sql: localDay), leg.instrument_id, leg.type, owner_ids
      ORDER BY \(sql: localDay) ASC, leg.type ASC
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
    for (planned, outcome) in zip(plan.rows, outcomes) {
      do {
        let amount = try Self.convertedTaxIncomeExpenseAmount(
          outcome: outcome,
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

  private static func convertedTaxIncomeExpenseAmount(
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

  private struct TaxIncomeExpensePlan {
    let rows: [(row: TaxIncomeExpenseRow, day: Date)]
    let requests: [BatchConversionRequest]
    let unparseableDays: [String]
    let unavailableRows: [TaxIncomeExpenseRow]
  }

  private static func planTaxIncomeExpense(
    aggregation: TaxIncomeExpenseAggregation,
    targetInstrument: Instrument
  ) -> TaxIncomeExpensePlan {
    var rows: [(row: TaxIncomeExpenseRow, day: Date)] = []
    var requests: [BatchConversionRequest] = []
    var unparseableDays: [String] = []
    var unavailableRows: [TaxIncomeExpenseRow] = []
    for row in aggregation.rows {
      guard let day = parseDayString(row.day) else {
        unparseableDays.append(row.day)
        unavailableRows.append(row)
        continue
      }
      let instrument =
        aggregation.instrumentMap[row.instrumentId]
        ?? Instrument.fiat(code: row.instrumentId)
      rows.append((row: row, day: day))
      requests.append(
        BatchConversionRequest(
          amount: InstrumentAmount(storageValue: row.qty, instrument: instrument),
          target: targetInstrument,
          date: day))
    }
    return TaxIncomeExpensePlan(
      rows: rows,
      requests: requests,
      unparseableDays: unparseableDays,
      unavailableRows: unavailableRows)
  }
}
