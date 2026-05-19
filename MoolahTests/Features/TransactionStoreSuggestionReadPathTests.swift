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

  /// Blocks until the store's `observeAll()`-fed
  /// `suggestedTransactionIds` reflects the supplied membership.
  /// `hasSuggestion(for:)` is now a synchronous read of that observed
  /// set, so tests must let the suggestion observation settle before
  /// asserting — the `waitForNextEmission(matching:)` idiom, same as
  /// the data-observation suites. The predicate matching the current
  /// state returns immediately if the stream has already emitted.
  private func waitForSuggestionState(
    _ store: TransactionStore,
    contains ids: Set<UUID>,
    excludes excluded: Set<UUID> = []
  ) async throws {
    try await store.waitForNextEmission(
      matching: { snapshot in
        ids.isSubset(of: snapshot.suggestedTransactionIds)
          && excluded.isDisjoint(with: snapshot.suggestedTransactionIds)
      },
      description: "suggestion set contains \(ids), excludes \(excluded)")
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

    // Let the suggestion observation deliver the record before
    // dismissing so the post-dismiss "set is now empty" wait is
    // meaningful (not just observing the never-populated initial state).
    try await waitForSuggestionState(
      store, contains: [outgoing.id, incoming.id])

    await store.dismissSuggestedTransfer(incoming)

    #expect(store.transferDetection?.error == nil)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
    #expect(all.contains { $0.id == outgoing.id })
    #expect(all.contains { $0.id == incoming.id })
    // Dismiss deletes the suggestion record so the pair is no longer
    // surfaced.
    #expect(try await backend.transferSuggestions.fetchAll().isEmpty)
    // C1 regression guard: the store's reactive presence set must clear
    // for both sides once `observeAll()` delivers the deletion, so the
    // detail banner hides without a `transaction.id` change.
    try await waitForSuggestionState(
      store, contains: [], excludes: [outgoing.id, incoming.id])
    #expect(store.hasSuggestion(for: outgoing) == false)
    #expect(store.hasSuggestion(for: incoming) == false)
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

    try await waitForSuggestionState(
      store, contains: [outgoing.id, incoming.id], excludes: [unrelated.id])
    #expect(store.hasSuggestion(for: outgoing))
    #expect(store.hasSuggestion(for: incoming))
    #expect(store.hasSuggestion(for: unrelated) == false)
  }

  /// C1 regression guard, isolated: the detail banner derives its
  /// visibility from `hasSuggestion(for:)` (a sync read of the
  /// `observeAll()`-fed set). Before the fix, dismissing from detail
  /// deleted the record but the view's `.task(id: transaction.id)`
  /// never re-fired (the id is unchanged), so the banner stayed on
  /// screen. After the fix the store's reactive set must clear for
  /// both sides once the deletion streams back, hiding the banner with
  /// no id change.
  @Test
  func dismissClearsReactiveSuggestionPresenceForPair() async throws {
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

    try await waitForSuggestionState(
      store, contains: [outgoing.id, incoming.id])
    #expect(store.hasSuggestion(for: outgoing))
    #expect(store.hasSuggestion(for: incoming))

    await store.dismissSuggestedTransfer(outgoing)

    try await waitForSuggestionState(
      store, contains: [], excludes: [outgoing.id, incoming.id])
    #expect(store.hasSuggestion(for: outgoing) == false)
    #expect(store.hasSuggestion(for: incoming) == false)
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
    #expect(store.hasSuggestion(for: outgoing) == false)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }
}
