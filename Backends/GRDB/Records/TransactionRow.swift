// Backends/GRDB/Records/TransactionRow.swift

import Foundation
import GRDB

/// One row in the `"transaction"` table. Carries the denormalised
/// `import_origin_*` columns directly — one column per `ImportOrigin`
/// field rather than a single JSON blob — so the CKRecord wire format
/// stays stable across the codebase.
///
/// `import_origin_kind` discriminates the `TransactionImportOrigin`
/// case: `"single"` projects through the eight existing
/// `import_origin_*` columns; `"merged"` projects the outgoing side
/// through those eight and the incoming side through the eight
/// `import_origin_incoming_*` columns. A null kind is a pre-v12 row
/// and reads as `.single`.
struct TransactionRow {
  static let databaseTableName = "transaction"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case date
    case payee
    case notes
    case recurPeriod = "recur_period"
    case recurEvery = "recur_every"
    case importOriginRawDescription = "import_origin_raw_description"
    case importOriginBankReference = "import_origin_bank_reference"
    case importOriginRawAmount = "import_origin_raw_amount"
    case importOriginRawBalance = "import_origin_raw_balance"
    case importOriginImportedAt = "import_origin_imported_at"
    case importOriginImportSessionId = "import_origin_import_session_id"
    case importOriginSourceFilename = "import_origin_source_filename"
    case importOriginParserIdentifier = "import_origin_parser_identifier"
    case importOriginKind = "import_origin_kind"
    case importOriginIncomingRawDescription = "import_origin_incoming_raw_description"
    case importOriginIncomingBankReference = "import_origin_incoming_bank_reference"
    case importOriginIncomingRawAmount = "import_origin_incoming_raw_amount"
    case importOriginIncomingRawBalance = "import_origin_incoming_raw_balance"
    case importOriginIncomingImportedAt = "import_origin_incoming_imported_at"
    case importOriginIncomingImportSessionId = "import_origin_incoming_import_session_id"
    case importOriginIncomingSourceFilename = "import_origin_incoming_source_filename"
    case importOriginIncomingParserIdentifier = "import_origin_incoming_parser_identifier"
    case encodedSystemFields = "encoded_system_fields"
    case needsPush = "needs_push"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case date
    case payee
    case notes
    case recurPeriod = "recur_period"
    case recurEvery = "recur_every"
    case importOriginRawDescription = "import_origin_raw_description"
    case importOriginBankReference = "import_origin_bank_reference"
    case importOriginRawAmount = "import_origin_raw_amount"
    case importOriginRawBalance = "import_origin_raw_balance"
    case importOriginImportedAt = "import_origin_imported_at"
    case importOriginImportSessionId = "import_origin_import_session_id"
    case importOriginSourceFilename = "import_origin_source_filename"
    case importOriginParserIdentifier = "import_origin_parser_identifier"
    case importOriginKind = "import_origin_kind"
    case importOriginIncomingRawDescription = "import_origin_incoming_raw_description"
    case importOriginIncomingBankReference = "import_origin_incoming_bank_reference"
    case importOriginIncomingRawAmount = "import_origin_incoming_raw_amount"
    case importOriginIncomingRawBalance = "import_origin_incoming_raw_balance"
    case importOriginIncomingImportedAt = "import_origin_incoming_imported_at"
    case importOriginIncomingImportSessionId = "import_origin_incoming_import_session_id"
    case importOriginIncomingSourceFilename = "import_origin_incoming_source_filename"
    case importOriginIncomingParserIdentifier = "import_origin_incoming_parser_identifier"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var date: Date
  var payee: String?
  var notes: String?
  /// Raw value of `RecurPeriod`. Pinned by a CHECK constraint.
  var recurPeriod: String?
  var recurEvery: Int?
  // ImportOrigin denormalised — each field is nullable to match the
  // domain `ImportOrigin` shape. Decimals stored as String to preserve
  // precision across the database ↔ CloudKit ↔ Domain round-trip.
  var importOriginRawDescription: String?
  var importOriginBankReference: String?
  var importOriginRawAmount: String?
  var importOriginRawBalance: String?
  var importOriginImportedAt: Date?
  var importOriginImportSessionId: UUID?
  var importOriginSourceFilename: String?
  var importOriginParserIdentifier: String?
  /// `TransactionImportOrigin` case discriminator: `"single"`,
  /// `"merged"`, or null for a pre-v12 row (which reads as `.single`).
  var importOriginKind: String?
  // Incoming side of a `.merged` origin. Mirrors the eight columns
  // above field-for-field; all null when the origin is `.single` or
  // absent.
  var importOriginIncomingRawDescription: String?
  var importOriginIncomingBankReference: String?
  var importOriginIncomingRawAmount: String?
  var importOriginIncomingRawBalance: String?
  var importOriginIncomingImportedAt: Date?
  var importOriginIncomingImportSessionId: UUID?
  var importOriginIncomingSourceFilename: String?
  var importOriginIncomingParserIdentifier: String?
  var encodedSystemFields: Data?
}

extension TransactionRow: Codable {}
extension TransactionRow: Sendable {}
extension TransactionRow: Identifiable {}
extension TransactionRow: FetchableRecord {}
extension TransactionRow: PersistableRecord {}
extension TransactionRow: GRDBSystemFieldsStampable {}
