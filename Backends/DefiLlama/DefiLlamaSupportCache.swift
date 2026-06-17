import Foundation
import SQLite3
import os

/// One token's DefiLlama support state: whether DefiLlama prices it and, if so,
/// the earliest date it has data for (its history floor).
struct DefiLlamaSupport: Sendable, Equatable {
  let supported: Bool
  let earliestDate: String?
  let lastChecked: Date
}

/// Local-only, drop-and-recreate cache of which tokens DefiLlama can price,
/// backed by `<directory>/defillama-support.sqlite`. Unlike the #1140 catalogs
/// it holds no downloaded list — it is a bottom-up per-token memoization filled
/// by the startup probe (see `refreshSupport`, Task 6). SQLite work runs on the
/// actor's serial executor; the non-`Sendable` `CatalogDatabase` never escapes.
actor DefiLlamaSupportCache {
  static let log = Logger(subsystem: "moolah.instrument-registry", category: "defillama-support")

  let networking: NetworkingServices
  let database: CatalogDatabase

  static func make(
    directory: URL, networking: NetworkingServices
  ) throws -> DefiLlamaSupportCache {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try CatalogDatabase.open(
      dbURL: directory.appendingPathComponent("defillama-support.sqlite"),
      schemaVersion: DefiLlamaSupportCacheSchema.version,
      schemaStatements: DefiLlamaSupportCacheSchema.schemaStatements(
        schemaVersion: DefiLlamaSupportCacheSchema.version))
    return DefiLlamaSupportCache(networking: networking, database: database)
  }

  private init(networking: NetworkingServices, database: CatalogDatabase) {
    self.networking = networking
    self.database = database
  }

  isolated deinit {
    database.close()
  }

  // MARK: - refreshSupport

  /// 24h staleness window for re-probing (matches `CatalogRefresh.defaultMaxAge`).
  private static let maxAge: TimeInterval = 24 * 3600

  /// Re-probes DefiLlama support for `registrations` whose row is missing, older
  /// than 24h, or currently unsupported (so a token that gains liquidity later
  /// is re-detected). Coin ids are chunked into batches of 50 so the URL stays
  /// within length limits for large token sets. `.spam` tokens and tokens with
  /// no derivable coin id are skipped. Best-effort: a network failure leaves all
  /// rows untouched (logged); cancellation returns early.
  func refreshSupport(for registrations: [CryptoRegistration], now: Date) async {
    let coinToInstrument = eligibleCoins(from: registrations, now: now)
    guard !coinToInstrument.isEmpty else { return }
    if Task.isCancelled { return }

    let firstPoints: [String: DefiLlamaWireFormat.FirstPoint]
    do {
      firstPoints = try await fetchFirstPoints(for: coinToInstrument.keys.sorted())
    } catch {
      Self.log.error("refreshSupport failed: \(String(describing: error), privacy: .public)")
      return  // leave rows untouched; next launch retries
    }
    if Task.isCancelled { return }

    for (coinId, instrumentId) in coinToInstrument {
      if let point = firstPoints[coinId] {
        upsert(
          instrumentId: instrumentId,
          supported: true,
          earliestDate: DefiLlamaWireFormat.isoDay(from: point.timestamp),
          lastChecked: now)
      } else {
        upsert(instrumentId: instrumentId, supported: false, earliestDate: nil, lastChecked: now)
      }
    }
  }

  /// Returns the coinId → instrumentId map for tokens that need re-probing:
  /// missing rows, stale rows (>24h), or unsupported tokens (may gain liquidity).
  private func eligibleCoins(
    from registrations: [CryptoRegistration], now: Date
  ) -> [String: String] {
    var coinToInstrument: [String: String] = [:]
    for registration in registrations {
      guard registration.pricingStatus != .spam else { continue }
      let instrumentId = registration.instrument.id
      if let existing = support(for: instrumentId),
        existing.supported,
        now.timeIntervalSince(existing.lastChecked) < Self.maxAge
      {
        continue  // fresh + supported → skip
      }
      guard
        let coinId = DefiLlamaCoinID.make(
          instrumentId: instrumentId, coingeckoId: registration.mapping.coingeckoId)
      else { continue }
      coinToInstrument[coinId] = instrumentId
    }
    return coinToInstrument
  }

  /// Issues one `/prices/first` request per 50-coin batch (deterministic order:
  /// `sortedCoinIds` must already be sorted). Merges all batch results into one
  /// map. Throws on the first network or parse error — callers must not write
  /// any rows when this throws (partial-failure safety).
  private func fetchFirstPoints(
    for sortedCoinIds: [String]
  ) async throws -> [String: DefiLlamaWireFormat.FirstPoint] {
    let batches = stride(from: 0, to: sortedCoinIds.count, by: 50).map {
      Array(sortedCoinIds[$0..<min($0 + 50, sortedCoinIds.count)])
    }
    var firstPoints: [String: DefiLlamaWireFormat.FirstPoint] = [:]
    let http = networking.client(forHost: "coins.llama.fi")
    for batch in batches {
      if Task.isCancelled { return firstPoints }
      let url = DefiLlamaWireFormat.firstURL(coinIds: batch)
      let (data, _) = try await http.data(for: URLRequest(url: url))
      let batchPoints = try DefiLlamaWireFormat.parseFirst(data)
      firstPoints.merge(batchPoints) { _, new in new }
    }
    return firstPoints
  }

  // MARK: - Stored support query

  /// The stored support row for `instrumentId`, or `nil` if never probed.
  /// Infallible: a read failure logs and returns `nil` (treated as "unknown").
  func support(for instrumentId: String) -> DefiLlamaSupport? {
    var statement: OpaquePointer?
    do {
      try database.prepare(
        """
        SELECT supported, earliest_date, last_checked
        FROM defillama_support WHERE instrument_id = ? LIMIT 1;
        """, into: &statement)
    } catch {
      Self.log.error("support(for:) prepare failed: \(String(describing: error), privacy: .public)")
      return nil
    }
    defer { sqlite3_finalize(statement) }
    do {
      try database.bind(statement, at: 1, to: instrumentId)
    } catch {
      Self.log.error("support(for:) bind failed: \(String(describing: error), privacy: .public)")
      return nil
    }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    let supported = sqlite3_column_int64(statement, 0) != 0
    let earliest = database.readText(statement, column: 1)
    let lastChecked = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
    return DefiLlamaSupport(
      supported: supported, earliestDate: earliest, lastChecked: lastChecked)
  }

  /// Inserts or replaces the support row for `instrumentId`. Infallible: a
  /// write failure is logged and swallowed (the next probe retries).
  func upsert(
    instrumentId: String, supported: Bool, earliestDate: String?, lastChecked: Date
  ) {
    var statement: OpaquePointer?
    do {
      try database.prepare(
        """
        INSERT INTO defillama_support (instrument_id, supported, earliest_date, last_checked)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(instrument_id) DO UPDATE SET
          supported = excluded.supported,
          earliest_date = excluded.earliest_date,
          last_checked = excluded.last_checked;
        """, into: &statement)
      defer { sqlite3_finalize(statement) }
      try database.bind(statement, at: 1, to: instrumentId)
      try database.bind(statement, at: 2, to: supported ? 1 : 0)
      if let earliestDate {
        try database.bind(statement, at: 3, to: earliestDate)
      } else {
        let result = sqlite3_bind_null(statement, 3)
        guard result == SQLITE_OK else {
          throw CatalogError.sqlite(
            "bind null \(result): \(String(cString: sqlite3_errmsg(sqlite3_db_handle(statement))))")
        }
      }
      let result = sqlite3_bind_double(statement, 4, lastChecked.timeIntervalSince1970)
      guard result == SQLITE_OK else {
        throw CatalogError.sqlite(
          "bind double \(result): \(String(cString: sqlite3_errmsg(sqlite3_db_handle(statement))))")
      }
      try database.step(statement)
    } catch {
      Self.log.error("upsert failed: \(String(describing: error), privacy: .public)")
    }
  }
}
