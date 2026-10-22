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
  }

  private func seedDenseAccount(_ database: DatabaseQueue, accountID: UUID, transactionID: UUID)
    async throws
  {
    try await database.write { database in
      for index in 0..<10_001 {
        let leg = TransactionLeg(
          accountId: accountID,
          instrument: .defaultTestInstrument,
          quantity: 1,
          type: .income
        )
        try TransactionLegRow(domain: leg, transactionId: transactionID, sortOrder: index).insert(
          database
        )
      }
    }
  }
}
