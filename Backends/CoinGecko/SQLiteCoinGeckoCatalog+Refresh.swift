import Foundation
import SQLite3

/// ETag-aware refresh path for `SQLiteCoinGeckoCatalog`. Hosted in a
/// separate file so the actor's primary body stays focused on schema
/// bootstrap and the storage seam (see CLAUDE.md and `guides/CODE_GUIDE.md`
/// §7 on extension grouping).
extension SQLiteCoinGeckoCatalog {
  /// Performs a conditional GET against CoinGecko's `/coins/list` and
  /// `/asset_platforms`, replacing the relevant tables in a transaction and
  /// updating the meta row.
  ///
  /// Skipped when the prior fetch happened within `Self.maxAge` (24h).
  /// Silent on failure (logged via `os_log` and swallowed) — the catalog
  /// degrades to a stale snapshot rather than propagating errors to UI.
  /// Crucially, when the network call throws the catch fires *before*
  /// `writeMeta` runs, so `last_fetched` stays at its previous value and
  /// the next launch retries.
  func refreshIfStale() async {
    do {
      // Capture `now` once so the staleness compare and the `writeMeta`
      // timestamp use the same instant — avoids any drift if the body
      // takes long enough that two `Date()` reads diverge.
      let now = Date()
      let meta = try Self.readMeta(database: database)
      if let lastFetched = meta.lastFetched,
        now.timeIntervalSince(lastFetched) < Self.maxAge
      {
        return
      }
      async let coinsRequest = Self.fetchConditional(
        http: http, url: Self.coinsListURL, ifNoneMatch: meta.coinsEtag)
      async let platformsRequest = Self.fetchConditional(
        http: http, url: Self.assetPlatformsURL, ifNoneMatch: meta.platformsEtag)
      let coinsResult = try await coinsRequest
      let platformsResult = try await platformsRequest

      var newCoinsEtag = meta.coinsEtag
      var newPlatformsEtag = meta.platformsEtag
      var coinsUpdate = CoinsUpdate.unchanged
      var platformsUpdate = PlatformsUpdate.unchanged

      switch coinsResult {
      case .notModified:
        break
      case let .ok(body, etag):
        coinsUpdate = try .replace(Self.parseCoins(body))
        newCoinsEtag = etag
      }
      switch platformsResult {
      case .notModified:
        break
      case let .ok(body, etag):
        platformsUpdate = try .replace(Self.parsePlatforms(body))
        newPlatformsEtag = etag
      }

      try Self.applyUpdates(
        database: database, coins: coinsUpdate, platforms: platformsUpdate)
      try Self.writeMeta(
        database: database,
        lastFetched: now,
        coinsEtag: newCoinsEtag,
        platformsEtag: newPlatformsEtag
      )
    } catch {
      Self.log.error("refresh failed: \(String(describing: error), privacy: .public)")
    }
  }
}

// MARK: - Constants and fetch primitives

extension SQLiteCoinGeckoCatalog {
  static let coinsListURL: URL = {
    guard
      let url = URL(string: "https://api.coingecko.com/api/v3/coins/list?include_platform=true")
    else { preconditionFailure("malformed CoinGecko coins-list URL — fix the literal") }
    return url
  }()

  static let assetPlatformsURL: URL = {
    guard let url = URL(string: "https://api.coingecko.com/api/v3/asset_platforms")
    else { preconditionFailure("malformed CoinGecko asset-platforms URL — fix the literal") }
    return url
  }()
  /// 24-hour stale-fetch guard. Refresh callers are no-ops within this
  /// window even if the previous fetch returned 304.
  static let maxAge: TimeInterval = 24 * 3600

  enum FetchOutcome: Sendable {
    case ok(Data, etag: String?)
    case notModified
  }

  /// One side of a `refreshIfStale()` snapshot: the network either returned
  /// a fresh body (`.replace`) or a 304 (`.unchanged`). Modeled as an enum
  /// so the SQLite write path doesn't conflate "no change" with "empty
  /// list".
  enum CoinsUpdate: Sendable {
    case unchanged
    case replace([RawCoin])
  }

  enum PlatformsUpdate: Sendable {
    case unchanged
    case replace([RawPlatform])
  }

  static func fetchConditional(
    http: RateLimitedHTTPClient,
    url: URL,
    ifNoneMatch: String?
  ) async throws -> FetchOutcome {
    var request = URLRequest(url: url)
    if let ifNoneMatch {
      request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
    }
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    let (data, response) = try await http.data(for: request)
    switch response.statusCode {
    case 200:
      return .ok(data, etag: response.value(forHTTPHeaderField: "ETag"))
    case 304:
      return .notModified
    default:
      throw CatalogError.network("status \(response.statusCode) for \(url.absoluteString)")
    }
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

// MARK: - Apply updates and meta write

extension SQLiteCoinGeckoCatalog {
  /// If both halves changed, delegate to the all-tables `replaceAll` so the
  /// snapshot is consistent. Otherwise replace only the side that changed,
  /// preserving the other. A 304/304 pair is a no-op.
  static func applyUpdates(
    database: OpaquePointer?,
    coins: CoinsUpdate,
    platforms: PlatformsUpdate
  ) throws {
    switch (coins, platforms) {
    case (.unchanged, .unchanged):
      return
    case let (.replace(coins), .replace(platforms)):
      try replaceAll(database: database, coins: coins, platforms: platforms)
    case let (.replace(coins), .unchanged):
      try replaceCoinsOnly(database: database, coins: coins)
    case let (.unchanged, .replace(platforms)):
      try replacePlatformsOnly(database: database, platforms: platforms)
    }
  }

  private static func replaceCoinsOnly(
    database: OpaquePointer?, coins: [RawCoin]
  ) throws {
    try exec(database: database, "BEGIN IMMEDIATE;")
    do {
      try exec(database: database, "DELETE FROM coin;")
      try insertCoins(database: database, coins: coins)
      try exec(database: database, "COMMIT;")
    } catch {
      rollback(database: database)
      throw error
    }
  }

  private static func replacePlatformsOnly(
    database: OpaquePointer?, platforms: [RawPlatform]
  ) throws {
    try exec(database: database, "BEGIN IMMEDIATE;")
    do {
      try exec(database: database, "DELETE FROM platform;")
      try insertPlatforms(database: database, platforms: platforms)
      try exec(database: database, "COMMIT;")
    } catch {
      rollback(database: database)
      throw error
    }
  }

  static func writeMeta(
    database: OpaquePointer?,
    lastFetched: Date,
    coinsEtag: String?,
    platformsEtag: String?
  ) throws {
    var statement: OpaquePointer?
    try prepare(
      database: database,
      sql: "UPDATE meta SET last_fetched = ?, coins_etag = ?, platforms_etag = ?;",
      into: &statement
    )
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, lastFetched.timeIntervalSince1970)
    if let coinsEtag {
      try bind(statement, at: 2, to: coinsEtag)
    } else {
      sqlite3_bind_null(statement, 2)
    }
    if let platformsEtag {
      try bind(statement, at: 3, to: platformsEtag)
    } else {
      sqlite3_bind_null(statement, 3)
    }
    try step(statement)
  }
}
