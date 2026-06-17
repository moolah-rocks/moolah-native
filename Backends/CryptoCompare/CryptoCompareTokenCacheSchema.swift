import Foundation

/// Single source of truth for the CryptoCompare token-cache SQLite schema.
/// Bump `version` whenever the on-disk shape changes; the cache drops and
/// recreates the file rather than running a migration (see
/// `guides/DATABASE_SCHEMA_GUIDE.md`, drop-and-recreate-for-caches rule).
///
/// The engine-owned `meta` / `etag` bookkeeping tables and the connection
/// PRAGMAs are provided by `CatalogDatabase.baseSchemaStatements(_:)`; this
/// type contributes only the CryptoCompare-specific `cc_coin` table plus its
/// lookup indexes. `schemaStatements(schemaVersion:)` composes the engine base
/// first, then the CryptoCompare table.
///
/// Retention: this is a derived cache of CryptoCompare's public coin list. The
/// whole table is replaced atomically on every successful refresh (bounded by
/// `maxAge` = 24 h in `CatalogRefresh`), and a schema-version mismatch drops
/// and recreates the file clean. The source of truth is the live CryptoCompare
/// API, so no per-row TTL or scheduled purge is needed.
enum CryptoCompareTokenCacheSchema {
  static let version: Int = 1

  /// CryptoCompare-specific table and indexes. One row per `(symbol,
  /// contract_address)` pair: contract rows carry the lowercased contract
  /// address; symbol-only / native rows carry SQL `NULL`. `STRICT` per
  /// `guides/DATABASE_SCHEMA_GUIDE.md`.
  static let ccStatements: [String] = [
    """
    CREATE TABLE cc_coin (
      symbol            TEXT NOT NULL,
      contract_address  TEXT
    ) STRICT;
    """,
    "CREATE INDEX cc_coin_contract ON cc_coin(contract_address);",
    "CREATE INDEX cc_coin_symbol ON cc_coin(symbol);",
  ]

  /// Full DDL for a fresh cache file: the engine-owned `meta` / `etag` tables
  /// (which MUST come first) followed by the CryptoCompare table.
  static func schemaStatements(schemaVersion: Int) -> [String] {
    CatalogDatabase.baseSchemaStatements(schemaVersion: schemaVersion) + ccStatements
  }
}
