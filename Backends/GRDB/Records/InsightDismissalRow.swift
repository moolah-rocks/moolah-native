import Foundation
import GRDB

/// One row in the `insight_dismissal` table: a cumulative dismissal `count`
/// for a single `InsightKind`. `id` is deterministic from `kind` (see
/// `InsightDismissalRow.id(for:)`), so the row is content-addressed and
/// cross-device upserts merge instead of duplicating.
struct InsightDismissalRow {
  static let databaseTableName = "insight_dismissal"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case kind
    case count
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case kind
    case count
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  /// Raw value of `InsightKind`. `UNIQUE` in the schema.
  var kind: String
  var count: Int
  var encodedSystemFields: Data?
}

extension InsightDismissalRow: Codable {}
extension InsightDismissalRow: Sendable {}
extension InsightDismissalRow: Identifiable {}
extension InsightDismissalRow: FetchableRecord {}
extension InsightDismissalRow: PersistableRecord {}
extension InsightDismissalRow: GRDBSystemFieldsStampable {}
