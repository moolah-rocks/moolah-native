// Backends/GRDB/Records/TransactionLegRow.swift

import Foundation
import GRDB

/// One row in the `transaction_leg` table. The leg's `instrument`
/// resolves to a full `Instrument` value at the boundary of
/// `+Mapping.swift` because `TransactionLeg` carries the resolved
/// instrument but the storage column is just the id.
struct TransactionLegRow {
  static let databaseTableName = "transaction_leg"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case transactionId = "transaction_id"
    case accountId = "account_id"
    case instrumentId = "instrument_id"
    case quantity
    case type
    case categoryId = "category_id"
    case earmarkId = "earmark_id"
    case sortOrder = "sort_order"
    case encodedSystemFields = "encoded_system_fields"
    case externalId = "external_id"
    case counterpartyAddress = "counterparty_address"
    case needsPush = "needs_push"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case transactionId = "transaction_id"
    case accountId = "account_id"
    case instrumentId = "instrument_id"
    case quantity
    case type
    case categoryId = "category_id"
    case earmarkId = "earmark_id"
    case sortOrder = "sort_order"
    case encodedSystemFields = "encoded_system_fields"
    case externalId = "external_id"
    case counterpartyAddress = "counterparty_address"
  }

  var id: UUID
  var recordName: String
  var transactionId: UUID
  var accountId: UUID?
  var instrumentId: String
  /// `Decimal × 10^8` storage form — see `InstrumentAmount.storageValue`.
  var quantity: Int64
  /// Raw value of `TransactionType`. CHECK constraint pins to
  /// `'income'`, `'expense'`, `'transfer'`, `'openingBalance'`.
  var type: String
  var categoryId: UUID?
  var earmarkId: UUID?
  var sortOrder: Int
  var encodedSystemFields: Data?
  /// Source-provided identifier for per-leg dedup across re-syncs.
  /// On-chain `txHash` for wallet-imported legs; `nil` for manual or
  /// CSV-imported legs. Partial-unique index enforces no duplicates per
  /// `(account_id, external_id)` for non-NULL values. Defaulted to
  /// `nil` so existing memberwise-init call sites continue to compile.
  var externalId: String?
  /// On-chain counterparty address (lowercased) for wallet-imported
  /// legs. `nil` for non-crypto legs, gas legs, and self-sends. No
  /// CHECK in the schema — the importer enforces shape upstream so
  /// non-EVM chains can land without a migration. Defaulted to `nil`
  /// so existing memberwise-init call sites continue to compile.
  var counterpartyAddress: String?
}

extension TransactionLegRow: Codable {}
extension TransactionLegRow: Sendable {}
extension TransactionLegRow: Identifiable {}
extension TransactionLegRow: FetchableRecord {}
extension TransactionLegRow: PersistableRecord {}
extension TransactionLegRow: GRDBSystemFieldsStampable {}
