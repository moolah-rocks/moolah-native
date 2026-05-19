import Foundation
import Testing

@testable import Moolah

/// Store-level coverage for the record-backed transfer-suggestion read
/// path. `mergeSuggestedTransfer` / `dismissSuggestedTransfer` /
/// `hasSuggestion(for:)` must resolve the counterpart and the presence
/// gate from the synced `TransferSuggestion` record (never a
/// denormalised model field). Coordinator-internal merge / dismiss
/// behaviour is covered by `TransferDetectionMergeTests`; these assert
/// the store resolves through `backend.transferSuggestions`.
@Suite("TransactionStore/SuggestionReadPath")
@MainActor
struct TransactionStoreSuggestionReadPathTests {
  private typealias Fixture = TransferDetectionFixture

  private func makeStore(backend: CloudKitBackend) -> TransactionStore {
    TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument,
      transferSuggestions: backend.transferSuggestions)
  }

  @Test
  func mergeResolvesCounterpartFromRecordThenCollapsesAndDeletesRecord()
    async throws
  {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    _ = try await backend.transferSuggestions.create(
      TransferSuggestion(
        transactionIds: [outgoing.id, incoming.id], suggestedAt: date))
    let store = makeStore(backend: backend)

    await store.mergeSuggestedTransfer(outgoing)

    #expect(store.transferDetection?.error == nil)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 1)
    let merged = try #require(all.first)
    #expect(all.contains { $0.id == outgoing.id } == false)
    #expect(all.contains { $0.id == incoming.id } == false)
    #expect(merged.legs.filter { $0.type == .transfer }.count == 2)
    // Merge deletes the pair's suggestion record.
    #expect(try await backend.transferSuggestions.fetchAll().isEmpty)
  }

  @Test
  func dismissDeletesRecordAndLeavesBothTransactions() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    _ = try await backend.transferSuggestions.create(
      TransferSuggestion(
        transactionIds: [outgoing.id, incoming.id], suggestedAt: date))
    let store = makeStore(backend: backend)

    await store.dismissSuggestedTransfer(incoming)

    #expect(store.transferDetection?.error == nil)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
    #expect(all.contains { $0.id == outgoing.id })
    #expect(all.contains { $0.id == incoming.id })
    // Dismiss deletes the suggestion record so the pair is no longer
    // surfaced.
    #expect(try await backend.transferSuggestions.fetchAll().isEmpty)
  }

  @Test
  func hasSuggestionReflectsRecordPresence() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    let unrelated = Fixture.cashTx(
      account: Fixture.accountA, amount: -10, type: .expense, on: date)
    TestBackend.seed(
      transactions: [incoming, outgoing, unrelated], in: database)
    _ = try await backend.transferSuggestions.create(
      TransferSuggestion(
        transactionIds: [outgoing.id, incoming.id], suggestedAt: date))
    let store = makeStore(backend: backend)

    #expect(await store.hasSuggestion(for: outgoing))
    #expect(await store.hasSuggestion(for: incoming))
    #expect(await store.hasSuggestion(for: unrelated) == false)
  }

  @Test
  func noopWhenStoreHasNoSuggestionRepository() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    // No `transferSuggestions:` argument → no coordinator wired.
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.mergeSuggestedTransfer(outgoing)

    #expect(store.transferDetection == nil)
    #expect(await store.hasSuggestion(for: outgoing) == false)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }
}
