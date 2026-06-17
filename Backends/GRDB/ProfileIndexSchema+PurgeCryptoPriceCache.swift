// Backends/GRDB/ProfileIndexSchema+PurgeCryptoPriceCache.swift

import Foundation
import GRDB

// MARK: - v7 migration body
//
// Empties the two crypto rate-cache tables in the profile-index database —
// `crypto_price` and `crypto_token_meta`.
//
// Why a one-shot purge: crypto daily prices fetched before the DefiLlama
// 12h-oversampling fix carry scattered single-day holes. DefiLlama's
// `period=1d` series snapped each point to the nearest real observation
// (~00:00 / ~23:59), which aliased against UTC-day buckets and dropped ~1 day
// in 5. The fixed client requests `period=12h`, but `ContiguousFetchPlanner`
// only ever extends a cache toward its `[earliest, latest]` bounds — it never
// re-fetches a date already inside them — so the existing interior gaps would
// persist forever. Wiping the rows forces a dense cold re-backfill.
//
// Both tables must go together: the bounds the planner trusts live in
// `crypto_token_meta`, so leaving the meta row would keep the planner treating
// the gappy interior as covered (`CryptoPriceService.loadCache` returns a
// hydrated cache whenever a meta row exists). The stock and exchange-rate
// caches use date-anchored providers without this aliasing, so they are left
// intact.
//
// The tables are local, derived, and un-synced — safe to truncate. They
// re-warm automatically as the price service serves requests.
// `DATABASE_SCHEMA_GUIDE.md §9`'s "rate caches kept forever" retention rule is
// unaffected — only the *rows* are purged, not the tables themselves.

extension ProfileIndexSchema {
  /// Body of the `v7_purge_crypto_price_cache` migration.
  ///
  /// Deletes every row from `crypto_price` and `crypto_token_meta` so the
  /// daily-gap rows cached before the DefiLlama 12h-oversampling fix
  /// re-backfill densely. Both tables together: the cache bounds that drive
  /// `ContiguousFetchPlanner` live in `crypto_token_meta`, so dropping only the
  /// prices would leave the planner believing the gappy interior is covered.
  static func purgeCryptoPriceCache(_ database: Database) throws {
    try database.execute(
      sql: """
        DELETE FROM crypto_price;
        DELETE FROM crypto_token_meta;
        """)
  }
}
