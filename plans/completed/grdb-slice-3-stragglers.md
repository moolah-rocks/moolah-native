# Slice 3 — Profile Index Migration & SwiftData Teardown (detailed plan)

**Status:** Not started.
**Roadmap context:** `plans/grdb-migration.md` §6 → Slice 3.
**Branch (Phase A):** `feat/grdb-slice-3-profile-index` (not yet created).
**Branch (Phase B):** `chore/grdb-slice-3-swiftdata-teardown` (not yet created).
**Parent branch:** `main` (Slice 1's PR [#573](https://github.com/ajsutton/moolah-native/pull/573) merged via [#573](https://github.com/ajsutton/moolah-native/pull/573) — already on `main`).

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Tasks under §3 are written for direct execution.

---

## 1. Goal

Migrate the eleventh and final synced record type — `ProfileRecord`, the
profile-index entry that lives in CloudKit's `profile-index` zone — from
SwiftData (`@Model class ProfileRecord` under
`Backends/CloudKit/Models/`) to GRDB (`Sendable struct ProfileRow` under
`Backends/GRDB/Records/`), then **delete the SwiftData layer entirely**.

After Slice 3 ships:

- Every CloudKit record type is GRDB-backed.
- `import SwiftData` appears in zero production files.
- All `@Model` classes (eleven of them) and the
  `SwiftDataToGRDBMigrator` are deleted.
- `ProfileContainerManager` no longer holds a `ModelContainer`; it holds
  a single per-profile `DatabaseQueue` and an app-scoped
  `ProfileIndexRepository`.
- `Moolah-v2.store` and `Moolah-{UUID}.store` SwiftData files are
  deleted from disk on first launch after upgrade (gated by a
  `UserDefaults` flag, like the legacy rate-cache cleanup in Step 2).

The slice ships in **two phases** so review surface stays small and the
migrator can verify itself in production before its source rows are
deleted:

- **Phase A — ProfileRecord migration.** New `profile-index.sqlite`
  database, `ProfileRow` struct + mapping + CloudKit conformance,
  `GRDBProfileIndexRepository`, migrator extension reading
  `ProfileRecord` from the SwiftData index container. SwiftData
  `@Model` classes stay in place (the migrator and the legacy `ProfileStore`
  mutation paths still consult them until Phase B lands).
- **Phase B — SwiftData teardown.** Once Phase A has shipped a release
  the user has run on every device (verified by their telemetry / our
  manual confirmation), delete the eleven `@Model` classes, delete the
  `SwiftDataToGRDBMigrator` (it is no longer needed — every device has
  by definition been migrated), delete `ProfileDataDeleter`, strip
  `import SwiftData` from every production file, and shrink
  `ProfileContainerManager` to its GRDB-only surface.

Phase A and Phase B are sized small enough to ship as separate PRs
without churn. Phase B is gated by a single criterion: **at least one
release containing Phase A's migrator must have run on every active
device**. The plan below treats them as sequential.

The slice does **not** ship:

- `AnalysisRepository` SQL aggregation — already shipped via Slice 4
  (PR [#594](https://github.com/ajsutton/moolah-native/pull/594)). The
  CloudKit-side analysis helpers were also deleted as part of #594, so
  Slice 3 has nothing to do under
  `Backends/CloudKit/Repositories/` (the directory no longer exists).
- Schema changes to existing GRDB tables. The `profile` table is the
  only new one.
- Changes to CloudKit zone layout. The `profile-index` zone, its
  `ProfileRecord` wire type, and the per-profile zones are unchanged.

---

## 2. What's already in place from Slice 0/1 (don't change)

Slice 0 and Slice 1 establish the patterns Slice 3 mirrors:

| File | Provides |
|---|---|
| `Backends/GRDB/ProfileDatabase.swift` | `DatabaseQueue` factory: `open(at:)` + `openInMemory()`. Reused for the new `profile-index.sqlite`. |
| `Backends/GRDB/ProfileSchema.swift` | `DatabaseMigrator` for the per-profile DB. Slice 3 does **not** add a migration here — `ProfileRow` lives in a separate database and gets its own schema file. |
| `Backends/GRDB/Records/CSVImportProfileRow.swift` + `+Mapping.swift` | Reference shape for `ProfileRow`. |
| `Backends/GRDB/Sync/CSVImportProfileRow+CloudKit.swift` | Reference shape for `ProfileRow+CloudKit.swift`. |
| `Backends/GRDB/Repositories/GRDBCSVImportProfileRepository.swift` | Reference shape for `GRDBProfileIndexRepository`. |
| `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift` | `@MainActor` migrator with per-type `committed` / `defer` flag pattern. **Now async** — `migrateIfNeeded(...)` and every per-type method are `async throws`; SwiftData fetches stay on `@MainActor` while GRDB writes hand off to the writer queue (issue #575, PR #592). Slice 3 Phase A extends it with one more (also-async) type, then Phase B deletes the whole file. |
| `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift` | The handler we are rewriting. Reads/writes ProfileRecord rows via `ModelContext`; Phase A swaps to GRDB. |
| `App/MoolahApp+Setup.swift` `makeContainerSetup` | Currently creates a SwiftData index container + `dataSchema`. Phase A leaves the index container alone (the migrator still needs it); Phase B strips it. |
| `Shared/ProfileContainerManager.swift` | Holds `indexContainer`, per-profile `containers` (SwiftData), per-profile `databases` (GRDB). Phase A adds `profileIndexRepository`; Phase B drops `indexContainer`, `containers`, and `dataSchema`. |
| `Backends/CloudKit/Sync/SyncCoordinator.swift` | Constructs `ProfileIndexSyncHandler(modelContainer:)`. Phase A switches the constructor parameter from `ModelContainer` to `GRDBProfileIndexRepository`; Phase B does nothing here. |

The slice extends, never replaces. New SQLite file `profile-index.sqlite`
is justified per `plans/grdb-migration.md` §4 ("A new SQLite file is
justified only when the data has materially different access patterns /
durability / lifetime to existing per-profile data"): the profile index
spans the entire app, lives independently of any active profile session,
and must be readable before any profile is selected — no per-profile
`data.sqlite` can host it.

---

## 3. What's left

### Phase A — ProfileRecord migration to GRDB

#### 3.A.1 New database file

App-scoped database at:

```
URL.moolahScopedApplicationSupport
  .appendingPathComponent("Moolah", isDirectory: true)
  .appendingPathComponent("profile-index.sqlite")
```

Owned by `ProfileContainerManager`. Created on first construction; the
`DatabaseMigrator` runs at open time. WAL mode and project PRAGMA
defaults inherited from `ProfileDatabase.open(at:)` — **reuse the
existing helper**, do not duplicate.

```swift
// Backends/GRDB/ProfileIndexDatabase.swift
import Foundation
import GRDB

enum ProfileIndexDatabase {
  /// Opens (or creates) the app-scoped `profile-index.sqlite` at the
  /// given URL, applies `ProfileIndexSchema.migrator`, and returns the
  /// `DatabaseQueue`. Mirrors `ProfileDatabase.open(at:)` so the PRAGMA
  /// configuration stays in lock-step.
  static func open(at url: URL) throws -> DatabaseQueue {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    var configuration = Configuration()
    configuration.prepareDatabase { database in
      try database.execute(sql: "PRAGMA journal_mode = WAL")
      try database.execute(sql: "PRAGMA foreign_keys = ON")
      // …other PRAGMAs identical to ProfileDatabase.swift…
    }
    let database = try DatabaseQueue(path: url.path, configuration: configuration)
    try ProfileIndexSchema.migrator.migrate(database)
    return database
  }

  static func openInMemory() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.prepareDatabase { database in
      try database.execute(sql: "PRAGMA foreign_keys = ON")
    }
    let database = try DatabaseQueue(configuration: configuration)
    try ProfileIndexSchema.migrator.migrate(database)
    return database
  }
}
```

Verify the existing PRAGMA list in `ProfileDatabase.swift` and copy
**every** PRAGMA into `ProfileIndexDatabase.open` — drift between the two
opens-and-PRAGMAs would be subtle. If `ProfileDatabase.swift` already
exposes a shared PRAGMA-application helper, use it directly; otherwise,
factor the PRAGMA block out into a `Backends/GRDB/Shared/Pragmas.swift`
helper consumed by both.

#### 3.A.2 Schema

```swift
// Backends/GRDB/ProfileIndexSchema.swift
import Foundation
import GRDB

/// Schema for the app-scoped `profile-index.sqlite`. Holds one row per
/// CloudKit profile; the `profile-index` zone is shared across all
/// profiles so this DB lives alongside (not inside) the per-profile
/// `data.sqlite` files.
enum ProfileIndexSchema {
  static let version = 1

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    #if DEBUG
      migrator.eraseDatabaseOnSchemaChange = true
    #endif

    migrator.registerMigration("v1_initial", migrate: createProfileTable)

    return migrator
  }

  private static func createProfileTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE profile (
            id                          BLOB    NOT NULL PRIMARY KEY,
            record_name                 TEXT    NOT NULL UNIQUE,
            label                       TEXT    NOT NULL,
            currency_code               TEXT    NOT NULL,
            financial_year_start_month  INTEGER NOT NULL
                CHECK (financial_year_start_month BETWEEN 1 AND 12),
            created_at                  TEXT    NOT NULL,
            encoded_system_fields       BLOB
        ) STRICT;

        -- Drives `loadCloudProfiles`'s SortDescriptor(\\.createdAt).
        CREATE INDEX profile_by_created_at ON profile(created_at);
        """)
  }
}
```

Schema notes:

- **STRICT** non-negotiable per `DATABASE_SCHEMA_GUIDE.md` §3.
- **`record_name TEXT NOT NULL UNIQUE`** — every synced table per
  `plans/grdb-migration.md` §4. Format: `"ProfileRecord|<UUID>"`.
- **`encoded_system_fields BLOB` (nullable).** Bit-for-bit copies of
  CloudKit's bytes; never decoded outside `Backends/CloudKit/Sync/`.
- **No FK in or out.** ProfileRecord references nothing and nothing
  references it (the per-profile DB carries its own data, keyed by the
  same UUID but joined only at the application layer).
- **CHECK** on `financial_year_start_month` matches the existing
  default of `7` and the validation enforced by `Profile`'s domain
  layer (months 1–12). Domain rejects out-of-range values today; the
  storage CHECK is defence-in-depth.
- **`WITHOUT ROWID` not justified.** Wide-ish row, ROWID overhead
  negligible. Keep ROWID.

#### 3.A.3 `ProfileRow` + Mapping

```swift
// Backends/GRDB/Records/ProfileRow.swift
import Foundation
import GRDB

/// One row in the `profile` table — the GRDB-backed counterpart to
/// the SwiftData `@Model` `ProfileRecord`. Lives in
/// `profile-index.sqlite` (an app-scoped DB shared across all
/// profiles), not in any `data.sqlite`.
///
/// **Naming.** "Row" is the GRDB convention. The SwiftData
/// `ProfileRecord` retains its name until Phase B deletes the
/// `@Model` class entirely.
struct ProfileRow {
  static let databaseTableName = "profile"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case label
    case currencyCode = "currency_code"
    case financialYearStartMonth = "financial_year_start_month"
    case createdAt = "created_at"
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case label
    case currencyCode = "currency_code"
    case financialYearStartMonth = "financial_year_start_month"
    case createdAt = "created_at"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var label: String
  var currencyCode: String
  var financialYearStartMonth: Int
  var createdAt: Date
  var encodedSystemFields: Data?
}

extension ProfileRow: Codable {}
extension ProfileRow: Sendable {}
extension ProfileRow: Identifiable {}
extension ProfileRow: FetchableRecord {}
extension ProfileRow: PersistableRecord {}
extension ProfileRow: GRDBSystemFieldsStampable {}
```

```swift
// Backends/GRDB/Records/ProfileRow+Mapping.swift
import Foundation

extension ProfileRow {
  static let recordType = "ProfileRecord"

  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  init(domain profile: Profile) {
    self.init(
      id: profile.id,
      recordName: ProfileRow.recordName(for: profile.id),
      label: profile.label,
      currencyCode: profile.currencyCode,
      financialYearStartMonth: profile.financialYearStartMonth,
      createdAt: profile.createdAt,
      encodedSystemFields: nil)
  }

  func toDomain() -> Profile {
    Profile(
      id: id,
      label: label,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth,
      createdAt: createdAt)
  }
}
```

**One extension per protocol** per `CODE_GUIDE.md` §11. **No inline
conformance lists.** Mirror `CSVImportProfileRow.swift` exactly.

#### 3.A.4 `ProfileRow + CloudKit`

```swift
// Backends/GRDB/Sync/ProfileRow+CloudKit.swift
import CloudKit
import Foundation

extension ProfileRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    ProfileRecordCloudKitFields(
      createdAt: createdAt,
      currencyCode: currencyCode,
      financialYearStartMonth: Int64(financialYearStartMonth),
      label: label
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> ProfileRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = ProfileRecordCloudKitFields(from: ckRecord)
    let monthRaw = Int(fields.financialYearStartMonth ?? 7)
    // Mirror the skip-and-log pattern Slice 1 established for
    // CHECK-violating remote rows (see AccountRow+CloudKit.swift).
    // financial_year_start_month must be 1…12; out-of-range values
    // would trip the SQLite CHECK on upsert and stall the batch.
    let month = (1...12).contains(monthRaw) ? monthRaw : 7
    return ProfileRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      label: fields.label ?? "",
      currencyCode: fields.currencyCode ?? "",
      financialYearStartMonth: month,
      createdAt: fields.createdAt ?? Date(),
      // Stamped post-upsert by ProfileIndexSyncHandler; never read
      // from the CKRecord itself.
      encodedSystemFields: nil)
  }
}
```

Wire `recordType = "ProfileRecord"` is **frozen** — the existing
CloudKit zone references this exact string. Use the
auto-generated `ProfileRecordCloudKitFields` struct from
`Backends/CloudKit/Sync/Generated/`.

`RecordTypeRegistry.allTypes` (in
`Backends/CloudKit/Sync/CloudKitRecordConvertible.swift`) updates the
value for `ProfileRecord` to point at `ProfileRow.self`. Wire string
unchanged.

#### 3.A.5 `GRDBProfileIndexRepository`

Single repository covering both the app-side mutation surface
(`ProfileStore` consumer) and the sync-side dispatch surface
(`ProfileIndexSyncHandler` consumer). Mirrors
`GRDBCSVImportProfileRepository`'s shape: `final class …
@unchecked Sendable`, `let database`, `@Sendable` hooks, sync entry
points for the CKSyncEngine delegate executor.

```swift
// Backends/GRDB/Repositories/GRDBProfileIndexRepository.swift
import Foundation
import GRDB
import OSLog

/// GRDB-backed repository for `ProfileRow` rows in the app-scoped
/// `profile-index.sqlite`. Replaces the SwiftData fetch path inside
/// `ProfileStore` and `ProfileIndexSyncHandler`.
///
/// **Concurrency.** `final class` + `@unchecked Sendable`, mirroring the
/// per-profile GRDB repos. All stored properties are `let`. `database`
/// (`any DatabaseWriter`) is itself `Sendable`. `onRecordChanged` and
/// `onRecordDeleted` are `@Sendable` closures captured at init.
final class GRDBProfileIndexRepository: @unchecked Sendable {
  private let database: any DatabaseWriter
  private let onRecordChanged: @Sendable (UUID) -> Void
  private let onRecordDeleted: @Sendable (UUID) -> Void
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "GRDBProfileIndexRepository")

  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (UUID) -> Void = { _ in },
    onRecordDeleted: @escaping @Sendable (UUID) -> Void = { _ in }
  ) {
    self.database = database
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - App-side surface (consumed by ProfileStore)

  /// Returns every profile, ordered by `createdAt` ascending. Mirrors
  /// the existing SwiftData `FetchDescriptor<ProfileRecord>(sortBy:
  /// [SortDescriptor(\.createdAt)])`.
  func fetchAll() async throws -> [Profile] {
    try await database.read { database in
      try ProfileRow
        .order(ProfileRow.Columns.createdAt.asc)
        .fetchAll(database)
        .map { $0.toDomain() }
    }
  }

  /// Inserts or updates a profile, then fires the change hook so
  /// CKSyncEngine queues an upload.
  func upsert(_ profile: Profile) async throws {
    try await database.write { database in
      var row = ProfileRow(domain: profile)
      // Preserve encodedSystemFields if a row already exists for this id.
      if let existing = try ProfileRow
        .filter(ProfileRow.Columns.id == profile.id)
        .fetchOne(database)
      {
        row.encodedSystemFields = existing.encodedSystemFields
      }
      try row.upsert(database)
    }
    onRecordChanged(profile.id)
  }

  /// Deletes a profile row and fires the delete hook so CKSyncEngine
  /// queues a deletion.
  @discardableResult
  func delete(id: UUID) async throws -> Bool {
    let didDelete = try await database.write { database in
      try ProfileRow.deleteOne(database, key: id)
    }
    if didDelete {
      onRecordDeleted(id)
    }
    return didDelete
  }

  /// Returns every profile id known to the index. Used by
  /// `ProfileIndexSyncHandler.queueAllExistingRecords()` on first
  /// start.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try ProfileRow
        .select(ProfileRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from ProfileIndexSyncHandler on the CKSyncEngine delegate's
  // executor. Same convention as GRDBCSVImportProfileRepository.

  /// Applies a CKSyncEngine batch of ProfileRow upserts and deletes
  /// to the local store atomically. Throws on write failure so the
  /// caller can return `.saveFailed` and CKSyncEngine refetches.
  func applyRemoteChangesSync(saved rows: [ProfileRow], deleted ids: [UUID]) throws {
    try database.write { database in
      for row in rows {
        try row.upsert(database)
      }
      for id in ids {
        _ = try ProfileRow.deleteOne(database, key: id)
      }
    }
  }

  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try ProfileRow
        .filter(ProfileRow.Columns.id == id)
        .updateAll(database, [ProfileRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ = try ProfileRow
        .updateAll(
          database,
          [ProfileRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  func fetchRowSync(id: UUID) throws -> ProfileRow? {
    try database.read { database in
      try ProfileRow
        .filter(ProfileRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  func deleteAllSync() throws {
    try database.write { database in
      _ = try ProfileRow.deleteAll(database)
    }
  }
}
```

The single `(UUID) -> Void` hook signature (rather than the per-profile
`(String, UUID) -> Void` form) reflects that ProfileRecord is the only
type sharing this database — there's no record-type ambiguity to disam-
biguate. The ProfileIndexSyncHandler doesn't need the recordType prefix.

#### 3.A.6 `ProfileIndexSyncHandler` rewrite

Swap the SwiftData-backed body for the GRDB-backed equivalent. Same
`@MainActor final class` shape, same external surface, identical
public API.

```swift
// Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift
@preconcurrency import CloudKit
import Foundation
import OSLog

@MainActor
final class ProfileIndexSyncHandler {
  nonisolated let zoneID: CKRecordZone.ID
  nonisolated let repository: GRDBProfileIndexRepository

  nonisolated private let logger = Logger(
    subsystem: "com.moolah.app", category: "ProfileIndexSyncHandler")

  init(repository: GRDBProfileIndexRepository) {
    self.repository = repository
    self.zoneID = CKRecordZone.ID(
      zoneName: "profile-index",
      ownerName: CKCurrentUserDefaultName)
  }

  // MARK: - Applying Remote Changes

  nonisolated func applyRemoteChanges(saved: [CKRecord], deleted: [CKRecord.ID]) -> ApplyResult {
    var rows: [ProfileRow] = []
    rows.reserveCapacity(saved.count)
    for ckRecord in saved {
      guard ckRecord.recordType == ProfileRow.recordType else { continue }
      guard var row = ProfileRow.fieldValues(from: ckRecord) else {
        logger.error(
          "applyRemoteChanges: malformed recordID '\(ckRecord.recordID.recordName)' — skipping")
        continue
      }
      row.encodedSystemFields = ckRecord.encodedSystemFields
      rows.append(row)
    }

    var deletedIds: [UUID] = []
    deletedIds.reserveCapacity(deleted.count)
    for recordID in deleted {
      guard let id = recordID.uuid else {
        logger.error(
          "applyRemoteChanges: malformed deleted recordID '\(recordID.recordName)' — skipping")
        continue
      }
      deletedIds.append(id)
    }

    do {
      try repository.applyRemoteChangesSync(saved: rows, deleted: deletedIds)
      return .success(changedTypes: Set(saved.map(\.recordType)))
    } catch {
      logger.error("Failed to apply remote profile changes: \(error, privacy: .public)")
      return .saveFailed(error.localizedDescription)
    }
  }

  // MARK: - Building CKRecords

  func buildCKRecord(for row: ProfileRow) -> CKRecord {
    let freshRecord = row.toCKRecord(in: zoneID)
    if let cachedData = row.encodedSystemFields,
      let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData),
      ProfileDataSyncHandler.isUsableCachedRecordName(cachedRecord.recordID.recordName)
    {
      for key in freshRecord.allKeys() {
        cachedRecord[key] = freshRecord[key]
      }
      return cachedRecord
    }
    return freshRecord
  }

  // MARK: - Record Lookup for Upload

  func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    guard let id = recordID.uuid else { return nil }
    do {
      guard let row = try repository.fetchRowSync(id: id) else { return nil }
      return buildCKRecord(for: row)
    } catch {
      logger.error(
        "recordToSave: GRDB fetch failed for \(id, privacy: .public): \(error, privacy: .public)")
      return nil
    }
  }

  // MARK: - Queue All Existing Records

  func queueAllExistingRecords() -> [CKRecord.ID] {
    do {
      let ids = try repository.allRowIdsSync()
      guard !ids.isEmpty else { return [] }
      let recordIDs = ids.map { id in
        CKRecord.ID(
          recordType: ProfileRow.recordType, uuid: id, zoneID: zoneID)
      }
      logger.info("Collected \(recordIDs.count) existing profiles for upload")
      return recordIDs
    } catch {
      logger.error("queueAllExistingRecords: \(error, privacy: .public)")
      return []
    }
  }

  // MARK: - Local Data Deletion

  func deleteLocalData() {
    do {
      try repository.deleteAllSync()
      logger.info("Deleted all local profile index data")
    } catch {
      logger.error("Failed to delete local profile data: \(error, privacy: .public)")
    }
  }

  // MARK: - System Fields Management

  func clearAllSystemFields() {
    do {
      try repository.clearAllSystemFieldsSync()
    } catch {
      logger.error("Failed to clear all system fields: \(error, privacy: .public)")
    }
  }

  func updateEncodedSystemFields(_ recordID: CKRecord.ID, data: Data) {
    guard let id = recordID.uuid else { return }
    do {
      _ = try repository.setEncodedSystemFieldsSync(id: id, data: data)
    } catch {
      logger.error("Failed to update system fields: \(error, privacy: .public)")
    }
  }

  func clearEncodedSystemFields(_ recordID: CKRecord.ID) {
    guard let id = recordID.uuid else { return }
    do {
      _ = try repository.setEncodedSystemFieldsSync(id: id, data: nil)
    } catch {
      logger.error("Failed to clear system fields: \(error, privacy: .public)")
    }
  }

  // MARK: - Handle Sent Record Zone Changes

  func handleSentRecordZoneChanges(
    savedRecords: [CKRecord],
    failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
    failedDeletes: [(CKRecord.ID, CKError)]
  ) -> SyncErrorRecovery.ClassifiedFailures {
    persistSystemFields(for: savedRecords)
    let failures = SyncErrorRecovery.classify(
      failedSaves: failedSaves,
      failedDeletes: failedDeletes,
      logger: logger)
    resolveSystemFields(for: failures)
    return failures
  }

  private func persistSystemFields(for savedRecords: [CKRecord]) {
    for saved in savedRecords {
      updateEncodedSystemFields(saved.recordID, data: saved.encodedSystemFields)
    }
  }

  private func resolveSystemFields(for failures: SyncErrorRecovery.ClassifiedFailures) {
    for (_, serverRecord) in failures.conflicts {
      updateEncodedSystemFields(serverRecord.recordID, data: serverRecord.encodedSystemFields)
    }
    for (recordID, _) in failures.unknownItems {
      clearEncodedSystemFields(recordID)
    }
  }
}
```

`SyncCoordinator.init(...)` updates to construct the handler with the
new repository:

```swift
self.profileIndexHandler = ProfileIndexSyncHandler(
  repository: containerManager.profileIndexRepository)
```

`containerManager.profileIndexRepository` is the new property added in
§3.A.7. The `modelContainer:` parameter is removed.

#### 3.A.7 `ProfileContainerManager` extension

Add `profileIndexRepository: GRDBProfileIndexRepository` and the
infrastructure to construct it. `indexContainer` stays in place for
Phase A (the migrator and the legacy `addProfile` / `updateProfile`
paths still need it during the transition); Phase B drops it.

```swift
// Shared/ProfileContainerManager.swift (Phase A additions only)
@Observable
@MainActor
final class ProfileContainerManager {
  let indexContainer: ModelContainer            // unchanged in Phase A
  let profileIndexRepository: GRDBProfileIndexRepository  // NEW
  private let dataSchema: Schema
  let inMemory: Bool
  private var containers: [UUID: ModelContainer] = [:]
  private var databases: [UUID: DatabaseQueue] = [:]
  private let profileIndexDatabase: DatabaseQueue   // NEW

  init(
    indexContainer: ModelContainer,
    profileIndexDatabase: DatabaseQueue,            // NEW
    dataSchema: Schema,
    inMemory: Bool = false
  ) {
    self.indexContainer = indexContainer
    self.profileIndexDatabase = profileIndexDatabase
    self.dataSchema = dataSchema
    self.inMemory = inMemory
    self.profileIndexRepository = GRDBProfileIndexRepository(
      database: profileIndexDatabase,
      onRecordChanged: { _ in /* wired by SyncCoordinator below */ },
      onRecordDeleted: { _ in /* wired by SyncCoordinator below */ })
  }

  // …existing methods unchanged in Phase A…
}
```

The `onRecordChanged` / `onRecordDeleted` hook closures need to publish
to `SyncCoordinator.queueSave` / `queueDeletion`. **Wire those at the
SyncCoordinator side**, not the container manager: in
`MoolahApp+Setup.configureSyncCoordinator(...)`, replace the existing

```swift
store.onProfileChanged = { [weak coordinator] id in
  let zoneID = CKRecordZone.ID(zoneName: "profile-index", …)
  coordinator?.queueSave(recordType: ProfileRecord.recordType, id: id, zoneID: zoneID)
}
store.onProfileDeleted = { [weak coordinator] id in
  let zoneID = CKRecordZone.ID(zoneName: "profile-index", …)
  coordinator?.queueDeletion(recordType: ProfileRecord.recordType, id: id, zoneID: zoneID)
}
```

with hooks on the repository instead. Construct the repository with the
hooks at SyncCoordinator construction time:

```swift
// Inside SyncCoordinator.init or a setup helper
let zoneID = CKRecordZone.ID(zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
let repo = containerManager.profileIndexRepository
// Hook-attachment helper lets SyncCoordinator install the closures
// onto the existing repository instance after construction.
repo.attachSyncHooks(
  onRecordChanged: { [weak self] id in
    self?.queueSave(recordType: ProfileRow.recordType, id: id, zoneID: zoneID)
  },
  onRecordDeleted: { [weak self] id in
    self?.queueDeletion(recordType: ProfileRow.recordType, id: id, zoneID: zoneID)
  })
```

`attachSyncHooks` is a new method on `GRDBProfileIndexRepository` that
swaps the `let` hooks for `var` `Atomic<...>`-wrapped storage so the
post-init injection compiles. Alternative: inject the SyncCoordinator
into the repository constructor (or a thin protocol it conforms to) so
the hooks resolve via the protocol — that's cleaner but introduces a
cycle (`SyncCoordinator` → `containerManager.profileIndexRepository` →
`SyncCoordinator`).

**Pick the post-init `attachSyncHooks` form** — it's a one-shot wiring
call at app launch, the implementation uses
`@MainActor`-isolated `private var` storage (no cross-thread mutation
because `attachSyncHooks` is `@MainActor` and the hook is read from
the GRDB queue executor *after* attach has run), and the cycle is
broken because the `[weak self]` capture is in `SyncCoordinator`.

Verify the `@MainActor`/`Sendable` story carefully during code review;
if it can't be made clean, fall back to the per-init injection form
and accept the cycle (resolved by lazy hook lookup through a closure
captured by `containerManager`).

#### 3.A.8 `ProfileStore` rewrite

Swap the SwiftData index reads/writes for repository calls.
`containerManager` stays in the constructor for the per-profile
container surface (until Phase B drops it).

```swift
// Features/Profiles/ProfileStore.swift
@Observable
@MainActor
final class ProfileStore {
  // …
  private let profileIndexRepository: GRDBProfileIndexRepository

  init(
    defaults: UserDefaults = .standard,
    containerManager: ProfileContainerManager? = nil,
    syncCoordinator: SyncCoordinator? = nil
  ) {
    self.defaults = defaults
    self.containerManager = containerManager
    self.syncCoordinator = syncCoordinator
    self.profileIndexRepository = containerManager?.profileIndexRepository
      ?? GRDBProfileIndexRepository(
        database: (try? ProfileIndexDatabase.openInMemory())
          ?? (preconditionFailure("ProfileStore needs a profileIndexRepository")))
    loadFromDefaults()
    if containerManager != nil {
      loadCloudProfiles(isInitialLoad: true)
      scheduleRetryIfNeeded()
    } else {
      isCloudLoadPending = false
    }
  }

  func addProfile(_ profile: Profile) {
    Task { [weak self] in
      do {
        try await self?.profileIndexRepository.upsert(profile)
      } catch {
        self?.logger.error("Failed to add profile: \(error, privacy: .public)")
      }
    }
    profiles.append(profile)
    if profiles.count == 1 {
      activeProfileID = profile.id
      saveActiveProfileID()
    }
  }

  // updateProfile / removeProfile mirror this shape.
}
```

The `addProfile` / `updateProfile` path becomes **fire-and-forget
async** because the SwiftUI binding doesn't need to wait on the GRDB
write. (The existing SwiftData path is synchronous — it calls
`context.save()` directly.) Wrap the `Task` in a tracked
`@MainActor private var pendingWriteTask: Task<Void, Never>?` per
`CONCURRENCY_GUIDE.md` §8 — fire-and-forget tasks must be tracked.

Alternative: make `addProfile` / `updateProfile` `async`. Investigate
during implementation whether every call site can `await`; if there
are SwiftUI-binding contexts that can't, stick with the
fire-and-forget form. (Current SwiftData synchronous path suggests
most call sites don't `await`; favour fire-and-forget.)

`loadCloudProfiles` becomes:

```swift
func loadCloudProfiles(isInitialLoad: Bool = false) {
  guard let containerManager else { return }
  let repo = containerManager.profileIndexRepository
  Task { [weak self] in
    do {
      let loaded = try await repo.fetchAll()
      await MainActor.run {
        self?.applyLoadedProfiles(loaded, isInitialLoad: isInitialLoad)
      }
    } catch {
      self?.logger.error("Failed to load cloud profiles: \(error, privacy: .public)")
    }
  }
}

private func applyLoadedProfiles(_ loaded: [Profile], isInitialLoad: Bool) {
  let previousCloudProfiles = profiles
  profiles = loaded
  // …rest of existing logic unchanged…
}
```

The async hop is a new behaviour — `loadCloudProfiles` previously
returned synchronously after a `context.fetch`. Verify that
`WelcomeView`'s binding on `profiles.count` / `activeProfile` still
behaves correctly when the load lands one tick later (SwiftUI
@Observable should propagate fine).

#### 3.A.9 `ProfileDataDeleter` removal

`ProfileDataDeleter.deleteProfileRecord(for:)` becomes a single
`profileIndexRepository.delete(id:)` call. Delete the file in Phase A
(it's a one-method utility); inline the call inside
`ProfileStore.removeProfile`.

#### 3.A.10 SwiftDataToGRDBMigrator extension

Add a single per-type migrator for `ProfileRecord`. Same `committed`
defer flag pattern as Slice 0/1, **and async** to match the post-#592
migrator shape (the existing per-type methods are all `async throws`
already; the SwiftData fetch stays on `@MainActor` while the GRDB
write hands off to the writer queue).

```swift
// Backends/GRDB/Migration/SwiftDataToGRDBMigrator+ProfileIndex.swift
extension SwiftDataToGRDBMigrator {
  static let profileIndexFlag = "v4.profileIndex.grdbMigrated"

  /// Migrates `ProfileRecord` rows from the SwiftData index container
  /// to the GRDB `profile-index.sqlite`. Reads from the index
  /// container (not a per-profile container); the destination is
  /// app-scoped, not per-profile, so this migrator runs once per
  /// install rather than once per profile.
  func migrateProfileIndexIfNeeded(
    indexContainer: ModelContainer,
    profileIndexDatabase: any DatabaseWriter,
    defaults: UserDefaults
  ) async throws {
    guard !defaults.bool(forKey: Self.profileIndexFlag) else { return }
    var committed = false
    var rowCount = 0
    defer {
      if committed {
        defaults.set(true, forKey: Self.profileIndexFlag)
        logger.info(
          """
          SwiftData → GRDB migration complete for ProfileRecord: \
          \(rowCount, privacy: .public) row(s) copied
          """)
      }
    }
    let context = ModelContext(indexContainer)
    let descriptor = FetchDescriptor<ProfileRecord>()
    let sourceRows: [ProfileRecord]
    do {
      sourceRows = try context.fetch(descriptor)
    } catch {
      logger.error(
        """
        SwiftData fetch for ProfileRecord failed during GRDB migration: \
        \(error.localizedDescription, privacy: .public). Migration aborted; \
        will retry next launch.
        """)
      throw error
    }
    let mappedRows = sourceRows.map(Self.mapProfile(_:))
    if !mappedRows.isEmpty {
      try await profileIndexDatabase.write { database in
        for row in mappedRows {
          try row.upsert(database)
        }
      }
    }
    rowCount = mappedRows.count
    committed = true
  }

  private static func mapProfile(_ source: ProfileRecord) -> ProfileRow {
    ProfileRow(
      id: source.id,
      recordName: ProfileRow.recordName(for: source.id),
      label: source.label,
      currencyCode: source.currencyCode,
      financialYearStartMonth: source.financialYearStartMonth,
      createdAt: source.createdAt,
      encodedSystemFields: source.encodedSystemFields)
  }
}
```

**Hook point.** Unlike the per-profile migrators (which run from
`ProfileSession.runSwiftDataToGRDBMigrationIfNeeded` and need a
specific profile-id), the profile-index migrator runs **once at app
launch** before `ProfileStore.init`. Add a new helper to
`MoolahApp+Setup.swift`:

```swift
extension MoolahApp {
  /// Runs the one-shot ProfileRecord (index) migration at app launch.
  /// Must run before ProfileStore.init so the first cloud-profiles
  /// load reads from a populated GRDB.
  static func runProfileIndexMigrationIfNeeded(
    setup: ContainerSetup,
    defaults: UserDefaults = .standard
  ) async {
    do {
      try await SwiftDataToGRDBMigrator().migrateProfileIndexIfNeeded(
        indexContainer: setup.manager.indexContainer,
        profileIndexDatabase: setup.manager.profileIndexRepository.databaseWriter,
        defaults: defaults)
    } catch {
      Logger(subsystem: "com.moolah.app", category: "Setup")
        .error("ProfileRecord migration failed: \(error, privacy: .public)")
    }
  }
}
```

The migrator failure is logged but **not fatal**: if it fails the user
sees no profiles on first launch (because GRDB is empty), but the next
launch retries. This is the same failure mode Slice 0 / 1 already
accept. A retry-on-next-launch loop on a permanent fetch error is the
worst outcome — acceptable trade-off vs. crashing the app at startup.

The hook needs an `await` site at app launch — `MoolahApp.init`
already awaits the per-profile migration via
`ProfileSession.runSwiftDataToGRDBMigrationIfNeeded` (post-#592), so
adding one more `await` for the profile-index migration before
`ProfileStore.init` follows the same pattern.

`databaseWriter` is a new computed property exposed by
`GRDBProfileIndexRepository` that returns the underlying
`any DatabaseWriter` so the migrator can write through the same queue
the repository uses. Without exposing it, the migrator would have to
construct a parallel queue and the schema migrator would run twice on
the same file.

Add the reset call to `SwiftDataToGRDBMigrator.allMigrationFlags` so
UI tests reset this flag too:

```swift
static let allMigrationFlags: [String] = [
  csvImportProfilesFlag,
  importRulesFlag,
  instrumentsFlag,
  // …
  transactionLegsFlag,
  profileIndexFlag,    // NEW
]
```

#### 3.A.11 BackendProvider / `CloudKitBackend` — no change

`CloudKitBackend` doesn't expose `ProfileIndexRepository` (the index
isn't a domain repository — it's an app-level concern). No changes
here.

#### 3.A.12 Wiring update in `MoolahApp+Setup`

`makeContainerSetup` adds the `profileIndexDatabase` construction:

```swift
static func makeContainerSetup(uiTestingSeed: UITestSeed?) -> ContainerSetup {
  do {
    if let seed = uiTestingSeed {
      SwiftDataToGRDBMigrator.resetMigrationFlags()
      let manager = try ProfileContainerManager.forTesting()
      let profile = try UITestSeedHydrator.hydrate(seed, into: manager)
      return ContainerSetup(manager: manager, uiTestingProfileId: profile?.id)
    }

    let profileSchema = Schema([ProfileRecord.self])
    let profileStoreURL = URL.moolahScopedApplicationSupport
      .appending(path: "Moolah-v2.store")
    let profileConfig = ModelConfiguration(
      url: profileStoreURL,
      cloudKitDatabase: .none)
    let indexContainer = try ModelContainer(
      for: profileSchema, configurations: [profileConfig])

    let dataSchema = Schema([
      AccountRecord.self, /* …existing list… */ ImportRuleRecord.self,
    ])

    // NEW: open the app-scoped profile-index.sqlite
    let profileIndexURL = URL.moolahScopedApplicationSupport
      .appendingPathComponent("Moolah", isDirectory: true)
      .appendingPathComponent("profile-index.sqlite")
    let profileIndexDatabase = try ProfileIndexDatabase.open(at: profileIndexURL)

    let manager = ProfileContainerManager(
      indexContainer: indexContainer,
      profileIndexDatabase: profileIndexDatabase,
      dataSchema: dataSchema)
    return ContainerSetup(manager: manager, uiTestingProfileId: nil)
  } catch {
    fatalError("Failed to initialize containers: \(error)")
  }
}
```

`ProfileContainerManager.forTesting()` updates similarly: open an
in-memory profile-index DB.

`MoolahApp.init` (or wherever `runProfileIndexMigrationIfNeeded` is
hooked) calls the migrator helper after `makeContainerSetup` returns
and before `ProfileStore.init`.

**UI test seed hydrator** — `UITestSeedHydrator+Upserts.upsertProfile`
moves to writing into the GRDB profile-index repository instead of
SwiftData. Mirror the existing
`upsertCSVImportProfile`-style helper. Keeps the SwiftData fallback
during Phase A only because the SwiftData-side `ProfileRecord` still
exists for the migrator; UI tests run from a fresh in-memory state
where the migrator is a no-op, so write directly to GRDB.

#### 3.A.13 Tests (Phase A)

Mandatory:

- **Contract test** for `GRDBProfileIndexRepository` in
  `MoolahTests/Backends/GRDB/GRDBProfileIndexRepositoryTests.swift`.
  Round-trips fetchAll / upsert / delete; covers the
  `encodedSystemFields` preservation on update.
- **Plan-pinning test** for the `ORDER BY created_at` query in
  `MoolahTests/Backends/GRDB/AnalysisPlanPinningTests.swift` (or a new
  file `ProfileIndexPlanPinningTests.swift`). Asserts
  `USING INDEX profile_by_created_at`, rejects `SCAN profile`.
- **Sync round-trip test** for ProfileRecord in
  `MoolahTests/Backends/GRDB/ProfileIndexSyncRoundTripTests.swift`.
  Pattern: build two test backends; create on A; manually drive
  `ProfileIndexSyncHandler.applyRemoteChanges` on B with the recorded
  outbound batch; assert the GRDB row on B matches the source bit-for-
  bit including `encodedSystemFields`. Mirror Slice 0's
  `SyncRoundTripCSVImportTests`.
- **Migrator test** in
  `MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorProfileIndexTests.swift`:
  seed a SwiftData index container with N `ProfileRecord` rows + non-nil
  `encodedSystemFields`; open an in-memory GRDB profile-index queue;
  run `migrateProfileIndexIfNeeded`; assert all rows present in GRDB,
  `encodedSystemFields` byte-equal to source, flag set; verify re-run
  is a no-op.
- **`ProfileStore` tests pass unchanged** against the GRDB-backed
  repository. The existing `ProfileStoreTests.swift` family
  (`ProfileStoreAvailabilityTests`, `ProfileStoreAutoActivateGuardTests`,
  `ProfileStoreTestsMore`, `ProfileStoreTestsMoreSecondHalf`) covers
  the `addProfile`/`removeProfile`/`loadCloudProfiles` behaviour. Since
  `loadCloudProfiles` becomes async, tests may need an `await` on the
  store's first observation; verify and adapt.
- **`ProfileIndexSyncHandlerTests` and
  `ProfileIndexSyncHandlerTestsMore`** continue to pass after the
  rewrite. The handler's external surface is unchanged.
- **`SyncCoordinatorProfileIndexFetchTests`** continues to pass.
- **No new benchmarks required.** The profile-index DB has at most a
  handful of rows; reads / writes are sub-millisecond on any device.

### Phase B — SwiftData teardown

Phase B presupposes Phase A has shipped a release that has run on every
active device. Verification: visit each device the user owns (work +
personal Mac, iPhone, iPad), confirm the latest build is installed,
confirm `defaults read com.moolah.app v4.profileIndex.grdbMigrated`
returns `1`. If any device shows `0`, run the Phase A build there
first.

The teardown is mechanical. Each step deletes a category of files and
strips the corresponding `import SwiftData`.

#### 3.B.1 Delete `@Model` classes

Files to delete:

```
Backends/CloudKit/Models/AccountRecord.swift
Backends/CloudKit/Models/CategoryRecord.swift
Backends/CloudKit/Models/CSVImportProfileRecord.swift
Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift
Backends/CloudKit/Models/EarmarkRecord.swift
Backends/CloudKit/Models/ImportRuleRecord.swift
Backends/CloudKit/Models/InstrumentRecord.swift
Backends/CloudKit/Models/InvestmentValueRecord.swift
Backends/CloudKit/Models/ProfileRecord.swift
Backends/CloudKit/Models/TransactionLegRecord.swift
Backends/CloudKit/Models/TransactionRecord.swift
```

Also delete the entire `Backends/CloudKit/Models/` directory once
empty.

#### 3.B.2 Delete `SwiftDataToGRDBMigrator`

Files to delete:

```
Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift
Backends/GRDB/Migration/SwiftDataToGRDBMigrator+CoreFinancialGraph.swift
Backends/GRDB/Migration/SwiftDataToGRDBMigrator+Earmarks.swift
Backends/GRDB/Migration/SwiftDataToGRDBMigrator+Transactions.swift
Backends/GRDB/Migration/SwiftDataToGRDBMigrator+ProfileIndex.swift   # added in Phase A
```

Also delete the entire `Backends/GRDB/Migration/` directory.

Remove call sites:

- `App/ProfileSession.swift::runSwiftDataToGRDBMigrationIfNeeded` —
  delete the method, and the `try Self.runSwiftDataToGRDBMigrationIfNeeded`
  call in `ProfileSession.init`.
- `App/MoolahApp+Setup.swift::runProfileIndexMigrationIfNeeded` —
  delete the method, and its call site (probably in `MoolahApp.init`).
- `App/MoolahApp+Setup.swift::makeContainerSetup` — delete the
  `SwiftDataToGRDBMigrator.resetMigrationFlags()` call in the UI-testing
  branch.

The flag-reset shim was needed because UI tests reuse a process-level
`UserDefaults` across runs; after the migrator is gone, the flags are
inert. Acceptable trash; they don't cost anything beyond a few bytes
in the test runner's defaults.

#### 3.B.3 Delete `ProfileDataDeleter`

```
Backends/CloudKit/ProfileDataDeleter.swift
```

The single call site in `ProfileStore.removeProfile` was already
swapped to `profileIndexRepository.delete(id:)` in Phase A.

#### 3.B.4 CloudKit analysis repo files — already gone

Slice 4 (PR [#594](https://github.com/ajsutton/moolah-native/pull/594))
already deleted every file under
`Backends/CloudKit/Repositories/`, lifted `financialMonth` to
`Shared/FinancialMonth.swift`, and ported the remaining static helpers
into per-method extensions on `GRDBAnalysisRepository` (e.g.
`+IncomeAndExpense.swift`, `+DailyBalances.swift`,
`+ExpenseBreakdown.swift`, `+CategoryBalances.swift`, +
`InvestmentValueSnapshot.swift` now alongside them). The
`Backends/CloudKit/Repositories/` directory no longer exists in the
working tree.

**No-op for Phase B.** Originally Phase B was going to move the
helpers; Slice 4 made that step redundant. Verify before starting
Phase B by running `ls Backends/CloudKit/Repositories/` and confirming
the directory is absent.

#### 3.B.5 `ProfileContainerManager` shrink

```swift
// Shared/ProfileContainerManager.swift (Phase B shape)
import CloudKit
import Foundation
import GRDB
import OSLog
import Observation

@Observable
@MainActor
final class ProfileContainerManager {
  let profileIndexRepository: GRDBProfileIndexRepository
  let inMemory: Bool
  private var databases: [UUID: DatabaseQueue] = [:]
  private let profileIndexDatabase: DatabaseQueue
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "ProfileContainerManager")

  init(
    profileIndexDatabase: DatabaseQueue,
    inMemory: Bool = false
  ) {
    self.profileIndexDatabase = profileIndexDatabase
    self.inMemory = inMemory
    self.profileIndexRepository = GRDBProfileIndexRepository(
      database: profileIndexDatabase)
  }

  func database(for profileId: UUID) throws -> DatabaseQueue { /* unchanged */ }
  func deleteStore(for profileId: UUID) { /* see below */ }
  func allProfileIds() -> [UUID] {
    let repo = profileIndexRepository
    do {
      return try repo.allRowIdsSync()
    } catch {
      logger.error("Failed to fetch profile ids: \(error, privacy: .public)")
      return []
    }
  }

  static func forTesting() throws -> ProfileContainerManager {
    let database = try ProfileIndexDatabase.openInMemory()
    return ProfileContainerManager(profileIndexDatabase: database, inMemory: true)
  }
}
```

`deleteStore(for:)` no longer touches `Moolah-{UUID}.store` files (they
should not exist after Phase B's one-shot cleanup runs). Keep removal
of the legacy paths in case the cleanup races a delete request:

```swift
func deleteStore(for profileId: UUID) {
  databases.removeValue(forKey: profileId)
  guard !inMemory else { return }
  let fileManager = FileManager.default
  // GRDB profile directory (data.sqlite + sidecars)
  let dbDirectory = ProfileSession.profileDatabaseDirectory(for: profileId)
  removeIfPresent(dbDirectory, fileManager: fileManager, label: "GRDB profile directory")
  // Sync state file
  let syncStateURL = URL.moolahScopedApplicationSupport
    .appending(path: "Moolah-\(profileId.uuidString).syncstate")
  removeIfPresent(syncStateURL, fileManager: fileManager, label: "sync state file")
  deleteCloudKitZone(for: profileId)
}
```

The legacy SwiftData `Moolah-{UUID}.store` removal moves into a
dedicated one-shot cleanup (§3.B.7).

#### 3.B.6 `MoolahApp+Setup` cleanup

```swift
static func makeContainerSetup(uiTestingSeed: UITestSeed?) -> ContainerSetup {
  do {
    if let seed = uiTestingSeed {
      let manager = try ProfileContainerManager.forTesting()
      let profile = try UITestSeedHydrator.hydrate(seed, into: manager)
      return ContainerSetup(manager: manager, uiTestingProfileId: profile?.id)
    }
    let profileIndexURL = URL.moolahScopedApplicationSupport
      .appendingPathComponent("Moolah", isDirectory: true)
      .appendingPathComponent("profile-index.sqlite")
    let profileIndexDatabase = try ProfileIndexDatabase.open(at: profileIndexURL)
    let manager = ProfileContainerManager(profileIndexDatabase: profileIndexDatabase)
    return ContainerSetup(manager: manager, uiTestingProfileId: nil)
  } catch {
    fatalError("Failed to initialize ProfileContainerManager: \(error)")
  }
}
```

Drop:

- `let profileSchema = Schema([ProfileRecord.self])`
- The full `dataSchema = Schema([...])`
- `try ModelContainer(for: profileSchema, configurations: [profileConfig])`
- The `runProfileIndexMigrationIfNeeded` call site

`configureSyncCoordinator` keeps the
`store.onProfileChanged` / `onProfileDeleted` wiring (those hooks fire
from the GRDB repository now, not from `ProfileStore` directly — but
the closures connecting to `coordinator.queueSave` /
`coordinator.queueDeletion` need the same shape).

Actually, since Phase A moved the queue-save/delete hook attachment to
`SyncCoordinator` directly (via `attachSyncHooks`), the
`store.onProfileChanged` / `onProfileDeleted` closures are no longer
needed. Phase B drops them along with the corresponding `var
onProfileChanged: ((UUID) -> Void)?` properties on `ProfileStore`.

#### 3.B.7 Legacy SwiftData store cleanup

One-shot cleanup that runs at app launch, gated by a `UserDefaults`
flag, mirroring `cleanupLegacyRateCachesOnce`:

```swift
extension MoolahApp {
  static func cleanupLegacySwiftDataStoresOnce(
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default
  ) {
    let key = "v4.swiftDataStores.cleared"
    guard !defaults.bool(forKey: key) else { return }
    let logger = Logger(
      subsystem: "com.moolah.app", category: "LegacySwiftDataCleanup")
    let appSupport = URL.moolahScopedApplicationSupport
    // Index store
    for suffix in ["", "-shm", "-wal"] {
      let url = appSupport.appendingPathComponent("Moolah-v2.store\(suffix)")
      removeQuietly(url, fileManager: fileManager, logger: logger)
    }
    // Per-profile data stores. Enumerate any files matching
    // "Moolah-<UUID>.store{,-shm,-wal}" via FileManager.contentsOfDirectory.
    let suffixesToScrub = [".store", ".store-shm", ".store-wal"]
    if let contents = try? fileManager.contentsOfDirectory(
      at: appSupport, includingPropertiesForKeys: nil)
    {
      for url in contents
      where url.lastPathComponent.hasPrefix("Moolah-")
        && suffixesToScrub.contains(where: { url.lastPathComponent.hasSuffix($0) })
        && !url.lastPathComponent.contains("v2") /* keep v2 cleanup separate */
      {
        removeQuietly(url, fileManager: fileManager, logger: logger)
      }
    }
    defaults.set(true, forKey: key)
  }

  private static func removeQuietly(
    _ url: URL, fileManager: FileManager, logger: Logger
  ) {
    do {
      try fileManager.removeItem(at: url)
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain
      && error.code == NSFileNoSuchFileError
    {
      // Already absent — fine.
    } catch {
      logger.warning(
        "Failed to delete legacy SwiftData store \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
```

Hook this from `MoolahApp.init` (or the launch path), the same way
`cleanupLegacyRateCachesOnce` is called.

The flag scheme `v4.swiftDataStores.cleared` is independent from the
migrator flags; the cleanup runs whether the migrator already ran or
not (defensive — if it didn't run, the SwiftData files won't exist
either, so the cleanup is a no-op).

#### 3.B.8 Strip `import SwiftData`

Remove `import SwiftData` from every production file that no longer
references SwiftData APIs. The list (verified against working tree):

```
App/ProfileRootView.swift
App/ProfileSession+Factories.swift
App/MoolahApp.swift
App/ProfileSession.swift
App/MoolahApp+Setup.swift
App/UITestSeedHydrator.swift
App/UITestSeedHydrator+Upserts.swift
App/SessionManager.swift
Backends/CloudKit/CloudKitDataImporter.swift
Backends/CloudKit/Sync/SyncCoordinator+Zones.swift
Backends/CloudKit/Sync/SyncCoordinator+Backfill.swift
Backends/CloudKit/Sync/ProfileDataSyncHandler+ApplyRemoteChanges.swift
Backends/CloudKit/Sync/ProfileDataSyncHandler.swift
Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift
Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift
Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift
Backends/CloudKit/Sync/SyncCoordinator.swift
Features/Earmarks/Views/EarmarkDetailView.swift
Features/Earmarks/Views/EarmarksView.swift
Features/Transactions/Views/UpcomingView.swift
Features/Transactions/Views/TransactionListView.swift
Features/Profiles/ProfileStore.swift
Features/Profiles/ProfileStore+Cloud.swift
Features/Categories/Views/CategoryTreeView.swift
Features/Categories/Views/CategoriesView.swift
Shared/ImportVerifier.swift
Shared/PreviewBackend.swift
Shared/ProfileContainerManager.swift
Shared/ExportCoordinator.swift
MoolahBenchmarks/SyncUploadBenchmarks.swift
MoolahBenchmarks/SyncDownloadBenchmarks.swift
```

Several feature views (`EarmarkDetailView`, `EarmarksView`,
`CategoriesView`, etc.) import SwiftData but **do not use any SwiftData
APIs** (verified by `grep`). These are stale imports — drop the import,
no other change.

Re-grep after each edit:

```bash
grep -l "import SwiftData" Backends/ App/ Features/ Shared/ MoolahBenchmarks/ \
  | xargs -I{} grep -l "ModelContainer\|ModelContext\|@Model\|FetchDescriptor\|@Query\|@Attribute\|PersistentModel" {}
```

Any file matching the second `grep` still uses SwiftData — investigate
each. The expected result by the end of Phase B is **zero matches** in
production (the test target may temporarily retain SwiftData imports
for the migrator tests; those tests are deleted as part of §3.B.10).

#### 3.B.9 `ProfileDataSyncHandler` cleanup

Drop:

- `nonisolated let modelContainer: ModelContainer` field.
- `modelContainer:` parameter in `init`.
- The corresponding `import SwiftData` from
  `ProfileDataSyncHandler.swift` and its `+ApplyRemoteChanges.swift`
  extension.

`SyncCoordinator+HandlerAccess.handlerForProfileZone` no longer reads
`containerManager.container(for: profileId)`. Drop that line.
`ProfileDataSyncHandler(...)`'s call site loses the `modelContainer:`
argument.

#### 3.B.10 Test cleanup

Delete tests that exercise the deleted SwiftData paths:

- `MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorTests.swift`
- `MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorCoreGraphTests.swift`
- `MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorCrossFKTests.swift`
- `MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorProfileIndexTests.swift`
  (added in Phase A)

Update tests that read `containerManager.indexContainer` or
construct `ModelContainer` directly:

- `MoolahTests/App/ProfileContainerManagerTests.swift` — adapt to the
  GRDB-only shape.
- `MoolahTests/Sync/ProfileIndexSyncHandlerTests.swift` and
  `ProfileIndexSyncHandlerTestsMore.swift` — already adapted in Phase A
  to the new constructor.
- `MoolahTests/Features/ProfileStoreAutoActivateGuardTests.swift`,
  `ProfileStoreTests.swift`, `ProfileStoreTestsMore.swift`,
  `ProfileStoreTestsMoreSecondHalf.swift` — drop direct SwiftData
  usage (e.g. constructing `ProfileRecord` instances) in favour of
  `Profile` + `profileIndexRepository.upsert(...)`.
- `MoolahTests/Sync/RecordMappingTests.swift` and
  `SyncCoordinatorTestsMore.swift` — replace `ProfileRecord` usage
  with `ProfileRow`.
- `MoolahTests/CloudKit/ProfileDataDeleterTests.swift` — delete (the
  type is gone).
- `MoolahTests/Support/TestModelContainer.swift` — delete (no longer
  used).

Verify after Phase B that:

```bash
just test
```

still passes 1731+ tests, plus the new Slice 3 additions.

#### 3.B.11 Tests (Phase B) — coverage additions

- **Legacy cleanup test** in
  `MoolahTests/App/LegacySwiftDataCleanupTests.swift`. Seed a temp
  directory with `Moolah-v2.store`, `Moolah-v2.store-shm`,
  `Moolah-v2.store-wal`, plus `Moolah-{UUID}.store{,-shm,-wal}`; call
  `cleanupLegacySwiftDataStoresOnce(defaults:)`; assert all matching
  files are gone and the flag is set; assert a re-run is a no-op.
- **`ProfileContainerManager` shape test** — assert
  `containerManager.profileIndexRepository` is non-nil; call
  `allProfileIds()`, assert it round-trips a seeded profile.
- **`@import SwiftData` regression guard** — a build-time test? No,
  this is best as a CI grep: add a `just` recipe `just no-swiftdata`
  that runs:
  ```bash
  ! grep -rln "import SwiftData" \
      App/ Features/ Backends/ Shared/ MoolahBenchmarks/
  ```
  Hook it from CI alongside `just format-check`. If a future change
  reintroduces a SwiftData import, the build fails. (Test target is
  exempt — XCTest helpers may need it for backward compatibility for a
  release before they're cleaned up, though by Phase B they shouldn't.)

### 3.C — UI tests

- Re-record the UI test seeds that mention `ProfileRecord` directly
  (`UITestSeedHydrator+Upserts.upsertProfile` becomes
  `profileIndexRepository.upsert(profile)` inside an `await`).
- Verify each `UITestSeed` case's hydration runs end-to-end by
  invoking the corresponding UI test in
  `MoolahUITests_macOS/`. Reference: `writing-ui-tests` skill.
- The UI test seed reset path — `SwiftDataToGRDBMigrator.resetMigrationFlags()`
  in Phase A's `MoolahApp+Setup.makeContainerSetup` — covers the new
  `profileIndexFlag` because §3.A.10 added it to `allMigrationFlags`.
  In Phase B that whole code path goes away (the migrator is gone);
  UI tests run from a fresh in-memory `ProfileContainerManager` per
  launch, no flag-reset needed.

---

## 4. File-level inventory of edits

### Phase A

| File | Action |
|---|---|
| `Backends/GRDB/ProfileIndexDatabase.swift` | NEW — `DatabaseQueue` factory mirroring `ProfileDatabase.swift` |
| `Backends/GRDB/ProfileIndexSchema.swift` | NEW — `DatabaseMigrator` with the `v1_initial` `profile` table |
| `Backends/GRDB/Records/ProfileRow.swift` | NEW — bare struct + per-protocol extensions |
| `Backends/GRDB/Records/ProfileRow+Mapping.swift` | NEW — `recordType`, `recordName(for:)`, `init(domain:)`, `toDomain()` |
| `Backends/GRDB/Sync/ProfileRow+CloudKit.swift` | NEW — `CloudKitRecordConvertible` |
| `Backends/GRDB/Repositories/GRDBProfileIndexRepository.swift` | NEW — domain + sync surfaces |
| `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+ProfileIndex.swift` | NEW — per-type migrator |
| `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift` | EDIT — extend `allMigrationFlags` with `profileIndexFlag` |
| `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift` | EDIT — `RecordTypeRegistry.allTypes` reroutes `ProfileRecord` to `ProfileRow.self` |
| `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift` | REWRITE — GRDB-backed body; same external API |
| `Backends/CloudKit/Sync/SyncCoordinator.swift` | EDIT — `ProfileIndexSyncHandler(repository:)` constructor; install hook closures via `attachSyncHooks` |
| `Backends/CloudKit/ProfileDataDeleter.swift` | DELETE (Phase A — no remaining call site) |
| `Shared/ProfileContainerManager.swift` | EDIT — add `profileIndexRepository` and `profileIndexDatabase`; new init parameter; `forTesting()` updated |
| `Features/Profiles/ProfileStore.swift` | EDIT — swap SwiftData reads/writes for `profileIndexRepository` |
| `Features/Profiles/ProfileStore+Cloud.swift` | EDIT — `loadCloudProfiles` becomes async-driven |
| `App/MoolahApp+Setup.swift` | EDIT — `makeContainerSetup` opens `profile-index.sqlite`; new `runProfileIndexMigrationIfNeeded`; `configureSyncCoordinator` no longer wires `store.onProfileChanged` / `onProfileDeleted` (covered by repo hooks) |
| `App/MoolahApp.swift` | EDIT — call `runProfileIndexMigrationIfNeeded` before `ProfileStore.init` |
| `App/UITestSeedHydrator+Upserts.swift` | EDIT — `upsertProfile` writes to GRDB |
| `MoolahTests/Backends/GRDB/GRDBProfileIndexRepositoryTests.swift` | NEW — contract test |
| `MoolahTests/Backends/GRDB/ProfileIndexPlanPinningTests.swift` | NEW — plan-pinning |
| `MoolahTests/Backends/GRDB/ProfileIndexSyncRoundTripTests.swift` | NEW — round-trip |
| `MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorProfileIndexTests.swift` | NEW — migrator |
| `MoolahTests/Sync/ProfileIndexSyncHandlerTests.swift`, `ProfileIndexSyncHandlerTestsMore.swift` | EDIT — adapt to GRDB-backed handler |
| `MoolahTests/App/ProfileContainerManagerTests.swift` | EDIT — assert `profileIndexRepository` non-nil; allProfileIds round-trip |
| `MoolahTests/Features/ProfileStoreTests.swift` family | EDIT — async load behaviour |

### Phase B

| File | Action |
|---|---|
| `Backends/CloudKit/Models/*Record.swift` (all 11) | DELETE |
| `Backends/CloudKit/Models/` directory | DELETE (empty) |
| `Backends/GRDB/Migration/SwiftDataToGRDBMigrator*.swift` (all 5) | DELETE |
| `Backends/GRDB/Migration/` directory | DELETE (empty) |
| ~~`Backends/CloudKit/Repositories/CloudKitAnalysisRepository*.swift`~~ | Already deleted by Slice 4 (PR #594). No-op. |
| ~~`Backends/CloudKit/Repositories/InvestmentValueSnapshot.swift`~~ | Already moved to `Backends/GRDB/Repositories/` by Slice 4. No-op. |
| ~~`Backends/CloudKit/Repositories/`~~ directory | Already absent. No-op. |
| `Backends/CloudKit/CloudKitDataImporter.swift` | EDIT or DELETE — verify usage; if it still does SwiftData mirror writes, refactor to GRDB-only or delete entirely |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift` | EDIT — drop `modelContainer` field + `init` parameter + `import SwiftData` |
| `Backends/CloudKit/Sync/SyncCoordinator+HandlerAccess.swift` | EDIT — drop `try containerManager.container(for: profileId)` line |
| `App/ProfileSession.swift` | EDIT — drop `runSwiftDataToGRDBMigrationIfNeeded` and call site; drop `containerManager` references that are no longer used |
| `App/MoolahApp+Setup.swift` | EDIT — drop SwiftData container setup, drop `runProfileIndexMigrationIfNeeded`, add `cleanupLegacySwiftDataStoresOnce` |
| `App/MoolahApp.swift` | EDIT — call `cleanupLegacySwiftDataStoresOnce`, drop `runProfileIndexMigrationIfNeeded` |
| `Shared/ProfileContainerManager.swift` | EDIT — strip SwiftData entirely (no more `indexContainer`, `containers`, `dataSchema`); init parameter shrinks |
| `Features/Profiles/ProfileStore.swift` | EDIT — drop `onProfileChanged` / `onProfileDeleted` properties (hooks moved to repo) |
| `Features/Profiles/ProfileStore+Cloud.swift` | EDIT — drop SwiftData import and any remaining direct uses |
| All other production files with `import SwiftData` | EDIT — strip the import line (verified clean by `just no-swiftdata`) |
| `MoolahTests/Backends/GRDB/SwiftDataToGRDBMigrator*Tests.swift` (4 files) | DELETE |
| `MoolahTests/CloudKit/ProfileDataDeleterTests.swift` | DELETE |
| `MoolahTests/Support/TestModelContainer.swift` | DELETE |
| `MoolahTests/App/LegacySwiftDataCleanupTests.swift` | NEW — one-shot cleanup |
| `justfile` | EDIT — add `just no-swiftdata` recipe |
| `.github/workflows/*.yml` (or wherever CI runs) | EDIT — invoke `just no-swiftdata` alongside `just format-check` |

---

## 5. Acceptance criteria

### Phase A

- `just build-mac` ✅ and `just build-ios` ✅.
- `just format-check` clean. (`.swiftlint-baseline.yml` **not**
  modified.)
- `just test` passes — including the existing `ProfileStoreTests` and
  `ProfileIndexSyncHandlerTests` suites.
- New tests added per §3.A.13 all pass.
- Plan-pinning test asserts `USING INDEX profile_by_created_at` for
  the `loadCloudProfiles` query.
- After upgrade on a real profile (verified via
  `run-mac-app-with-logs` skill):
  - The migrator runs once on first launch; the
    `v4.profileIndex.grdbMigrated` flag is set in `UserDefaults`.
  - `Application Support/Moolah/profile-index.sqlite` is created and
    populated with one row per profile that previously existed in
    `Moolah-v2.store`.
  - `ProfileStore.profiles` shows the same list as before the
    upgrade.
  - CKSyncEngine produces no `.serverRecordChanged` errors on the
    next sync session (verified via `os_log` pattern in
    `automate-app` skill).
  - `Moolah-v2.store` is **not yet deleted** (Phase B does that).
- Two-device sync round-trip works for ProfileRecord:
  - Create a profile on device A; observe it appear on device B.
  - Update label on B; observe the update on A.
  - Delete on A; observe the deletion on B.
- All five reviewer agents (`database-schema-review`,
  `database-code-review`, `concurrency-review`, `sync-review`,
  `code-review`) report clean, or any findings are addressed before
  the PR is queued.

### Phase B

- `just build-mac` ✅ and `just build-ios` ✅ — **with zero
  `import SwiftData` in production**.
- `just format-check` clean.
- `just no-swiftdata` (new recipe) returns zero matches in production.
- `just test` passes; deleted-test count matches §3.B.10's list.
- After upgrade on a real profile:
  - `cleanupLegacySwiftDataStoresOnce` runs once; the
    `v4.swiftDataStores.cleared` flag is set.
  - `Moolah-v2.store{,-shm,-wal}` and `Moolah-{UUID}.store{,-shm,-wal}`
    are gone from `Application Support`.
  - All UI surfaces work end-to-end: sidebar, transactions, reports,
    earmarks, investments, profile management, CSV import.
  - CKSyncEngine continues to round-trip records normally — no
    `.serverRecordChanged` errors.
- `code-review`, `concurrency-review`, `sync-review` report clean.

---

## 6. Workflow constraints

- **Branches.** Phase A on `feat/grdb-slice-3-profile-index`; Phase B
  on `chore/grdb-slice-3-swiftdata-teardown`. **Phase A merges
  first**, ships in a release the user runs on every device, then
  Phase B is queued. Reviewer agents run separately on each PR.
- **Schema generator.** `CloudKit/schema.ckdb` unchanged in Slice 3
  (the wire `ProfileRecord` is frozen). `just generate` for Xcode
  project regeneration after adding new files.
- **Plan-pinning evidence** sits inside the test assertions, not the
  PR description.
- **PR convention:** `gh pr create --base main --head <branch>`; queue
  via `~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR>`.
- **All git/just commands use absolute paths:** `git -C <path>` and
  `just --justfile <path>/justfile --working-directory <path>`. Never
  `cd <path> && cmd`.
- **`.agent-tmp/` for any temp files** in the worktree. Delete when
  done.
- **`.swiftlint-baseline.yml` MUST NOT be modified.** If
  `just format-check` reports a violation, fix the underlying code.
- **Patterns from Slice 0 / Slice 1 apply throughout** (records: bare
  struct + per-protocol extensions; closure parameter is `database`
  not `db`; no silent `try?`; `final class` + `@unchecked Sendable`
  with explicit member-by-member justification; Swift Testing not
  XCTest; no `Column("…")` raw strings).
- **`Date()` only at boundaries.** `runProfileIndexMigrationIfNeeded`
  takes no Date parameters but the migrator's `committed` defer
  pattern uses `ContinuousClock.now` for timing only — fine. No
  production code path constructs a `Date()` to populate a profile
  field; `ProfileRow.createdAt` always comes from the source data.

---

## 7. Reference reading

### Slice plans
- `plans/grdb-migration.md` — overall roadmap and decisions.
- `plans/grdb-slice-1-core-financial-graph.md` — Slice 1's plan
  (closer template; Slice 3 mirrors its sectioning).
- `plans/grdb-slice-0-csv-import.md` — Slice 0's plan (shows the
  smallest viable migrator-extension shape).

### Slice 4 reference (as-shipped)
- PR [#594](https://github.com/ajsutton/moolah-native/pull/594) — the
  `AnalysisRepository` SQL aggregation rewrite. Notable side-effects
  for Slice 3: deleted the `Backends/CloudKit/Repositories/`
  directory, lifted `financialMonth` to `Shared/FinancialMonth.swift`,
  ported analysis compute helpers into per-method GRDB extensions.

### Guides (non-optional)
- `guides/DATABASE_SCHEMA_GUIDE.md` — schema rules.
- `guides/DATABASE_CODE_GUIDE.md` — Swift / GRDB rules.
- `guides/SYNC_GUIDE.md` — CKSyncEngine architecture.
- `guides/CONCURRENCY_GUIDE.md` — actor isolation rules.
- `guides/CODE_GUIDE.md` — naming, type choice, optional discipline.
- `guides/TEST_GUIDE.md` — test structure.

### Slice 0/1 reference files (the patterns Slice 3 mirrors)
- `Backends/GRDB/ProfileDatabase.swift` — `DatabaseQueue` factory.
- `Backends/GRDB/ProfileSchema.swift` — `DatabaseMigrator` shape.
- `Backends/GRDB/Records/CSVImportProfileRow.swift` + `+Mapping.swift`
  — record-type pattern.
- `Backends/GRDB/Sync/CSVImportProfileRow+CloudKit.swift` —
  `CloudKitRecordConvertible` pattern.
- `Backends/GRDB/Repositories/GRDBCSVImportProfileRepository.swift` —
  repo shape with sync entry points.
- `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift` —
  per-type migrator pattern.
- `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift` (current) —
  the rewrite target; same external surface, GRDB internals.
- `App/MoolahApp+Setup.swift::cleanupLegacyRateCachesOnce` —
  template for the SwiftData cleanup helper in §3.B.7.

---

## 8. Open questions

| Q | Resolution before code |
|---|---|
| Can `ProfileRecord` migration ship in the same PR as the SwiftData teardown? | **Two PRs.** The teardown deletes the SwiftData `@Model` classes the migrator reads. They must be available on every device by the time the teardown lands; that requires a release running between the two PRs. The user verifies migrator completion across devices manually before queuing Phase B. |
| Should `profile-index.sqlite` live inside `Application Support/Moolah/` (with the per-profile DB folders) or at the top level? | **Inside `Moolah/`**, alongside `profiles/<UUID>/data.sqlite`. Keeps all moolah-owned SQLite files under a single moolah-scoped folder for backup / scrubbing / inspection. The path is `Application Support/Moolah/profile-index.sqlite`. |
| Should `GRDBProfileIndexRepository` be `@MainActor` rather than `@unchecked Sendable`? | **`@unchecked Sendable`**, mirroring per-profile repos. The repo's reads are async on the GRDB queue; the sync entry points run on CKSyncEngine's delegate executor. `@MainActor` would propagate `await` through every CKSyncEngine sync dispatch site for no benefit. |
| `ProfileStore.addProfile` becomes async (was sync against SwiftData). Does any caller misbehave? | Verify each call site: `WelcomeView`'s "Create Profile" button, `validateAndAddProfile`, the multi-profile picker. SwiftUI bindings tolerate the one-tick lag because `profiles` is updated synchronously (the GRDB write is fire-and-forget; the in-memory `profiles` array updates immediately for UI feedback). |
| What if the legacy `Moolah-v2.store` is corrupted such that `ModelContext.fetch(ProfileRecord.self)` throws? | The Phase A migrator logs the error and re-throws so `runProfileIndexMigrationIfNeeded` returns failure — caught by `MoolahApp+Setup` and logged. The user sees no profiles on first launch (GRDB is empty). Recovery: manually create a new profile from `WelcomeView`, which writes to GRDB; the user accepts that the corrupted SwiftData store's profile data is lost. The corruption is itself a degenerate case (it would have been broken pre-Slice 3 too) so we don't add specific handling. |
| Will `ProfileIndexSyncHandler` need a separate `ProfileGRDBRepositories`-style bundle? | **No.** The bundle exists for the per-profile data handler so the sync dispatch tables can switch on record type; the index handler only ever sees `ProfileRecord`. A direct repository reference suffices. |
| Should `runProfileIndexMigrationIfNeeded` run on a background actor instead of `@MainActor`? | **`@MainActor` for now.** Profile-index is small (low single-digit row counts); the SwiftData `ModelContext.fetch` requires `@MainActor`. If profiling shows >16ms on a real device, convert to `async` per the same path Slice 1 traced. For a profile-index that has never had more than ~5 rows, this is moot. |
| Where does `ProfileContainerManager.allProfileIds` get its data after Phase B? | **From `profileIndexRepository.allRowIdsSync()`.** The current SwiftData fetch is replaced. `allProfileIds` was used by callers iterating profiles for cleanup; it stays a `[UUID]` return type. |
| Will the `ProfileStore`'s `onProfileChanged` / `onProfileDeleted` callbacks (today wired to `coordinator.queueSave` / `queueDeletion`) need to stay during Phase A while the repo hooks are also active? | **Stay during Phase A.** The store fires `onProfileChanged` after a successful local mutation; in Phase A the GRDB repository *also* fires `onRecordChanged` from the same code path (via `repository.upsert`). Double-firing is benign — `coordinator.queueSave` is idempotent over the same `(recordType, id, zoneID)` triple within a sync session. Phase B drops the store-side callbacks; the repo hooks stay. |
| Can the `attachSyncHooks` method on `GRDBProfileIndexRepository` be replaced by a cleaner construction-time injection? | **Try construction-time injection first.** Pass the SyncCoordinator into the repo's init via a thin protocol (`ProfileIndexSyncHooks { func queueProfileSave(id:); func queueProfileDeletion(id:) }`). The cycle (`SyncCoordinator` constructs `containerManager` → constructs `repository` → which references `SyncCoordinator`) is broken by adding a setter for the SyncCoordinator field on the manager *after* both have been constructed, or by lazy-resolving through a closure that the `SyncCoordinator` updates post-init. If injection adds three lines of indirection, fall back to `attachSyncHooks` — pragmatic. |

---

*End of plan. Implementer: re-read §3.A.7 (`ProfileContainerManager`
extension) and §3.B.7 (legacy cleanup) before starting Phase A — those
two sections decide most of the file/test surface.*
