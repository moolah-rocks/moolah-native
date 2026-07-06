import Foundation
import Testing

@testable import Moolah

/// Coverage for `TransferDetectionCoordinator.mergeCertainSameCycleTransfers`
/// — the same-cycle cross-account auto-merge restored for the windowed sync
/// path. A CERTAIN pair (shared on-chain `externalId`, opposing
/// equal-magnitude value legs in one instrument on different accounts, both
/// within the newly-persisted set) is collapsed into one two-`.transfer`-leg
/// transfer, and its `TransferSuggestion` is deleted, so the fuzzy pass never
/// re-suggests it. Every other shape is left untouched for the fuzzy pass. The
/// whole batch is one atomic write — all pairs collapse or none do.
@Suite("TransferDetectionCoordinator/SameCycleMerge")
@MainActor
struct TransferDetectionSameCycleMergeTests {
  private typealias Fixture = TransferDetectionFixture

  private static let externalId = "0xhash:0"
  private static let date = Date(timeIntervalSince1970: 1_700_000_000)

  /// A single-value-leg transfer side carrying an `externalId` — the shape
  /// the per-account windowed apply persists before pairing.
  private static func side(
    id: UUID = UUID(),
    account: UUID,
    amount: Decimal,
    externalId: String,
    type: TransactionType
  ) -> Transaction {
    Fixture.cashTx(
      id: id, account: account, amount: amount, type: type, externalId: externalId,
      on: date)
  }

  // MARK: - Positive: a certain same-cycle pair is merged

