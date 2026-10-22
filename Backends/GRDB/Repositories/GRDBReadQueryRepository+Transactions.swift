import Foundation
import GRDB

extension GRDBReadQueryRepository {
  func transactions(
    search: ReadTransactionSearch,
    page: ReadPageRequest,
    includeNotes: Bool
  ) async throws -> ReadPage<ReadTransactionDTO> {
    guard page.after == nil || page.after?.date != nil else { throw ReadQueryError.invalidFilter }
    let filter = search.transactionFilter
    let instruments = try await instrumentResolver.instrumentMap()
    let fingerprint = try self.instrumentFingerprint(instruments)
    return try await database.read { database in
      let revision = try self.revision(in: database, fingerprint: fingerprint, page: page)
      try self.validateFilterEntities(filter, in: database)
      let request = Self.transactionRequest(filter: filter, after: page.after)
      let rows = try request.limit(page.limit + 1).fetchAll(database)
      let selected = Array(rows.prefix(page.limit))
      let items = try self.transactionDTOs(
        rows: selected,
        database: database,
        instruments: instruments,
        includeNotes: includeNotes,
        filter: filter
      )
      return ReadPage(
        items: items,
        revision: revision,
        queriedAt: self.now(),
        nextKey: rows.count > page.limit
          ? selected.last.map {
            ReadPageKey(
              id: $0.id,
              date: $0.date
            )
          } : nil
      )
    }
  }

  func transaction(
    id: UUID,
    includeNotes: Bool
  ) async throws -> ReadPage<ReadTransactionDTO> {
    let instruments = try await instrumentResolver.instrumentMap()
    let fingerprint = try self.instrumentFingerprint(instruments)
    return try await database.read { database in
      let revision = try self.revision(in: database, fingerprint: fingerprint)
      guard let row = try TransactionRow.filter(TransactionRow.Columns.id == id).fetchOne(database)
      else { throw ReadQueryError.notFound }
      let items = try self.transactionDTOs(
        rows: [row],
        database: database,
        instruments: instruments,
        includeNotes: includeNotes,
        filter: TransactionFilter()
      )
      return ReadPage(items: items, revision: revision, queriedAt: self.now(), nextKey: nil)
    }
  }

  /// This request is shared with query-plan tests. Filters match one leg, then return full parents.
  static func transactionRequest(
    filter: TransactionFilter,
    after: ReadPageKey?
  ) -> QueryInterfaceRequest<TransactionRow> {
    var request = GRDBTransactionRepository.applyingHeaderFilters(
      to: TransactionRow.all(),
      filter: filter
    )
    var accountIDs = filter.accountIds
    if let id = filter.accountId { accountIDs.insert(id) }
    var legs = TransactionLegRow.all()
    if !accountIDs.isEmpty {
      legs = legs.filter(accountIDs.contains(TransactionLegRow.Columns.accountId))
    }
    if !filter.categoryIds.isEmpty {
      legs = legs.filter(filter.categoryIds.contains(TransactionLegRow.Columns.categoryId))
    }
    if !accountIDs.isEmpty || !filter.categoryIds.isEmpty {
      let matchingIDs = legs.select(TransactionLegRow.Columns.transactionId, as: UUID.self)
      request = request.filter(matchingIDs.contains(TransactionRow.Columns.id))
    }
    if let after, let date = after.date {
      let columns = TransactionRow.Columns.self
      request = request.filter(
        columns.date < date || (columns.date == date && columns.id > after.id)
      )
    }
    return request.order(TransactionRow.Columns.date.desc, TransactionRow.Columns.id.asc)
  }
}

extension GRDBReadQueryRepository {
  private func transactionDTOs(
    rows: [TransactionRow],
    database: Database,
    instruments: [String: Instrument],
    includeNotes: Bool,
    filter: TransactionFilter
  ) throws -> [ReadTransactionDTO] {
    let ids = Set(rows.map(\.id))
    guard !ids.isEmpty else { return [] }
    let probe: SQLRequest<Int> = """
      SELECT COUNT(*) FROM (
        SELECT 1 FROM transaction_leg WHERE transaction_id IN \(ids) LIMIT 10001
      )
      """
    let legCount = try Int.fetchOne(database, probe) ?? 0
    guard legCount <= 10_000 else {
      throw ReadLimitError(operation: .transactionDetails, unit: .transactionLegs, maximum: 10_000)
    }
    let instrumentIDs = try String.fetchSet(
      database,
      TransactionLegRow.filter(ids.contains(TransactionLegRow.Columns.transactionId))
        .select(TransactionLegRow.Columns.instrumentId).distinct()
    )
    for id in instrumentIDs { _ = try instrument(id, in: instruments) }
    let legs = try GRDBTransactionRepository.fetchLegs(
      database: database,
      transactionIds: rows.map(\.id),
      instruments: instruments
    )
    return try rows.map { row in
      let transaction = try row.toDomain(legs: legs[row.id] ?? [])
      return ReadTransactionDTO(transaction, includeNotes: includeNotes, filter: filter)
    }
  }

  private func validateFilterEntities(_ filter: TransactionFilter, in database: Database) throws {
    var accounts = filter.accountIds
    if let id = filter.accountId { accounts.insert(id) }
    if !accounts.isEmpty {
      let count = try AccountRow.filter(accounts.contains(AccountRow.Columns.id)).fetchCount(
        database
      )
      guard count == accounts.count else { throw ReadQueryError.notFound }
    }
    if !filter.categoryIds.isEmpty {
      let count = try CategoryRow.filter(filter.categoryIds.contains(CategoryRow.Columns.id))
        .fetchCount(database)
      guard count == filter.categoryIds.count else { throw ReadQueryError.notFound }
    }
  }
}
