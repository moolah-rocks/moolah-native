// App/UnifiedInstrumentIdentityMigration+ProfileRewrite.swift

import Foundation
import GRDB

extension UnifiedInstrumentIdentityMigration {
  /// Step 2 (design §4): rewrite every stored `instrument_id` FK from a retired
  /// id to its canonical, marking each rewritten row `needs_push = 1`. FK
  /// enforcement is OFF (`v5_drop_foreign_keys`), so a plain UPDATE — never a
  /// rebuild. All statements share ONE `write` transaction: a throw rolls the
  /// whole profile back byte-identical to its pre-run state
  /// (DATABASE_CODE_GUIDE §5). Idempotent: canonical rows are not in `mapping`
  /// keys, so a re-run's `WHERE instrument_id = :retired` matches nothing.
  func rewriteProfile(_ profileId: UUID, mapping: [String: String]) async throws {
    guard !mapping.isEmpty else { return }
    let queue = try dataDatabaseProvider(profileId)
    let fault = faultAfterFirstStatement
    try await queue.write { database in
      var faultFired = false
      for (retired, canonical) in mapping {
        for statement in Self.rewriteStatements {
          try database.execute(sql: statement, arguments: [canonical, retired])
          if !faultFired {
            faultFired = true
            try fault?(database)
          }
        }
      }
    }
  }

  /// One UPDATE per FK column. `needs_push` set via raw SQL (absent from these
  /// records' CodingKeys). Order is irrelevant — each targets a distinct table
  /// or column. The FK columns live on `transaction_leg`, not `"transaction"`.
  /// `nonisolated` so the constant array is safely accessible from within the
  /// `@Sendable` `database.write` closure without a main-actor hop.
  nonisolated static let rewriteStatements: [String] = [
    "UPDATE transaction_leg     SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
    "UPDATE earmark             SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
    // savings_target_instrument_id is a legacy column — rewrite so no stale id
    // survives even though toDomain() currently ignores it.
    "UPDATE earmark             SET savings_target_instrument_id = ?, needs_push = 1 "
      + "WHERE savings_target_instrument_id = ?",
    "UPDATE earmark_budget_item SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
    "UPDATE account_group       SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
    "UPDATE investment_value    SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
    // Defensive: account.instrument_id is normally a fiat denomination, but the
    // schema does not enforce it — rewrite a retired crypto id if present.
    "UPDATE account             SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
  ]
}
