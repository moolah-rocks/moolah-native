import Foundation
import GRDB

extension GRDBReadQueryRepository {
  func summaryInputs(query: ReadSummaryQuery) async throws -> ReadSummarySnapshot {
    let instruments = try await instrumentResolver.instrumentMap()
    let fingerprint = try instrumentFingerprint(instruments)
    return try await database.read { database in
      let revision = try self.revision(in: database, fingerprint: fingerprint)
      let netWorth: ReadNetWorthInput =
        query.includeNetWorth
        ? .requested(try self.summaryBalances(database: database, instruments: instruments))
        : .omitted
      let flows = try self.summaryFlows(
        range: query.range,
        groupByCategory: query.grouping.includesCategories,
        database: database,
        instruments: instruments
      )
      return ReadSummarySnapshot(
        flows: flows,
        netWorth: netWorth,
        categories: query.grouping.includesCategories
          ? try self.summaryCategories(
            flows: flows,
            includeParents: query.includeParentTotals,
            database: database
          ) : [],
        timeZone: query.range.timeZone,
        revision: revision,
        queriedAt: self.now()
      )
    }
  }
  private func summaryBalances(database: Database, instruments: [String: Instrument]) throws
    -> [ReadBalanceInput]
  {
    let accounts = try AccountRow.order(AccountRow.Columns.id.asc).limit(501).fetchAll(database)
    guard accounts.count <= 500 else {
      throw ReadLimitError(operation: .netWorth, unit: .accounts, maximum: 500)
    }
    let positions = try self.positionAmounts(
      ids: Set(accounts.map(\.id)),
      query: .netWorth,
      database: database,
      instruments: instruments
    )
    return accounts.map {
      ReadBalanceInput(accountID: $0.id, positions: positions[$0.id] ?? [], accountName: $0.name)
    }
  }

  /// The date-bounded outer loop avoids scanning lifetime leg history for a narrow query.
  /// There is no sorting/materialization before LIMIT; grouping order is deterministic in the domain fold.
  static let summaryFlowSQL = """
    SELECT txn.date, txn.recur_period, leg.category_id, leg.account_id,
      leg.type, leg.instrument_id, leg.quantity
    FROM "transaction" AS txn
    CROSS JOIN transaction_leg AS leg ON leg.transaction_id = txn.id
    WHERE txn.date >= :from AND txn.date < :through
    LIMIT :maximum
    """

  /// Count every joined leg before applying Reports exclusions. Fold within this read
  /// snapshot; no raw history or GRDB objects escape to the conversion service.
  private func summaryFlows(
    range: ReadDateRange,
    groupByCategory: Bool,
    database: Database,
    instruments: [String: Instrument]
  ) throws -> [ReadSummaryFlow] {
    let request = SQLRequest<Row>(
      sql: Self.summaryFlowSQL,
      arguments: [
        "from": range.interval.lowerBound, "through": range.interval.upperBound,
        "maximum": ReadAggregationBudget.maximumLegs + 1,
      ]
    )
    let cursor = try Row.fetchCursor(database, request)
    var budget = ReadAggregationBudget(operation: .summaryFlows)
    var totals: [ReadFlowKey: ReadSummaryFlow] = [:]
    var previousDates: ReadFlowDates?
    var calendar = Calendar.utc
    calendar.timeZone = range.timeZone
    while let row = try cursor.next() {
      try budget.consume()
      guard row["recur_period"] == nil as String?,
        let type = TransactionType(rawValue: row["type"]), type == .income || type == .expense,
        (row["category_id"] as UUID?) != nil || (row["account_id"] as UUID?) != nil
      else { continue }
      let date: Date = row["date"]
      if previousDates?.instant != date {
        previousDates = try ReadFlowDates(date: date, calendar: calendar)
      }
      guard let dates = previousDates else { throw ReadCalculationError.invalidResult }
      let key = ReadFlowKey(
        day: dates.utcDay,
        month: dates.localMonth,
        categoryID: groupByCategory ? row["category_id"] : nil,
        type: type,
        instrumentID: row["instrument_id"]
      )
      let instrument = try self.instrument(key.instrumentID, in: instruments)
      let quantity = try ReadAggregationBudget.adding(
        row["quantity"],
        to: totals[key]?.amount.quantity ?? 0
      )
      totals[key] = ReadSummaryFlow(
        date: date,
        categoryID: key.categoryID,
        type: type,
        amount: InstrumentAmount(quantity: quantity, instrument: instrument)
      )
      try budget.validateGroupCount(totals.count)
    }
    try Task.checkCancellation()
    return totals.keys.sorted().compactMap { totals[$0] }
  }
}

private struct ReadFlowKey: Hashable, Sendable {
  let day: Date
  let month: Date
  let categoryID: UUID?
  let type: TransactionType
  let instrumentID: String
}

extension ReadFlowKey: Comparable {
  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.day != rhs.day { return lhs.day < rhs.day }
    if lhs.month != rhs.month { return lhs.month < rhs.month }
    if lhs.categoryID != rhs.categoryID {
      return (lhs.categoryID?.uuidString ?? "") < (rhs.categoryID?.uuidString ?? "")
    }
    if lhs.type != rhs.type { return lhs.type.rawValue < rhs.type.rawValue }
    return lhs.instrumentID < rhs.instrumentID
  }
}

/// One-entry date cache avoids repeating calendar work for every leg of a dense transaction.
private struct ReadFlowDates {
  let instant: Date
  let utcDay: Date
  let localMonth: Date

  init(date: Date, calendar: Calendar) throws {
    guard let month = calendar.dateInterval(of: .month, for: date)?.start else {
      throw ReadCalculationError.invalidResult
    }
    instant = date
    utcDay = Calendar.utc.startOfDay(for: date)
    localMonth = month
  }
}
