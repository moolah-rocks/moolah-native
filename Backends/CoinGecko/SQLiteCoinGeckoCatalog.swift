import Foundation
import SQLite3
import os

/// Catalogue actor backing `CoinGeckoCatalog` with a local SQLite database
/// at `<directory>/catalog.sqlite`. Public methods are `async`; all SQLite
/// work runs on the actor's serial executor so the connection is never
/// shared across threads. See design §4.1 / §6.
///
/// The SQLite engine (connection, `meta` / `etag` bookkeeping, the C-API
/// helpers, and the drop-and-recreate-on-version-mismatch bootstrap) lives
/// in the shared `CatalogDatabase`; this actor holds one and routes its
/// CoinGecko-specific replace-all / search / refresh / contract-lookup code
/// through `database.exec/prepare/bind/step/...`.
actor SQLiteCoinGeckoCatalog: CoinGeckoCatalog {
  /// Stateless `Logger`; `static` so every extension call site can emit on
  /// the same subsystem/category without rebuilding the logger.
  static let log = Logger(subsystem: "moolah.instrument-registry", category: "catalog")

  /// Resolves the CoinGecko key per refresh (not once at construction) so a
  /// Pro key entered in Settings flips the `/coins/list` + `/asset_platforms`
  /// refresh from the free public host to the authenticated Pro host on the
  /// next refresh.
  let apiKeyProvider: @Sendable () -> String?
  let networking: NetworkingServices
  let database: CatalogDatabase

  /// Opens or creates the on-disk catalog at `<directory>/catalog.sqlite`,
  /// then constructs the actor with the prepared `CatalogDatabase`. Factored
  /// out as a `static func` per CODE_GUIDE §10 so `init` can stay a
  /// memberwise property assignment — keeping the directory creation and
  /// SQLite bootstrap in one named place.
  static func make(
    directory: URL,
    apiKeyProvider: @Sendable @escaping () -> String?,
    networking: NetworkingServices
  ) throws -> SQLiteCoinGeckoCatalog {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true
    )
    let database = try CatalogDatabase.open(
      dbURL: directory.appendingPathComponent("catalog.sqlite"),
      schemaVersion: CoinGeckoCatalogSchema.version,
      schemaStatements: CoinGeckoCatalogSchema.schemaStatements(
        schemaVersion: CoinGeckoCatalogSchema.version))
    return SQLiteCoinGeckoCatalog(
      apiKeyProvider: apiKeyProvider,
      networking: networking,
      database: database)
  }

  private init(
    apiKeyProvider: @Sendable @escaping () -> String?,
    networking: NetworkingServices,
    database: CatalogDatabase
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.networking = networking
    self.database = database
  }

  isolated deinit {
    database.close()
  }

  // MARK: - CoinGeckoCatalog
  //
  // `search(query:limit:)` lives in `SQLiteCoinGeckoCatalog+Search.swift`.
  // `refreshIfStale()` lives in `SQLiteCoinGeckoCatalog+Refresh.swift`.

  // MARK: - Replace-all

  func replaceAll(coins: [RawCoin], platforms: [RawPlatform]) throws {
    try database.exec("BEGIN IMMEDIATE;")
    do {
      try database.exec("DELETE FROM coin;")
      try database.exec("DELETE FROM platform;")
      try insertCoins(coins)
      try insertPlatforms(platforms)
      try database.exec("COMMIT;")
    } catch {
      database.rollback()
      throw error
    }
  }

  func insertCoins(_ coins: [RawCoin]) throws {
    guard !coins.isEmpty else { return }
    var insertCoin: OpaquePointer?
    try database.prepare(
      "INSERT INTO coin (coingecko_id, symbol, name) VALUES (?, ?, ?);",
      into: &insertCoin)
    defer { sqlite3_finalize(insertCoin) }
    var insertCoinPlatform: OpaquePointer?
    try database.prepare(
      "INSERT INTO coin_platform (coingecko_id, platform_slug, contract_address) "
        + "VALUES (?, ?, ?);",
      into: &insertCoinPlatform)
    defer { sqlite3_finalize(insertCoinPlatform) }

    for coin in coins {
      try database.bind(insertCoin, at: 1, to: coin.id)
      try database.bind(insertCoin, at: 2, to: coin.symbol)
      try database.bind(insertCoin, at: 3, to: coin.name)
      try database.step(insertCoin)
      sqlite3_reset(insertCoin)

      for (slug, contract) in coin.platforms where !contract.isEmpty {
        try database.bind(insertCoinPlatform, at: 1, to: coin.id)
        try database.bind(insertCoinPlatform, at: 2, to: slug)
        try database.bind(insertCoinPlatform, at: 3, to: contract.lowercased())
        try database.step(insertCoinPlatform)
        sqlite3_reset(insertCoinPlatform)
      }
    }
  }

  func insertPlatforms(_ platforms: [RawPlatform]) throws {
    guard !platforms.isEmpty else { return }
    var insertPlatform: OpaquePointer?
    try database.prepare(
      "INSERT INTO platform (slug, chain_id, name) VALUES (?, ?, ?);",
      into: &insertPlatform)
    defer { sqlite3_finalize(insertPlatform) }
    for platform in platforms {
      try database.bind(insertPlatform, at: 1, to: platform.slug)
      if let chainId = platform.chainId {
        try database.bind(insertPlatform, at: 2, to: chainId)
      } else {
        sqlite3_bind_null(insertPlatform, 2)
      }
      try database.bind(insertPlatform, at: 3, to: platform.name)
      try database.step(insertPlatform)
      sqlite3_reset(insertPlatform)
    }
  }
}

