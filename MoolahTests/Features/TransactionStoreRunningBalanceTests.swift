import Foundation
import Testing

@testable import Moolah

/// Running-balance update tests for `TransactionStore`.
@Suite("TransactionStore/Running Balances")
@MainActor
struct TransactionStoreRunningBalanceTests {
  private let accountId = UUID()

  @Test
  func testRunningBalancesUpdateAfterCreate() async throws {
    let existing = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-01"),
      payee: "Initial",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(100000) / 100,
          type: .income
        )
      ]
    )
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [existing], in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions[0].balance?.quantity == Decimal(100000) / 100)

    // Add a newer expense
    let expense = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-3000) / 100,
          type: .expense
        )
      ]
    )
    _ = await store.create(expense)

    // Newest first: expense (balance 97000), then income (balance 100000).
    await expectEventually("running balances recompute after create") {
      store.transactions.count == 2
        && store.transactions[0].transaction.payee == "Coffee"
        && store.transactions[0].balance?.quantity == Decimal(97000) / 100
        && store.transactions[1].transaction.payee == "Initial"
        && store.transactions[1].balance?.quantity == Decimal(100000) / 100
    }
  }

  @Test
  func testRunningBalancesUpdateAfterDelete() async throws {
    let salary = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-01"),
      payee: "Salary",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(100000) / 100,
          type: .income
        )
      ]
    )
    let coffee = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-3000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [salary, coffee], in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].balance?.quantity == Decimal(97000) / 100)  // After Coffee

    // Delete the expense — balance should revert
    await store.delete(id: coffee.id)
    // Only Salary remains, so its running balance reverts to 100000.
    await expectEventually("running balance reverts after delete") {
      store.transactions.count == 1
        && store.transactions[0].balance?.quantity == Decimal(100000) / 100
    }
  }

  @Test
  func testRunningBalancesUpdateAfterAmountChange() async throws {
    let salary = try makeIncome(date: "2024-01-01", payee: "Salary", quantity: 1000)
    let coffee = try makeExpense(date: "2024-01-15", payee: "Coffee", quantity: -30)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [salary, coffee], in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions[0].balance?.quantity == 970)  // After Coffee
    #expect(store.transactions[1].balance?.quantity == 1000)  // After Salary

    var updated = coffee
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: -50,
        type: .expense
      )
    ]
    await store.update(updated)
    await expectEventually("running balances recompute after amount change") {
      store.transactions[0].balance?.quantity == 950
        && store.transactions[1].balance?.quantity == 1000
    }
  }

  // MARK: - Account groups

  /// Regression for the account-group balance bug: viewing a group's merged
  /// transactions, the newest row's running balance must equal the sum of the
  /// member accounts' balances (what the group sidebar shows) — even when the
  /// list is paginated, so older history sits in `priorBalance`. Before the
  /// fix the group `priorBalance` was forced to zero and the merged list never
  /// tied out to the sidebar total.
  @Test
  func testGroupRunningBalanceTiesOutToMemberTotalAcrossPages() async throws {
    let memberA = UUID()
    let memberB = UUID()
    let target = Instrument.defaultTestInstrument
    // 5 transactions across the two members, oldest → newest.
    let txs = [
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-01"), payee: "A in",
        legs: [TransactionLeg(accountId: memberA, instrument: target, quantity: 100, type: .income)]
      ),
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-02"), payee: "B in",
        legs: [TransactionLeg(accountId: memberB, instrument: target, quantity: 50, type: .income)]),
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-03"), payee: "A out",
        legs: [
          TransactionLeg(accountId: memberA, instrument: target, quantity: -30, type: .expense)
        ]),
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-04"), payee: "B in 2",
        legs: [TransactionLeg(accountId: memberB, instrument: target, quantity: 20, type: .income)]),
      Transaction(
        date: try TransactionStoreTestSupport.makeDate("2024-01-05"), payee: "A in 2",
        legs: [TransactionLeg(accountId: memberA, instrument: target, quantity: 10, type: .income)]),
    ]

    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        (
          Account(id: memberA, name: "A", type: .bank, instrument: target),
          .zero(instrument: target)
        ),
        (
          Account(id: memberB, name: "B", type: .bank, instrument: target),
          .zero(instrument: target)
        ),
      ],
      in: database)
    TestBackend.seed(transactions: txs, in: database)

    // Small page size forces pagination, so older history lands in priorBalance.
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: target,
      pageSize: 2
    )

    await store.load(filter: TransactionFilter(accountIds: [memberA, memberB]))

    // Member total = 100 + 50 - 30 + 20 + 10 = 150 — the group sidebar figure.
    // The newest row (index 0) must tie out to it.
    let newest = try #require(store.transactions.first)
    #expect(newest.balance?.quantity == 150)
  }

  // MARK: - Helpers

  private func makeIncome(
    date: String, payee: String, quantity: Decimal
  ) throws -> Transaction {
    Transaction(
      date: try TransactionStoreTestSupport.makeDate(date),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: quantity,
          type: .income
        )
      ]
    )
  }

  private func makeExpense(
    date: String, payee: String, quantity: Decimal
  ) throws -> Transaction {
    Transaction(
      date: try TransactionStoreTestSupport.makeDate(date),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: quantity,
          type: .expense
        )
      ]
    )
  }
}
