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
      nextKey: input.nextKey
    )
  }

  func balanceInputs(accountIDs: Set<UUID>, page: ReadPageRequest) async throws -> ReadPage<
    ReadBalanceInput
  > {
    guard accountIDs.count <= 500 else { throw ReadQueryError.invalidFilter }
    let instruments = try await instrumentResolver.instrumentMap()
    let fingerprint = try self.instrumentFingerprint(instruments)
    return try await database.read { database in
      let revision = try self.revision(in: database, fingerprint: fingerprint, page: page)
      let request = Self.balanceAccountRequest(accountIDs: accountIDs, after: page.after)
      if !accountIDs.isEmpty {
        guard
          try Self.balanceAccountCountRequest(accountIDs: accountIDs).fetchOne(database)
            == accountIDs.count
        else {
          throw ReadQueryError.notFound
        }
      }
      let rows = try request.limit(page.limit + 1).fetchAll(database)
      let selected = Array(rows.prefix(page.limit))
      let ids = Set(selected.map(\.id))
      let positions = try self.accountPositionAmounts(
        ids: ids,
        database: database,
        instruments: instruments
      )
      return ReadPage(
        items: selected.map {
          ReadBalanceInput(
            accountID: $0.id,
            positions: positions[$0.id] ?? [],
            accountName: $0.name
          )
        },
        revision: revision,
        queriedAt: self.now(),
        nextKey: rows.count > page.limit ? selected.last.map { ReadPageKey(id: $0.id) } : nil
      )
    }
  }

  static func balanceAccountCountRequest(accountIDs: Set<UUID>) -> QueryInterfaceRequest<Int> {
    balanceAccountRequest(accountIDs: accountIDs, after: nil)
      .select(count(AccountRow.Columns.id), as: Int.self)
  }

  static func balanceAccountRequest(
    accountIDs: Set<UUID>,
    after: ReadPageKey?
  ) -> QueryInterfaceRequest<AccountRow> {
    var request = AccountRow.order(AccountRow.Columns.id.asc)
    if !accountIDs.isEmpty { request = request.filter(accountIDs.contains(AccountRow.Columns.id)) }
    if let after { request = request.filter(AccountRow.Columns.id > after.id) }
    return request
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
