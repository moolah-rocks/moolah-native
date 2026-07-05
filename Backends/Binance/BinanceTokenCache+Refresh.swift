import Foundation
import SQLite3

/// ETag-aware refresh path for `BinanceTokenCache`. The staleness gate, the
/// conditional GET / `If-None-Match` loop, and the `last_fetched` / `etag`
/// persistence are delegated to the shared `CatalogRefresh`; this file owns
/// only the Binance endpoint wiring and the table-replace `apply` step. Hosted
/// in a separate file so the actor's primary body stays focused (CLAUDE.md,
/// `guides/CODE_GUIDE.md` §7).
extension BinanceTokenCache {
  /// `etag` table key and the key under which `CatalogRefresh` hands the
  /// fetched body back to `apply`.
  static let exchangeInfoEndpointKey = "exchangeInfo"

  /// Host whose rate-limit gate the refresh shares with the Binance price
  /// client.
  static let host = "api.binance.com"

  /// Performs a conditional GET against Binance's `/api/v3/exchangeInfo`,
  /// replacing `binance_pair` in a transaction and updating the engine-owned
  /// `last_fetched` / `etag` bookkeeping.
  ///
  /// Skipped when the prior fetch happened within `CatalogRefresh.maxAge`
  /// (24h). Silent on failure (logged via `os_log` and swallowed) — the cache
  /// degrades to a stale snapshot rather than propagating errors to UI.
  /// `CatalogRefresh.run` PROPAGATES on failure; the `do/catch` here is the
  /// graceful-degradation boundary, and because `run` persists `last_fetched`
  /// only after a successful `apply`, a thrown network error leaves
  /// `last_fetched` at its previous value and the next launch retries. The
  /// endpoint is keyless, so no API key is sent.
  func refreshIfStale() async {
    do {
      let http = networking.client(forHost: Self.host)
      let endpoints = [
        CatalogEndpoint(
          key: Self.exchangeInfoEndpointKey,
          url: BinanceClient.exchangeInfoURL())
      ]
      try await CatalogRefresh.run(
        database: database,
        endpoints: endpoints,
        http: http,
        now: Date()
      ) { bodies in
        try self.applyRefresh(bodies: bodies)
      }
    } catch {
      Self.log.error("refresh failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// Translates the changed-endpoint body from `CatalogRefresh` into a full
  /// `binance_pair` replace. An absent key means the endpoint returned 304
  /// (unchanged), so the existing snapshot is preserved.
  private func applyRefresh(bodies: [String: Data]) throws {
    guard let data = bodies[Self.exchangeInfoEndpointKey] else { return }
    try replaceAll(pairs: BinanceClient.parseExchangeInfoResponse(data))
  }

  /// Atomically replaces the whole `binance_pair` table inside a single
  /// `BEGIN IMMEDIATE` transaction, rolling back on any error.
  func replaceAll(pairs: Set<String>) throws {
    try database.exec("BEGIN IMMEDIATE;")
    do {
      try database.exec("DELETE FROM binance_pair;")
      try insertPairs(pairs)
      try database.exec("COMMIT;")
    } catch {
      database.rollback()
      throw error
    }
  }

  private func insertPairs(_ pairs: Set<String>) throws {
    guard !pairs.isEmpty else { return }
    var insert: OpaquePointer?
    try database.prepare(
      "INSERT OR IGNORE INTO binance_pair (pair_symbol) VALUES (?);", into: &insert)
    defer { sqlite3_finalize(insert) }
    for pair in pairs {
      try database.bind(insert, at: 1, to: pair)
      try database.step(insert)
      sqlite3_reset(insert)
    }
  }
}

// MARK: - Test seams

extension BinanceTokenCache {
  /// Replaces the whole table with `pairs`. Module-internal so storage tests
  /// can seed the cache without driving the network refresh path.
  func replaceAllForTesting(pairs: Set<String>) throws {
    try replaceAll(pairs: pairs)
  }

  /// Current `binance_pair` row count. Module-internal for tests.
  func countForTesting() throws -> Int {
    try database.scalarInt("SELECT COUNT(*) FROM binance_pair;")
  }
}
