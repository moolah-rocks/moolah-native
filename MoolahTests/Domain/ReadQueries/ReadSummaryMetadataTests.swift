import Foundation
import GRDB
import Testing

@testable import Moolah

struct ReadSummaryMetadataTests {
  @Test
  func summariesReadOnlyUsedCategoriesAndTheirRequestedAncestors() async throws {
    let (backend, database) = try TestBackend.create()
    let parent = try await backend.categories.create(Category(name: "Household"))
    let child = try await backend.categories.create(
      Category(name: "Groceries", parentId: parent.id)
    )
    let account = try await backend.accounts.create(
      Account(name: "Fixture", type: .bank, instrument: .defaultTestInstrument)
    )
    let date = Date(timeIntervalSince1970: 1_767_312_000)
    _ = try await backend.transactions.create(
      Transaction(
        date: date,
        legs: [
          TransactionLeg(
            accountId: account.id,
            instrument: .defaultTestInstrument,
            quantity: -7,
            type: .expense,
            categoryId: child.id
          )
        ]
      )
    )
    try await seedUnrelatedCategories(database)
    let repository = try #require(backend.readQueries)
    let range = try ReadDateRange(interval: date..<date.addingTimeInterval(1), timeZone: .utc)
    let full = try await repository.summaryInputs(
      query: query(range, grouping: .categoryMonth, includeParents: true)
    )
    #expect(Set(full.categories.map(\.id)) == [parent.id, child.id])
    let direct = try await repository.summaryInputs(
      query: query(range, grouping: .category, includeParents: false)
    )
    #expect(direct.categories.map(\.id) == [child.id])
    let ungrouped = try await repository.summaryInputs(
      query: query(range, grouping: .none, includeParents: true)
    )
    #expect(ungrouped.categories.isEmpty)
  }
  private func query(_ range: ReadDateRange, grouping: ReadSummaryGrouping, includeParents: Bool)
    -> ReadSummaryQuery
  {
    ReadSummaryQuery(
      range: range,
      grouping: grouping,
      includeNetWorth: false,
      includeParentTotals: includeParents
    )
  }

  private func seedUnrelatedCategories(_ database: DatabaseQueue) async throws {
    try await database.write { database in
      for index in 0..<501 {
        try CategoryRow(domain: Category(name: "Unrelated \(index)")).insert(database)
      }
    }
  }

}
