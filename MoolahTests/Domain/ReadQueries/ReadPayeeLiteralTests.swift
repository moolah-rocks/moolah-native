import Foundation
import Testing

@testable import Moolah

struct ReadPayeeLiteralTests {
  @Test(arguments: ["%", "_", "\\"])
  func containsAndSuggestionsTreatWildcardsAsLiteralData(marker: String) async throws {
    let (backend, _) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_777_680_000)
    let literal = marker + " Fixture"
    let matching = Transaction(date: date, payee: literal, legs: [])
    _ = try await backend.transactions.create(matching)
    _ = try await backend.transactions.create(Transaction(date: date, payee: "Other", legs: []))
    let repository = try #require(backend.readQueries)
    let range = try ReadDateRange(interval: date..<date.addingTimeInterval(1), timeZone: .utc)
    let result = try await repository.transactions(
      search: ReadTransactionSearch(range: range, payeeQuery: marker), page: ReadPageRequest())
    #expect(result.items.map(\.id) == [matching.id])
    let suggestions = try await backend.transactions.fetchPayeeSuggestions(prefix: marker)
    #expect(suggestions == [literal])
    let excluding = try await backend.transactions.fetchPayeeSuggestions(
      prefix: marker, excludingTransactionId: matching.id)
    #expect(excluding.isEmpty)
  }
}
