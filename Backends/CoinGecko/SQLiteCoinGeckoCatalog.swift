import Foundation
import SQLite3
import os

/// Catalogue actor backing `CoinGeckoCatalog` with a local SQLite database
/// at `<directory>/catalog.sqlite`. Public methods are `async`; all SQLite
/// work runs on the actor's serial executor so the connection is never
/// shared across threads. See design §4.1 / §6.
actor SQLiteCoinGeckoCatalog: CoinGeckoCatalog {
  /// Stateless `Logger`; `static` so the nonisolated bootstrap path and the
  /// `static` SQLite helpers can both emit on the same subsystem/category
  /// without each call site rebuilding the logger.
  static let log = Logger(subsystem: "moolah.instrument-registry", category: "catalog")

  private let directory: URL
  /// Resolves the CoinGecko key per refresh (not once at construction) so a
  /// Pro key entered in Settings flips the `/coins/list` + `/asset_platforms`
  /// refresh from the free public host to the authenticated Pro host on the
  /// next refresh.
  let apiKeyProvider: @Sendable () -> String?
  let networking: NetworkingServices
  private(set) var database: OpaquePointer?

  // MARK: - Cross-extension internals
  //
  // Swift's `private` doesn't reach across files, so members called from
  // `+Search.swift`, `+Refresh.swift`, or `+SQLite.swift` drop their
  // `private` keyword and become module-internal. This is the closed
  // surface — callers outside `Backends/CoinGecko/` MUST NOT use them.
  //
  // Most low-level SQLite helpers (`exec`, `prepare`, `bind` ×2, `step`,
  // `rollback`, `readText`, `errorMessage` ×2, `scalarInt`) live in
  // `+SQLite.swift`.
  //
  // Used by +Search.swift only:    nothing in this file
  // Used by +Refresh.swift only:   `apiKeyProvider`, `networking`,
  //                                `replaceAll`, `insertCoins`,
  //                                `insertPlatforms`, `readMeta`
  // Used by both extensions:       `log` (static), `database` (read-only)

  /// Opens or creates the on-disk catalog at `<directory>/catalog.sqlite`,
  /// then constructs the actor with the prepared handle. Factored out as a
  /// `static func` per CODE_GUIDE §10 so `init` can stay a memberwise
  /// property assignment — keeping all the I/O and schema bootstrap
  /// (directory creation, SQLite open, version check, drop-and-recreate)
  /// in one named place.
  static func make(
    directory: URL,
    apiKeyProvider: @Sendable @escaping () -> String?,
    networking: NetworkingServices
  ) throws -> SQLiteCoinGeckoCatalog {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true
    )
    let database = try open(dbURL: directory.appendingPathComponent("catalog.sqlite"))
    return SQLiteCoinGeckoCatalog(
      directory: directory,
      apiKeyProvider: apiKeyProvider,
      networking: networking,
      database: database)
  }

  private init(
    directory: URL,
    apiKeyProvider: @Sendable @escaping () -> String?,
    networking: NetworkingServices,
    database: OpaquePointer
  ) {
    self.directory = directory
    self.apiKeyProvider = apiKeyProvider
    self.networking = networking
    self.database = database
  }

  isolated deinit {
    if let database { sqlite3_close_v2(database) }
  }

  // MARK: - CoinGeckoCatalog
  //
  // `search(query:limit:)` lives in `SQLiteCoinGeckoCatalog+Search.swift`.
  // `refreshIfStale()` lives in `SQLiteCoinGeckoCatalog+Refresh.swift`.

  // MARK: - Schema bootstrap
  //
  // Bootstrap helpers are `static` so they can run from the actor's
  // nonisolated `init`, before `self.database` is assigned. Once
  // initialisation is complete the live handle is stored on the actor and
  // every subsequent call routes through the actor-isolated wrappers
  // below, which re-use the same nonisolated SQLite helpers by passing
  // `self.database` as a parameter.

  private static func open(dbURL: URL) throws -> OpaquePointer {
    if FileManager.default.fileExists(atPath: dbURL.path) {
      let handle = try connect(dbURL: dbURL)
      var shouldClose = true
      defer { if shouldClose { sqlite3_close_v2(handle) } }

      let storedVersion = try readMeta(database: handle).schemaVersion
      if storedVersion != CoinGeckoCatalogSchema.version {
        // `shouldClose` is true; the defer closes the stale handle before
        // we recreate the file.
        try FileManager.default.removeItem(at: dbURL)
        // SQLite's WAL mode produces `<db>-wal` and `<db>-shm` sidecar
        // files; drop them too so the recreated database starts clean.
        try? FileManager.default.removeItem(
          at: URL(fileURLWithPath: dbURL.path + "-wal"))
        try? FileManager.default.removeItem(
          at: URL(fileURLWithPath: dbURL.path + "-shm"))
        return try createFresh(dbURL: dbURL)
      }
      shouldClose = false  // caller takes ownership
      return handle
    } else {
      return try createFresh(dbURL: dbURL)
    }
  }

  private static func connect(dbURL: URL) throws -> OpaquePointer {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let result = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
    guard result == SQLITE_OK, let handle else {
      throw CatalogError.sqlite("open failed: \(result)")
    }
    // Promote bare codes (e.g. `19 SQLITE_CONSTRAINT`) into specific
    // extended codes (e.g. `2067 SQLITE_CONSTRAINT_UNIQUE`) so log lines
    // pinpoint the actual failure mode. Combined with `sqlite3_errmsg(_:)`
    // pulled into our throw sites, a constraint violation surfaces as
    // `step 2067: UNIQUE constraint failed: coin.coingecko_id` instead of
    // bare `step 19`.
    sqlite3_extended_result_codes(handle, 1)
    return handle
  }

  private static func createFresh(dbURL: URL) throws -> OpaquePointer {
    let handle = try connect(dbURL: dbURL)
    for stmt in CoinGeckoCatalogSchema.statements {
      try exec(database: handle, stmt)
    }
    return handle
  }

  // MARK: - Replace-all

  static func replaceAll(
    database: OpaquePointer?,
    coins: [RawCoin],
    platforms: [RawPlatform]
  ) throws {
    try exec(database: database, "BEGIN IMMEDIATE;")
    do {
      try exec(database: database, "DELETE FROM coin;")
      try exec(database: database, "DELETE FROM platform;")
      try insertCoins(database: database, coins: coins)
      try insertPlatforms(database: database, platforms: platforms)
      try exec(database: database, "COMMIT;")
    } catch {
      rollback(database: database)
      throw error
    }
  }

  static func insertCoins(database: OpaquePointer?, coins: [RawCoin]) throws {
    guard !coins.isEmpty else { return }
    var insertCoin: OpaquePointer?
    try prepare(
      database: database,
      sql: "INSERT INTO coin (coingecko_id, symbol, name) VALUES (?, ?, ?);",
      into: &insertCoin)
    defer { sqlite3_finalize(insertCoin) }
    var insertCoinPlatform: OpaquePointer?
    try prepare(
      database: database,
      sql: "INSERT INTO coin_platform (coingecko_id, platform_slug, contract_address) "
        + "VALUES (?, ?, ?);",
      into: &insertCoinPlatform)
    defer { sqlite3_finalize(insertCoinPlatform) }

    for coin in coins {
      try bind(insertCoin, at: 1, to: coin.id)
      try bind(insertCoin, at: 2, to: coin.symbol)
      try bind(insertCoin, at: 3, to: coin.name)
      try step(insertCoin)
      sqlite3_reset(insertCoin)

      for (slug, contract) in coin.platforms where !contract.isEmpty {
        try bind(insertCoinPlatform, at: 1, to: coin.id)
        try bind(insertCoinPlatform, at: 2, to: slug)
        try bind(insertCoinPlatform, at: 3, to: contract.lowercased())
        try step(insertCoinPlatform)
        sqlite3_reset(insertCoinPlatform)
      }
    }
  }

  static func insertPlatforms(
    database: OpaquePointer?,
    platforms: [RawPlatform]
  ) throws {
    guard !platforms.isEmpty else { return }
    var insertPlatform: OpaquePointer?
    try prepare(
      database: database,
      sql: "INSERT INTO platform (slug, chain_id, name) VALUES (?, ?, ?);",
      into: &insertPlatform)
    defer { sqlite3_finalize(insertPlatform) }
    for platform in platforms {
      try bind(insertPlatform, at: 1, to: platform.slug)
      if let chainId = platform.chainId {
        try bind(insertPlatform, at: 2, to: chainId)
      } else {
        sqlite3_bind_null(insertPlatform, 2)
      }
      try bind(insertPlatform, at: 3, to: platform.name)
      try step(insertPlatform)
      sqlite3_reset(insertPlatform)
    }
  }

  // MARK: - Meta read / write

  static func readMeta(database: OpaquePointer?) throws -> MetaSnapshot {
    var statement: OpaquePointer?
    try prepare(
      database: database,
      sql: "SELECT schema_version, last_fetched, coins_etag, platforms_etag FROM meta LIMIT 1;",
      into: &statement)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw CatalogError.sqlite("meta table empty")
    }
    let version = Int(sqlite3_column_int64(statement, 0))
    let lastFetched: Date? = {
      let raw = sqlite3_column_double(statement, 1)
      if sqlite3_column_type(statement, 1) == SQLITE_NULL { return nil }
      return Date(timeIntervalSince1970: raw)
    }()
    let coinsEtag = readText(statement, column: 2)
    let platformsEtag = readText(statement, column: 3)
    return MetaSnapshot(
      schemaVersion: version,
      lastFetched: lastFetched,
      coinsEtag: coinsEtag,
      platformsEtag: platformsEtag
    )
  }

  // MARK: - Low-level SQLite helpers
  //
  // Live in `SQLiteCoinGeckoCatalog+SQLite.swift`.

  enum CatalogError: Error, Equatable {
    case sqlite(String)
    case network(String)
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

  struct MetaSnapshot: Sendable, Equatable {
    let schemaVersion: Int
    let lastFetched: Date?
    let coinsEtag: String?
    let platformsEtag: String?
  }

  func replaceAllForTesting(coins: [RawCoin], platforms: [RawPlatform]) throws {
    try Self.replaceAll(database: database, coins: coins, platforms: platforms)
  }

  func bumpLastFetchedBackwardForTesting(by seconds: TimeInterval) throws {
    try Self.exec(
      database: database,
      "UPDATE meta SET last_fetched = COALESCE(last_fetched, 0) - \(seconds);"
    )
  }

  func readMetaForTesting() throws -> MetaSnapshot {
    try Self.readMeta(database: database)
  }

  func coinCountForTesting() throws -> Int {
    try Self.scalarInt(database: database, "SELECT COUNT(*) FROM coin")
  }

  func platformCountForTesting() throws -> Int {
    try Self.scalarInt(database: database, "SELECT COUNT(*) FROM platform")
  }

  func coinPlatformCountForTesting() throws -> Int {
    try Self.scalarInt(database: database, "SELECT COUNT(*) FROM coin_platform")
  }

  func writeMetaSchemaVersionForTesting(_ version: Int) throws {
    var statement: OpaquePointer?
    try Self.prepare(
      database: database, sql: "UPDATE meta SET schema_version = ?;", into: &statement)
    defer { sqlite3_finalize(statement) }
    try Self.bind(statement, at: 1, to: version)
    try Self.step(statement)
  }
}
