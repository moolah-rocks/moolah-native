// App/UnifiedInstrumentIdentityMigration+SharedDB.swift

import Foundation
import GRDB

extension UnifiedInstrumentIdentityMigration {
  /// Sets `alias_of` on every retired shared-registry row.
  /// Raw SQL — `alias_of` is a local-only column outside `InstrumentRow.CodingKeys`.
  /// Idempotent: writing the same value twice is a no-op (UPDATE sets the column
  /// to a value it already holds). All writes share one transaction so a
  /// mid-step throw rolls the shared DB back unchanged.
  func applyAliasStep(mapping: [String: String]) async throws {
    guard !mapping.isEmpty else { return }
    try await profileIndexDatabase.write { database in
      for (retired, canonical) in mapping {
        try database.execute(
          sql: "UPDATE instrument SET alias_of = ? WHERE id = ?",
          arguments: [canonical, retired])
      }
    }
  }

  /// Step 4 (design §4): fold retired price caches into the canonical's.
  ///
  /// Order of operations (order matters — MIN must read retired meta rows
  /// before they are deleted):
  /// 1. Update `crypto_token_meta.first_traded_on` on the canonical row to
  ///    MIN(canonical, all retireds), ignoring NULLs — so the canonical never
  ///    loses an earlier trade date. When all `first_traded_on` values are NULL
  ///    the EXISTS guard suppresses the UPDATE, leaving the canonical's NULL
  ///    unchanged.
  /// 2. DELETE the retired `crypto_price` rows.
  /// 3. DELETE the retired `crypto_token_meta` rows.
  ///
  /// Re-fetch of the deleted rows is cheap (precedent: v7_purge_crypto_price_cache).
  /// Idempotent: retired rows already deleted → DELETEs match nothing; MIN
  /// already applied → UPDATE is effectively a no-op.
  /// One atomic `write` transaction (DATABASE_CODE_GUIDE §5).
  func applyPriceCacheStep(mapping: [String: String]) async throws {
    guard !mapping.isEmpty else { return }
    let retiredByCanonical = mapping.reduce(into: [String: [String]]()) { acc, pair in
      acc[pair.value, default: []].append(pair.key)
    }
    try await profileIndexDatabase.write { database in
      for (canonical, retireds) in retiredByCanonical {
        // Build one SQL literal per token id so each value is bound, not
        // interpolated as SQL text (DATABASE_CODE_GUIDE §4).
        let ids = [canonical] + retireds
        let idsClause: SQL = ids.map { id -> SQL in "\(id)" }.joined(separator: ", ")
        // MIN ignores NULLs; the EXISTS guard prevents overwriting a canonical
        // NULL when no row in the group has a confirmed first_traded_on.
        try database.execute(
          literal: """
            UPDATE crypto_token_meta
               SET first_traded_on = (
                 SELECT MIN(first_traded_on) FROM crypto_token_meta
                  WHERE token_id IN (\(idsClause)) AND first_traded_on IS NOT NULL)
             WHERE token_id = \(canonical)
               AND EXISTS (
                 SELECT 1 FROM crypto_token_meta
                  WHERE token_id IN (\(idsClause)) AND first_traded_on IS NOT NULL)
            """)
        let retiredClause: SQL =
          retireds.map { id -> SQL in "\(id)" }.joined(separator: ", ")
        try database.execute(
          literal: "DELETE FROM crypto_price WHERE token_id IN (\(retiredClause))")
        try database.execute(
          literal: "DELETE FROM crypto_token_meta WHERE token_id IN (\(retiredClause))")
      }
    }
  }
}
