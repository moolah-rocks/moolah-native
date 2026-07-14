import Foundation
import GRDB

extension GRDBAnalysisRepository {
  static func fetchTaxIncomeExpenseDetailAggregation(
    database: any DatabaseReader,
    instruments: [String: Instrument],
    dateInterval: Range<Date>,
    defaultTaxOwnerId: UUID,
    selection: TaxIncomeExpenseDetailSelection
  ) async throws -> TaxIncomeExpenseAggregation {
    try await database.read { database -> TaxIncomeExpenseAggregation in
      let request = makeTaxIncomeExpenseDetailRequest(
        dateInterval: dateInterval,
        defaultTaxOwnerId: defaultTaxOwnerId,
        ownerId: selection.ownerId,
        type: selection.type)
      let sqlRows = try Row.fetchAll(database, request)
      let rows = Self.mapTaxIncomeExpenseDetailRows(sqlRows)
      return TaxIncomeExpenseAggregation(rows: rows, instrumentMap: instruments)
    }
  }

  static func mapTaxIncomeExpenseDetailRows(_ rows: [Row]) -> [TaxIncomeExpenseRow] {
    rows.compactMap { row in
      guard let transactionId: UUID = row["transaction_id"] else { return nil }
      guard let transactionDate: Date = row["transaction_date"] else { return nil }
      guard let instrumentId: String = row["instrument_id"] else { return nil }
      guard let typeRaw: String = row["type"] else { return nil }
      guard let type = TransactionType(rawValue: typeRaw) else { return nil }
      guard let qty: Int64 = row["qty"] else { return nil }
      guard let categoryId: UUID = row["category_id"] else { return nil }
      return TaxIncomeExpenseRow(
        transactionId: transactionId,
        day: australianTaxDayString(for: transactionDate),
        categoryId: categoryId,
        instrumentId: instrumentId,
        type: type,
        ownerIds: TaxOwnerIDListCoding.decode(row["owner_ids"]),
        qty: qty)
    }
    .sorted(by: taxIncomeExpenseRowSort)
  }

  static func makeTaxIncomeExpenseDetailRequest(
    dateInterval: Range<Date>,
    defaultTaxOwnerId: UUID,
    ownerId: UUID?,
    type: TransactionType
  ) -> SQLRequest<Row> {
    let lower = dateInterval.lowerBound
    let upper = dateInterval.upperBound
    let ownerIds = GRDBTaxOwnerSQL.effectiveOwnerIdsExpression(
      defaultTaxOwnerId: defaultTaxOwnerId)
    let ownerFilter: SQL
    if let ownerId {
      let ownerIdString = ownerId.uuidString
      ownerFilter = """
        AND instr(
          ',' || \(ownerIds) || ',',
          ',' || \(ownerIdString) || ','
        ) > 0
        """
    } else {
      ownerFilter = ""
    }
    let typeRaw = type.rawValue
    let literal: SQL = """
      SELECT t.id AS transaction_id,
             t.date AS transaction_date,
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
        AND leg.type = \(typeRaw)
        \(ownerFilter)
      GROUP BY t.id, t.date, leg.category_id, leg.instrument_id, leg.type, owner_ids
      ORDER BY t.date ASC, t.id ASC, leg.category_id ASC, leg.type ASC
      """
    return SQLRequest<Row>(literal: literal)
  }
}

extension GRDBAnalysisRepository {
  @concurrent
  static func assembleTaxIncomeExpenseDetails(
    aggregation: TaxIncomeExpenseAggregation,
    targetInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    selection: TaxIncomeExpenseDetailSelection,
    handlers: TaxIncomeExpenseHandlers
  ) async throws -> [TaxIncomeExpenseDetailRow] {
    let plan = planTaxIncomeExpense(
      aggregation: aggregation,
      targetInstrument: targetInstrument)
    for dayString in plan.unparseableDays {
      handlers.handleUnparseableDay(dayString)
    }
    let outcomes = try await conversionService.convertResultBatch(plan.requests)

    let convertedRows = try convertedTaxIncomeExpenseDetailRows(
      plan: plan,
      outcomes: outcomes,
      targetInstrument: targetInstrument,
      selection: selection,
      handlers: handlers)
    let unavailableRows = try unavailableTaxIncomeExpenseDetailRows(
      plan: plan,
      aggregation: aggregation,
      targetInstrument: targetInstrument,
      selection: selection)
    return mergedTaxIncomeExpenseDetailRows(convertedRows + unavailableRows)
      .sorted(by: taxIncomeExpenseDetailRowSort)
  }

  private static func convertedTaxIncomeExpenseDetailRows(
    plan: TaxIncomeExpensePlan,
    outcomes: [BatchConversionOutcome],
    targetInstrument: Instrument,
    selection: TaxIncomeExpenseDetailSelection,
    handlers: TaxIncomeExpenseHandlers
  ) throws -> [TaxIncomeExpenseDetailRow] {
    var rows: [TaxIncomeExpenseDetailRow] = []
    for planned in plan.rows where planned.row.type == selection.type {
      var converted: InstrumentAmount?
      var hasUnavailableData = false
      do {
        converted =
          try planned.convertedAmount
          ?? Self.convertedTaxIncomeExpenseAmount(
            outcome: conversionOutcome(for: planned, in: outcomes),
            targetInstrument: targetInstrument)
      } catch {
        hasUnavailableData = true
        let context = TaxIncomeExpenseFailureContext(
          day: planned.row.day,
          instrumentId: planned.row.instrumentId,
          ownerIds: planned.row.ownerIds)
        handlers.handleConversionFailure(error, context)
      }
      rows.append(
        contentsOf: try detailRows(
          for: planned.row,
          context: TaxIncomeExpenseDetailRowContext(
            day: planned.day,
            dayLabel: TaxReportPresentation.dateLabel(planned.day),
            converted: converted,
            instrument: planned.instrument,
            targetInstrument: targetInstrument,
            selectedOwnerId: selection.ownerId,
            hasUnavailableData: hasUnavailableData)))
    }
    return rows
  }

