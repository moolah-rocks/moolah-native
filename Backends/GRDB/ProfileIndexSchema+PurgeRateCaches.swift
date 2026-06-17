// Backends/GRDB/ProfileIndexSchema+PurgeRateCaches.swift

import Foundation
import GRDB

extension ProfileIndexSchema {
  /// Body of the `v6_purge_rate_caches` migration.
  ///
  /// Deletes every row from all six rate-cache tables in the profile-index
  /// database. The caches were built by the pre-contiguous fetch logic, which
  /// could leave arbitrary gaps between the recorded `earliest_date` and
  /// `latest_date` bounds; those bounds are now trusted as contiguous by the
  /// fixed `ContiguousFetchPlanner`-driven services, so stale gappy rows must
  /// be wiped before the new logic takes over.
  ///
  /// The tables are local, derived, and un-synced — safe to truncate. They
  /// re-warm automatically as the price services serve requests. Schema
  /// retention: `DATABASE_SCHEMA_GUIDE.md §9` (kept forever for historic
  /// conversion correctness) still applies; only the *rows* are purged, not
  /// the tables themselves.
  static func purgeRateCaches(_ database: Database) throws {
    try database.execute(
      sql: """
        DELETE FROM crypto_price;
        DELETE FROM crypto_token_meta;
        DELETE FROM stock_price;
        DELETE FROM stock_ticker_meta;
        DELETE FROM exchange_rate;
        DELETE FROM exchange_rate_meta;
        """)
  }
}
