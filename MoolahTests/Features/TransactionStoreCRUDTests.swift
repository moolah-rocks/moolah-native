import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/CRUD")
@MainActor
struct TransactionStoreCRUDTests {
  private let accountId = UUID()

  // MARK: - CRUD

  @Test
  func testCreateAddsTransaction() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.isEmpty)

    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Coffee Shop",
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

    await expectEventually("created transaction is observable") {
      store.transactions.count == 1
        && store.transactions[0].transaction.payee == "Coffee Shop"
    }
    #expect(store.error == nil)
  }

  /// The placeholder-pass-through pattern in `TransactionListView.createNewTransaction`
  /// (and the upcoming-view equivalent) relies on `store.create(placeholder)`
  /// returning a transaction with the same UUID the caller passed in. The
  /// inspector's `.id(selected.id)` otherwise forces a view recreation on
  /// every create, which would drop focus state. See
  /// `plans/2026-04-21-transaction-detail-focus-design.md`.
  @Test
  func testCreatePreservesInputUUID() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )
    await store.load(filter: TransactionFilter(accountId: accountId))

    let placeholderId = UUID()
    let placeholder = Transaction(
      id: placeholderId,
      date: try TransactionStoreTestSupport.makeDate("2024-02-01"),
      payee: "",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: 0,
          type: .expense
        )
      ]
    )

    let created = await store.create(placeholder)

    // `created` is the captured return value (non-reactive), so assert it
    // directly; the store list is reactive, so poll it.
    #expect(created?.id == placeholderId)
    await expectEventually("placeholder UUID preserved in observed list") {
      store.transactions.count == 1
        && store.transactions[0].transaction.id == placeholderId
    }
  }

  @Test
  func testUpdateModifiesTransaction() async throws {
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Coffee Shop",
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
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 1)

    var updated = transaction
    updated.payee = "Fancy Coffee"
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-7500) / 100,
        type: .expense
      )
    ]
    await store.update(updated)

    await expectEventually("update is observable") {
      store.transactions.count == 1
        && store.transactions[0].transaction.payee == "Fancy Coffee"
        && store.transactions[0].displayAmount?.quantity == Decimal(-7500) / 100
    }
    #expect(store.error == nil)
  }

  @Test
  func testDeleteRemovesTransaction() async throws {
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Coffee Shop",
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
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 1)

    await store.delete(id: transaction.id)

    await expectEventually("delete is observable") {
      store.transactions.isEmpty
    }
    #expect(store.error == nil)
  }

  @Test
  func testCreateUpdateDeleteCycle() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Create
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-10"),
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
    _ = await store.create(transaction)
    await expectEventually("created transaction is observable") {
      store.transactions.count == 1
    }

    // Update
    var modified = transaction
    modified.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(110000) / 100,
        type: .income
      )
    ]
    await store.update(modified)
    await expectEventually("update is observable") {
      store.transactions.count == 1
        && store.transactions[0].displayAmount?.quantity == Decimal(110000) / 100
    }

    // Delete
    await store.delete(id: transaction.id)
    await expectEventually("delete is observable") {
      store.transactions.isEmpty
    }
  }

  // Running-balance recompute tests live in
  // `TransactionStoreRunningBalanceTests.swift`.
}
