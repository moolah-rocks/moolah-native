import Foundation
import GRDB
import Testing

@testable import Moolah

struct ReadStreamingAggregationTests {
  @Test(arguments: [10_001, 250_000])
  func denseHistoryIsAggregatedBeforeReturningSummaryRows(count: Int) async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(name: "Dense", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)
    let date = Date(timeIntervalSince1970: 1_767_312_000)
    let transaction = Transaction(date: date, legs: [])
    _ = try await backend.transactions.create(transaction)
    try await seed(database, transaction: transaction.id, account: account.id, count: count)
    let repository = try #require(backend.readQueries)
    let started = ContinuousClock.now
    let snapshot = try await repository.summaryInputs(
      range: ReadDateRange(interval: date..<date.addingTimeInterval(1), timeZone: .utc)
    )
    print("MCP summary fold, \(count) legs: \(ContinuousClock.now - started)")
    #expect(snapshot.flows.count == 1)
    #expect(snapshot.flows.first?.amount.quantity == Decimal(count))
  }

  @Test
  func accountTotalsCanExceedSQLiteIntegerSumRangeExactly() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(name: "Large", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)
    let transaction = Transaction(date: Date(timeIntervalSince1970: 1_767_312_000), legs: [])
    _ = try await backend.transactions.create(transaction)
    try await seed(
      database,
      transaction: transaction.id,
      account: account.id,
      count: 3,
      quantity: Int64.max
    )
    let result = try await #require(backend.readQueries).balanceInputs(accountIDs: [account.id])
    let expected = Decimal(Int64.max) * 3 / 100_000_000
    #expect(result.items.first?.positions.first?.quantity == expected)
  }

  @Test
  func excludedReportLegsStillConsumeTheProcessingBudget() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_767_312_000)
    let transaction = Transaction(date: date, recurPeriod: .once, legs: [])
    _ = try await backend.transactions.create(transaction)
    try await seed(database, transaction: transaction.id, account: nil, count: 250_001)
    let repository = try #require(backend.readQueries)
    await #expect(
      throws: ReadLimitError(operation: .summaryFlows, unit: .transactionLegs, maximum: 250_000)
    ) {
      try await repository.summaryInputs(
        range: ReadDateRange(interval: date..<date.addingTimeInterval(1), timeZone: .utc)
      )
    }
  }

  @Test
  func aFullProcessingPageReturnsOneExactAccountTotal() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(name: "Dense", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)
    let transaction = Transaction(date: Date(timeIntervalSince1970: 1_767_312_000), legs: [])
    _ = try await backend.transactions.create(transaction)
    try await seed(database, transaction: transaction.id, account: account.id, count: 250_000)
    let started = ContinuousClock.now
    let result = try await #require(backend.readQueries).balanceInputs(accountIDs: [account.id])
    print("MCP balance fold, 250000 legs: \(ContinuousClock.now - started)")
    #expect(result.items.first?.positions.first?.quantity == 250_000)
  }

  @Test
  func earmarkTotalsUseTheSameExactStreamingAggregation() async throws {
    let (backend, database) = try TestBackend.create()
    let earmark = Earmark(name: "Large", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)
    let transaction = Transaction(date: Date(timeIntervalSince1970: 1_767_312_000), legs: [])
    _ = try await backend.transactions.create(transaction)
    try await seed(
      database,
      transaction: transaction.id,
      account: nil,
      count: 3,
      quantity: Int64.max
    )
    try await database.write { database in
      _ = try TransactionLegRow.updateAll(
        database,
        TransactionLegRow.Columns.earmarkId.set(to: earmark.id)
      )
    }
    let result = try await #require(backend.readQueries).earmarks(page: ReadPageRequest())
    #expect(result.items.first?.positions.first?.quantity == "276701161105.64327421")
  }

  @Test
  func aggregateCardinalityIsBoundedBeforeResolvingOutputInstruments() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(name: "Diverse", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)
    let transaction = Transaction(date: Date(timeIntervalSince1970: 1_767_312_000), legs: [])
    _ = try await backend.transactions.create(transaction)
    try await seed(database, transaction: transaction.id, account: account.id, count: 10_001)
    try await database.write { database in
      try database.execute(
        sql: "UPDATE transaction_leg SET instrument_id = 'fixture-' || sort_order"
      )
    }
    let repository = try #require(backend.readQueries)
    await #expect(
      throws: ReadLimitError(operation: .balances, unit: .calculationGroups, maximum: 10_000)
    ) {
      try await repository.balanceInputs(accountIDs: [account.id])
    }
  }

  @Test(arguments: ["America/Los_Angeles", "Pacific/Kiritimati", "Australia/Brisbane"])
  func localMonthsRemainDistinctWithinOneUTCPriceDay(zoneID: String) async throws {
    let (backend, _) = try TestBackend.create()
    let zone = try #require(TimeZone(identifier: zoneID))
    var calendar = Calendar.utc
    calendar.timeZone = zone
    let boundary = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
    let dates = [-1.0, 1, 2].map { boundary.addingTimeInterval($0) }
    let account = Account(name: "Boundary", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)
    for (index, date) in dates.enumerated() {
      _ = try await backend.transactions.create(
        Transaction(
          date: date,
          legs: [
            TransactionLeg(
              accountId: account.id,
              instrument: .defaultTestInstrument,
              quantity: Decimal(index + 1),
              type: .income
            )
          ]
        )
      )
    }
    let result = try await #require(backend.readQueries).summaryInputs(
      range: ReadDateRange(interval: dates[0]..<dates[2].addingTimeInterval(1), timeZone: zone)
    )
    #expect(result.flows.count == 2)
    #expect(Set(result.flows.map { $0.amount.quantity }) == [1, 5])
    #expect(Set(result.flows.map { calendar.component(.month, from: $0.date) }) == [2, 3])
    #expect(result.flows.allSatisfy { dates.contains($0.date) })
    #expect(
      Set(result.flows.map { Calendar.utc.startOfDay(for: $0.date) }) == [
        Calendar.utc.startOfDay(for: boundary)
      ]
    )
  }

  @Test
  func cancelledAggregationStopsAtTheNextCheckpoint() async throws {
    let calculation = Task {
      var budget = ReadAggregationBudget(operation: .balances)
      try budget.consume()
      withUnsafeCurrentTask { $0?.cancel() }
      for _ in 0..<1024 { try budget.consume() }
    }
    await #expect(throws: CancellationError.self) { try await calculation.value }
  }

  private func seed(
    _ queue: DatabaseQueue,
    transaction: UUID,
    account: UUID?,
    count: Int,
    quantity: Int64 = 100_000_000
  ) async throws {
    try await queue.write { database in
      try database.execute(
        sql: """
          WITH RECURSIVE sequence(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM sequence WHERE n < ?)
          INSERT INTO transaction_leg
            (id, record_name, transaction_id, account_id, instrument_id, quantity, type, sort_order)
          SELECT CAST(printf('%016x', n) AS BLOB), 'fixture-' || n, ?, ?, ?, ?, 'income', n FROM sequence
          """,
        arguments: [count, transaction, account, Instrument.defaultTestInstrument.id, quantity]
      )
    }
  }
}
