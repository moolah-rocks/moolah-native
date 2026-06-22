import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("TransactionStore/ScheduledViews")
@MainActor
struct TransactionStoreScheduledViewTests {

  // MARK: - Multi-instrument loading

  @Test
  func testLoadsUSDAccountTransactionsInUSDInstrument() async throws {
    // A USD-denominated account should load expense/income legs with USD instrument intact.
    let usdAccountId = UUID()
    let expectedAmount = try #require(Decimal(string: "-4.50"))
    let transactions = [
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-06-15"),
        payee: "Starbucks",
        legs: [
          TransactionLeg(
            accountId: usdAccountId,
            instrument: .USD,
            quantity: expectedAmount,
            type: .expense)
        ]
      )
    ]
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(id: usdAccountId, name: "US Checking", type: .bank, instrument: .USD)
      ], in: database)
    TestBackend.seed(transactions: transactions, in: database)

    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )
    await store.load(filter: TransactionFilter(accountId: usdAccountId))

    #expect(store.transactions.count == 1)
    let transaction = store.transactions[0].transaction
    #expect(transaction.legs[0].instrument == .USD)
    #expect(transaction.legs[0].quantity == expectedAmount)
  }

  @Test
  func testLoadsTransactionSpanningMultipleInstruments() async throws {
    // Currency conversion transaction on the same account — leg instruments must be preserved.
    let revolutId = UUID()
    let audQuantity = try #require(Decimal(string: "-1000.00"))
    let usdQuantity = try #require(Decimal(string: "650.00"))
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-06-15"),
      payee: "FX",
      legs: [
        TransactionLeg(
          accountId: revolutId, instrument: .AUD,
          quantity: audQuantity, type: .transfer),
        TransactionLeg(
          accountId: revolutId, instrument: .USD,
          quantity: usdQuantity, type: .transfer),
      ]
    )
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(id: revolutId, name: "Revolut", type: .bank, instrument: .AUD)
      ], in: database)
    TestBackend.seed(transactions: [transaction], in: database)

    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )
    await store.load(filter: TransactionFilter(accountId: revolutId))

    #expect(store.transactions.count == 1)
    let fetched = store.transactions[0].transaction
    #expect(fetched.legs.count == 2)
    let audLeg = try #require(fetched.legs.first(where: { $0.instrument == .AUD }))
    let usdLeg = try #require(fetched.legs.first(where: { $0.instrument == .USD }))
    #expect(audLeg.quantity == audQuantity)
    #expect(usdLeg.quantity == usdQuantity)
    #expect(fetched.isTransfer)
  }

  // MARK: - Scheduled view helpers

  /// Holds the prepared store and related test backend handles returned by
  /// `makeScheduledTestStore`.
  private struct ScheduledTestStoreFixture {
    let store: TransactionStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
  }

  /// Seeds one past-dated scheduled transaction and one future-dated scheduled
  /// transaction plus one past-dated non-scheduled (paid) transaction, then
  /// returns the prepared store. The non-scheduled transaction is what the
  /// pre-fix Analysis card was rendering as "overdue" when the shared
  /// transactionStore had been loaded with a non-scheduled filter first.
  private func makeScheduledTestStore() async throws -> ScheduledTestStoreFixture {
    let (backend, database) = try TestBackend.create()
    let accountId = UUID()
    TestBackend.seed(
      accounts: [
        (
          account: Account(
            id: accountId, name: "Bank", type: .bank, instrument: .defaultTestInstrument),
          openingBalance: InstrumentAmount(quantity: 0, instrument: .defaultTestInstrument)
        )
      ],
      in: database)
    TestBackend.seed(
      transactions: try makeScheduledFixtureTransactions(accountId: accountId),
      in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    return ScheduledTestStoreFixture(store: store, backend: backend, database: database)
  }

  private func makeScheduledFixtureTransactions(accountId: UUID) throws -> [Transaction] {
    let calendar = Calendar.current
    let now = Date()
    let overdue = try #require(calendar.date(byAdding: .day, value: -5, to: now))
    let upcoming = try #require(calendar.date(byAdding: .day, value: 5, to: now))
    let farFuture = try #require(calendar.date(byAdding: .day, value: 60, to: now))
    let pastPaid = try #require(calendar.date(byAdding: .day, value: -10, to: now))
    return [
      Transaction(
        date: overdue, payee: "Overdue Rent",
        recurPeriod: .month, recurEvery: 1,
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .defaultTestInstrument,
            quantity: Decimal(-2000), type: .expense)
        ]),
      Transaction(
        date: upcoming, payee: "Upcoming Internet",
        recurPeriod: .month, recurEvery: 1,
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .defaultTestInstrument,
            quantity: Decimal(-150), type: .expense)
        ]),
      Transaction(
        date: farFuture, payee: "Future Insurance",
        recurPeriod: .month, recurEvery: 1,
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .defaultTestInstrument,
            quantity: Decimal(-300), type: .expense)
        ]),
      Transaction(
        date: pastPaid, payee: "Old Coffee",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .defaultTestInstrument,
            quantity: Decimal(-10), type: .expense)
        ]),
    ]
  }

  @Test("scheduledOverdueTransactions is empty when filter isn't scheduled-only")
  func overdueEmptyWhenFilterMismatched() async throws {
    let fixture = try await makeScheduledTestStore()

    await fixture.store.load(filter: TransactionFilter())

    #expect(!fixture.store.transactions.isEmpty)
    #expect(fixture.store.scheduledOverdueTransactions.isEmpty)
    #expect(fixture.store.scheduledUpcomingTransactions.isEmpty)
    #expect(fixture.store.scheduledShortTermTransactions().isEmpty)
  }

  @Test("scheduledOverdueTransactions returns past-dated scheduled transactions only")
  func overdueReturnsPastDatedScheduled() async throws {
    let fixture = try await makeScheduledTestStore()

    await fixture.store.load(filter: TransactionFilter(scheduled: .scheduledOnly))

    #expect(fixture.store.scheduledOverdueTransactions.count == 1)
    #expect(fixture.store.scheduledOverdueTransactions.first?.transaction.payee == "Overdue Rent")
  }

  @Test("scheduledUpcomingTransactions returns today-or-later scheduled transactions")
  func upcomingReturnsTodayOrLaterScheduled() async throws {
    let fixture = try await makeScheduledTestStore()

    await fixture.store.load(filter: TransactionFilter(scheduled: .scheduledOnly))

    let payees = fixture.store.scheduledUpcomingTransactions.map(\.transaction.payee)
    #expect(payees == ["Upcoming Internet", "Future Insurance"])
  }

  @Test("scheduledShortTermTransactions limits to within the daysAhead window")
  func shortTermWindowedByDaysAhead() async throws {
    let fixture = try await makeScheduledTestStore()

    await fixture.store.load(filter: TransactionFilter(scheduled: .scheduledOnly))

    // Default 14-day window: includes overdue + near upcoming, excludes 60-day future.
    let payees = fixture.store.scheduledShortTermTransactions().map(\.transaction.payee)
    #expect(payees == ["Overdue Rent", "Upcoming Internet"])
  }
}
