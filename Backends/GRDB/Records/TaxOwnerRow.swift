// Backends/GRDB/Records/TaxOwnerRow.swift

import Foundation
import GRDB

/// One row in the synced `tax_owner` table.
struct TaxOwnerRow {
  static let databaseTableName = "tax_owner"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case name
    case kind
    case encodedSystemFields = "encoded_system_fields"
    case needsPush = "needs_push"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case name
    case kind
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var name: String
  var kind: String
  var encodedSystemFields: Data?
}

extension TaxOwnerRow: Codable {}
extension TaxOwnerRow: Sendable {}
extension TaxOwnerRow: Identifiable {}
extension TaxOwnerRow: FetchableRecord {}
extension TaxOwnerRow: PersistableRecord {}
extension TaxOwnerRow: GRDBSystemFieldsStampable {}
