import Foundation
import GRDB
import Testing

@testable import Moolah

struct ReadQueryBoundsTests {
  @Test(arguments: [false, true])
  func denseTransactionRespectsPostedOnlyPositionBounds(scheduled: Bool) async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(name: "Dense", type: .bank, instrument: .defaultTestInstrument)
    let earmark = Earmark(name: "Dense", instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)
    _ = try await backend.earmarks.create(earmark)
    let transaction = Transaction(
      date: Date(timeIntervalSince1970: 1_777_680_000),
      recurPeriod: scheduled ? .once : nil,
      legs: [])
    _ = try await backend.transactions.create(transaction)
    try await database.write { database in
      for index in 0..<10_001 {
        let leg = TransactionLeg(
          accountId: account.id,
          instrument: .defaultTestInstrument,
          quantity: 1,
          type: .income,
          earmarkId: earmark.id)
        try TransactionLegRow(domain: leg, transactionId: transaction.id, sortOrder: index)
          .insert(database)
      }
    }
    let repository = try #require(backend.readQueries)
    await #expect(throws: ReadQueryError.resultTooLarge) {
      try await repository.transaction(id: transaction.id)
    }
    let search = try ReadTransactionSearch(
      range: ReadDateRange(
        interval: transaction.date..<transaction.date.addingTimeInterval(1),
        timeZone: .utc),
      scheduled: scheduled)
    await #expect(throws: ReadQueryError.resultTooLarge) {
      try await repository.transactions(search: search, page: ReadPageRequest())
    }
    if scheduled {
      let balances = try await repository.balances(accountIDs: [account.id])
      let earmarks = try await repository.earmarks(page: ReadPageRequest())
      #expect(balances.items.first?.positions.isEmpty == true)
      #expect(earmarks.items.first?.positions.isEmpty == true)
    } else {
      await #expect(throws: ReadQueryError.resultTooLarge) {
        try await repository.balances(accountIDs: [account.id])
      }
      await #expect(throws: ReadQueryError.resultTooLarge) {
        try await repository.earmarks(page: ReadPageRequest())
      }
    }
  }
}
