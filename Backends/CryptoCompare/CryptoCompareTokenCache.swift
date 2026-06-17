import Foundation
import SQLite3
import os

/// Self-refreshing local cache of CryptoCompare's coin list, backed by a
/// SQLite database at `<directory>/cryptocompare.sqlite`. Maps a token's
/// contract address to its CryptoCompare symbol, exposes the set of native
/// (contract-less) symbols, and the full symbol set — the inputs the token
/// resolver needs to authorise a CryptoCompare by-symbol price fallback.
///
/// Public methods are `async`; all SQLite work runs on the actor's serial
/// executor so the connection is never shared across threads. The SQLite
/// engine (connection, `meta` / `etag` bookkeeping, the C-API helpers, and
/// the drop-and-recreate-on-version-mismatch bootstrap) lives in the shared
/// `CatalogDatabase`; this actor holds one and routes its CryptoCompare
/// replace-all / lookup / refresh code through `database.exec/prepare/...`.
///
/// CryptoCompare's `/data/all/coinlist` endpoint now rejects keyless requests
/// with HTTP 401, so the refresh MUST send the configured `api_key`. The key
/// is resolved per refresh (not once at construction) so a key entered in
/// Settings takes effect on the next refresh.
actor CryptoCompareTokenCache: RefreshableCatalog {
  /// Stateless `Logger`; `static` so every extension call site can emit on
  /// the same subsystem/category without rebuilding the logger.
  static let log = Logger(subsystem: "moolah.instrument-registry", category: "catalog")

  let apiKeyProvider: @Sendable () -> String?
  let networking: NetworkingServices
  let database: CatalogDatabase

  /// Opens or creates the on-disk cache at `<directory>/cryptocompare.sqlite`,
  /// then constructs the actor with the prepared `CatalogDatabase`. Factored
  /// out as a `static func` per CODE_GUIDE §10 so `init` stays a memberwise
  /// property assignment.
  static func make(
    directory: URL,
    apiKeyProvider: @Sendable @escaping () -> String?,
    networking: NetworkingServices
  ) throws -> CryptoCompareTokenCache {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let database = try CatalogDatabase.open(
      dbURL: directory.appendingPathComponent("cryptocompare.sqlite"),
      schemaVersion: CryptoCompareTokenCacheSchema.version,
      schemaStatements: CryptoCompareTokenCacheSchema.schemaStatements(
        schemaVersion: CryptoCompareTokenCacheSchema.version))
    return CryptoCompareTokenCache(
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

  // MARK: - Query support
  //
  // Each query (in the `CryptoCompareSymbolLookup` conformance below) calls
  // `loadIfEmpty()` first so a cold cache downloads once on demand; a warm
  // cache is a no-op. Lookups degrade to empty rather than throwing — token
  // resolution treats an unavailable cache as "no answer".

  private func fetchSymbol(forContract address: String) throws -> String? {
    var statement: OpaquePointer?
    try database.prepare(
      "SELECT symbol FROM cc_coin WHERE contract_address = ? LIMIT 1;", into: &statement)
    defer { sqlite3_finalize(statement) }
    try database.bind(statement, at: 1, to: address)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return database.readText(statement, column: 0)
  }

  /// Runs `sql` (a single `symbol` column) and collects the non-null results.
  /// Read failures are logged and degrade to an empty set per the actor's
  /// no-throw contract.
  private func symbols(matching sql: String) -> Set<String> {
    do {
      return try fetchSymbols(matching: sql)
    } catch {
      Self.log.error("symbols(matching:) failed: \(String(describing: error), privacy: .public)")
      return []
    }
  }

  private func fetchSymbols(matching sql: String) throws -> Set<String> {
    var statement: OpaquePointer?
    try database.prepare(sql, into: &statement)
    defer { sqlite3_finalize(statement) }
    var result: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let symbol = database.readText(statement, column: 0) {
        result.insert(symbol)
      }
    }
    return result
  }

  /// Downloads the coin list once when the cache is empty. A no-op when warm
  /// (`refreshIfStale` itself short-circuits within `maxAge`, but the count
  /// check avoids even reading `last_fetched` on the hot path). Infallible:
  /// a read failure is logged and treated as "empty", so the subsequent query
  /// degrades to an empty answer rather than throwing.
  private func loadIfEmpty() async {
    let count: Int
    do {
      count = try database.scalarInt("SELECT COUNT(*) FROM cc_coin;")
    } catch {
      // A failed count read leaves the cache state unknown; log and fall
      // through to a refresh attempt rather than masking the failure.
      Self.log.error("loadIfEmpty count failed: \(String(describing: error), privacy: .public)")
      count = 0
    }
    guard count == 0 else { return }
    await refreshIfStale()
  }
}

// MARK: - CryptoCompareSymbolLookup

extension CryptoCompareTokenCache: CryptoCompareSymbolLookup {
  /// The CryptoCompare symbol registered for `address` (matched
  /// case-insensitively against the lowercased contract column), or `nil`.
  /// Infallible by design — any SQLite failure is logged and swallowed to
  /// `nil`, mirroring `SQLiteCoinGeckoCatalog.localContractMatch`.
  func symbol(forContract address: String) async -> String? {
    await loadIfEmpty()
    do {
      return try fetchSymbol(forContract: address.lowercased())
    } catch {
      Self.log.error("symbol(forContract:) failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  /// Symbols listed without a contract address (native / chain-agnostic).
  func nativeSymbols() async -> Set<String> {
    await loadIfEmpty()
    return symbols(matching: "SELECT symbol FROM cc_coin WHERE contract_address IS NULL;")
  }

  /// Every distinct symbol present in the cached coin list.
  func allSymbols() async -> Set<String> {
    await loadIfEmpty()
    return symbols(matching: "SELECT DISTINCT symbol FROM cc_coin;")
  }
}
