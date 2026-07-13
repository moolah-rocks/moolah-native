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
    case implicitPlaceholderMarker = "is_implicit_placeholder"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case name
    case kind
    case encodedSystemFields = "encoded_system_fields"
    case implicitPlaceholderMarker = "is_implicit_placeholder"
  }

  var id: UUID
  var recordName: String
  var name: String
  var kind: String
  var encodedSystemFields: Data?
  /// `nil` only for rows that predate the local placeholder marker; otherwise
  /// `0` is explicit data and `1` is a local placeholder. The schema pins the
  /// integer domain. Bootstrap classifies the deterministic default owner, and
  /// all new local and remote rows write an explicit value.
  var implicitPlaceholderMarker: Int? = 0
}

extension TaxOwnerRow: Codable {}
extension TaxOwnerRow: Sendable {}
extension TaxOwnerRow: Identifiable {}
extension TaxOwnerRow: FetchableRecord {}
extension TaxOwnerRow: PersistableRecord {}
extension TaxOwnerRow: GRDBSystemFieldsStampable {}
