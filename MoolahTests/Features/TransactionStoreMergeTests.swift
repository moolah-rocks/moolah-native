import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/Merge")
@MainActor
struct TransactionStoreMergeTests {
  private func makeStore(backend: CloudKitBackend) -> TransactionStore {
    TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
  }

  private func tx(
    account: UUID, quantity: Decimal, payee: String, on date: Date
  ) -> Transaction {
    Transaction(
      date: date, payee: payee,
      legs: [
        TransactionLeg(
          accountId: account, instrument: .defaultTestInstrument,
          quantity: quantity, type: quantity < 0 ? .expense : .income)
      ])
  }

  @Test
  func mergeCombinesSelectionAndRemovesSources() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let account = UUID()
    let txA = tx(account: account, quantity: -10, payee: "Acme", on: date)
    let txB = tx(account: account, quantity: -20, payee: "Acme", on: date)
    TestBackend.seed(transactions: [txA, txB], in: database)
    let store = makeStore(backend: backend)

    await store.mergeTransactions([txA, txB])

    #expect(store.error == nil)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 1)
    let merged = try #require(all.first)
    #expect(merged.legs.count == 2)
    #expect(all.contains { $0.id == txA.id } == false)
    #expect(all.contains { $0.id == txB.id } == false)
  }

  @Test
  func mergeInvalidSelectionSurfacesErrorWithoutMutating() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let account = UUID()
    let txA = tx(account: account, quantity: -10, payee: "Acme", on: date)
    let txB = tx(account: account, quantity: -20, payee: "Other", on: date)
    TestBackend.seed(transactions: [txA, txB], in: database)
    let store = makeStore(backend: backend)

    await store.mergeTransactions([txA, txB])

    #expect(store.error != nil)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }
}
