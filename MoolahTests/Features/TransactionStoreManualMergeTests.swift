import Foundation
import Testing

@testable import Moolah

/// Store-level manual-merge / unmerge dispatch for `TransactionStore`.
/// These exercise the thin pass-throughs that the menu-bar / toolbar /
/// context-menu surfaces dispatch into. Coordinator-internal merge /
/// validation behaviour is covered by `TransferDetectionMergeTests`;
/// these assert the store wires the coordinator and surfaces its state.
@Suite("TransactionStore/ManualMerge")
@MainActor
struct TransactionStoreManualMergeTests {
  private typealias Fixture = TransferDetectionFixture

  /// Builds a `TransactionStore` with the transfer-suggestion repository
  /// wired so `store.transferDetection != nil` and `manualMerge` /
  /// `unmerge` reach the coordinator.
  private func makeStore(backend: CloudKitBackend) -> TransactionStore {
    TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument,
      transferSuggestions: backend.transferSuggestions)
  }

  @Test
  func manualMergeCollapsesSelectedPairAndRemovesSources() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let store = makeStore(backend: backend)

    await store.manualMerge(outgoing, incoming)

    #expect(store.transferDetection?.error == nil)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 1)
    let merged = try #require(all.first)
    #expect(all.contains { $0.id == outgoing.id } == false)
    #expect(all.contains { $0.id == incoming.id } == false)
    #expect(merged.legs.filter { $0.type == .transfer }.count == 2)
    #expect(merged.isMergedTransfer)
  }

  @Test
  func manualMergeInvalidSelectionSurfacesErrorWithoutMutating() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    // Same account: the coordinator must reject with `.sameAccount`
    // and leave both rows untouched.
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountA, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let store = makeStore(backend: backend)

    await store.manualMerge(outgoing, incoming)

    #expect(store.transferDetection?.error as? ManualMergeError == .sameAccount)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
    #expect(all.contains { $0.id == outgoing.id })
    #expect(all.contains { $0.id == incoming.id })
  }

  @Test
  func unmergeSplitsTransferWithoutWritingASuggestionRecord() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let store = makeStore(backend: backend)
    await store.manualMerge(outgoing, incoming)
    let merged = try #require(
      try await backend.transactions.fetchAll(filter: TransactionFilter()).first)
    #expect(merged.isMergedTransfer)

    await store.unmerge(merged)

    #expect(store.transferDetection?.error == nil)
    let splits = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(splits.count == 2)
    #expect(splits.contains { $0.id == merged.id } == false)
    // Unmerge writes no `TransferSuggestion` record — the split
    // products are not "newly imported", so a later detection pass
    // never re-evaluates them and cannot re-suggest the pair.
    let suggestions = try await backend.transferSuggestions.fetchAll()
    #expect(suggestions.isEmpty)
  }

  @Test
  func manualMergeWithoutCoordinatorIsNoOp() async throws {
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

    await store.manualMerge(outgoing, incoming)

    #expect(store.transferDetection == nil)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }
}

/// Unit coverage for the shared gating predicates the menu-bar /
/// toolbar / context-menu surfaces all call so the gate logic is not
/// triplicated inline in the views.
@Suite("Transaction/TransferMergeGate")
struct TransactionTransferMergeGateTests {
  private typealias Fixture = TransferDetectionFixture

  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  @Test
  func canManualMergeAcceptsOppositeCrossAccountPair() {
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    #expect(Transaction.canManualMerge(outgoing, with: incoming))
  }

  @Test
  func canManualMergeRejectsSameAccountPair() {
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountA, amount: 250, type: .income, on: date)
    #expect(Transaction.canManualMerge(outgoing, with: incoming) == false)
  }

  @Test
  func canManualMergeRejectsAlreadyMergedTransferLeg() {
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let merged = Transaction(
      date: date,
      legs: [
        TransactionLeg(
          accountId: Fixture.accountA, instrument: .defaultTestInstrument,
          quantity: -250, type: .transfer),
        TransactionLeg(
          accountId: Fixture.accountB, instrument: .defaultTestInstrument,
          quantity: 250, type: .transfer),
      ],
      importOrigin: .merged(MergedImportOrigin(outgoing: nil, incoming: nil)))
    #expect(Transaction.canManualMerge(outgoing, with: merged) == false)
  }

  @Test
  func isMergedTransferTrueForTwoLegTransferWithMergedOrigin() {
    let merged = Transaction(
      date: date,
      legs: [
        TransactionLeg(
          accountId: Fixture.accountA, instrument: .defaultTestInstrument,
          quantity: -250, type: .transfer),
        TransactionLeg(
          accountId: Fixture.accountB, instrument: .defaultTestInstrument,
          quantity: 250, type: .transfer),
      ],
      importOrigin: .merged(MergedImportOrigin(outgoing: nil, incoming: nil)))
    #expect(merged.isMergedTransfer)
  }

  @Test
  func isMergedTransferFalseForHandEnteredTransfer() {
    // A two-`.transfer`-leg transaction with no merged import origin is
    // a hand-entered transfer, not a detection merge — not unmergeable.
    let handEntered = Transaction(
      date: date,
      legs: [
        TransactionLeg(
          accountId: Fixture.accountA, instrument: .defaultTestInstrument,
          quantity: -250, type: .transfer),
        TransactionLeg(
          accountId: Fixture.accountB, instrument: .defaultTestInstrument,
          quantity: 250, type: .transfer),
      ])
    #expect(handEntered.isMergedTransfer == false)
  }

  @Test
  func isMergedTransferFalseForSingleLegCash() {
    let cash = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    #expect(cash.isMergedTransfer == false)
  }
}
