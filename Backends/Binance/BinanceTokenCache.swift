import Foundation
import SQLite3
import os

/// Self-refreshing local cache of Binance's active USDT trading pairs, backed
/// by a SQLite database at `<directory>/binance.sqlite`. Records each pair
/// symbol (e.g. `RPLUSDT`) so the token resolver can authorise a Binance
/// by-symbol price fallback without a network round-trip per lookup.
///
/// Public methods are `async`; all SQLite work runs on the actor's serial
/// executor so the connection is never shared across threads. The SQLite
/// engine (connection, `meta` / `etag` bookkeeping, the C-API helpers, and the
/// drop-and-recreate-on-version-mismatch bootstrap) lives in the shared
/// `CatalogDatabase`; this actor holds one and routes its Binance replace-all /
/// lookup / refresh code through `database.exec/prepare/...`.
///
/// Binance's `/api/v3/exchangeInfo` endpoint is keyless, so — unlike the
/// CryptoCompare cache — there is no API key to resolve.
actor BinanceTokenCache: RefreshableCatalog {
  /// Stateless `Logger`; `static` so every extension call site can emit on the
  /// same subsystem/category without rebuilding the logger.
  static let log = Logger(subsystem: "moolah.instrument-registry", category: "catalog")

  let networking: NetworkingServices
  let database: CatalogDatabase

  /// Opens or creates the on-disk cache at `<directory>/binance.sqlite`, then
  /// constructs the actor with the prepared `CatalogDatabase`. Factored out as
  /// a `static func` per CODE_GUIDE §10 so `init` stays a memberwise property
  /// assignment.
  static func make(
    directory: URL,
    networking: NetworkingServices
  ) throws -> BinanceTokenCache {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let database = try CatalogDatabase.open(
      dbURL: directory.appendingPathComponent("binance.sqlite"),
      schemaVersion: BinanceTokenCacheSchema.version,
      schemaStatements: BinanceTokenCacheSchema.schemaStatements(
        schemaVersion: BinanceTokenCacheSchema.version))
    return BinanceTokenCache(networking: networking, database: database)
  }

  private init(networking: NetworkingServices, database: CatalogDatabase) {
    self.networking = networking
    self.database = database
  }

  isolated deinit {
    database.close()
  }

  // MARK: - Query API
  //
  // Each query calls `loadIfEmpty()` first so a cold cache downloads once on
  // demand; a warm cache is a no-op. Lookups degrade to a "no answer" result
  // rather than throwing — token resolution treats an unavailable cache as
  // "no Binance pair known".

  /// Every active USDT trading-pair symbol present in the cache.
  func usdtPairs() async -> Set<String> {
    await loadIfEmpty()
    do {
      return try fetchPairs()
    } catch {
      Self.log.error("usdtPairs() failed: \(String(describing: error), privacy: .public)")
      return []
    }
  }

  private func fetchHasPair(_ pairSymbol: String) throws -> Bool {
    var statement: OpaquePointer?
    try database.prepare(
      "SELECT 1 FROM binance_pair WHERE pair_symbol = ? LIMIT 1;", into: &statement)
    defer { sqlite3_finalize(statement) }
    try database.bind(statement, at: 1, to: pairSymbol)
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private func fetchPairs() throws -> Set<String> {
    var statement: OpaquePointer?
    try database.prepare("SELECT pair_symbol FROM binance_pair;", into: &statement)
    defer { sqlite3_finalize(statement) }
    var result: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let symbol = database.readText(statement, column: 0) {
        result.insert(symbol)
      }
    }
    return result
  }

  /// Downloads the exchange-info listing once when the cache is empty. A no-op
  /// when warm (`refreshIfStale` itself short-circuits within `maxAge`, but the
  /// count check avoids even reading `last_fetched` on the hot path).
  /// Infallible: a read failure is logged and treated as "empty", so the
  /// subsequent query degrades to a "no answer" result rather than throwing.
  private func loadIfEmpty() async {
    let count: Int
    do {
      count = try database.scalarInt("SELECT COUNT(*) FROM binance_pair;")
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

// MARK: - BinancePairLookup

extension BinanceTokenCache: BinancePairLookup {
  /// Whether Binance lists an active `<symbol>USDT` trading pair for `symbol`
  /// (matched case-insensitively by uppercasing the base before composing the
  /// pair symbol). Infallible by design — any SQLite failure is logged and
  /// swallowed to `false`.
  func hasUsdtPair(base symbol: String) async -> Bool {
    await loadIfEmpty()
    let pairSymbol = "\(symbol.uppercased())USDT"
    do {
      return try fetchHasPair(pairSymbol)
    } catch {
      Self.log.error("hasUsdtPair(base:) failed: \(String(describing: error), privacy: .public)")
      return false
    }
  }
}
