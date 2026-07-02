// App/UnifiedInstrumentIdentityMigration+ProfileRewrite.swift

import Foundation
import GRDB

extension UnifiedInstrumentIdentityMigration {
  /// Rewrites every stored `instrument_id` FK from a retired id to its
  /// canonical, marking each rewritten row `needs_push = 1`. FK enforcement is
  /// OFF (`v5_drop_foreign_keys`), so a plain UPDATE — never a rebuild. All
  /// statements share ONE `write` transaction: a throw rolls the whole profile
  /// back byte-identical to its pre-run state (DATABASE_CODE_GUIDE §5).
  /// Idempotent: canonical rows are not in `mapping` keys, so a re-run's
  /// `WHERE instrument_id = ?` (bound to a retired id) matches nothing.
  func rewriteProfile(_ profileId: UUID, mapping: [String: String]) async throws {
    guard !mapping.isEmpty else { return }
    let queue = try dataDatabaseProvider(profileId)
    let fault = faultAfterFirstStatementForTesting
    try await queue.write { database in
      let statements = try Self.rewriteStatements(database)
      var faultFired = false
      for (retired, canonical) in mapping {
        for statement in statements {
          try statement.execute(arguments: [canonical, retired])
          if !faultFired {
            faultFired = true
            try fault?(database)
          }
        }
      }
    }
  }

  /// Prepares one cached UPDATE per FK column, in mapping-key order. `needs_push`
  /// is set via raw SQL (absent from these records' CodingKeys). Order is
  /// irrelevant — each targets a distinct table or column. The FK columns live
  /// on `transaction_leg`, not `"transaction"`. `cachedStatement` skips
  /// re-preparation across the mapping loop (DATABASE_CODE_GUIDE §4); every
  /// `sql:` argument is a string literal. `nonisolated` so it is callable from
  /// within the `@Sendable` `database.write` closure without a main-actor hop.
  nonisolated static func rewriteStatements(_ database: Database) throws -> [Statement] {
    try [
      database.cachedStatement(
        sql: "UPDATE transaction_leg SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?"),
      database.cachedStatement(
        sql: "UPDATE earmark SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?"),
      // savings_target_instrument_id is a legacy column — rewrite so no stale id
      // survives even though toDomain() currently ignores it.
      database.cachedStatement(
        sql: "UPDATE earmark SET savings_target_instrument_id = ?, needs_push = 1 "
          + "WHERE savings_target_instrument_id = ?"),
      database.cachedStatement(
        sql:
          "UPDATE earmark_budget_item SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?"
      ),
      database.cachedStatement(
        sql: "UPDATE account_group SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?"),
      database.cachedStatement(
        sql: "UPDATE investment_value SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?"
      ),
      // Defensive: account.instrument_id is normally a fiat denomination, but the
      // schema does not enforce it — rewrite a retired crypto id if present.
      database.cachedStatement(
        sql: "UPDATE account SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?"),
    ]
  }
}
