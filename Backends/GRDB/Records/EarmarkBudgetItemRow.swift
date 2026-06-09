// Backends/GRDB/Records/EarmarkBudgetItemRow.swift

import Foundation
import GRDB

/// One row in the `earmark_budget_item` table. Owned by an `EarmarkRow`
/// via `earmarkId` and references a `CategoryRow` via `categoryId`.
struct EarmarkBudgetItemRow {
  static let databaseTableName = "earmark_budget_item"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case earmarkId = "earmark_id"
    case categoryId = "category_id"
    case amount
    case instrumentId = "instrument_id"
    case encodedSystemFields = "encoded_system_fields"
    case needsPush = "needs_push"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case earmarkId = "earmark_id"
    case categoryId = "category_id"
    case amount
    case instrumentId = "instrument_id"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var earmarkId: UUID
  var categoryId: UUID
  /// `Decimal × 10^8` storage form (matches `InstrumentAmount.storageValue`).
  var amount: Int64
  /// Legacy column — `toDomain` prefers the owning earmark's instrument
  /// when available.
  var instrumentId: String
  var encodedSystemFields: Data?
}

extension EarmarkBudgetItemRow: Codable {}
extension EarmarkBudgetItemRow: Sendable {}
extension EarmarkBudgetItemRow: Identifiable {}
extension EarmarkBudgetItemRow: FetchableRecord {}
extension EarmarkBudgetItemRow: PersistableRecord {}
extension EarmarkBudgetItemRow: GRDBSystemFieldsStampable {}
