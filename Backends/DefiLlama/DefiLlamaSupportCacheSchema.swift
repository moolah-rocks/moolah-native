import Foundation

/// Schema for the local DefiLlama per-token support cache. Bump `version` to
/// force a drop-and-recreate (network-derived cache; no migration needed).
enum DefiLlamaSupportCacheSchema {
  static let version = 1

  static func schemaStatements(schemaVersion: Int) -> [String] {
    CatalogDatabase.baseSchemaStatements(schemaVersion: schemaVersion) + [
      """
      CREATE TABLE defillama_support (
        instrument_id  TEXT NOT NULL PRIMARY KEY,
        supported      INTEGER NOT NULL CHECK (supported IN (0, 1)),
        earliest_date  TEXT,
        last_checked   REAL NOT NULL
      ) STRICT;
      """
    ]
  }
}
