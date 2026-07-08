// Backends/GRDB/Records/CategoryTaxOwnerRow.swift

import Foundation
import GRDB

struct CategoryTaxOwnerRow: Codable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "category_tax_owner"

  enum Columns: String, ColumnExpression {
    case categoryId = "category_id"
    case ownerId = "owner_id"
    case position
  }

  enum CodingKeys: String, CodingKey {
    case categoryId = "category_id"
    case ownerId = "owner_id"
    case position
  }

  var categoryId: UUID
  var ownerId: UUID
  var position: Int
}
