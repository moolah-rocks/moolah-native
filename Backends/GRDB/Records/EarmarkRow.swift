// Backends/GRDB/Records/EarmarkRow.swift

import Foundation
import GRDB

/// One row in the `earmark` table.
///
/// **Legacy `savingsTargetInstrumentId`.** Earlier builds carried a
/// `savingsTargetInstrumentId` column for backwards compatibility with
/// records that stored the savings goal in a different instrument than
/// the earmark itself. The row preserves the column so existing
/// records round-trip byte-identically, but `toDomain()` always labels
/// the goal in the earmark's own `instrumentId`.
struct EarmarkRow {
  static let databaseTableName = "earmark"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case name
    case position
    case isHidden = "is_hidden"
    case instrumentId = "instrument_id"
    case savingsTarget = "savings_target"
    case savingsTargetInstrumentId = "savings_target_instrument_id"
    case savingsStartDate = "savings_start_date"
    case savingsEndDate = "savings_end_date"
    case encodedSystemFields = "encoded_system_fields"
    case needsPush = "needs_push"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case name
    case position
    case isHidden = "is_hidden"
    case instrumentId = "instrument_id"
    case savingsTarget = "savings_target"
    case savingsTargetInstrumentId = "savings_target_instrument_id"
    case savingsStartDate = "savings_start_date"
    case savingsEndDate = "savings_end_date"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var name: String
  var position: Int
  var isHidden: Bool
  /// Nullable column; domain reconstruction defaults to
  /// `defaultInstrument` when nil.
  var instrumentId: String?
  /// `Decimal × 10^8` storage form.
  var savingsTarget: Int64?
  /// Legacy column. `toDomain` ignores this and always labels the goal
  /// in the earmark's own `instrumentId`.
  var savingsTargetInstrumentId: String?
  var savingsStartDate: Date?
  var savingsEndDate: Date?
  var encodedSystemFields: Data?
}

extension EarmarkRow: Codable {}
extension EarmarkRow: Sendable {}
extension EarmarkRow: Identifiable {}
extension EarmarkRow: FetchableRecord {}
extension EarmarkRow: PersistableRecord {}
extension EarmarkRow: GRDBSystemFieldsStampable {}
