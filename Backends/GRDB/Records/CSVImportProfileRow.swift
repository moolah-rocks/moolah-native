// Backends/GRDB/Records/CSVImportProfileRow.swift

import Foundation
import GRDB

/// One row in the `csv_import_profile` table.
///
/// **Sync metadata.** `recordName` is the canonical CloudKit recordName
/// (`"CSVImportProfileRecord|<uuid>"`, see
/// `Backends/CloudKit/Sync/CKRecordIDRecordName.swift`).
/// `encodedSystemFields` holds the cached CKRecord change-tag blob;
/// these bytes are bit-for-bit copies of what CloudKit returned and
/// are never decoded outside the sync boundary.
struct CSVImportProfileRow {
  static let databaseTableName = "csv_import_profile"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case accountId = "account_id"
    case parserIdentifier = "parser_identifier"
    case headerSignature = "header_signature"
    case filenamePattern = "filename_pattern"
    case deleteAfterImport = "delete_after_import"
    case createdAt = "created_at"
    case lastUsedAt = "last_used_at"
    case dateFormatRawValue = "date_format_raw_value"
    case columnRoleRawValuesEncoded = "column_role_raw_values_encoded"
    case encodedSystemFields = "encoded_system_fields"
    case needsPush = "needs_push"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case accountId = "account_id"
    case parserIdentifier = "parser_identifier"
    case headerSignature = "header_signature"
    case filenamePattern = "filename_pattern"
    case deleteAfterImport = "delete_after_import"
    case createdAt = "created_at"
    case lastUsedAt = "last_used_at"
    case dateFormatRawValue = "date_format_raw_value"
    case columnRoleRawValuesEncoded = "column_role_raw_values_encoded"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var accountId: UUID
  var parserIdentifier: String
  /// Normalised CSV headers joined by the ASCII unit-separator (U+001F).
  /// See `Backends/GRDB/Records/CSVImportProfileRow+Mapping.swift` for
  /// the (de)serialisation helpers.
  var headerSignature: String
  var filenamePattern: String?
  var deleteAfterImport: Bool
  var createdAt: Date
  var lastUsedAt: Date?
  var dateFormatRawValue: String?
  /// Same unit-separator-joined encoding as `headerSignature`. `nil` when
  /// the user has not assigned column roles.
  var columnRoleRawValuesEncoded: String?
  var encodedSystemFields: Data?
}

extension CSVImportProfileRow: Codable {}
extension CSVImportProfileRow: Sendable {}
extension CSVImportProfileRow: Identifiable {}
extension CSVImportProfileRow: FetchableRecord {}
extension CSVImportProfileRow: PersistableRecord {}
extension CSVImportProfileRow: GRDBSystemFieldsStampable {}