  private static func unavailableTaxIncomeExpenseDetailRows(
    plan: TaxIncomeExpensePlan,
    aggregation: TaxIncomeExpenseAggregation,
    targetInstrument: Instrument,
    selection: TaxIncomeExpenseDetailSelection
  ) throws -> [TaxIncomeExpenseDetailRow] {
    var rows: [TaxIncomeExpenseDetailRow] = []
    for row in plan.unavailableRows where row.type == selection.type {
      rows.append(
        contentsOf: try detailRows(
          for: row,
          context: TaxIncomeExpenseDetailRowContext(
            day: nil,
            dayLabel: row.day,
            converted: nil,
            instrument: aggregation.instrumentMap[row.instrumentId]
              ?? Instrument.fiat(code: row.instrumentId),
            targetInstrument: targetInstrument,
            selectedOwnerId: selection.ownerId,
            hasUnavailableData: true)))
    }
    return rows
  }

  private static func mergedTaxIncomeExpenseDetailRows(
    _ rows: [TaxIncomeExpenseDetailRow]
  ) -> [TaxIncomeExpenseDetailRow] {
    var merged: [String: TaxIncomeExpenseDetailRow] = [:]
    for row in rows {
      guard let existing = merged[row.id] else {
        merged[row.id] = row
        continue
      }
      merged[row.id] = TaxIncomeExpenseDetailRow(
        transactionId: row.transactionId,
        ownerId: row.ownerId,
        categoryId: row.categoryId,
        instrument: row.instrument,
        day: row.day,
        dayLabel: row.dayLabel,
        amount: mergedAmount(existing.amount, row.amount),
        isSplitAcrossTaxOwners: existing.isSplitAcrossTaxOwners || row.isSplitAcrossTaxOwners,
        hasUnavailableData: existing.hasUnavailableData || row.hasUnavailableData)
    }
    return Array(merged.values)
  }

  private static func taxIncomeExpenseDetailRowSort(
    _ lhs: TaxIncomeExpenseDetailRow,
    _ rhs: TaxIncomeExpenseDetailRow
  ) -> Bool {
    if lhs.ownerId != rhs.ownerId { return lhs.ownerId.uuidString < rhs.ownerId.uuidString }
    if lhs.categoryId != rhs.categoryId {
      return lhs.categoryId.uuidString < rhs.categoryId.uuidString
    }
    if lhs.dayLabel != rhs.dayLabel { return lhs.dayLabel < rhs.dayLabel }
    return lhs.instrument.displayLabel < rhs.instrument.displayLabel
  }

  private static func mergedAmount(
    _ lhs: InstrumentAmount?,
    _ rhs: InstrumentAmount?
  ) -> InstrumentAmount? {
    guard let lhs, let rhs else { return nil }
    return lhs + rhs
  }

  private struct TaxIncomeExpenseDetailRowContext {
    let day: Date?
    let dayLabel: String
    let converted: InstrumentAmount?
    let instrument: Instrument
    let targetInstrument: Instrument
    let selectedOwnerId: UUID?
    let hasUnavailableData: Bool
  }

  private static func detailRows(
    for row: TaxIncomeExpenseRow,
    context: TaxIncomeExpenseDetailRowContext
  ) throws -> [TaxIncomeExpenseDetailRow] {
    guard let transactionId = row.transactionId else {
      throw TaxIncomeExpenseDetailAssemblyError.missingTransactionId
    }
    let matchingOwnerIds = row.ownerIds.filter {
      context.selectedOwnerId == nil || $0 == context.selectedOwnerId
    }
    guard !matchingOwnerIds.isEmpty else { return [] }
    let signedAmount = context.converted.map { converted in
      let allocated = InstrumentAmount(
        quantity: converted.quantity / Decimal(row.ownerIds.count),
        instrument: context.targetInstrument)
      return row.type == .expense
        ? InstrumentAmount.zero(instrument: context.targetInstrument) - allocated : allocated
    }
    return matchingOwnerIds.map { ownerId in
      TaxIncomeExpenseDetailRow(
        transactionId: transactionId,
        ownerId: ownerId,
        categoryId: row.categoryId,
        instrument: context.instrument,
        day: context.day,
        dayLabel: context.dayLabel,
        amount: signedAmount,
        isSplitAcrossTaxOwners: row.ownerIds.count > 1,
        hasUnavailableData: context.hasUnavailableData)
    }
  }

  private enum TaxIncomeExpenseDetailAssemblyError: LocalizedError {
    case missingTransactionId

    var errorDescription: String? {
      "Tax transaction detail aggregation returned a row without a transaction ID."
    }
  }
}
