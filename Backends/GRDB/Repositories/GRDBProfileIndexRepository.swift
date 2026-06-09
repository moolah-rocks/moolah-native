// Backends/GRDB/Repositories/GRDBProfileIndexRepository.swift

import Foundation
import GRDB
import os

/// GRDB-backed repository for the app-scoped `profile` table that lives
/// in `profile-index.sqlite`. The only repository for that database; it
/// covers both the app-side mutation surface (consumed by
/// `ProfileStore`) and the sync-side dispatch surface (consumed by
/// `ProfileIndexSyncHandler`).
///
/// **Scope.** Most of this repository's surface (sync entry points,
/// system-fields helpers, hook wiring) is intentionally not on a
/// Domain protocol — the profile-index DB is an app-level concern, so
/// the per-feature protocol boundary that other repositories use does
/// not apply. The narrow subset that `SessionManager` needs
/// (`profile(forID:)`, `upsert`, `fetchAll`) is exposed via
/// `ProfileIndexRepository` in `Domain/Repositories/` so the App
/// layer can hold a reference without importing `Backends/GRDB/`.
///
/// **Concurrency.** `final class` + `Sendable` rather than `actor`.
/// The CKSyncEngine delegate path calls into the repository's sync
/// entry points synchronously; converting those to `await` against
/// an `actor` would ripple async propagation through every
/// per-record-type dispatch table for no concurrency benefit (the
/// GRDB queue's serial executor already mediates concurrent access).
/// The repo's *public* mutating surface (`upsert`, `delete`,
/// `fetchAll`) is `async throws` so callers see no concurrency-model
/// change. `@MainActor` would propagate `await` through every
/// CKSyncEngine sync dispatch site for no concurrency benefit, so it
/// is deliberately avoided. All stored properties are structurally
/// `Sendable` (`DatabaseWriter` per GRDB's protocol;
/// `OSAllocatedUnfairLock` unconditionally), so the conformance
/// holds without `@unchecked`.
///
/// **Hook installation.** `ProfileContainerManager` builds the repo
/// before the `SyncCoordinator` exists (chicken-and-egg), so the repo
/// is constructed with no-op hooks and the coordinator calls
/// `attachSyncHooks(onRecordChanged:onRecordDeleted:)` once both
/// objects are available. The lock-guarded `HookState` makes the swap
/// race-free.
///
/// **Hook signature.** `(UUID) -> Void`, not the per-record-type
/// `(String, UUID)` form used by per-profile repositories. Only one
/// record type ever flows through the profile-index DB, so the
/// recordType prefix would be redundant.
final class GRDBProfileIndexRepository {
  /// Holds the post-init hook closures so they can be swapped in
  /// atomically by `attachSyncHooks`. A small struct rather than two
  /// independent locks so the install is a single atomic write.
  private struct HookState {
    var onRecordChanged: @Sendable (UUID) -> Void
    var onRecordDeleted: @Sendable (UUID) -> Void
  }

