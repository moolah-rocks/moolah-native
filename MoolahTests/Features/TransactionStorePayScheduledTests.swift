import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/PayScheduled")
@MainActor
struct TransactionStorePayScheduledTests {
  private let accountId = UUID()

  @Test
  func testPayRecurringTransactionAdvancesDate() async throws {
    let originalDate = try TransactionStoreTestSupport.makeDate("2024-01-15")
    let scheduled = Transaction(
      date: originalDate,
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
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(scheduled: .scheduledOnly))
    #expect(store.transactions.count == 1)

    let result = await store.payScheduledTransaction(scheduled)
    let expectedNextDate = try TransactionStoreTestSupport.makeDate("2024-02-15")

    // Store should show the scheduled tx with advanced date.
    await expectEventually("advanced date is observable") {
      store.transactions.count == 1
        && store.transactions[0].transaction.id == scheduled.id
        && store.transactions[0].transaction.date == expectedNextDate
        && store.transactions[0].transaction.recurPeriod == .month
    }

    // Result should return the updated transaction
    guard case .paid(let updated) = result else {
      Issue.record("Expected .paid result, got \(result)")
      return
    }
    #expect(updated?.id == scheduled.id)
    #expect(updated?.date == expectedNextDate)

    try await assertBackendStateAfterRentPay(backend: backend, scheduled: scheduled)
  }

  private func assertBackendStateAfterRentPay(
    backend: any BackendProvider, scheduled: Transaction
  ) async throws {
    // Backend should have the paid (non-scheduled) transaction
    let paidPage = try await backend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 50)
    #expect(paidPage.transactions.count == 1)
    let paidTx = paidPage.transactions.first
    #expect(paidTx != nil)
    #expect(paidTx?.recurPeriod == nil)
    #expect(paidTx?.recurEvery == nil)
    #expect(paidTx?.payee == "Rent")
    #expect(paidTx?.legs.first?.quantity == Decimal(-200000) / 100)
    // Backend should still have the scheduled transaction with advanced date
    let scheduledPage = try await backend.transactions.fetch(
      filter: TransactionFilter(scheduled: .scheduledOnly), page: 0, pageSize: 50)
    #expect(scheduledPage.transactions.count == 1)
    #expect(scheduledPage.transactions[0].id == scheduled.id)
  }

  @Test
  func testPayRecurringWeeklyTransactionAdvancesByWeek() async throws {
    let scheduled = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Groceries",
      recurPeriod: .week,
      recurEvery: 2,
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
    TestBackend.seed(transactions: [scheduled], in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(scheduled: .scheduledOnly))
    let result = await store.payScheduledTransaction(scheduled)
    let expectedNextDate = try TransactionStoreTestSupport.makeDate("2024-01-29")

    await expectEventually("advanced (weekly) date is observable") {
      store.transactions.count == 1
        && store.transactions[0].transaction.date == expectedNextDate
    }

    guard case .paid(let updated) = result else {
      Issue.record("Expected .paid result")
      return
    }
    #expect(updated?.date == expectedNextDate)
  }

  @Test
  func testPayOneTimeScheduledTransactionDeletesIt() async throws {
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
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(scheduled: .scheduledOnly))
    #expect(store.transactions.count == 1)

    let result = await store.payScheduledTransaction(scheduled)

    // Store should show no scheduled transactions (the original was deleted).
    await expectEventually("scheduled transaction removed from observed list") {
      store.transactions.isEmpty
    }

    // Result should be .deleted
    guard case .deleted = result else {
      Issue.record("Expected .deleted result, got \(result)")
      return
    }

    // Backend should have only the paid transaction
    let allPage = try await backend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 50)
    #expect(allPage.transactions.count == 1)
    #expect(allPage.transactions[0].recurPeriod == nil)
    #expect(allPage.transactions[0].payee == "Annual Fee")
  }

  @Test
  func testPaidCopyKeepsScheduledDate() async throws {
    let scheduledDate = try TransactionStoreTestSupport.makeDate("2024-01-15")
    let scheduled = Transaction(
      date: scheduledDate,
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
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(scheduled: .scheduledOnly))
    _ = await store.payScheduledTransaction(scheduled)

    let allPage = try await backend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 50)
    let paid = allPage.transactions.first { $0.id != scheduled.id }
    #expect(paid != nil)
    #expect(paid?.date == scheduledDate)
  }

  @Test
  func testPayPreservesAllTransactionFields() async throws {
    let categoryId = UUID()
    let earmarkId = UUID()
    let toAccountId = UUID()
    let scheduled = try makeScheduledTransfer(
      toAccountId: toAccountId,
      categoryId: categoryId,
      earmarkId: earmarkId)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(scheduled: .scheduledOnly))
    _ = await store.payScheduledTransaction(scheduled)

    // Find the paid (non-scheduled) transaction in the backend
    let allPage = try await backend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 50)
    let paid = allPage.transactions.first { $0.id != scheduled.id }
    #expect(paid != nil)
    #expect(paid?.legs.first?.type ?? .expense == .transfer)
    #expect(paid?.accountIds.contains(accountId) == true)
    #expect(
      paid?.legs.first(where: { $0.accountId != accountId })?.accountId
        == toAccountId)
    #expect(paid?.legs.first?.quantity == Decimal(-100000) / 100)
    #expect(paid?.payee == "Savings Transfer")
    #expect(paid?.notes == "Monthly savings")
    #expect(paid?.legs.contains(where: { $0.categoryId == categoryId }) == true)
    #expect(paid?.legs.contains(where: { $0.earmarkId == earmarkId }) == true)
    #expect(paid?.recurPeriod == nil)
    #expect(paid?.recurEvery == nil)
  }

  // MARK: - Helpers

  /// Builds a fully-populated scheduled transfer for the "preserves all
  /// fields" assertion.
  private func makeScheduledTransfer(
    toAccountId: UUID,
    categoryId: UUID,
    earmarkId: UUID
  ) throws -> Transaction {
    Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "Savings Transfer",
      notes: "Monthly savings",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-100000) / 100,
          type: .transfer,
          categoryId: categoryId,
          earmarkId: earmarkId
        ),
        TransactionLeg(
          accountId: toAccountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(100000) / 100,
          type: .transfer
        ),
      ]
    )
  }
}
