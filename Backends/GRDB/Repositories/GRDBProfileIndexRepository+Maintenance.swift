import Foundation
import GRDB

// Bulk wipe / system-fields-clear maintenance entry points for the
// profile-index repository. Split out of `GRDBProfileIndexRepository.swift`
// to keep that file under the 400-line limit; behaviour is unchanged.

extension GRDBProfileIndexRepository {
  /// Atomically wipes every profile-index table — `profile`,
  /// `instrument`, and the six rate-cache tables — in a single GRDB
  /// write transaction. Called by
  /// `ProfileIndexSyncHandler.deleteLocalData()` on sign-out, account
  /// switch, and zone deletion / purge.
  ///
  /// Atomicity rationale: a process kill mid-wipe would otherwise
  /// leave price-cache rows that reference instruments now gone, or
  /// profiles whose instruments survived. Sign-out semantics demand
  /// "the DB is empty"; partial wipes are not safe.
  ///
  /// Tables that don't exist yet (i.e. when this repository is opened
  /// against a DB that hasn't run the v3 migration) are skipped via a
  /// `sqlite_master` lookup so legacy fixtures continue to work.
  ///
  /// Per-table deletes use typed `*Row.deleteAll(database)` (not a
  /// generic `DELETE FROM \(table)` interpolation) so the call satisfies
  /// `guides/DATABASE_CODE_GUIDE.md` §4 — no `sql:` argument carries a
  /// `\(...)` interpolation at all. Adding a new cache table is a
  /// matter of registering its `Row` type below alongside its
  /// `databaseTableName`.
  func deleteAllProfileIndexDataSync() throws {
    try database.write { database in
      _ = try ProfileRow.deleteAll(database)
      // Clear pending deletion intents too (issue #1090): a local index wipe
      // (sign-out / account-switch / zone purge) must not leave tombstones that
      // would replay on the next sign-in.
      try DeletionJournal.clearAll(in: database)
      let existingTables = try Set(
        String.fetchAll(
          database,
          sql: "SELECT name FROM sqlite_master WHERE type='table'"))
      let candidates: [(name: String, deleteAll: (Database) throws -> Void)] = [
        (InstrumentRow.databaseTableName, { _ = try InstrumentRow.deleteAll($0) }),
        (ExchangeRateRecord.databaseTableName, { _ = try ExchangeRateRecord.deleteAll($0) }),
        (
          ExchangeRateMetaRecord.databaseTableName,
          { _ = try ExchangeRateMetaRecord.deleteAll($0) }
        ),
        (StockPriceRecord.databaseTableName, { _ = try StockPriceRecord.deleteAll($0) }),
        (
          StockTickerMetaRecord.databaseTableName,
          { _ = try StockTickerMetaRecord.deleteAll($0) }
        ),
        (CryptoPriceRecord.databaseTableName, { _ = try CryptoPriceRecord.deleteAll($0) }),
        (
          CryptoTokenMetaRecord.databaseTableName,
          { _ = try CryptoTokenMetaRecord.deleteAll($0) }
        ),
      ]
      for entry in candidates where existingTables.contains(entry.name) {
        try entry.deleteAll(database)
      }
    }
  }

  /// Clears `encoded_system_fields` on every row across both the
  /// `profile` table and (when the `instrumentRepository` is wired)
  /// the `instrument` table. Encrypted-data-reset semantics — the
  /// data stays but the change tags must be re-uploaded.
  ///
  /// Both updates run on the same `DatabaseWriter` so they share the
  /// same serial queue; a concurrent reader sees either both cleared
  /// or neither. The call shape mirrors `deleteAllProfileIndexDataSync`.
  func clearAllProfileIndexSystemFieldsSync(
    instrumentRepository: GRDBInstrumentRegistryRepository?
  ) throws {
    try database.write { database in
      _ =
        try ProfileRow
        .updateAll(
          database,
          [ProfileRow.Columns.encodedSystemFields.set(to: nil)])
      let hasInstrumentTable =
        try Bool.fetchOne(
          database,
          sql: """
            SELECT EXISTS(
              SELECT 1 FROM sqlite_master
              WHERE type='table' AND name='instrument'
            )
            """) ?? false
      if hasInstrumentTable {
        try database.execute(
          sql: "UPDATE instrument SET encoded_system_fields = NULL")
      }
      // `instrumentRepository` is intentionally not used here — the
      // `instrument` table lives in the same DB as `profile`, so the
      // direct `UPDATE` above is sufficient. The parameter is retained
      // so the handler's call shape remains consistent and a future
      // database split (separate DB for the registry) becomes a
      // mechanical change at this site.
    }
  }
}
