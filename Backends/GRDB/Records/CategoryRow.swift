// Backends/GRDB/Records/CategoryRow.swift

import Foundation
import GRDB

/// One row in the `category` table. Self-referential via `parentId`.
struct CategoryRow {
  static let databaseTableName = "category"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case name
    case parentId = "parent_id"
    case encodedSystemFields = "encoded_system_fields"
    case needsPush = "needs_push"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case name
    case parentId = "parent_id"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var name: String
  var parentId: UUID?
  var encodedSystemFields: Data?
}

extension CategoryRow: Codable {}
extension CategoryRow: Sendable {}
extension CategoryRow: Identifiable {}
extension CategoryRow: FetchableRecord {}
extension CategoryRow: PersistableRecord {}
extension CategoryRow: GRDBSystemFieldsStampable {}
