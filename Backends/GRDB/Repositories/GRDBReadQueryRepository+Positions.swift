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
      let positions = try self.positionAmounts(
        ids: ids,
        query: .balances,
        database: database,
        instruments: instruments
      )
      return ReadPage(
        items: selected.map { self.balanceInput($0, positions: positions) },
        revision: revision,
        queriedAt: self.now(),
        nextKey: rows.count > page.limit ? selected.last.map { ReadPageKey(id: $0.id) } : nil
      )
    }
  }

  private func balanceInput(_ row: AccountRow, positions: [UUID: [InstrumentAmount]])
    -> ReadBalanceInput
  {
    ReadBalanceInput(accountID: row.id, positions: positions[row.id] ?? [], accountName: row.name)
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

  func earmarkPositions(
    ids: Set<UUID>,
    database: Database,
    instruments: [String: Instrument]
  ) throws -> [UUID: [ReadQuantityDTO]] {
    try positionAmounts(ids: ids, query: .earmarks, database: database, instruments: instruments)
      .mapValues { $0.map { ReadQuantityDTO(quantity: $0.quantity, instrument: $0.instrument) } }
  }

  /// Fixed selective queries stream raw legs before any filtering, grouping or sorting.
  static func positionRequest(ids: Set<UUID>, query: ReadPositionQuery) -> SQLRequest<Row> {
    switch query {
    case .balances, .netWorth:
      """
      SELECT leg.account_id AS owner_id, leg.instrument_id, leg.quantity, txn.recur_period
      FROM transaction_leg AS leg
      CROSS JOIN "transaction" AS txn ON txn.id = leg.transaction_id
      WHERE leg.account_id IN \(ids) LIMIT \(ReadAggregationBudget.maximumLegs + 1)
      """
    case .earmarks:
      """
      SELECT leg.earmark_id AS owner_id, leg.instrument_id, leg.quantity, txn.recur_period
      FROM transaction_leg AS leg
      CROSS JOIN "transaction" AS txn ON txn.id = leg.transaction_id
      WHERE leg.earmark_id IN \(ids) LIMIT \(ReadAggregationBudget.maximumLegs + 1)
      """
    }
  }

  func positionAmounts(
    ids: Set<UUID>,
    query: ReadPositionQuery,
    database: Database,
    instruments: [String: Instrument]
  ) throws -> [UUID: [InstrumentAmount]] {
    guard !ids.isEmpty else { return [:] }
    let cursor = try Row.fetchCursor(database, Self.positionRequest(ids: ids, query: query))
    var budget = ReadAggregationBudget(operation: query.operation)
    var totals: [ReadPositionKey: Decimal] = [:]
    while let row = try cursor.next() {
      try budget.consume()
      guard row["recur_period"] == nil as String? else { continue }
      let key = ReadPositionKey(ownerID: row["owner_id"], instrumentID: row["instrument_id"])
      totals[key] = try ReadAggregationBudget.adding(row["quantity"], to: totals[key] ?? 0)
      // Keys remain present even when they cancel to zero, so this cap is monotonic.
      try budget.validateGroupCount(totals.count)
    }
    try Task.checkCancellation()
    var result: [UUID: [InstrumentAmount]] = [:]
    for key in totals.keys.sorted() {
      guard let quantity = totals[key], quantity != 0 else { continue }
      result[key.ownerID, default: []].append(
        InstrumentAmount(
          quantity: quantity,
          instrument: try instrument(key.instrumentID, in: instruments)
        )
      )
    }
    return result
  }
}

enum ReadPositionQuery: Sendable {
  case balances
  case earmarks
  case netWorth

  var operation: ReadLimitOperation {
    switch self {
    case .balances: .balances
    case .earmarks: .earmarks
    case .netWorth: .netWorth
    }
  }
}

private struct ReadPositionKey: Hashable, Sendable {
  let ownerID: UUID
  let instrumentID: String
}

extension ReadPositionKey: Comparable {
  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.ownerID != rhs.ownerID { return lhs.ownerID.uuidString < rhs.ownerID.uuidString }
    return lhs.instrumentID < rhs.instrumentID
  }
}
