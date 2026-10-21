import Foundation
import Testing

@testable import Moolah

struct ReadQueryRepositoryTests {
  @Test
  func transactionPagesUseDateAndUUIDTieBreakers() async throws {
    let (backend, _) = try TestBackend.create()
    let repository = try #require(backend.readQueries)
    let date = Date(timeIntervalSince1970: 1_777_680_000)
    let identifiers = [
      "00000000-0000-0000-0000-000000000001",
      "00000000-0000-0000-0000-000000000002",
      "00000000-0000-0000-0000-000000000003",
    ]
    for identifier in identifiers.reversed() {
      let id = try #require(UUID(uuidString: identifier))
      _ = try await backend.transactions.create(
        Transaction(
          id: id,
          date: date,
          payee: "Fixture",
          legs: []))
    }
    let search = try ReadTransactionSearch(
      range: ReadDateRange(
        interval: date..<date.addingTimeInterval(1),
        timeZone: .utc))
    let first = try await repository.transactions(search: search, page: ReadPageRequest(limit: 2))
    #expect(first.items.map(\.id.uuidString) == Array(identifiers.prefix(2)))
    #expect(first.hasMore)
    let last = try #require(first.items.last)
    let second = try await repository.transactions(
      search: search,
      page: ReadPageRequest(
        limit: 2,
        after: ReadPageKey(
          id: last.id,
          date: last.date),
        revision: first.revision))
    #expect(second.items.map(\.id.uuidString) == [identifiers[2]])
    #expect(!second.hasMore)
  }

  @Test
  func dataChangesExpirePreviouslyIssuedPages() async throws {
    let (backend, _) = try TestBackend.create()
    let repository = try #require(backend.readQueries)
    let first = try await repository.accounts(includeHidden: false, page: ReadPageRequest(limit: 1))
    let account = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)
    await #expect(throws: ReadQueryError.cursorExpired) {
      try await repository.accounts(
        includeHidden: false,
        page: ReadPageRequest(
          limit: 1,
          revision: first.revision))
    }
  }

  @Test
  func hiddenAccountsRequireExplicitInclusion() async throws {
    let (backend, _) = try TestBackend.create()
    let repository = try #require(backend.readQueries)
    _ = try await backend.accounts.create(
      Account(
        id: UUID(),
        name: "Hidden",
        type: .bank,
        instrument: .defaultTestInstrument,
        isHidden: true))
    let visible = try await repository.accounts(includeHidden: false, page: ReadPageRequest())
    let all = try await repository.accounts(includeHidden: true, page: ReadPageRequest())
    #expect(visible.items.isEmpty)
    #expect(all.items.count == 1)
  }

  @Test
  func oversizedPageRequestsFailBeforeReadingData() {
    #expect(throws: ReadQueryError.invalidFilter) { try ReadPageRequest(limit: 501) }
    #expect(throws: ReadQueryError.invalidFilter) { try ReadPageRequest(limit: 0) }
  }

  @Test
  func entityIDsAreResolvedOnlyInsideTheirProfileDatabase() async throws {
    let (first, _) = try TestBackend.create()
    let (second, _) = try TestBackend.create()
    let id = UUID()
    _ = try await first.transactions.create(
      Transaction(
        id: id,
        date: Date(),
        payee: "Private",
        legs: []))
    let repository = try #require(second.readQueries)
    await #expect(throws: ReadQueryError.notFound) { try await repository.transaction(id: id) }
  }
}
