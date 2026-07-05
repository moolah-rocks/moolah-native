import Foundation
import SQLite3
import os

/// Provider-neutral error surfaced by the catalog SQLite engine and the
/// providers that build on it (CoinGecko, Binance). Lives at
/// module scope so every provider shares one error type rather than nesting
/// its own.
enum CatalogError: Error, Equatable {
  case sqlite(String)
  case network(String)
}

/// Reusable, provider-neutral SQLite engine backing the crypto provider
/// catalogs. Wraps a single `sqlite3` connection plus the engine-owned
/// `meta` / `etag` bookkeeping tables, and exposes the thin C-API helpers
/// each provider's storage code needs.
///
/// Non-`Sendable` by design: an instance owns a raw connection handle and is
/// expected to be held inside a provider actor, which serialises access. See
/// `guides/DATABASE_SCHEMA_GUIDE.md` for the drop-and-recreate-for-caches
/// rule this type implements.
///
/// Throw sites embed `sqlite3_errmsg(_:)` (resolved via `sqlite3_db_handle`
/// for statement-only call sites) so logs read e.g.
/// `step 2067: UNIQUE constraint failed: …` rather than bare `step 19`.
/// Extended result codes are enabled in `connect(dbURL:)`.
final class CatalogDatabase {
  /// Stateless `Logger`; `static` so the bootstrap path and the instance
  /// helpers can both emit on the same subsystem/category without each call
  /// site rebuilding the logger.
  static let log = Logger(subsystem: "moolah.instrument-registry", category: "catalog")

  private var handle: OpaquePointer?

  private init(handle: OpaquePointer) {
    self.handle = handle
  }

  // MARK: - Lifecycle

