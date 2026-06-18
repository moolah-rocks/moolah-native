// Backends/GRDB/Records/CryptoTokenMetaRecord.swift

import Foundation
import GRDB

/// One row per token in `crypto_token_meta`. Records the display symbol and
/// the date span we have USD prices for.
///
/// Mirrors the `symbol` / `earliestDate` / `latestDate` fields on the
/// legacy `CryptoPriceCache` JSON struct.
struct CryptoTokenMetaRecord {
  static let databaseTableName = "crypto_token_meta"

  // `INSERT OR REPLACE` instead of GRDB's default `INSERT ... ON CONFLICT
  // DO UPDATE`. The latter hard-codes `RETURNING "rowid"` (see
  // GRDB 7's `MutablePersistableRecord+Upsert.swift`) which breaks
  // against this table's `WITHOUT ROWID` shape. No FK references this
  // table and no triggers fire on delete, so the delete-then-insert
  // semantics of `.replace` are observably equivalent here.
  static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .replace)

  enum Columns: String, ColumnExpression, CaseIterable {
    case tokenId = "token_id"
    case symbol
    case earliestDate = "earliest_date"
    case latestDate = "latest_date"
    case firstTradedOn = "first_traded_on"
  }

  // `CodingKeys` is required (not redundant with `Columns`): GRDB's
  // FetchableRecord/PersistableRecord conformance is Codable-derived, so
  // this enum drives the snake_case ⇄ camelCase mapping when rows decode
  // and parameters bind. `Columns` is consumed by the query interface only.
  enum CodingKeys: String, CodingKey {
    case tokenId = "token_id"
    case symbol
    case earliestDate = "earliest_date"
    case latestDate = "latest_date"
    case firstTradedOn = "first_traded_on"
  }

  var tokenId: String
  /// Display symbol (e.g. `"ETH"`). Not used for lookups; kept for support
  /// tooling.
  var symbol: String
  var earliestDate: String
  var latestDate: String
  /// Confirmed cross-provider first-trade date for this token (`YYYY-MM-DD`).
  /// `nil` means the date has not yet been confirmed.
  var firstTradedOn: String?
}

extension CryptoTokenMetaRecord: Codable {}
extension CryptoTokenMetaRecord: Sendable {}
extension CryptoTokenMetaRecord: FetchableRecord {}
extension CryptoTokenMetaRecord: PersistableRecord {}
