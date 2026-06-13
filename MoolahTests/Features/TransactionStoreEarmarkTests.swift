import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/Earmarks")
@MainActor
struct TransactionStoreEarmarkTests {
  private let accountId = UUID()

  // MARK: - Cross-Store Balance Updates with Earmarks

  @Test
  func testCreateWithEarmarkUpdatesEarmarkBalance() async throws {
    let earmarkId = UUID()
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 1000)
    let earmark = Earmark(
      id: earmarkId, name: "Holiday",
      instrument: .defaultTestInstrument)
    let (backend, database) = try TestBackend.create()
    let stores = try await TransactionStoreTestSupport.makeStores(
      backend: backend, database: database, accounts: [account], earmarks: [earmark])
    let store = stores.transactions
    let earmarkStore = stores.earmarks

    await store.load(filter: TransactionFilter(accountId: accountId))

    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense,
          earmarkId: earmarkId
        )
      ]
    )
    _ = await store.create(transaction)

    // EarmarkStore is reactive — poll the post-create state (spent = 50).
    // This both lets the applyDelta + observation race converge and
    // asserts the final converged value rather than whichever transient
    // mid-state happens to be visible synchronously.
    await expectEventually("earmark spent settled at 50") {
      earmarkStore.earmarks.by(id: earmarkId)?.spentPositions.first?.quantity == Decimal(50)
    }
  }

  @Test
  func testUpdateChangingEarmarkId() async throws {
    let earmarkId1 = UUID()
    let earmarkId2 = UUID()
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 950)
    let earmark1 = Earmark(
      id: earmarkId1, name: "Holiday",
      instrument: .defaultTestInstrument)
    let earmark2 = Earmark(
      id: earmarkId2, name: "Emergency",
      instrument: .defaultTestInstrument)
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense,
          earmarkId: earmarkId1
        )
      ]
    )
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [transaction], in: database)
    let stores = try await TransactionStoreTestSupport.makeStores(
      backend: backend, database: database, accounts: [account],
      earmarks: [earmark1, earmark2])
    let store = stores.transactions
    let earmarkStore = stores.earmarks

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change earmark from 1 to 2
    var updated = transaction
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-5000) / 100,
        type: .expense,
        earmarkId: earmarkId2
      )
    ]
    await store.update(updated)

    // EarmarkStore is reactive — poll the post-update state. Earmark1
    // should have spent reversed (transaction moved away) and earmark2
    // should have spent=50.
    await expectEventually("earmark1 spent reversed to 0 and earmark2 settled at 50") {
      let earmark1 = earmarkStore.earmarks.by(id: earmarkId1)
      let earmark2 = earmarkStore.earmarks.by(id: earmarkId2)
      return earmark1?.spentPositions.first?.quantity ?? 0 == Decimal(0)
        && earmark2?.spentPositions.first?.quantity == Decimal(50)
    }
  }

  @Test
  func testTypeChangeExpenseToIncomeUpdatesAccountBalance() async throws {
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 950)
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [transaction], in: database)
    let stores = try await TransactionStoreTestSupport.makeStores(
      backend: backend, database: database, accounts: [account])
    let store = stores.transactions
    let accountStore = stores.accounts

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change from expense (-50) to income (+50)
    var updated = transaction
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(5000) / 100,
        type: .income
      )
    ]
    await store.update(updated)

    // AccountStore is reactive — poll the displayed balance until the
    // observation settles (OB 950 + income +50 = 1000).
    await expectEventually("account settled at 1000 after expense-to-income update") {
      let balance = try? await accountStore.displayBalance(for: accountId)
      return balance?.quantity == Decimal(1000)
    }
  }

  @Test
  func testPayScheduledTransactionUpdatesAccountBalance() async throws {
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 1000)
    let scheduled = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Rent",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-200000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: database)
    let stores = try await TransactionStoreTestSupport.makeStores(
      backend: backend, database: database, accounts: [account])
    let store = stores.transactions
    let accountStore = stores.accounts

    await store.load(filter: TransactionFilter(scheduled: .scheduledOnly))
    _ = await store.payScheduledTransaction(scheduled)

    // AccountStore is reactive — poll the displayed balance until the
    // observation settles (OB 1000 + paid -2000 = -1000). Paying a
    // -2000 expense should decrease balance by 2000.
    await expectEventually("account settled at -1000 after paying -2000 scheduled expense") {
      let balance = try? await accountStore.displayBalance(for: accountId)
      return balance?.quantity == Decimal(-1000)
    }
  }

  @Test
  func testPayOneTimeScheduledTransactionUpdatesAccountBalance() async throws {
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 1000)
    let scheduled = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Annual Fee",
      recurPeriod: .once,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-50000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: database)
    let stores = try await TransactionStoreTestSupport.makeStores(
      backend: backend, database: database, accounts: [account])
    let store = stores.transactions
    let accountStore = stores.accounts

    await store.load(filter: TransactionFilter(scheduled: .scheduledOnly))
    _ = await store.payScheduledTransaction(scheduled)

    // AccountStore is reactive — poll the displayed balance until the
    // observation settles (OB 1000 + paid -500 = 500). Paying a -500
    // expense should decrease balance by 500.
    await expectEventually("account settled at 500 after paying -500 one-time expense") {
      let balance = try? await accountStore.displayBalance(for: accountId)
      return balance?.quantity == Decimal(500)
    }
  }

  // Running-balance update tests live in
  // `TransactionStoreRunningBalanceTests.swift`.
}
