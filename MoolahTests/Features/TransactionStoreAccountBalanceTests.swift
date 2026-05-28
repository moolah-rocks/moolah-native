import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/AccountBalance")
@MainActor
struct TransactionStoreAccountBalanceTests {
  private let accountId = UUID()

  // MARK: - Cross-Store Balance Updates

  @Test
  func testCreateUpdatesAccountBalance() async throws {
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 1000)
    let (backend, database) = try TestBackend.create()
    let stores = try await TransactionStoreTestSupport.makeStores(
      backend: backend, database: database, accounts: [account])
    let store = stores.transactions
    let accountStore = stores.accounts

    await store.load(filter: TransactionFilter(accountId: accountId))

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
    _ = await store.create(transaction)

    // AccountStore is reactive — wait for observation to settle (OB 1000 + new -50 = 950).
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: accountId)?.positions.first?.quantity == Decimal(950) },
      description: "account settled at 950 after -50 expense created")
    // Seeded balance is 1000 (from OB tx), create adds -50 expense -> 950
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(950))
  }

  @Test
  func testUpdateUpdatesAccountBalance() async throws {
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

    // Change amount from -50 to -75
    var updated = transaction
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-7500) / 100,
        type: .expense
      )
    ]
    await store.update(updated)

    // AccountStore is reactive — wait for observation to settle (OB 950 + updated -75 = 875).
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: accountId)?.positions.first?.quantity == Decimal(875) },
      description: "account settled at 875 after -50 expense updated to -75")
    // Seeded account OB=950 + seeded tx=-50 gives loaded balance=900
    // Update delta: (-75)-(-50)=-25, so 900-25=875
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(875))
  }

  @Test
  func testDeleteUpdatesAccountBalance() async throws {
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

    await store.delete(id: transaction.id)

    // AccountStore is reactive — wait for observation to settle (OB 950 only, positions = 950).
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: accountId)?.positions.first?.quantity == Decimal(950) },
      description: "account settled at 950 after -50 expense deleted")
    // Seeded account OB=950 + seeded tx=-50 gives loaded balance=900
    // Deleting the -50 expense adds 50 back: 900+50=950
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(950))
  }
}
