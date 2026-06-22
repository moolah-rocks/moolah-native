import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/Loading")
@MainActor
struct TransactionStoreLoadingTests {
  private let accountId = UUID()

  @Test
  func testLoadsFirstPage() async throws {
    let transactions = try TransactionStoreTestSupport.seedTransactions(
      count: 3, accountId: accountId)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 3)
    #expect(!store.isLoading)

    // Each entry should have a running balance
    for entry in store.transactions {
      #expect(entry.transaction.accountIds.contains(accountId))
    }
  }

  @Test
  func testPaginationAppendsSecondPage() async throws {
    // Create more transactions than one page
    let transactions = try TransactionStoreTestSupport.seedTransactions(
      count: 5, accountId: accountId)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument,
      pageSize: 3
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 3)
    #expect(store.hasMore == true)

    await store.loadMore()
    try await store.awaitTransactionCount(5)
    #expect(store.transactions.count == 5)
    #expect(store.hasMore == false)
  }

  @Test
  func testEndOfResultsDetection() async throws {
    let transactions = try TransactionStoreTestSupport.seedTransactions(
      count: 2, accountId: accountId)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument,
      pageSize: 10
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 2)
    #expect(store.hasMore == false)
  }

  @Test
  func testLoadMoreDoesNothingWhenNoMore() async throws {
    let transactions = try TransactionStoreTestSupport.seedTransactions(
      count: 2, accountId: accountId)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument,
      pageSize: 10
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.hasMore == false)

    await store.loadMore()
    #expect(store.transactions.count == 2)  // No duplicates
  }

  @Test
  func testFilterByAccountId() async throws {
    let otherAccountId = UUID()
    let transactions = [
      try singleLegTransaction(
        date: "2024-01-01", payee: "Mine", accountId: accountId,
        amount: Decimal(-1000) / 100, type: .expense),
      try singleLegTransaction(
        date: "2024-01-02", payee: "Other", accountId: otherAccountId,
        amount: Decimal(-2000) / 100, type: .expense),
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-03"),
        payee: "Transfer In",
        legs: [
          TransactionLeg(
            accountId: otherAccountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-5000) / 100,
            type: .transfer
          ),
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(5000) / 100,
            type: .transfer
          ),
        ]
      ),
    ]
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 2)  // Direct + transfer-in
    let payees = store.transactions.map(\.transaction.payee)
    #expect(payees.contains("Mine"))
    #expect(payees.contains("Transfer In"))
  }

  @Test
  func testSortedByDateDescending() async throws {
    let transactions = [
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-01"),
        payee: "Oldest",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-1000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
        payee: "Middle",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-2000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-30"),
        payee: "Newest",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-3000) / 100,
            type: .expense
          )
        ]
      ),
    ]
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions[0].transaction.payee == "Newest")
    #expect(store.transactions[1].transaction.payee == "Middle")
    #expect(store.transactions[2].transaction.payee == "Oldest")
  }

  @Test
  func testRunningBalancesComputed() async throws {
    let transactions = [
      try singleLegTransaction(
        date: "2024-01-03", payee: "Salary", accountId: accountId,
        amount: Decimal(100000) / 100, type: .income),
      try singleLegTransaction(
        date: "2024-01-02", payee: "Coffee", accountId: accountId,
        amount: Decimal(-2500) / 100, type: .expense),
      try singleLegTransaction(
        date: "2024-01-01", payee: "Groceries", accountId: accountId,
        amount: Decimal(-10000) / 100, type: .expense),
    ]
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 3)

    // Transactions are newest-first; balance is the running total after each tx
    // priorBalance = 0 (no older transactions)
    // Groceries (oldest): 0 + (-10000) = -10000
    // Coffee: -10000 + (-2500) = -12500
    // Salary (newest): -12500 + 100000 = 87500
    #expect(
      store.transactions[0].balance
        == InstrumentAmount(
          quantity: Decimal(87500) / 100, instrument: Instrument.defaultTestInstrument))  // After Salary
    #expect(
      store.transactions[1].balance
        == InstrumentAmount(
          quantity: Decimal(-12500) / 100, instrument: Instrument.defaultTestInstrument))  // After Coffee
    #expect(
      store.transactions[2].balance
        == InstrumentAmount(
          quantity: Decimal(-10000) / 100, instrument: Instrument.defaultTestInstrument))  // After Groceries
  }

  @Test
  func testReloadClearsExisting() async throws {
    let transactions = try TransactionStoreTestSupport.seedTransactions(
      count: 5, accountId: accountId)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument,
      pageSize: 3
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 3)

    // Reload should start fresh
    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 3)
  }

  // MARK: - Helpers

  /// Builds a single-leg transaction with the given attributes. Used to keep
  /// test arrange blocks concise and under the SwiftLint function-body-length
  /// threshold without hiding the scenario intent behind a wider abstraction.
  private func singleLegTransaction(
    date: String,
    payee: String,
    accountId: UUID,
    amount: Decimal,
    type: TransactionType
  ) throws -> Transaction {
    Transaction(
      date: try TransactionStoreTestSupport.makeDate(date),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: amount,
          type: type
        )
      ]
    )
  }
}
