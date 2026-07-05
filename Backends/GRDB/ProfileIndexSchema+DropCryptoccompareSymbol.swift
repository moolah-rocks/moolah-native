// Backends/GRDB/ProfileIndexSchema+DropCryptoccompareSymbol.swift

import Foundation
import GRDB

extension ProfileIndexSchema {
  /// v10 migration body. Drops `cryptocompare_symbol` from `instrument`
  /// in the shared profile-index database.
  ///
  /// CryptoCompare was removed as a price provider in 2026-07. The column
  /// carried the provider-specific symbol string used to build CryptoCompare
  /// API request URLs. No live code reads or writes this column after the v10
  /// migration; dropping it cleans up the shared instrument registry.
  ///
  /// Mirrors `ProfileSchema`'s v20 migration which does the same for each
  /// profile's per-profile `data.sqlite` instrument table (that table was
  /// dropped by v10_drop_shared_instrument_legacy, so only the index copy
  /// needs this migration).
  static func dropCryptocomplareSymbolColumn(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE instrument DROP COLUMN cryptocompare_symbol;
        """)
  }
}
