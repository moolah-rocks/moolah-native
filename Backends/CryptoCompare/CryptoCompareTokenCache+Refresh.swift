import Foundation
import SQLite3

/// ETag-aware refresh path for `CryptoCompareTokenCache`. The staleness gate,
/// the conditional GET / `If-None-Match` loop, and the `last_fetched` / `etag`
/// persistence are delegated to the shared `CatalogRefresh`; this file owns
/// only the CryptoCompare endpoint wiring, the row building, and the
/// table-replace `apply` step. Hosted in a separate file so the actor's
/// primary body stays focused (CLAUDE.md, `guides/CODE_GUIDE.md` §7).
extension CryptoCompareTokenCache {
  /// `etag` table key and the key under which `CatalogRefresh` hands the
  /// fetched body back to `apply`.
  static let coinListEndpointKey = "coinlist"

  /// Host whose rate-limit gate the refresh shares with the CryptoCompare
  /// price client.
  static let host = "min-api.cryptocompare.com"

  /// Performs a conditional GET against CryptoCompare's `/data/all/coinlist`,
  /// replacing `cc_coin` in a transaction and updating the engine-owned
  /// `last_fetched` / `etag` bookkeeping.
  ///
  /// Skipped when the prior fetch happened within `CatalogRefresh.maxAge`
  /// (24h). Silent on failure (logged via `os_log` and swallowed) — the cache
  /// degrades to a stale snapshot rather than propagating errors to UI.
  /// `CatalogRefresh.run` PROPAGATES on failure; the `do/catch` here is the
  /// graceful-degradation boundary, and because `run` persists `last_fetched`
  /// only after a successful `apply`, a thrown network error leaves
  /// `last_fetched` at its previous value and the next launch retries.
  func refreshIfStale() async {
    do {
      // Resolve the key per refresh so a key entered in Settings takes effect
      // on the next refresh. CryptoCompare's coin-list endpoint rejects
      // keyless requests with HTTP 401, so the key is what restores access.
      let apiKey = apiKeyProvider() ?? ""
      let http = networking.client(forHost: Self.host)
      let endpoints = [
        CatalogEndpoint(
          key: Self.coinListEndpointKey,
          url: Self.coinListURL(apiKey: apiKey))
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

  /// Coin-list URL carrying `summary=true` and the authenticating `api_key`
  /// query item. `CryptoCompareClient.coinListURL()` is key-less, so this
  /// builder appends the key the cache refresh requires.
  private static func coinListURL(apiKey: String) -> URL {
    let base = CryptoCompareClient.coinListURL()
    guard !apiKey.isEmpty,
      var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    else { return base }
    var items = components.queryItems ?? []
    items.append(URLQueryItem(name: "api_key", value: apiKey))
    components.queryItems = items
    return components.url ?? base
  }

  /// Translates the changed-endpoint body from `CatalogRefresh` into a full
  /// `cc_coin` replace. An absent key means the endpoint returned 304
  /// (unchanged), so the existing snapshot is preserved.
  private func applyRefresh(bodies: [String: Data]) throws {
    guard let data = bodies[Self.coinListEndpointKey] else { return }
    try replaceAll(rows: Self.parseRows(data))
  }

  /// Builds the `cc_coin` rows from a coin-list body, reusing the public
  /// `CryptoCompareClient` parsers. Contract entries become contract-carrying
  /// rows (lowercased address); every symbol with no contract (native /
  /// chain-agnostic listings) becomes a `NULL`-contract row, so `allSymbols`
  /// covers the full catalog and `nativeSymbols` returns the contract-less set.
  private static func parseRows(_ data: Data) throws -> [Row] {
    let contractIndex = try CryptoCompareClient.parseCoinListResponse(data)
    let allSymbols = try CryptoCompareClient.parseCoinSymbols(data)

    var rows: [Row] = []
    rows.reserveCapacity(allSymbols.count)
    var symbolsWithContract: Set<String> = []
    for (contract, symbol) in contractIndex {
      rows.append(Row(symbol: symbol, contractAddress: contract))
      symbolsWithContract.insert(symbol)
    }
    for symbol in allSymbols where !symbolsWithContract.contains(symbol) {
      rows.append(Row(symbol: symbol, contractAddress: nil))
    }
    return rows
  }

  /// Atomically replaces the whole `cc_coin` table inside a single
  /// `BEGIN IMMEDIATE` transaction, rolling back on any error (mirrors
  /// `SQLiteCoinGeckoCatalog.replaceAll`).
  func replaceAll(rows: [Row]) throws {
    try database.exec("BEGIN IMMEDIATE;")
    do {
      try database.exec("DELETE FROM cc_coin;")
      try insertRows(rows)
      try database.exec("COMMIT;")
    } catch {
      database.rollback()
      throw error
    }
  }

  private func insertRows(_ rows: [Row]) throws {
    guard !rows.isEmpty else { return }
    var insert: OpaquePointer?
    try database.prepare(
      "INSERT INTO cc_coin (symbol, contract_address) VALUES (?, ?);", into: &insert)
    defer { sqlite3_finalize(insert) }
    for row in rows {
      try database.bind(insert, at: 1, to: row.symbol)
      if let contract = row.contractAddress {
        try database.bind(insert, at: 2, to: contract.lowercased())
      } else {
        sqlite3_bind_null(insert, 2)
      }
      try database.step(insert)
      sqlite3_reset(insert)
    }
  }
}

// MARK: - Row + test seams

extension CryptoCompareTokenCache {
  /// One `cc_coin` row: a symbol paired with an optional contract address
  /// (`nil` for native / chain-agnostic listings). The contract is lowercased
  /// on insert so lookups match case-insensitively.
  struct Row: Sendable, Equatable {
    let symbol: String
    let contractAddress: String?
  }

  /// Replaces the whole table with `rows`. Module-internal so storage tests
  /// can seed the cache without driving the network refresh path.
  func replaceAllForTesting(rows: [Row]) throws {
    try replaceAll(rows: rows)
  }

  /// Current `cc_coin` row count. Module-internal for tests.
  func countForTesting() throws -> Int {
    try database.scalarInt("SELECT COUNT(*) FROM cc_coin;")
  }
}