  /// Opens (or, on a schema-version mismatch, drops and recreates) the cache
  /// database at `dbURL`. `schemaStatements` is the full DDL to run on a
  /// fresh file and MUST begin with `baseSchemaStatements(schemaVersion:)`
  /// so the engine-owned `meta` / `etag` tables exist. Providers prepend
  /// that helper and append their own tables.
  static func open(
    dbURL: URL,
    schemaVersion: Int,
    schemaStatements: [String]
  ) throws -> CatalogDatabase {
    if FileManager.default.fileExists(atPath: dbURL.path) {
      // Open once and reuse the handle on the version-match path (mirrors
      // `SQLiteCoinGeckoCatalog.open`'s `shouldClose` precedent) rather than
      // opening a throwaway connection just to read the version.
      let handle = try connect(dbURL: dbURL)
      var shouldClose = true
      defer { if shouldClose { sqlite3_close_v2(handle) } }

      let database = CatalogDatabase(handle: handle)
      // A missing/old `meta` shape (or any read failure) reads as `nil`,
      // which never equals `schemaVersion`, so it falls through to recreate.
      if (try? database.readSchemaVersion()) == schemaVersion {
        shouldClose = false  // caller takes ownership of the live handle
        return database
      }
      // Mismatch: close the stale handle (via the defer), then drop the file
      // and its WAL sidecars and recreate clean. `<db>-wal` / `<db>-shm` are
      // produced by WAL mode and must go too so the database starts empty.
      // `database` is dropped here while still owning `handle`; null it out
      // first so its `deinit` does not double-close the defer-closed handle.
      database.handle = nil
      try FileManager.default.removeItem(at: dbURL)
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))
    }
    return try createFresh(dbURL: dbURL, schemaStatements: schemaStatements)
  }

  /// Closes the underlying connection. Idempotent.
  func close() {
    if let handle { sqlite3_close_v2(handle) }
    handle = nil
  }

  deinit {
    if let handle { sqlite3_close_v2(handle) }
  }

  private static func connect(dbURL: URL) throws -> OpaquePointer {
    var handle: OpaquePointer?
    // NOMUTEX (not FULLMUTEX): each provider catalog holds this connection
    // inside its own actor, which already serialises every SQLite call, so
    // SQLite's own per-connection mutex would be wasted contention
    // (DATABASE_SCHEMA_GUIDE §5 Forbidden flags).
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
    let result = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
    guard result == SQLITE_OK, let handle else {
      throw CatalogError.sqlite("open failed: \(result)")
    }
    // Promote bare codes (e.g. `19 SQLITE_CONSTRAINT`) into specific
    // extended codes (e.g. `2067 SQLITE_CONSTRAINT_UNIQUE`) so log lines
    // pinpoint the actual failure mode.
    sqlite3_extended_result_codes(handle, 1)

    // Per-connection PRAGMAs (DATABASE_SCHEMA_GUIDE §5). `foreign_keys` and
    // `busy_timeout` do NOT persist in the file header, so they must be set
    // on every open — not just at create time — or FK enforcement (e.g.
    // CoinGecko's `ON DELETE CASCADE`) silently lapses on reopen. WAL is
    // header-persistent but cheap to reassert. Best-effort: a PRAGMA that
    // fails to apply degrades robustness but should not block opening an
    // otherwise valid database.
    for pragma in [
      "PRAGMA journal_mode = WAL;",
      "PRAGMA foreign_keys = ON;",
      "PRAGMA busy_timeout = 5000;",
      "PRAGMA synchronous = NORMAL;",
      "PRAGMA temp_store = MEMORY;",
      "PRAGMA cache_size = -8000;",
      "PRAGMA optimize = 0x10002;",
    ] {
      let result = sqlite3_exec(handle, pragma, nil, nil, nil)
      if result != SQLITE_OK {
        Self.log.error("PRAGMA failed (\(pragma, privacy: .public)): \(result)")
      }
    }
    return handle
  }

  private static func createFresh(
    dbURL: URL,
    schemaStatements: [String]
  ) throws -> CatalogDatabase {
    let handle = try connect(dbURL: dbURL)
    let database = CatalogDatabase(handle: handle)
    for statement in schemaStatements {
      try database.exec(statement)
    }
    return database
  }

  // MARK: - Engine-owned schema

  /// DDL for the engine-owned `meta` / `etag` bookkeeping tables every
  /// provider catalog shares. Providers prepend this to their own table
  /// statements when calling `open(…)`. `etag` is keyed by endpoint so a
  /// provider can track conditional-request validators for several
  /// endpoints without per-provider columns.
  ///
  /// Connection PRAGMAs (`journal_mode`, `foreign_keys`, `busy_timeout`,
  /// `synchronous`) are applied in `connect(dbURL:)` on every open — not
  /// here — because the per-connection ones do not persist in the file
  /// header and would otherwise lapse on reopen.
  static func baseSchemaStatements(schemaVersion: Int) -> [String] {
    [
      """
      CREATE TABLE meta (
        schema_version  INTEGER NOT NULL,
        last_fetched    REAL
      ) STRICT;
      """,
      "INSERT INTO meta (schema_version) VALUES (\(schemaVersion));",
      """
      CREATE TABLE etag (
        endpoint_key  TEXT NOT NULL PRIMARY KEY,
        value         TEXT
      ) STRICT;
      """,
    ]
  }

  // MARK: - Meta / etag accessors

  /// Reads the single `meta` row's `schema_version`. Throws if `meta` is
  /// missing or empty (used by the bootstrap mismatch check).
  func readSchemaVersion() throws -> Int {
    try scalarInt("SELECT schema_version FROM meta LIMIT 1;")
  }

  /// The last successful refresh time, or `nil` if never refreshed.
  func readLastFetched() -> Date? {
    var statement: OpaquePointer?
    guard (try? prepare("SELECT last_fetched FROM meta LIMIT 1;", into: &statement)) != nil
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) != SQLITE_NULL
    else { return nil }
    return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
  }

  func writeLastFetched(_ date: Date) throws {
    var statement: OpaquePointer?
    try prepare("UPDATE meta SET last_fetched = ?;", into: &statement)
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
    guard result == SQLITE_OK else {
      throw CatalogError.sqlite("bind double \(result): \(errorMessage(statement: statement))")
    }
    try step(statement)
  }

  /// The stored validator (ETag) for `key`, or `nil` if absent/cleared.
  func readEtag(key: String) -> String? {
    var statement: OpaquePointer?
    guard (try? prepare("SELECT value FROM etag WHERE endpoint_key = ?;", into: &statement)) != nil
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard (try? bind(statement, at: 1, to: key)) != nil else { return nil }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return readText(statement, column: 0)
  }

  /// Upserts the validator for `key`. A `nil` value stores SQL `NULL`,
  /// clearing any previously stored validator while keeping the row.
  func writeEtag(key: String, value: String?) throws {
    var statement: OpaquePointer?
    try prepare(
      """
      INSERT INTO etag (endpoint_key, value) VALUES (?, ?)
      ON CONFLICT(endpoint_key) DO UPDATE SET value = excluded.value;
      """,
      into: &statement)
    defer { sqlite3_finalize(statement) }
    try bind(statement, at: 1, to: key)
    if let value {
      try bind(statement, at: 2, to: value)
    } else {
      let result = sqlite3_bind_null(statement, 2)
      guard result == SQLITE_OK else {
        throw CatalogError.sqlite("bind null \(result): \(errorMessage(statement: statement))")
      }
    }
    try step(statement)
  }

  // MARK: - Low-level SQLite helpers

  func exec(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(handle, sql, nil, nil, &error)
    if result != SQLITE_OK {
      let message = error.map { String(cString: $0) } ?? "(no errmsg)"
      sqlite3_free(error)
      throw CatalogError.sqlite("exec \(result): \(message)")
    }
  }

  func prepare(_ sql: String, into statement: inout OpaquePointer?) throws {
    let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard result == SQLITE_OK else {
      throw CatalogError.sqlite("prepare \(result): \(errorMessage(database: handle)) — \(sql)")
    }
  }

  func bind(_ statement: OpaquePointer?, at index: Int32, to value: String) throws {
    let result = sqlite3_bind_text(
      statement,
      index,
      value,
      -1,
      unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)
    )
    guard result == SQLITE_OK else {
      throw CatalogError.sqlite("bind text \(result): \(errorMessage(statement: statement))")
    }
  }

  func bind(_ statement: OpaquePointer?, at index: Int32, to value: Int) throws {
    let result = sqlite3_bind_int64(statement, index, Int64(value))
    guard result == SQLITE_OK else {
      throw CatalogError.sqlite("bind int \(result): \(errorMessage(statement: statement))")
    }
  }

  func step(_ statement: OpaquePointer?) throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE || result == SQLITE_ROW else {
      throw CatalogError.sqlite("step \(result): \(errorMessage(statement: statement))")
    }
  }

  /// Issues `ROLLBACK;` and logs (rather than rethrows) any failure. A
  /// failed rollback indicates the connection is already in an undefined
  /// transaction state — every subsequent write will fail anyway, so
  /// surfacing the rollback error would mask the original cause; logging it
  /// is the right balance per CODE_GUIDE §8 (no silent `try?`). Callers must
  /// rethrow the original error after invoking this helper.
  func rollback() {
    do {
      try exec("ROLLBACK;")
    } catch {
      Self.log.error(
        """
        ROLLBACK failed: \(String(describing: error), privacy: .public) — \
        connection may be in undefined transaction state
        """
      )
    }
  }

  func readText(_ statement: OpaquePointer?, column: Int32) -> String? {
    guard let cString = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: cString)
  }

  func scalarInt(_ sql: String) throws -> Int {
    var statement: OpaquePointer?
    try prepare(sql, into: &statement)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw CatalogError.sqlite("scalar empty")
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  // MARK: - Error messages

  /// Reads `sqlite3_errmsg(_:)` for the connection backing `statement`.
  /// Only a nil handle falls back to the sentinel; when a handle is present
  /// `sqlite3_errmsg` always returns a non-null string (the literal
  /// "not an error" if nothing failed), so a throw site is never silent —
  /// even a degraded message beats `step 19` alone.
  private func errorMessage(statement: OpaquePointer?) -> String {
    errorMessage(database: statement.flatMap { sqlite3_db_handle($0) })
  }

  private func errorMessage(database: OpaquePointer?) -> String {
    guard let database, let cString = sqlite3_errmsg(database) else {
      return "(no errmsg)"
    }
    return String(cString: cString)
  }
}
