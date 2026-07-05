// Backends/GRDB/ProfileSchema+DropCryptoCompareSymbol.swift

import Foundation
import GRDB

extension ProfileSchema {
  /// v20 migration body. Drops `cryptocompare_symbol` from the per-profile
  /// `instrument` table when it exists.
  ///
  /// CryptoCompare was removed as a price provider in 2026-07. The column
  /// carried the provider-specific symbol string used to build CryptoCompare
  /// API request URLs. No live code reads or writes this column after this
  /// migration.
  ///
  /// Graceful no-op: the `instrument` table was dropped by
  /// `v10_drop_shared_instrument_legacy` on every existing database. This
  /// migration only acts when the table still exists (e.g. a hypothetical
  /// database that was created and then immediately migrated from v3 straight
  /// to v20 without passing through v10 in a fresh run of all migrations from
  /// scratch). In practice all live databases reach here with no instrument
  /// table; the guard prevents a "no such table" failure in that case.
  ///
  /// The corresponding `ProfileIndexSchema` v10 migration drops the column
  /// from the shared instrument registry, which IS the live table.
  static func dropCryptoCompareSymbolColumn(_ database: Database) throws {
    guard try database.tableExists("instrument") else { return }
    let columns = try database.columns(in: "instrument")
    guard columns.contains(where: { $0.name == "cryptocompare_symbol" }) else { return }
    try database.execute(
      sql: """
        ALTER TABLE instrument DROP COLUMN cryptocompare_symbol;
        """)
  }
}
