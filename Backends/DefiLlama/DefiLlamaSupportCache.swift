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
  /// is re-detected). One batched `/prices/first` call; `.spam` tokens and
  /// tokens with no derivable coin id are skipped. Best-effort: a network
  /// failure leaves all rows untouched (logged); cancellation returns early.
  func refreshSupport(for registrations: [CryptoRegistration], now: Date) async {
    // Build the to-probe set: coinId → instrumentId.
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
    guard !coinToInstrument.isEmpty else { return }
    if Task.isCancelled { return }

    let sortedCoinIds = coinToInstrument.keys.sorted()
    let url = DefiLlamaWireFormat.firstURL(coinIds: sortedCoinIds)
    let firstPoints: [String: DefiLlamaWireFormat.FirstPoint]
    do {
      let (data, _) = try await networking.client(forHost: "coins.llama.fi")
        .data(for: URLRequest(url: url))
      firstPoints = try DefiLlamaWireFormat.parseFirst(data)
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
        upsert(
          instrumentId: instrumentId,
          supported: false,
          earliestDate: nil,
          lastChecked: now)
      }
    }
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
