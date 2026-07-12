// Backends/GRDB/Records/InvestmentValueRow.swift

import Foundation
import GRDB

/// Legacy compatibility row retained only for CloudKit sync retirement.
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
