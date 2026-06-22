import Foundation
import Testing

@testable import Moolah

/// Locks in category-id filtering through `TransactionStore.load(filter:)`.
/// Issue #781: a regression in the filter-sheet binding chain meant the
/// store appeared to ignore category selections; the store + repository
/// path itself was always correct, and this suite pins it down so a
/// future re-break (e.g. a refactor that drops `categoryIds` from the
/// fetch arg) trips the test instead of the user.
@Suite("TransactionStore/CategoryFilter")
@MainActor
struct TransactionStoreCategoryFilterTests {
  private let accountId = UUID()

  @Test
  func testFilterByCategoryIds() async throws {
    let groceriesId = UUID()
    let transportId = UUID()
    let transactions = try makeTransactions(
      groceriesId: groceriesId, transportId: transportId)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(categoryIds: [groceriesId]))
    #expect(store.transactions.map(\.transaction.payee) == ["Woolworths"])

    await store.load(filter: TransactionFilter(categoryIds: [groceriesId, transportId]))
    let bothPayees = Set(store.transactions.compactMap(\.transaction.payee))
    #expect(bothPayees == ["Woolworths", "Caltex"])

    await store.load(filter: TransactionFilter())
    #expect(store.transactions.count == 3)
  }

  // MARK: - Helpers

  private func makeTransactions(
    groceriesId: UUID, transportId: UUID
  ) throws -> [Transaction] {
    [
      try expense(date: "2024-01-01", payee: "Woolworths", categoryId: groceriesId),
      try expense(date: "2024-01-02", payee: "Caltex", categoryId: transportId),
      try expense(date: "2024-01-03", payee: "Cash withdrawal", categoryId: nil),
    ]
  }

  private func expense(
    date: String, payee: String, categoryId: UUID?
  ) throws -> Transaction {
    Transaction(
      date: try TransactionStoreTestSupport.makeDate(date),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-1000) / 100,
          type: .expense,
          categoryId: categoryId
        )
      ]
    )
  }
}
