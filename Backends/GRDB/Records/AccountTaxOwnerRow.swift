// Backends/GRDB/Records/AccountTaxOwnerRow.swift

import Foundation
import GRDB

struct AccountTaxOwnerRow: Codable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "account_tax_owner"

  enum Columns: String, ColumnExpression {
    case accountId = "account_id"
    case ownerId = "owner_id"
    case position
  }

  enum CodingKeys: String, CodingKey {
    case accountId = "account_id"
    case ownerId = "owner_id"
    case position
  }

  var accountId: UUID
  var ownerId: UUID
  var position: Int
}
