import Foundation
import GRDB

// MARK: - v8 migration body
//
// Adds `crypto_token_meta.first_traded_on` (nullable ISO YYYY-MM-DD): the
// confirmed cross-provider first-trade date for a token. NULL means "not yet
// confirmed". The crypto price path values any date strictly before this as
// $0 (.knownZero) instead of throwing — see
// `plans/2026-06-18-crypto-pre-listing-zero-valuation-design.md`.

extension ProfileIndexSchema {
  /// Body of the `v8_crypto_first_traded_on` migration.
  static func addCryptoFirstTradedOn(_ database: Database) throws {
    try database.execute(
      sql: "ALTER TABLE crypto_token_meta ADD COLUMN first_traded_on TEXT;")
  }
}