// MARK: - Test seams
//
// The `RawCoin` / `RawPlatform` / `MetaSnapshot` value types and the
// `*ForTesting` accessors are module-internal so storage and refresh tests
// can exercise replace-all, meta read/write, and the stale-fetch guard
// without depending on the network refresh path. Production callers go
// through `search(query:limit:)` and `refreshIfStale()`. Hosting them in
// an extension keeps the actor body focused on production code paths.

extension SQLiteCoinGeckoCatalog {
  struct RawCoin: Sendable {
    let id: String
    let symbol: String
    let name: String
    /// platform slug → contract address (verbatim, normalised on insert)
    let platforms: [String: String]
  }

  struct RawPlatform: Sendable {
    let slug: String
    let chainId: Int?
    let name: String
  }

  /// Test-facing view of the engine-owned bookkeeping. `lastFetched` and the
  /// etags are sourced from the `CatalogDatabase` accessors (`meta` /
  /// `etag`), not from a CoinGecko-specific table.
  struct MetaSnapshot: Sendable, Equatable {
    let schemaVersion: Int
    let lastFetched: Date?
    let coinsEtag: String?
    let platformsEtag: String?
  }

  func replaceAllForTesting(coins: [RawCoin], platforms: [RawPlatform]) throws {
    try replaceAll(coins: coins, platforms: platforms)
  }

  func bumpLastFetchedBackwardForTesting(by seconds: TimeInterval) throws {
    try database.exec(
      "UPDATE meta SET last_fetched = COALESCE(last_fetched, 0) - \(seconds);"
    )
  }

  func readMetaForTesting() throws -> MetaSnapshot {
    MetaSnapshot(
      schemaVersion: try database.readSchemaVersion(),
      lastFetched: database.readLastFetched(),
      coinsEtag: database.readEtag(key: Self.coinsEndpointKey),
      platformsEtag: database.readEtag(key: Self.platformsEndpointKey)
    )
  }

  func coinCountForTesting() throws -> Int {
    try database.scalarInt("SELECT COUNT(*) FROM coin")
  }

  func platformCountForTesting() throws -> Int {
    try database.scalarInt("SELECT COUNT(*) FROM platform")
  }

  func coinPlatformCountForTesting() throws -> Int {
    try database.scalarInt("SELECT COUNT(*) FROM coin_platform")
  }

  func writeMetaSchemaVersionForTesting(_ version: Int) throws {
    var statement: OpaquePointer?
    try database.prepare("UPDATE meta SET schema_version = ?;", into: &statement)
    defer { sqlite3_finalize(statement) }
    try database.bind(statement, at: 1, to: version)
    try database.step(statement)
  }
}
