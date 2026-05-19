import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("TransferSuggestionRepository Contract")
struct TransferSuggestionRepoContractTests {
  @Test("creates and fetches a suggestion")
  func testCreateFetch() async throws {
    let repository = try makeRepository()
    let txA = UUID()
    let txB = UUID()
    let suggestion = TransferSuggestion(
      transactionIds: [txA, txB], suggestedAt: Date(timeIntervalSince1970: 1000))

    let created = try await repository.create(suggestion)

    #expect(created.id == suggestion.id)
    #expect(created.transactionIds == [txA, txB])

    let all = try await repository.fetchAll()
    #expect(all.count == 1)
    #expect(all[0].transactionIds == [txA, txB])
  }

  @Test("re-creating the same unordered pair is idempotent")
  func testIdempotentUpsert() async throws {
    let repository = try makeRepository()
    let txA = UUID()
    let txB = UUID()
    // Same unordered pair, reversed argument order, later timestamp.
    let first = TransferSuggestion(
      transactionIds: [txA, txB], suggestedAt: Date(timeIntervalSince1970: 1000))
    let second = TransferSuggestion(
      transactionIds: [txB, txA], suggestedAt: Date(timeIntervalSince1970: 5000))
    #expect(first.id == second.id, "Deterministic id must be order-independent")

    _ = try await repository.create(first)
    _ = try await repository.create(second)

    let all = try await repository.fetchAll()
    #expect(all.count == 1, "Re-creating the same pair must upsert, not duplicate")
    #expect(all[0].suggestedAt == Date(timeIntervalSince1970: 5000))
  }

  @Test("suggestions(touching:) returns every suggestion referencing the transaction")
  func testSuggestionsTouching() async throws {
    let repository = try makeRepository()
    let shared = UUID()
    let other1 = UUID()
    let other2 = UUID()
    let unrelatedA = UUID()
    let unrelatedB = UUID()
    let first = TransferSuggestion(
      transactionIds: [shared, other1], suggestedAt: Date(timeIntervalSince1970: 1))
    let second = TransferSuggestion(
      transactionIds: [other2, shared], suggestedAt: Date(timeIntervalSince1970: 2))
    let unrelated = TransferSuggestion(
      transactionIds: [unrelatedA, unrelatedB], suggestedAt: Date(timeIntervalSince1970: 3))
    _ = try await repository.create(first)
    _ = try await repository.create(second)
    _ = try await repository.create(unrelated)

    let touching = try await repository.suggestions(touching: shared)

    #expect(touching.count == 2)
    #expect(Set(touching.map(\.id)) == [first.id, second.id])
    #expect(!touching.contains { $0.id == unrelated.id })
  }

  @Test("delete(id:) removes the suggestion")
  func testDelete() async throws {
    let repository = try makeRepository()
    let suggestion = TransferSuggestion(
      transactionIds: [UUID(), UUID()], suggestedAt: Date(timeIntervalSince1970: 1))
    _ = try await repository.create(suggestion)

    try await repository.delete(id: suggestion.id)

    let all = try await repository.fetchAll()
    #expect(all.isEmpty)
  }

  @Test("observeAll emits the new suggestion after a create")
  func testObserveAllEmits() async throws {
    let repository = try makeRepository()
    var iterator = repository.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    let suggestion = TransferSuggestion(
      transactionIds: [UUID(), UUID()], suggestedAt: Date(timeIntervalSince1970: 1))
    _ = try await repository.create(suggestion)

    let afterCreate = await iterator.next()
    #expect(afterCreate?.count == 1)
    #expect(afterCreate?.first?.id == suggestion.id)
  }
}

private func makeRepository() throws -> any TransferSuggestionRepository {
  let pair = try TestBackend.create()
  return pair.backend.transferSuggestions
}
