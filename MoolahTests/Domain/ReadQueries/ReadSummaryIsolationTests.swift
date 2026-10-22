import Foundation
import GRDB
import Testing

@testable import Moolah

struct ReadSummaryIsolationTests {
  @Test
  func narrowSpendingSummaryDoesNotReadLifetimeBalances() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(name: "Long history", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)
    let historical = Transaction(date: Date(timeIntervalSince1970: 1_700_000_000), legs: [])
    _ = try await backend.transactions.create(historical)
    try await seedHistoricalLegs(database, accountID: account.id, transactionID: historical.id)
    let date = Date(timeIntervalSince1970: 1_767_312_000)
    _ = try await backend.transactions.create(
      Transaction(
        date: date,
        legs: [
          TransactionLeg(
            accountId: account.id,
            instrument: .defaultTestInstrument,
            quantity: -7,
            type: .expense
          )
        ]
      )
    )
    let range = try ReadDateRange(interval: date..<date.addingTimeInterval(1), timeZone: .utc)
    let repository = try #require(backend.readQueries)
    let snapshot = try await repository.summaryInputs(range: range)
    #expect(snapshot.flows.count == 1)
    guard case .omitted = snapshot.netWorth else {
      Issue.record("Spending-only summary unexpectedly read net worth")
      return
    }
    let (summary, _) = try await ReadFinancialCalculationService(
      conversion: FakeConversionService.alwaysThrows
    ).summary(
      snapshot,
      target: .defaultTestInstrument,
      grouping: .none
    )
    #expect(summary.reportingSpending.value?.quantity == "-7")
    #expect(summary.currentNetWorth == nil)
    #expect(!summary.netWorthIncluded)
    let full = try await repository.summaryInputs(range: range, includeNetWorth: true)
    guard case .requested(let balances) = full.netWorth else {
      Issue.record("Explicit net worth request was omitted")
      return
    }
    #expect(balances.first?.positions.first?.quantity == 9_994)
  }
  private func seedHistoricalLegs(_ database: DatabaseQueue, accountID: UUID, transactionID: UUID)
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
