import Foundation
import GRDB

extension GRDBReadQueryRepository {
  /// Fetch only categories used by this report and their requested ancestors. Unrelated
  /// category history cannot block a small summary; every lookup uses the UUID index.
  func summaryCategories(
    flows: [ReadSummaryFlow],
    includeParents: Bool,
    database: Database
  ) throws -> [ReadCategoryDTO] {
    var pending = Set(flows.compactMap(\.categoryID))
    var categories: [UUID: ReadCategoryDTO] = [:]
    while !pending.isEmpty {
      try Task.checkCancellation()
      try validateSummaryCategoryCount(categories.count + pending.count)
      let rows = try Self.summaryCategoryRequest(ids: pending).fetchAll(database)
      guard rows.count == pending.count else { throw ReadCalculationError.invalidResult }
      for row in rows {
        categories[row.id] = ReadCategoryDTO(id: row.id, name: row.name, parentID: row.parentId)
      }
      pending = includeParents ? Set(rows.compactMap(\.parentId)).subtracting(categories.keys) : []
    }
    return categories.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { categories[$0] }
  }

  static func summaryCategoryRequest(ids: Set<UUID>) -> QueryInterfaceRequest<CategoryRow> {
    CategoryRow.filter(ids.contains(CategoryRow.Columns.id)).order(CategoryRow.Columns.id.asc)
      .limit(501)
  }

  private func validateSummaryCategoryCount(_ count: Int) throws {
    guard count <= 500 else {
      throw ReadLimitError(operation: .summaryGroups, unit: .calculationGroups, maximum: 500)
    }
  }
}
