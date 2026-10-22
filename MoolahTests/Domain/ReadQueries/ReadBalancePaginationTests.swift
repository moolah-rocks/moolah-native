import Foundation
import GRDB
import Testing

@testable import Moolah

struct ReadBalancePaginationTests {
  @Test
  func allAccountsCanBeReadInPagesWithoutManualIDBatches() async throws {
    let (backend, database) = try TestBackend.create()
    try await database.write { database in
      for index in 0..<501 {
        let id = try #require(
          UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))
        )
        try AccountRow(
          domain: Account(
            id: id,
            name: "Fixture \(index)",
            type: .bank,
            instrument: .defaultTestInstrument
          )
        ).insert(database)
      }
    }
    let repository = try #require(backend.readQueries)
    var page = try ReadPageRequest(limit: 100)
    var found: [UUID] = []
    for _ in 0..<6 {
      let result = try await repository.balanceInputs(accountIDs: [], page: page)
      #expect(result.items.count <= 100)
      found += result.items.map(\.accountID)
      guard let key = result.nextKey else { break }
      page = try ReadPageRequest(limit: 100, after: key, revision: result.revision)
    }
    #expect(found.count == 501)
    #expect(Set(found).count == 501)
    #expect(found.map(\.uuidString) == found.map(\.uuidString).sorted())
  }

  @Test
  func selectedAccountIDsAreValidatedIndependentlyOfTheCurrentPage() async throws {
    let (backend, _) = try TestBackend.create()
    let first = Account(name: "First", type: .bank, instrument: .defaultTestInstrument)
    let second = Account(name: "Second", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(first)
    _ = try await backend.accounts.create(second)
    let repository = try #require(backend.readQueries)
    let ids: Set<UUID> = [first.id, second.id]
    let result = try await repository.balanceInputs(
      accountIDs: ids,
      page: ReadPageRequest(limit: 1)
    )
    #expect(result.items.count == 1)
    #expect(result.hasMore)
    await #expect(throws: ReadQueryError.notFound) {
      try await repository.balanceInputs(
        accountIDs: [first.id, UUID()],
        page: ReadPageRequest(limit: 1)
      )
    }
  }
}

extension ReadBalancePaginationTests {
  @Test
  func theNextPagesDenseAccountCannotBlockTheCurrentPage() async throws {
    let (backend, database) = try TestBackend.create()
    let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    for (id, name) in [(firstID, "First"), (secondID, "Dense sentinel")] {
      _ = try await backend.accounts.create(
        Account(id: id, name: name, type: .bank, instrument: .defaultTestInstrument)
      )
    }
    let transaction = Transaction(date: Date(timeIntervalSince1970: 1_700_000_000), legs: [])
    _ = try await backend.transactions.create(transaction)
    try await seedDenseAccount(database, accountID: secondID, transactionID: transaction.id)
    let repository = try #require(backend.readQueries)
    let first = try await repository.balanceInputs(accountIDs: [], page: ReadPageRequest(limit: 1))
    #expect(first.items.map(\.accountID) == [firstID])
    #expect(first.items.first?.positions.isEmpty == true)
    #expect(first.hasMore)
    let next = try #require(first.nextKey)
    await #expect(
      throws: ReadLimitError(operation: .balances, unit: .transactionLegs, maximum: 250_000)
    ) {
      try await repository.balanceInputs(
        accountIDs: [],
        page: ReadPageRequest(limit: 1, after: next, revision: first.revision)
      )
    }
  }

  private func seedDenseAccount(_ database: DatabaseQueue, accountID: UUID, transactionID: UUID)
    async throws
  {
    try await database.write { database in
      try database.execute(
        sql: """
          WITH RECURSIVE sequence(n) AS (
            SELECT 1 UNION ALL SELECT n + 1 FROM sequence WHERE n < 250001
          )
          INSERT INTO transaction_leg
            (id, record_name, transaction_id, account_id, instrument_id, quantity, type, sort_order)
          SELECT CAST(printf('%016x', n) AS BLOB), 'sentinel-' || n, ?, ?, ?, 100000000, 'income', n
          FROM sequence
          """,
        arguments: [transactionID, accountID, Instrument.defaultTestInstrument.id]
      )
    }
  }
}
