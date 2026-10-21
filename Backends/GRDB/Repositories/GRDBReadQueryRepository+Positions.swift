import Foundation
import GRDB

extension GRDBReadQueryRepository {
  func balances(accountIDs: Set<UUID>) async throws -> ReadPage<ReadBalanceDTO> {
    let input = try await balanceInputs(accountIDs: accountIDs)
    return ReadPage(
      items: input.items.map { row in
        ReadBalanceDTO(
          accountID: row.accountID,
          positions: row.positions.map {
            ReadQuantityDTO(quantity: $0.quantity, instrument: $0.instrument)
          }
        )
      },
      revision: input.revision,
      queriedAt: input.queriedAt,
      nextKey: nil
    )
  }

  func balanceInputs(accountIDs: Set<UUID>) async throws -> ReadPage<ReadBalanceInput> {
    guard accountIDs.count <= 500 else { throw ReadQueryError.invalidFilter }
    let instruments = try await instrumentResolver.instrumentMap()
    let fingerprint = try self.instrumentFingerprint(instruments)
    return try await database.read { database in
      let revision = try self.revision(in: database, fingerprint: fingerprint)
      var request = AccountRow.order(AccountRow.Columns.id.asc)
      if !accountIDs.isEmpty {
        request = request.filter(accountIDs.contains(AccountRow.Columns.id))
      }
      let rows = try request.limit(501).fetchAll(database)
      guard rows.count <= 500 else { throw ReadQueryError.resultTooLarge }
      let ids = Set(rows.map(\.id))
      guard accountIDs.isSubset(of: ids) else { throw ReadQueryError.notFound }
      let positions = try self.accountPositionAmounts(
        ids: ids,
        database: database,
        instruments: instruments
      )
      return ReadPage(
        items: rows.map {
          ReadBalanceInput(
            accountID: $0.id,
            positions: positions[$0.id] ?? []
          )
        },
        revision: revision,
        queriedAt: self.now(),
        nextKey: nil
      )
    }
  }

  func accountPositionAmounts(
    ids: Set<UUID>,
    database: Database,
    instruments: [String: Instrument]
  ) throws -> [UUID: [InstrumentAmount]] {
    guard !ids.isEmpty else { return [:] }
    let probe: SQLRequest<Int> = """
      SELECT COUNT(*) FROM (
        SELECT 1 FROM transaction_leg AS leg
        JOIN "transaction" AS txn ON txn.id = leg.transaction_id
        WHERE txn.recur_period IS NULL AND leg.account_id IN \(ids) LIMIT 10001
      )
      """
    guard try Int.fetchOne(database, probe) ?? 0 <= 10_000 else {
      throw ReadQueryError.resultTooLarge
    }
    let request: SQLRequest<Row> = """
      SELECT leg.account_id AS owner_id, leg.instrument_id, SUM(leg.quantity) AS quantity
      FROM transaction_leg AS leg
      JOIN "transaction" AS txn ON txn.id = leg.transaction_id
      WHERE txn.recur_period IS NULL AND leg.account_id IN \(ids)
      GROUP BY leg.account_id, leg.instrument_id
      HAVING SUM(leg.quantity) <> 0
      ORDER BY leg.account_id, leg.instrument_id
      """
    return try positionAmounts(rows: Row.fetchAll(database, request), instruments: instruments)
  }

  func earmarkPositions(
    ids: Set<UUID>,
    database: Database,
    instruments: [String: Instrument]
  ) throws -> [UUID: [ReadQuantityDTO]] {
    guard !ids.isEmpty else { return [:] }
    let probe: SQLRequest<Int> = """
      SELECT COUNT(*) FROM (
        SELECT 1 FROM transaction_leg AS leg
        JOIN "transaction" AS txn ON txn.id = leg.transaction_id
        WHERE txn.recur_period IS NULL AND leg.earmark_id IN \(ids) LIMIT 10001
      )
      """
    guard try Int.fetchOne(database, probe) ?? 0 <= 10_000 else {
      throw ReadQueryError.resultTooLarge
    }
    let request: SQLRequest<Row> = """
      SELECT leg.earmark_id AS owner_id, leg.instrument_id, SUM(leg.quantity) AS quantity
      FROM transaction_leg AS leg
      JOIN "transaction" AS txn ON txn.id = leg.transaction_id
      WHERE txn.recur_period IS NULL AND leg.earmark_id IN \(ids)
      GROUP BY leg.earmark_id, leg.instrument_id
      HAVING SUM(leg.quantity) <> 0
      ORDER BY leg.earmark_id, leg.instrument_id
      """
    return try positions(rows: Row.fetchAll(database, request), instruments: instruments)
  }

  private func positions(
    rows: [Row],
    instruments: [String: Instrument]
  ) throws -> [UUID: [ReadQuantityDTO]] {
    try positionAmounts(rows: rows, instruments: instruments).mapValues { amounts in
      amounts.map { ReadQuantityDTO(quantity: $0.quantity, instrument: $0.instrument) }
    }
  }

  private func positionAmounts(
    rows: [Row],
    instruments: [String: Instrument]
  ) throws -> [UUID: [InstrumentAmount]] {
    guard rows.count <= 10_000 else { throw ReadQueryError.resultTooLarge }
    var result: [UUID: [InstrumentAmount]] = [:]
    for row in rows {
      let ownerID: UUID = row["owner_id"]
      let instrumentID: String = row["instrument_id"]
      let quantity: Int64 = row["quantity"]
      let instrument = try instrument(instrumentID, in: instruments)
      let amount = InstrumentAmount(storageValue: quantity, instrument: instrument)
      result[ownerID, default: []].append(amount)
    }
    return result
  }
}
