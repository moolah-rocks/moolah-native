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
