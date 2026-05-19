import Foundation
import Testing

@testable import Moolah

/// Detection-pass behaviour for `TransferDetectionCoordinator`.
/// Merge / unmerge / manual-merge / atomicity / re-entrancy live in
/// `TransferDetectionMergeTests`.
@Suite("TransferDetectionCoordinator/Detection")
@MainActor
struct TransferDetectionScanTests {
  private typealias Fixture = TransferDetectionFixture

  @Test
  func detectionWritesOneSuggestionRecordForThePair() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming], in: database)
    let stamp = Date(timeIntervalSince1970: 1_700_500_000)
    let coordinator = Fixture.makeCoordinator(backend: backend, clock: { stamp })

    TestBackend.seed(transactions: [outgoing], in: database)
    await coordinator.runDetection(
      newlyImported: [outgoing],
      participatingAccountIds: [Fixture.accountA],
      windowLowerBound: date.addingTimeInterval(-86_400))

    #expect(coordinator.error == nil)
    let suggestions = try await backend.transferSuggestions.fetchAll()
    #expect(suggestions.count == 1)
    let suggestion = try #require(suggestions.first)
    #expect(suggestion.transactionIds == [outgoing.id, incoming.id])
    #expect(suggestion.suggestedAt == stamp)
    #expect(suggestion.counterpart(of: outgoing.id) == incoming.id)
    // The two transactions themselves are untouched.
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }

  @Test
  func dismissDeletesTheSuggestionRecord() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    await coordinator.runDetection(
      newlyImported: [outgoing],
      participatingAccountIds: [Fixture.accountA],
      windowLowerBound: date.addingTimeInterval(-86_400))
    #expect(coordinator.error == nil)
    #expect(try await backend.transferSuggestions.fetchAll().count == 1)

    await coordinator.dismiss(outgoing, incoming)

    #expect(coordinator.error == nil)
    #expect(try await backend.transferSuggestions.fetchAll().isEmpty)
  }

  @Test
  func detectionIsIdempotent() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(
      account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(
      account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)

    for _ in 0..<3 {
      await coordinator.runDetection(
        newlyImported: [outgoing],
        participatingAccountIds: [Fixture.accountA],
        windowLowerBound: date.addingTimeInterval(-86_400))
    }

    #expect(coordinator.error == nil)
    let suggestions = try await backend.transferSuggestions.fetchAll()
    #expect(suggestions.count == 1)
    #expect(suggestions.first?.counterpart(of: outgoing.id) == incoming.id)
  }

  @Test
  func alreadyMergedTransferIsNotResuggested() async throws {
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

    let merged = try await backend.transactions.fetchAll(
      filter: TransactionFilter())
    let mergedTx = try #require(merged.first)
    await coordinator.runDetection(
      newlyImported: [mergedTx],
      participatingAccountIds: [Fixture.accountA],
      windowLowerBound: date.addingTimeInterval(-86_400))

    #expect(coordinator.error == nil)
    let after = try await backend.transactions.fetchAll(
      filter: TransactionFilter())
    #expect(after.count == 1)
    #expect(try await backend.transferSuggestions.fetchAll().isEmpty)
  }
}
