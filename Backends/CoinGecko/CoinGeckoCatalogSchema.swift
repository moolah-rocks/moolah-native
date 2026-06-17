import Foundation

/// Single source of truth for the CoinGecko-catalogue SQLite schema.
/// Bump `version` whenever the on-disk shape changes; the catalogue
/// implementation drops and recreates the file rather than running a
/// migration.
///
/// The engine-owned `meta` / `etag` bookkeeping tables and the connection
/// PRAGMAs are provided by `CatalogDatabase.baseSchemaStatements(_:)`; this
/// type contributes only the CoinGecko-specific `coin` / `coin_platform` /
/// `platform` tables, the `coin_fts` virtual table and its sync triggers,
/// and the contract-lookup index. `schemaStatements(schemaVersion:)`
/// composes the engine base first, then the CoinGecko tables.
///
/// Retention: this is a derived cache of the public CoinGecko catalogue.
/// The whole table contents are replaced atomically on every successful
/// refresh (bounded by `maxAge` = 24 h in `CatalogRefresh`), and on a
/// schema-version mismatch the entire SQLite file is dropped and recreated
/// clean. The source of truth is the live CoinGecko API, so no per-row TTL
/// or scheduled purge migration is needed — `replaceAll` and the
/// drop-and-recreate path together bound staleness.
enum CoinGeckoCatalogSchema {
  static let version: Int = 2

  /// CoinGecko-specific tables, FTS index, and triggers. `coin`,
  /// `coin_platform`, and `platform` are `STRICT`; the FTS5 virtual table
  /// `coin_fts` and its triggers cannot be `STRICT` (FTS5 does not support
  /// it), so they remain plain.
  static let coinGeckoStatements: [String] = [
    """
    CREATE TABLE coin (
      rowid          INTEGER PRIMARY KEY,
      coingecko_id   TEXT NOT NULL UNIQUE,
      symbol         TEXT NOT NULL,
      name           TEXT NOT NULL
    ) STRICT;
    """,

    """
    CREATE TABLE coin_platform (
      coingecko_id     TEXT NOT NULL,
      platform_slug    TEXT NOT NULL,
      contract_address TEXT NOT NULL,
      PRIMARY KEY (coingecko_id, platform_slug),
      FOREIGN KEY (coingecko_id) REFERENCES coin(coingecko_id) ON DELETE CASCADE
    ) STRICT;
    """,

    """
    CREATE INDEX coin_platform_chain_contract
      ON coin_platform(platform_slug, contract_address);
    """,

    """
    CREATE TABLE platform (
      slug      TEXT PRIMARY KEY,
      chain_id  INTEGER,
      name      TEXT NOT NULL
    ) STRICT;
    """,

    """
    CREATE VIRTUAL TABLE coin_fts USING fts5(
      symbol, name,
      content='coin',
      content_rowid='rowid',
      tokenize='unicode61 remove_diacritics 1'
    );
    """,

    """
    CREATE TRIGGER coin_ai AFTER INSERT ON coin BEGIN
      INSERT INTO coin_fts(rowid, symbol, name) VALUES (new.rowid, new.symbol, new.name);
    END;
    """,

    """
    CREATE TRIGGER coin_ad AFTER DELETE ON coin BEGIN
      INSERT INTO coin_fts(coin_fts, rowid, symbol, name)
      VALUES('delete', old.rowid, old.symbol, old.name);
    END;
    """,

    """
    CREATE TRIGGER coin_au AFTER UPDATE ON coin BEGIN
      INSERT INTO coin_fts(coin_fts, rowid, symbol, name)
      VALUES('delete', old.rowid, old.symbol, old.name);
      INSERT INTO coin_fts(rowid, symbol, name) VALUES (new.rowid, new.symbol, new.name);
    END;
    """,
  ]

  /// Full DDL for a fresh catalog file: the engine-owned `meta` / `etag`
  /// tables (which MUST come first) followed by the CoinGecko tables.
  static func schemaStatements(schemaVersion: Int) -> [String] {
    CatalogDatabase.baseSchemaStatements(schemaVersion: schemaVersion) + coinGeckoStatements
  }

  /// Built-in priority order for picking a coin's preferred chain when it
  /// is listed on multiple platforms. Slugs not in this list fall through
  /// to the order returned from SQLite.
  static let platformPriority: [String] = [
    "ethereum",
    "polygon-pos",
    "binance-smart-chain",
    "base",
    "arbitrum-one",
    "optimism",
    "avalanche",
  ]
}
