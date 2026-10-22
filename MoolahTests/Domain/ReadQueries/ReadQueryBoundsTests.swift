import Foundation
import GRDB
import Testing

@testable import Moolah

struct ReadQueryBoundsTests {
  @Test(arguments: [false, true])
  func denseTransactionDetailsStayBoundedWhilePositionsAggregate(scheduled: Bool) async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(name: "Dense", type: .bank, instrument: .defaultTestInstrument)
    let earmark = Earmark(name: "Dense", instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)
    _ = try await backend.earmarks.create(earmark)
    let transaction = Transaction(
      date: Date(timeIntervalSince1970: 1_777_680_000),
      recurPeriod: scheduled ? .once : nil,
      legs: []
    )
    _ = try await backend.transactions.create(transaction)
    try await seedLegs(
      database,
      accountID: account.id,
      earmarkID: earmark.id,
      transactionID: transaction.id
    )
    let repository = try #require(backend.readQueries)
    try await expectRawDetailLimit(
      repository: repository,
      transaction: transaction,
      scheduled: scheduled
    )
    if scheduled {
      let balances = try await repository.balances(accountIDs: [account.id])
      let earmarks = try await repository.earmarks(page: ReadPageRequest())
      #expect(balances.items.first?.positions.isEmpty == true)
      #expect(earmarks.items.first?.positions.isEmpty == true)
    } else {
      let balances = try await repository.balances(accountIDs: [account.id])
      let earmarks = try await repository.earmarks(page: ReadPageRequest())
      #expect(balances.items.first?.positions.first?.quantity == "10001")
      #expect(earmarks.items.first?.positions.first?.quantity == "10001")
    }
  }
  private func expectRawDetailLimit(
    repository: any ReadQueryRepository,
    transaction: Transaction,
    scheduled: Bool
  ) async throws {
    await #expect(
      throws: ReadLimitError(
        operation: .transactionDetails,
        unit: .transactionLegs,
        maximum: 10_000
      )
    ) {
      try await repository.transaction(id: transaction.id)
    }
    let search = try ReadTransactionSearch(
      range: ReadDateRange(
        interval: transaction.date..<transaction.date.addingTimeInterval(1),
        timeZone: .utc
      ),
      scheduled: scheduled
    )
    await #expect(
      throws: ReadLimitError(
        operation: .transactionDetails,
        unit: .transactionLegs,
        maximum: 10_000
      )
    ) {
      try await repository.transactions(search: search, page: ReadPageRequest())
    }
  }

  private func seedLegs(
    _ database: DatabaseQueue,
    accountID: UUID,
    earmarkID: UUID,
    transactionID: UUID
  ) async throws {
    try await database.write { database in
      for index in 0..<10_001 {
        let leg = TransactionLeg(
          accountId: accountID,
          instrument: .defaultTestInstrument,
          quantity: 1,
          type: .income,
          earmarkId: earmarkID
        )
        try TransactionLegRow(domain: leg, transactionId: transactionID, sortOrder: index)
          .insert(database)
      }
    }
  }

}
