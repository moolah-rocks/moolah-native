// Backends/GRDB/Records/InvestmentValueRow.swift

import Foundation
import GRDB

/// One row in the `investment_value` table.
///
/// Composite uniqueness on `(account_id, date)` is enforced at the
/// repository layer, not as a SQL UNIQUE constraint —
/// `setValue(accountId:date:value:)` does an explicit
/// `SELECT … LIMIT 1; UPDATE / INSERT`.
struct InvestmentValueRow {
  static let databaseTableName = "investment_value"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case accountId = "account_id"
    case date
    case value
    case instrumentId = "instrument_id"
    case encodedSystemFields = "encoded_system_fields"
    case needsPush = "needs_push"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case accountId = "account_id"
    case date
    case value
    case instrumentId = "instrument_id"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var accountId: UUID
  var date: Date
  /// `Decimal × 10^8` storage form — see `InstrumentAmount.storageValue`.
  var value: Int64
  var instrumentId: String
  var encodedSystemFields: Data?
}

extension InvestmentValueRow: Codable {}
extension InvestmentValueRow: Sendable {}
extension InvestmentValueRow: Identifiable {}
extension InvestmentValueRow: FetchableRecord {}
extension InvestmentValueRow: PersistableRecord {}
extension InvestmentValueRow: GRDBSystemFieldsStampable {}
