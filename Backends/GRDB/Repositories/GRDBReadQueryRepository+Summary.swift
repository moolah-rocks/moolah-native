import Foundation
import GRDB

extension GRDBReadQueryRepository {
  func summaryInputs(range: ReadDateRange, includeNetWorth: Bool) async throws
    -> ReadSummarySnapshot
  {
    let instruments = try await instrumentResolver.instrumentMap()
    let fingerprint = try instrumentFingerprint(instruments)
    return try await database.read { database in
      let revision = try self.revision(in: database, fingerprint: fingerprint)
      let netWorth: ReadNetWorthInput =
        includeNetWorth
        ? .requested(try self.summaryBalances(database: database, instruments: instruments))
        : .omitted
      let flows = try self.summaryFlows(range: range, database: database, instruments: instruments)
      return ReadSummarySnapshot(
        flows: flows,
        netWorth: netWorth,
        revision: revision,
        queriedAt: self.now()
      )
    }
  }
  private func summaryBalances(database: Database, instruments: [String: Instrument]) throws
    -> [ReadBalanceInput]
  {
    let accounts = try AccountRow.order(AccountRow.Columns.id.asc).limit(501).fetchAll(database)
    guard accounts.count <= 500 else { throw ReadQueryError.resultTooLarge }
    let positions = try self.accountPositionAmounts(
      ids: Set(accounts.map(\.id)),
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
    SELECT txn.date, leg.category_id, leg.type, leg.instrument_id, leg.quantity
    FROM "transaction" AS txn
    CROSS JOIN transaction_leg AS leg ON leg.transaction_id = txn.id
    WHERE txn.recur_period IS NULL
      AND txn.date >= :from AND txn.date < :through
      AND leg.type IN ('income', 'expense')
      AND (leg.category_id IS NOT NULL OR leg.account_id IS NOT NULL)
    LIMIT 10001
    """

  /// Matches Reports category balances: income/expense only, across account types, excluding
  /// account-less uncategorized reserve movements. Transfer/trade/opening legs never enter it.
  /// LIMIT is applied before materialization; 10,001 signals an explicit calculation limit.
  private func summaryFlows(
    range: ReadDateRange,
    database: Database,
    instruments: [String: Instrument]
  ) throws -> [ReadSummaryFlow] {
    let request = SQLRequest<Row>(
      sql: Self.summaryFlowSQL,
      arguments: [
        "from": range.interval.lowerBound, "through": range.interval.upperBound,
      ]
    )
    let rows = try Row.fetchAll(database, request)
    guard rows.count <= 10_000 else { throw ReadQueryError.resultTooLarge }
    return try rows.map { row in
      let rawType: String = row["type"]
      guard let type = TransactionType(rawValue: rawType), type == .income || type == .expense
      else {
        throw ReadQueryError.profileUnavailable
      }
      let instrumentID: String = row["instrument_id"]
      let quantity: Int64 = row["quantity"]
      return ReadSummaryFlow(
        date: row["date"],
        categoryID: row["category_id"],
        type: type,
        amount: InstrumentAmount(
          storageValue: quantity,
          instrument: try instrument(instrumentID, in: instruments)
        )
      )
    }
  }
}
