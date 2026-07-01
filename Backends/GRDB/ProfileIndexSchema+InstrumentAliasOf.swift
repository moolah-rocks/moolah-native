// Backends/GRDB/ProfileIndexSchema+InstrumentAliasOf.swift

import Foundation
import GRDB

// MARK: - v9 migration body
//
// Adds `instrument.alias_of` (nullable TEXT): a LOCAL-ONLY column pointing a
// retired cross-chain crypto instrument at its canonical id (e.g. the OP-ETH
// row `10:native` aliases `1:native`). It is deliberately absent from
// `InstrumentRow.Columns` / `CodingKeys` / `toCKRecord`, so every Codable
// upsert and every sync apply writes only the CloudKit-backed columns and
// cannot clobber it. It is written exclusively by raw SQL — the data
// migration and the sync apply path in later PRs — and read by
// `Column("alias_of")` / raw SQL (registry filter + resolver map build).
//
// The partial index covers the resolver's map-build query
// `SELECT id, alias_of FROM instrument WHERE alias_of IS NOT NULL`
// (per DATABASE_SCHEMA_GUIDE §4: the WHERE column `alias_of` is in the index,
// and the index carries both selected columns so the query is index-only).
// The index ships with the column in the same migration — v9 is one frozen
// unit.

extension ProfileIndexSchema {
  /// Body of the `v9_add_instrument_alias_of` migration.
  static func addInstrumentAliasOf(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE instrument
          ADD COLUMN alias_of TEXT
          CHECK (alias_of IS NULL OR alias_of != id);

        CREATE INDEX instrument_by_alias
          ON instrument (id, alias_of) WHERE alias_of IS NOT NULL;
        """)
  }
}
