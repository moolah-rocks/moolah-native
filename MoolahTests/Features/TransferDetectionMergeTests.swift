import Foundation
import Testing

@testable import Moolah

/// Merge / unmerge / manual-merge / atomicity / re-entrancy behaviour
/// for `TransferDetectionCoordinator`. Detection-pass behaviour lives
/// in `TransferDetectionScanTests`.
///
/// The construction sites here build the coordinator directly (rather
/// than via `Fixture.makeCoordinator`) so they can inject a wrapping
/// test-double repository.
@Suite("TransferDetectionCoordinator/Merge")
@MainActor
struct TransferDetectionMergeTests {
  private typealias Fixture = TransferDetectionFixture

  @Test
  func mergeProducesTwoLegTransferAndRemovesSources() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    await coordinator.merge(outgoing, incoming)

    #expect(coordinator.error == nil)
    #expect(coordinator.isMutating == false)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 1)
    let merged = try #require(all.first)
    #expect(all.contains { $0.id == outgoing.id } == false)
    #expect(all.contains { $0.id == incoming.id } == false)
    #expect(merged.legs.filter { $0.type == .transfer }.count == 2)
    // The suggestion record for the merged pair is gone.
    let suggestionId = TransferSuggestion.contentAddressedID(
      for: [outgoing.id, incoming.id])
    #expect(
      try await backend.transferSuggestions.fetchAll()
        .contains { $0.id == suggestionId } == false)
  }

  @Test
  func unmergeRoundTripsAndDoesNotResuggest() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)
    await coordinator.merge(outgoing, incoming)
    let merged = try #require(
      try await backend.transactions.fetchAll(
        filter: TransactionFilter()
      ).first)

    await coordinator.unmerge(merged)

    #expect(coordinator.error == nil)
    let splits = try await backend.transactions.fetchAll(
      filter: TransactionFilter())
    #expect(splits.count == 2)
    #expect(splits.contains { $0.id == merged.id } == false)

    // Unmerge writes no tombstone. None is needed: the split products
    // are not "newly imported", so a later detection pass never
    // re-evaluates them and cannot re-suggest the just-split pair.
    #expect(try await backend.transferSuggestions.fetchAll().isEmpty)
  }

  @Test
  func manualMergeRejectsSameAccount() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountA, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    await coordinator.manualMerge(outgoing, incoming)

    #expect(coordinator.error as? ManualMergeError == .sameAccount)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }

  @Test
  func manualMergeRejectsNotOppositeAmount() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 300, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    await coordinator.manualMerge(outgoing, incoming)

    #expect(coordinator.error as? ManualMergeError == .notOppositeAmount)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }

  @Test
  func manualMergeRejectsDatesTooFarApart() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let far = date.addingTimeInterval(TransferMergeBuilder.manualMergeWindowSeconds + 86_400)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: far)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    await coordinator.manualMerge(outgoing, incoming)

    #expect(coordinator.error as? ManualMergeError == .datesTooFarApart)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }

  @Test
  func manualMergeAcceptsWithinFourteenDayWindow() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let later = date.addingTimeInterval(10 * 86_400)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: later)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    await coordinator.manualMerge(outgoing, incoming)

    #expect(coordinator.error == nil)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 1)
    #expect(all.first?.legs.filter { $0.type == .transfer }.count == 2)
    let suggestionId = TransferSuggestion.contentAddressedID(
      for: [outgoing.id, incoming.id])
    #expect(
      try await backend.transferSuggestions.fetchAll()
        .contains { $0.id == suggestionId } == false)
  }

  @Test
  func mergeIsAtomicWhenReplaceThrows() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let failing = ReplaceFailingTransactionRepository(
      wrapping: backend.transactions)
    let coordinator = TransferDetectionCoordinator(
      transactions: failing,
      suggestions: backend.transferSuggestions)

    await coordinator.merge(outgoing, incoming)

    #expect(coordinator.error != nil)
    #expect(coordinator.isMutating == false)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
    #expect(all.contains { $0.id == outgoing.id })
    #expect(all.contains { $0.id == incoming.id })
  }

  @Test
  func secondMutationWhileFirstInFlightIsRejected() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let gated = GatedReplaceTransactionRepository(wrapping: backend.transactions)
    let coordinator = TransferDetectionCoordinator(
      transactions: gated,
      suggestions: backend.transferSuggestions)

    async let first: Void = coordinator.merge(outgoing, incoming)
    await gated.waitUntilReplaceStarted()
    // The first merge is suspended inside `replace`; a second mutating
    // call must be rejected synchronously with `.mutationInProgress`.
    await coordinator.merge(outgoing, incoming)
    #expect(coordinator.error as? TransferMergeError == .mutationInProgress)
    await gated.releaseReplace()
    await first

    // The first merge still committed (one merged transfer, both
    // sources gone) and the guard released. The rejection error from
    // the bounced second call is the last failure and stays on `error`
    // until the next action clears it — the success path of an
    // in-flight mutation does not retroactively wipe another call's
    // recorded rejection.
    #expect(coordinator.error as? TransferMergeError == .mutationInProgress)
    #expect(coordinator.isMutating == false)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 1)
    #expect(all.first?.legs.filter { $0.type == .transfer }.count == 2)
  }

  @Test
  func detectionWhileMutationInFlightIsRejected() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let gated = GatedReplaceTransactionRepository(wrapping: backend.transactions)
    let coordinator = TransferDetectionCoordinator(
      transactions: gated,
      suggestions: backend.transferSuggestions)

    async let merge: Void = coordinator.merge(outgoing, incoming)
    await gated.waitUntilReplaceStarted()
    // The merge is suspended inside `replace`; a detection pass shares
    // the same one-at-a-time gate and must be rejected synchronously
    // with `.mutationInProgress` rather than racing the in-flight write.
    await coordinator.runDetection(
      newlyImported: [outgoing, incoming],
      participatingAccountIds: [],
      windowLowerBound: date.addingTimeInterval(-86_400))
    #expect(coordinator.error as? TransferMergeError == .mutationInProgress)
    await gated.releaseReplace()
    await merge

    #expect(coordinator.error as? TransferMergeError == .mutationInProgress)
    #expect(coordinator.isMutating == false)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 1)
    #expect(all.first?.legs.filter { $0.type == .transfer }.count == 2)
  }

  @Test
  func mutationWhileDetectionInFlightIsRejected() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let gated = GatedFetchAllTransactionRepository(wrapping: backend.transactions)
    let coordinator = TransferDetectionCoordinator(
      transactions: gated,
      suggestions: backend.transferSuggestions)

    async let detection: Void = coordinator.runDetection(
      newlyImported: [outgoing, incoming],
      participatingAccountIds: [],
      windowLowerBound: date.addingTimeInterval(-86_400))
    await gated.waitUntilFetchAllStarted()
    // The detection pass is suspended inside `fetchAll`; a merge shares
    // the same gate and must be rejected synchronously.
    await coordinator.merge(outgoing, incoming)
    #expect(coordinator.error as? TransferMergeError == .mutationInProgress)
    await gated.releaseFetchAll()
    await detection

    #expect(coordinator.error as? TransferMergeError == .mutationInProgress)
    #expect(coordinator.isMutating == false)
  }
}
