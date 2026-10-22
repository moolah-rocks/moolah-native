import Foundation
import Testing

@testable import Moolah

struct ReadSummaryRepositoryTests {
  @Test
  func summaryUsesReportsFlowsAndAllPostedCurrentPositions() async throws {
    let (backend, _) = try TestBackend.create()
    let repository = try #require(backend.readQueries)
    let instrument = Instrument.defaultTestInstrument
    let account = Account(name: "Hidden", type: .bank, instrument: instrument, isHidden: true)
    _ = try await backend.accounts.create(account)
    let lower = Date(timeIntervalSince1970: 1_767_312_000)
    let upper = lower.addingTimeInterval(86400)
    for (date, type, quantity, scheduled, hasAccount) in [
      (lower, TransactionType.income, 10, false, true),
      (upper.addingTimeInterval(-1), .expense, -3, false, true),
      (lower.addingTimeInterval(-1), .income, 20, false, true),
      (upper, .income, 30, false, true),
      (lower, .income, 999, true, true),
      (lower, .openingBalance, 100, false, true),
      (lower, .transfer, 200, false, true),
      (lower, .income, 777, false, false),
    ] {
      _ = try await backend.transactions.create(
        Transaction(
          date: date,
          recurPeriod: scheduled ? .once : nil,
          legs: [
            TransactionLeg(
              accountId: hasAccount ? account.id : nil,
              instrument: instrument,
              quantity: Decimal(quantity),
              type: type
            )
          ]
        )
      )
    }
    let snapshot = try await repository.summaryInputs(
      range: ReadDateRange(interval: lower..<upper, timeZone: .utc),
      includeNetWorth: true
    )
    #expect(snapshot.flows.count == 2)
    #expect(Set(snapshot.flows.map { $0.amount.quantity }) == [10, -3])
    guard case .requested(let balances) = snapshot.netWorth else {
      Issue.record("Explicit net worth request was omitted")
      return
    }
    #expect(balances.count == 1)
    #expect(balances.first?.accountID == account.id)
    #expect(balances.first?.positions.first?.quantity == 357)
  }
}
