import Foundation

/// Single source of truth for the Binance token-cache SQLite schema. Bump
/// `version` whenever the on-disk shape changes; the cache drops and recreates
/// the file rather than running a migration (see
/// `guides/DATABASE_SCHEMA_GUIDE.md`, drop-and-recreate-for-caches rule).
///
/// The engine-owned `meta` / `etag` bookkeeping tables and the connection
/// PRAGMAs are provided by `CatalogDatabase.baseSchemaStatements(_:)`; this
/// type contributes only the Binance-specific `binance_pair` table.
/// `schemaStatements(schemaVersion:)` composes the engine base first, then the
/// Binance table.
///
/// Retention: this is a derived cache of Binance's public `exchangeInfo`
/// listing. The whole table is replaced atomically on every successful refresh
/// (bounded by `maxAge` = 24 h in `CatalogRefresh`), and a schema-version
/// mismatch drops and recreates the file clean. The source of truth is the
/// live Binance API, so no per-row TTL or scheduled purge is needed.
enum BinanceTokenCacheSchema {
  static let version: Int = 1

  /// Binance-specific table. One row per active USDT trading pair symbol
  /// (e.g. `RPLUSDT`), keyed by the pair symbol itself. `STRICT` per
  /// `guides/DATABASE_SCHEMA_GUIDE.md`.
  static let binanceStatements: [String] = [
    "CREATE TABLE binance_pair (pair_symbol TEXT NOT NULL PRIMARY KEY) STRICT;"
  ]

  /// Full DDL for a fresh cache file: the engine-owned `meta` / `etag` tables
  /// (which MUST come first) followed by the Binance table.
  static func schemaStatements(schemaVersion: Int) -> [String] {
    CatalogDatabase.baseSchemaStatements(schemaVersion: schemaVersion) + binanceStatements
  }
}
