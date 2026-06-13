import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/Transfers")
@MainActor
struct TransactionStoreTransferTests {
  private let accountId = UUID()

  // MARK: - Cross-Store Balance Updates with Transfers

  @Test
  func testTransferUpdateAffectsBothAccounts() async throws {
    let savingsId = UUID()
    let checking = TransactionStoreTestSupport.acct(id: accountId, name: "Checking", balance: 900)
    let savings = TransactionStoreTestSupport.acct(id: savingsId, name: "Savings", balance: 1100)
    let instr = Instrument.defaultTestInstrument
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "",
      legs: [
        TransactionLeg(accountId: accountId, instrument: instr, quantity: -100, type: .transfer),
        TransactionLeg(accountId: savingsId, instrument: instr, quantity: 100, type: .transfer),
      ]
    )
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [transaction], in: database)
    let stores = try await TransactionStoreTestSupport.makeStores(
      backend: backend, database: database, accounts: [checking, savings])
    let (store, accountStore) = (stores.transactions, stores.accounts)
    await store.load(filter: TransactionFilter(accountId: accountId))

    // Update transfer amount from 100 to 150
    var updated = transaction
    updated.legs = [
      TransactionLeg(accountId: accountId, instrument: instr, quantity: -150, type: .transfer),
      TransactionLeg(accountId: savingsId, instrument: instr, quantity: 150, type: .transfer),
    ]
    await store.update(updated)

    // AccountStore is reactive — poll both displayed balances until the
    // observation settles (OB 900 + -150 = 750).
    // Loaded: checking=900-100=800, savings=1100+100=1200
    // Update: checking: -150-(-100)=-50 → 750, savings: +150-100=+50 → 1250
    await expectEventually(
      "checking settled at 750 and savings at 1250 after transfer amount increased"
    ) {
      let checkingBalance = try? await accountStore.displayBalance(for: accountId)
      let savingsBalance = try? await accountStore.displayBalance(for: savingsId)
      return checkingBalance?.quantity == Decimal(750)
        && savingsBalance?.quantity == Decimal(1250)
    }
  }

  @Test
  func testChangingTransferToAccount() async throws {
    let savingsId = UUID()
    let investmentId = UUID()
    let seed = try await seedThreeAccountTransfer(
      savingsId: savingsId, investmentId: investmentId)
    let store = seed.stores.transactions
    let accountStore = seed.stores.accounts

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change destination from savings to investment
    var updated = seed.transfer
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-10000) / 100,
        type: .transfer
      ),
      TransactionLeg(
        accountId: investmentId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(10000) / 100,
        type: .transfer
      ),
    ]
    await store.update(updated)

    // AccountStore is reactive — poll all three displayed balances until
    // the observation settles (savings: 1200-100=1100).
    // Loaded: checking=900-100=800, savings=1100+100=1200, investment=500
    // Change dest from savings→investment: savings -100=1100, investment +100=600
    await expectEventually(
      "checking 800, savings 1100, investment 600 after transfer destination changed"
    ) {
      let checkingBalance = try? await accountStore.displayBalance(for: accountId)
      let savingsBalance = try? await accountStore.displayBalance(for: savingsId)
      let investmentBalance = try? await accountStore.displayBalance(for: investmentId)
      return checkingBalance?.quantity == Decimal(800)
        && savingsBalance?.quantity == Decimal(1100)
        && investmentBalance?.quantity == Decimal(600)
    }
  }

  // MARK: - Helpers

  /// Bundles the seeded transfer transaction with the prepared stores so the
  /// test body can reference both without re-fetching from the store.
  private struct ThreeAccountTransferSeed {
    let stores: TransactionStoreTestSupport.Stores
    let transfer: Transaction
  }

  private func seedThreeAccountTransfer(
    savingsId: UUID,
    investmentId: UUID
  ) async throws -> ThreeAccountTransferSeed {
    let checking = TransactionStoreTestSupport.acct(id: accountId, name: "Checking", balance: 900)
    let savings = TransactionStoreTestSupport.acct(id: savingsId, name: "Savings", balance: 1100)
    // Investment account is `calculatedFromTrades` so its balance reflects
    // position-derived legs from the transfer (recordedValue accounts
    // ignore positions for displayBalance).
    let investment = TransactionStoreTestSupport.acct(
      id: investmentId, name: "Investment", type: .investment, balance: 500,
      valuationMode: .calculatedFromTrades)
    let transfer = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-10000) / 100,
          type: .transfer
        ),
        TransactionLeg(
          accountId: savingsId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(10000) / 100,
          type: .transfer
        ),
      ]
    )
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [transfer], in: database)
    let stores = try await TransactionStoreTestSupport.makeStores(
      backend: backend, database: database, accounts: [checking, savings, investment])
    return ThreeAccountTransferSeed(stores: stores, transfer: transfer)
  }
}
