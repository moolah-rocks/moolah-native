import Foundation
import SQLite3

/// ETag-aware refresh path for `SQLiteCoinGeckoCatalog`. The staleness gate,
/// the per-endpoint conditional GET / `If-None-Match` loop, and the
/// `last_fetched` / `etag` persistence are delegated to the shared
/// `CatalogRefresh`; this file owns only the CoinGecko endpoint wiring, the
/// JSON parsing, and the table-replace `apply` step. Hosted in a separate
/// file so the actor's primary body stays focused (see CLAUDE.md and
/// `guides/CODE_GUIDE.md` §7 on extension grouping).
extension SQLiteCoinGeckoCatalog {
  /// Endpoint keys: double as the `etag` table keys and as the keys under
  /// which `CatalogRefresh` hands fetched bodies back to `apply`.
  static let coinsEndpointKey = "coins"
  static let platformsEndpointKey = "platforms"

  /// Performs a conditional GET against CoinGecko's `/coins/list` and
  /// `/asset_platforms`, replacing the relevant tables in a transaction and
  /// updating the engine-owned `last_fetched` / `etag` bookkeeping.
  ///
  /// Skipped when the prior fetch happened within `CatalogRefresh.maxAge`
  /// (24h). Silent on failure (logged via `os_log` and swallowed) — the
  /// catalog degrades to a stale snapshot rather than propagating errors to
  /// UI. `CatalogRefresh.run` PROPAGATES on failure; the `do/catch` here is
  /// the graceful-degradation boundary, and because `run` persists
  /// `last_fetched` only after a successful `apply`, a thrown network error
  /// leaves `last_fetched` at its previous value and the next launch retries.
  func refreshIfStale() async {
    do {
      // Resolve the key per refresh so a Pro key entered in Settings flips
      // the host (and the auth query item) on the next refresh. Both URLs
      // and the rate-limit gate are derived from the same key, so they never
      // diverge.
      let apiKey = apiKeyProvider() ?? ""
      let http = networking.client(forHost: CoinGeckoClient.host(apiKey: apiKey))
      let endpoints = [
        CatalogEndpoint(
          key: Self.coinsEndpointKey,
          url: CoinGeckoClient.coinsListURL(apiKey: apiKey)),
        CatalogEndpoint(
          key: Self.platformsEndpointKey,
          url: CoinGeckoClient.assetPlatformsURL(apiKey: apiKey)),
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

  /// Translates the changed-endpoint bodies from `CatalogRefresh` into the
  /// right table replace. An absent key means that endpoint returned 304
  /// (unchanged), so the corresponding table is preserved; a present key
  /// carries a fresh `/coins/list` or `/asset_platforms` body to parse and
  /// replace. When both changed, the all-tables `replaceAll` keeps the
  /// snapshot consistent; otherwise only the changed side is replaced.
  private func applyRefresh(bodies: [String: Data]) throws {
    let coinsUpdate: CoinsUpdate =
      try bodies[Self.coinsEndpointKey].map { .replace(try Self.parseCoins($0)) } ?? .unchanged
    let platformsUpdate: PlatformsUpdate =
      try bodies[Self.platformsEndpointKey].map { .replace(try Self.parsePlatforms($0)) }
      ?? .unchanged
    try applyUpdates(coins: coinsUpdate, platforms: platformsUpdate)
  }
}

// MARK: - Update modelling

extension SQLiteCoinGeckoCatalog {
  /// One side of a refresh snapshot: the network either returned a fresh
  /// body (`.replace`) or a 304 (`.unchanged`). Modeled as an enum so the
  /// SQLite write path doesn't conflate "no change" with "empty list".
  enum CoinsUpdate: Sendable {
    case unchanged
    case replace([RawCoin])
  }

  enum PlatformsUpdate: Sendable {
    case unchanged
    case replace([RawPlatform])
  }
}

// MARK: - JSON parsing

/// Wire shape for one row of CoinGecko's `/coins/list` response.
private struct CoinWire: Decodable {
  let id: String
  let symbol: String
  let name: String
  /// CoinGecko sometimes maps a known platform slug to `null` for de-listed
  /// tokens; the parser compacts the dictionary to non-empty strings before
  /// inserting. The `platforms` key is always present in `?include_platform=true`
  /// responses; defaults to `[:]` for defensive decoding if a future API
  /// version omits it.
  let platforms: [String: String?]

  enum CodingKeys: String, CodingKey {
    case id, symbol, name, platforms
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.symbol = try container.decode(String.self, forKey: .symbol)
    self.name = try container.decode(String.self, forKey: .name)
    self.platforms =
      try container.decodeIfPresent([String: String?].self, forKey: .platforms) ?? [:]
  }
}

/// Wire shape for one row of CoinGecko's `/asset_platforms` response.
private struct PlatformWire: Decodable {
  let id: String
  let chainIdentifier: Int?
  let name: String

  enum CodingKeys: String, CodingKey {
    case id
    case chainIdentifier = "chain_identifier"
    case name
  }
}

extension SQLiteCoinGeckoCatalog {
  /// Decodes CoinGecko's `/coins/list` payload, collapsing duplicate `id`s
  /// to their first occurrence. CoinGecko occasionally lists the same id
  /// more than once (typically around delistings or rebrandings); a dupe
  /// would otherwise trip the `coin.coingecko_id UNIQUE` constraint mid-
  /// transaction and roll the whole refresh back. Dedupe at the seam keeps
  /// the on-disk constraints strict so genuine bugs in our insert path
  /// still trap.
  static func parseCoins(_ data: Data) throws -> [RawCoin] {
    let decoded = try JSONDecoder().decode([CoinWire].self, from: data)
    var seen: Set<String> = []
    seen.reserveCapacity(decoded.count)
    var coins: [RawCoin] = []
    coins.reserveCapacity(decoded.count)
    for wire in decoded where seen.insert(wire.id).inserted {
      coins.append(
        RawCoin(
          id: wire.id,
          symbol: wire.symbol.uppercased(),
          name: wire.name,
          platforms: compactPlatforms(wire.platforms)
        )
      )
    }
    return coins
  }

  /// Drops `null` and empty contract addresses from a `CoinWire.platforms`
  /// dict. CoinGecko sometimes maps a known platform slug to `null` for de-
  /// listed tokens; only mappings with a non-empty contract make it into
  /// `coin_platform`.
  static func compactPlatforms(_ raw: [String: String?]) -> [String: String] {
    var compacted: [String: String] = [:]
    compacted.reserveCapacity(raw.count)
    for (slug, contract) in raw {
      if let contract, !contract.isEmpty {
        compacted[slug] = contract
      }
    }
    return compacted
  }

  /// Decodes `/asset_platforms`, collapsing duplicate slugs to their first
  /// occurrence for the same reason as `parseCoins(_:)` — keeps the
  /// `platform.slug PRIMARY KEY` constraint strict at the DB layer.
  static func parsePlatforms(_ data: Data) throws -> [RawPlatform] {
    let decoded = try JSONDecoder().decode([PlatformWire].self, from: data)
    var seen: Set<String> = []
    seen.reserveCapacity(decoded.count)
    var platforms: [RawPlatform] = []
    platforms.reserveCapacity(decoded.count)
    for wire in decoded where seen.insert(wire.id).inserted {
      platforms.append(
        RawPlatform(slug: wire.id, chainId: wire.chainIdentifier, name: wire.name)
      )
    }
    return platforms
  }
}

// MARK: - Apply updates

extension SQLiteCoinGeckoCatalog {
  /// If both halves changed, delegate to the all-tables `replaceAll` so the
  /// snapshot is consistent. Otherwise replace only the side that changed,
  /// preserving the other. A 304/304 pair is a no-op.
  func applyUpdates(coins: CoinsUpdate, platforms: PlatformsUpdate) throws {
    switch (coins, platforms) {
    case (.unchanged, .unchanged):
      return
    case let (.replace(coins), .replace(platforms)):
      try replaceAll(coins: coins, platforms: platforms)
    case let (.replace(coins), .unchanged):
      try replaceCoinsOnly(coins: coins)
    case let (.unchanged, .replace(platforms)):
      try replacePlatformsOnly(platforms: platforms)
    }
  }

  private func replaceCoinsOnly(coins: [RawCoin]) throws {
    try database.exec("BEGIN IMMEDIATE;")
    do {
      try database.exec("DELETE FROM coin;")
      try insertCoins(coins)
      try database.exec("COMMIT;")
    } catch {
      database.rollback()
      throw error
    }
  }

  private func replacePlatformsOnly(platforms: [RawPlatform]) throws {
    try database.exec("BEGIN IMMEDIATE;")
    do {
      try database.exec("DELETE FROM platform;")
      try insertPlatforms(platforms)
      try database.exec("COMMIT;")
    } catch {
      database.rollback()
      throw error
    }
  }
}