  @Test("A certain same-externalId cross-account pair is merged into one transfer")
  func certainPairIsMerged() async throws {
    let (backend, database) = try TestBackend.create()
    let outgoing = Self.side(
      account: Fixture.accountA, amount: -250, externalId: Self.externalId, type: .expense)
    let incoming = Self.side(
      account: Fixture.accountB, amount: 250, externalId: Self.externalId, type: .income)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    // A stale fuzzy suggestion for the pair must be swept by the merge.
    _ = try await backend.transferSuggestions.create(
      TransferSuggestion(
        transactionIds: [outgoing.id, incoming.id], suggestedAt: Self.date))
    let coordinator = Fixture.makeCoordinator(backend: backend)

    let reduced = await coordinator.mergeCertainSameCycleTransfers(
      among: [outgoing, incoming])

    #expect(coordinator.error == nil)
    // The returned set replaces the two sides with one merged transfer.
    #expect(reduced.count == 1)
    let returnedMerged = try #require(reduced.first)
    #expect(returnedMerged.legs.filter { $0.type == .transfer }.count == 2)
    #expect(reduced.contains { $0.id == outgoing.id } == false)
    #expect(reduced.contains { $0.id == incoming.id } == false)

    // The DB row matches the returned identity: one merged transfer, both
    // sources deleted.
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 1)
    let persisted = try #require(all.first)
    #expect(persisted.id == returnedMerged.id)
    #expect(persisted.legs.filter { $0.type == .transfer }.count == 2)
    #expect(
      Set(persisted.legs.compactMap(\.accountId))
        == Set([Fixture.accountA, Fixture.accountB]))

    // The suggestion for the pair is gone.
    let suggestionId = TransferSuggestion.contentAddressedID(
      for: [outgoing.id, incoming.id])
    #expect(
      try await backend.transferSuggestions.fetchAll()
        .contains { $0.id == suggestionId } == false)
  }

  @Test("Two independent certain pairs in one cycle are both merged")
  func multipleCertainPairsAreEachMerged() async throws {
    let (backend, database) = try TestBackend.create()
    let accountC = UUID()
    let accountD = UUID()
    // Pair 1: A ⇄ B on "0xhashAB:0"; Pair 2: C ⇄ D on "0xhashCD:0".
    let outAB = Self.side(
      account: Fixture.accountA, amount: -250, externalId: "0xhashAB:0", type: .expense)
    let inAB = Self.side(
      account: Fixture.accountB, amount: 250, externalId: "0xhashAB:0", type: .income)
    let outCD = Self.side(
      account: accountC, amount: -99, externalId: "0xhashCD:0", type: .expense)
    let inCD = Self.side(
      account: accountD, amount: 99, externalId: "0xhashCD:0", type: .income)
    TestBackend.seed(transactions: [inAB, outAB, inCD, outCD], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    let reduced = await coordinator.mergeCertainSameCycleTransfers(
      among: [outAB, inAB, outCD, inCD])

    #expect(coordinator.error == nil)
    // Both pairs collapsed: two merged transfers, four sources gone.
    #expect(reduced.count == 2)
    #expect(reduced.allSatisfy { $0.legs.filter { $0.type == .transfer }.count == 2 })
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
    #expect(Set(all.map(\.id)) == Set(reduced.map(\.id)))
  }

  @Test("Re-running the merge over the already-merged set is a no-op")
  func mergeIsIdempotent() async throws {
    let (backend, database) = try TestBackend.create()
    let outgoing = Self.side(
      account: Fixture.accountA, amount: -250, externalId: Self.externalId, type: .expense)
    let incoming = Self.side(
      account: Fixture.accountB, amount: 250, externalId: Self.externalId, type: .income)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    let reduced = await coordinator.mergeCertainSameCycleTransfers(
      among: [outgoing, incoming])
    // A merged transfer carries two `.transfer` legs → nil value leg → it is
    // never re-paired; the second pass returns its input unchanged and writes
    // nothing new.
    let again = await coordinator.mergeCertainSameCycleTransfers(among: reduced)

    #expect(coordinator.error == nil)
    #expect(again.map(\.id) == reduced.map(\.id))
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 1)
  }

  // MARK: - Atomicity: a failed batch write leaves every source intact

  @Test("A throwing batch replace collapses no pair and returns the original set")
  func failedBatchWriteIsAllOrNothing() async throws {
    let (backend, database) = try TestBackend.create()
    // Two certain pairs — a multi-pair batch, so the single atomic replace
    // covers all four sources at once.
    let accountC = UUID()
    let accountD = UUID()
    let outAB = Self.side(
      account: Fixture.accountA, amount: -250, externalId: "0xhashAB:0", type: .expense)
    let inAB = Self.side(
      account: Fixture.accountB, amount: 250, externalId: "0xhashAB:0", type: .income)
    let outCD = Self.side(
      account: accountC, amount: -99, externalId: "0xhashCD:0", type: .expense)
    let inCD = Self.side(
      account: accountD, amount: 99, externalId: "0xhashCD:0", type: .income)
    TestBackend.seed(transactions: [inAB, outAB, inCD, outCD], in: database)
    let failing = ReplaceFailingTransactionRepository(wrapping: backend.transactions)
    let coordinator = TransferDetectionCoordinator(
      transactions: failing, suggestions: backend.transferSuggestions)

    let reduced = await coordinator.mergeCertainSameCycleTransfers(
      among: [outAB, inAB, outCD, inCD])

    // The write threw, so nothing was persisted and the ORIGINAL set is
    // returned unchanged (matching the still-separate DB rows the fuzzy pass
    // will see) — never a phantom-merged reduction.
    #expect(coordinator.error != nil)
    #expect(Set(reduced.map(\.id)) == Set([outAB.id, inAB.id, outCD.id, inCD.id]))
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 4)
  }

  // MARK: - Negatives: nothing merges, the input set is returned unchanged

  @Test("A same-account pair is not merged")
  func sameAccountPairIsNotMerged() async throws {
    let (backend, _) = try TestBackend.create()
    // Both sides on one account — the DB's `(account_id, external_id)` unique
    // constraint forbids this shape ever being persisted, so pass it purely
    // in-memory and assert the account-difference check in `isPair` rejects it
    // (no `replace` write ever runs).
    let outgoing = Self.side(
      account: Fixture.accountA, amount: -250, externalId: Self.externalId, type: .expense)
    let incoming = Self.side(
      account: Fixture.accountA, amount: 250, externalId: Self.externalId, type: .income)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    let reduced = await coordinator.mergeCertainSameCycleTransfers(
      among: [outgoing, incoming])

    #expect(coordinator.error == nil)
    #expect(Set(reduced.map(\.id)) == Set([outgoing.id, incoming.id]))
    // No merge write happened, so nothing was persisted.
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.isEmpty)
  }

  @Test("A different-externalId pair is not merged")
  func differentExternalIdPairIsNotMerged() async throws {
    let (backend, database) = try TestBackend.create()
    let outgoing = Self.side(
      account: Fixture.accountA, amount: -250, externalId: "0xhashA:0", type: .expense)
    let incoming = Self.side(
      account: Fixture.accountB, amount: 250, externalId: "0xhashB:0", type: .income)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    let reduced = await coordinator.mergeCertainSameCycleTransfers(
      among: [outgoing, incoming])

    #expect(coordinator.error == nil)
    #expect(Set(reduced.map(\.id)) == Set([outgoing.id, incoming.id]))
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }

  @Test("An unequal-magnitude pair is not merged")
  func unequalMagnitudePairIsNotMerged() async throws {
    let (backend, database) = try TestBackend.create()
    let outgoing = Self.side(
      account: Fixture.accountA, amount: -250, externalId: Self.externalId, type: .expense)
    let incoming = Self.side(
      account: Fixture.accountB, amount: 300, externalId: Self.externalId, type: .income)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    let reduced = await coordinator.mergeCertainSameCycleTransfers(
      among: [outgoing, incoming])

    #expect(coordinator.error == nil)
    #expect(Set(reduced.map(\.id)) == Set([outgoing.id, incoming.id]))
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }

  @Test("A pair whose mate is not in the newly-persisted set (cross-cycle) is untouched")
  func crossCycleMateIsNotMerged() async throws {
    let (backend, database) = try TestBackend.create()
    let outgoing = Self.side(
      account: Fixture.accountA, amount: -250, externalId: Self.externalId, type: .expense)
    // The mate is persisted (prior cycle) but NOT part of this cycle's set.
    let incoming = Self.side(
      account: Fixture.accountB, amount: 250, externalId: Self.externalId, type: .income)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    let reduced = await coordinator.mergeCertainSameCycleTransfers(among: [outgoing])

    #expect(coordinator.error == nil)
    #expect(reduced.map(\.id) == [outgoing.id])
    // Nothing collapsed: both rows still stand for the fuzzy cross-cycle pass.
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }
}
