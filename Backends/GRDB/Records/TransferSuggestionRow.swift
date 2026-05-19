import Foundation
import GRDB

/// One row in the `transfer_suggestion` table. The two transaction ids
/// are stored sorted (`transactionIdA` < `transactionIdB` by
/// `uuidString`) so a re-detection on any device upserts the same row.
struct TransferSuggestionRow {
  static let databaseTableName = "transfer_suggestion"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case transactionIdA = "transaction_id_a"
    case transactionIdB = "transaction_id_b"
    case suggestedAt = "suggested_at"
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case transactionIdA = "transaction_id_a"
    case transactionIdB = "transaction_id_b"
    case suggestedAt = "suggested_at"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var transactionIdA: UUID
  var transactionIdB: UUID
  var suggestedAt: Date
  var encodedSystemFields: Data?
}

extension TransferSuggestionRow: Codable {}
extension TransferSuggestionRow: Sendable {}
extension TransferSuggestionRow: Identifiable {}
extension TransferSuggestionRow: FetchableRecord {}
extension TransferSuggestionRow: PersistableRecord {}
extension TransferSuggestionRow: GRDBSystemFieldsStampable {}
