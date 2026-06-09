import Foundation
import GRDB

/// One row in the `account_group` table.
///
/// **Instrument resolution.** The row stores `instrumentId: String`,
/// not a full `Instrument`. The repository reconstructs the `Instrument`
/// during `toDomain` using its `InstrumentRegistryRepository` lookup —
/// the registry disambiguates synced stock / crypto IDs from ambient
/// fiat (which has no `instrument` row).
struct AccountGroupRow {
  static let databaseTableName = "account_group"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case name
    case bucket
    case instrumentId = "instrument_id"
    case position
    case encodedSystemFields = "encoded_system_fields"
    case needsPush = "needs_push"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case name
    case bucket
    case instrumentId = "instrument_id"
    case position
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var name: String
  /// Raw value of `AccountBucket` (`"current"` / `"investments"`).
  /// Pinned by a CHECK constraint in the v14 migration.
  var bucket: String
  var instrumentId: String
  var position: Int
  var encodedSystemFields: Data?
}

extension AccountGroupRow: Codable {}
extension AccountGroupRow: Sendable {}
extension AccountGroupRow: Identifiable {}
extension AccountGroupRow: FetchableRecord {}
extension AccountGroupRow: PersistableRecord {}
extension AccountGroupRow: GRDBSystemFieldsStampable {}