  /// Internal (not `private`) so `ProfileIndexSyncHandler+NeedsPush` can
  /// open one `database.write` spanning the dirty check, the clean-row
  /// upsert, and the dirty-row system-fields write in `applyProfilesGuarded`
  /// — and the compare-and-clear in `clearNeedsPushForConfirmed` — keeping
  /// each fully transactional with no echo race (issue #1081).
  let database: any DatabaseWriter
  private let hooks: OSAllocatedUnfairLock<HookState>

  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (UUID) -> Void = { _ in },
    onRecordDeleted: @escaping @Sendable (UUID) -> Void = { _ in }
  ) {
    self.database = database
    self.hooks = OSAllocatedUnfairLock(
      initialState: HookState(
        onRecordChanged: onRecordChanged,
        onRecordDeleted: onRecordDeleted))
  }

  // MARK: - Wiring

  /// Replaces both hook closures atomically. Called by the
  /// `SyncCoordinator` once it exists; before that the repo is using
  /// the no-op closures from `init`.
  func attachSyncHooks(
    onRecordChanged: @escaping @Sendable (UUID) -> Void,
    onRecordDeleted: @escaping @Sendable (UUID) -> Void
  ) {
    hooks.withLock { state in
      state.onRecordChanged = onRecordChanged
      state.onRecordDeleted = onRecordDeleted
    }
  }

  // MARK: - Public async surface (consumed by ProfileStore)

  /// Returns every profile in `created_at` ascending order — the order
  /// the profile picker renders. Matches the `profile_by_created_at`
  /// index pinned by `ProfileIndexPlanPinningTests`.
  func fetchAll() async throws -> [Profile] {
    try await database.read { database in
      try ProfileRow
        .order(ProfileRow.Columns.createdAt.asc)
        .fetchAll(database)
        .map { $0.toDomain() }
    }
  }

  func profile(forID id: UUID) async throws -> Profile? {
    try await database.read { database in
      try ProfileRow
        .filter(ProfileRow.Columns.id == id)
        .fetchOne(database)?
        .toDomain()
    }
  }

  /// Inserts or updates a profile by id. Preserves any pre-existing
  /// `encoded_system_fields` blob — a cross-device upsert from the
  /// app-side path must not strip the CKRecord change tag, which is
  /// only ever written by the sync layer.
  func upsert(_ profile: Profile) async throws {
    try await database.write { database in
      var row = ProfileRow(domain: profile)
      // Look up the existing row (if any) and inherit its cached
      // system-fields blob. `init(domain:)` always sets
      // `encodedSystemFields = nil`, so without this copy a domain-side
      // upsert would clear the change tag on every write.
      if let existing =
        try ProfileRow
        .filter(ProfileRow.Columns.id == profile.id)
        .fetchOne(database)
      {
        row.encodedSystemFields = existing.encodedSystemFields
      }
      try row.upsert(database)
      try markNeedsPushSync(id: profile.id, in: database)
    }
    // Capture the closure under the lock, release, then invoke.
    // `OSAllocatedUnfairLock` is non-reentrant, so calling an arbitrary
    // client closure under the lock would deadlock if the closure ever
    // re-entered the repo (e.g. a future `attachSyncHooks` rotation).
    let notify = hooks.withLock { $0.onRecordChanged }
    notify(profile.id)
  }

  /// Deletes a single profile by id. Returns `true` when a row was
  /// removed; `false` when no row existed (idempotent — sign-out and
  /// zone-delete callers don't need to track existence themselves).
  /// Hook fires only when a row was actually deleted.
  @discardableResult
  func delete(id: UUID) async throws -> Bool {
    let didDelete = try await database.write { database in
      try ProfileRow.deleteOne(database, id: id)
    }
    if didDelete {
      // See `upsert` for the lock-then-invoke rationale.
      let notify = hooks.withLock { $0.onRecordDeleted }
      notify(id)
    }
    return didDelete
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from `ProfileIndexSyncHandler` static dispatch tables on the
  // CKSyncEngine delegate's executor. `DatabaseWriter.write { db in … }`
  // has both async and sync overloads; the sync form blocks the calling
  // thread until the queue's serial executor admits the closure. Used
  // only off-MainActor; never call these synchronously from MainActor.

  /// Applies a CKSyncEngine remote-change batch in one transaction:
  /// every saved row is upserted and every deleted id is removed
  /// inside a single `database.write`. If any statement throws, the
  /// whole batch rolls back so prior on-disk state survives byte-equal
  /// — required by the rollback contract in
  /// `guides/DATABASE_CODE_GUIDE.md`.
  func applyRemoteChangesSync(saved rows: [ProfileRow], deleted ids: [UUID]) throws {
    try database.write { database in
      for row in rows {
        // `upsert` matches on the PK conflict (`id`). Because
        // `recordName(for: id)` is total over `id`, the implied UNIQUE
        // conflict on `record_name` is satisfied by the same row, so a
        // single conflict target suffices.
        try row.upsert(database)
      }
      for id in ids {
        _ = try ProfileRow.deleteOne(database, id: id)
      }
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try ProfileRow
        .filter(ProfileRow.Columns.id == id)
        .updateAll(database, [ProfileRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  /// Atomic `max(local, remote)` merge for `data_format_version` —
  /// reads the row and conditionally writes the higher value back inside
  /// a single GRDB write transaction, closing the read-modify-write
  /// window. Called from `ProfileIndexSyncHandler.handleSentRecordZoneChanges`
  /// after `resolveSystemFields(for:)` and before re-queue.
  ///
  /// Does NOT trigger the `pending_change` queue (no `onRecordChanged`
  /// hook fires); CKSyncEngine's own retry covers the re-upload.
  /// No-op when the row is absent (e.g. the profile was deleted between
  /// the conflict response and this call).
  func mergeDataFormatVersionSync(id: UUID, remoteValue: Int) throws {
    try database.write { database in
      guard
        let row =
          try ProfileRow
          .filter(ProfileRow.Columns.id == id)
          .fetchOne(database)
      else { return }
      let merged = max(row.dataFormatVersion, remoteValue)
      guard merged != row.dataFormatVersion else { return }
      _ =
        try ProfileRow
        .filter(ProfileRow.Columns.id == id)
        .updateAll(
          database,
          [ProfileRow.Columns.dataFormatVersion.set(to: merged)])
    }
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try ProfileRow
        .updateAll(
          database,
          [ProfileRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Synchronous equivalent of `fetchAll()`. Used at app startup so the
  /// in-memory `profileStore.profiles` list is populated *before* the
  /// first scene renders — without it the macOS `ProfileWindowView`
  /// resolves to `WelcomeView` for the brief window between launch and
  /// the async load completing, which under `--ui-testing` is long
  /// enough for the test to interact with the wrong UI. Safe on the
  /// main actor: the profile-index DB is small (single-digit row
  /// count in practice) and lives on a serial GRDB queue, so the
  /// read returns in microseconds.
  func fetchAllSync() throws -> [Profile] {
    try database.read { database in
      try ProfileRow
        .order(ProfileRow.Columns.createdAt.asc)
        .fetchAll(database)
        .map { $0.toDomain() }
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path.
  func fetchRowSync(id: UUID) throws -> ProfileRow? {
    try database.read { database in
      try ProfileRow
        .filter(ProfileRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Returns IDs of every row in the table. Used by
  /// `queueAllExistingRecords()` to seed the sync engine.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try ProfileRow
        .select(ProfileRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Async equivalent of `allRowIdsSync()` for callers that must not
  /// block the calling thread (e.g. `@MainActor` sites such as
  /// `ProfileContainerManager.allProfileIds()`). Returns ids only —
  /// avoids materialising full `ProfileRow` objects when only the
  /// primary key is needed.
  func allRowIds() async throws -> [UUID] {
    try await database.read { database in
      try ProfileRow
        .select(ProfileRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used on zone delete / sign-out.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try ProfileRow.deleteAll(database)
    }
  }

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

extension GRDBProfileIndexRepository: ProfileIndexRepository {}
extension GRDBProfileIndexRepository: Sendable {}
