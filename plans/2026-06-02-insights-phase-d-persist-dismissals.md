# Insights Phase D — Persist Dismissals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist per-`InsightKind` dismissal counts in a new CloudKit-synced repository so the `InsightRanker`'s fatigue penalty survives relaunch and syncs across devices.

**Architecture:** A new `InsightDismissalRecord` CloudKit record type + GRDB-backed `InsightDismissalRepository`, modelled exactly on the `AccountGroupRecord` / `GRDBAccountGroupRepository` pattern (the simplest fully-synced record type in the codebase). One row per kind, keyed by a **deterministic UUID** derived from the kind raw value (`UUID.deterministic(from:)`) so the same kind maps to the same record on every device — cross-device merges collapse to last-writer-wins on the count; concurrent dismissals of *different* kinds never conflict. `InsightStore` observes the repo's `observeAll()` stream to seed/maintain its in-memory `[InsightKind: Int]` fatigue table, and write-throughs each `dismiss(_:)` via an atomic read-modify-write inside one GRDB write transaction.

**Scope decisions (confirmed with user 2026-06-02):**
- **Dismissals only.** No declared-interests persistence — there is no UI affordance to set an interest, so it would be untestable dead code. Defer to a follow-up.
- **Per-kind counts only.** Persist + sync the `[InsightKind: count]` fatigue table. The session-only `dismissedIds` exact-card hiding stays session-only (those ids churn as transactions age out).

**Tech Stack:** Swift 6, GRDB (SQLite, STRICT), CKSyncEngine, Swift Testing (`@Test`/`#expect`), `just` targets.

---

## Architectural contract (must hold)

- The CloudKit wire `recordType` string `"InsightDismissalRecord"` is a **frozen contract** once shipped — never rename.
- Production CloudKit schema is **additive-only**: `just check-schema-additive` must pass. Adding a brand-new record type is additive (allowed).
- Generated wire structs (`Backends/CloudKit/Sync/Generated/`) are gitignored and produced by `just generate` — never hand-edit; never edit `CloudKit/schema-prod-baseline.ckdb`.
- All GRDB tables are `STRICT` (`guides/DATABASE_SCHEMA_GUIDE.md`).
- Off-main sync entry points are synchronous and block the GRDB writer; never call them from `@MainActor` (`guides/CONCURRENCY_GUIDE.md`).
- `recordDismissal` increments inside a **single** `database.write { }` block — GRDB's serial writer makes the read-modify-write atomic; no raw-SQL `ON CONFLICT` increment needed.

## File map

**New files (10):**
1. `Domain/Models/InsightDismissal.swift` — domain value type.
2. `Domain/Repositories/InsightDismissalRepository.swift` — protocol.
3. `Backends/GRDB/ProfileSchema+InsightDismissals.swift` — v16 migration body.
4. `Backends/GRDB/Records/InsightDismissalRow.swift` — GRDB row.
5. `Backends/GRDB/Records/InsightDismissalRow+Mapping.swift` — recordType / recordName / id(for:) / init(domain:) / toDomain.
6. `Backends/GRDB/Records/InsightDismissalRow+ObservableRegion.swift` — observable region.
7. `Backends/GRDB/Repositories/GRDBInsightDismissalRepository.swift` — repo + sync entry points.
8. `Backends/GRDB/Repositories/GRDBInsightDismissalRepository+Observation.swift` — observeAll / observeErrors.
9. `Backends/GRDB/Repositories/GRDBInsightDismissalRepository+Sync.swift` — setEncodedSystemFieldsBatchSync.
10. `Backends/GRDB/Sync/InsightDismissalRow+CloudKit.swift` — CloudKitRecordConvertible.

**Modified files (schema + wiring, 13):**
11. `CloudKit/schema.ckdb` — add `RECORD TYPE InsightDismissalRecord`.
12. `Backends/GRDB/ProfileSchema.swift` — register `v16_insight_dismissals`, bump `version` to 16.
13. `Domain/Repositories/BackendProvider.swift` — add `var insightDismissals`.
14. `Backends/CloudKit/CloudKitBackend.swift` — protocol+concrete props, hooks, bundle, makeRepositories.
15. `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift` — IdentifiableRecord + ValueTypeSystemFieldsReadable + RecordTypeRegistry.
16. `Backends/CloudKit/Sync/ProfileGRDBRepositories.swift` — field + makeForApply.
17. `Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBDispatch.swift` — save + delete cases.
18. `Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBSaveHelpers.swift` — applyBatchSaveInsightDismissal.
19. `Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift` — collectInsightDismissalIds + deleteAll.
20. `Backends/CloudKit/Sync/ProfileDataSyncHandler+RecordLookup.swift` — single + batch lookup + dispatch.
21. `Backends/CloudKit/Sync/ProfileDataSyncHandler+SystemFields.swift` — clearAll list + batch dispatch.
22. `App/ProfileSession+CloudKitBackendBuild.swift` — makeBackendHooks pair.
23. `Features/Insights/InsightStore.swift` — observe + write-through dismissals.

**Modified test doubles (2):**
24. `MoolahTests/Features/AuthStoreTests.swift` (`TestAuthBackend`) — forward `insightDismissals`.
25. `MoolahTests/Support/CloudKitAnalysisTestBackend.swift` — forward `insightDismissals`.

**New/updated tests (5):**
26. `MoolahTests/Domain/InsightDismissalRepositoryContractTests.swift` — repo contract.
27. `MoolahTests/Backends/GRDB/InsightDismissalRowMappingTests.swift` — row↔domain.
28. `MoolahTests/Sync/InsightDismissalRowCKRecordTests.swift` — row↔CKRecord round trip.
29. `MoolahTests/Sync/InsightDismissalSyncIntegrationTests.swift` — two-DB sync round trip (cross-device).
30. `MoolahTests/Features/Insights/InsightStoreTests.swift` — fatigue persistence + reorder (append).

---

## Task 1: Domain model + repository protocol

**Files:**
- Create: `Domain/Models/InsightDismissal.swift`
- Create: `Domain/Repositories/InsightDismissalRepository.swift`

- [ ] **Step 1: Write the domain model**

`Domain/Models/InsightDismissal.swift`:

```swift
import Foundation

/// Persisted per-`InsightKind` dismissal tally. Each time the user dismisses
/// an insight, the count for that kind is bumped; `InsightRanker`'s fatigue
/// penalty downranks kinds with a high count, so a kind the user keeps
/// dismissing recedes. There is exactly one record per kind.
///
/// A pure value type — the GRDB row and CloudKit adapter live in the backend
/// layer and never leak here. `id` is the `kind` itself: a dismissal tally is
/// identified by which kind it counts.
struct InsightDismissal {
  let kind: InsightKind
  var count: Int

  init(kind: InsightKind, count: Int = 0) {
    self.kind = kind
    self.count = count
  }
}

extension InsightDismissal: Identifiable {
  var id: InsightKind { kind }
}

extension InsightDismissal: Sendable {}
extension InsightDismissal: Hashable {}
```

- [ ] **Step 2: Write the repository protocol**

`Domain/Repositories/InsightDismissalRepository.swift`:

```swift
import Foundation

/// Persists per-`InsightKind` dismissal counts that feed `InsightRanker`'s
/// fatigue penalty. Synced across devices via CKSyncEngine so a dismissal on
/// one device downranks the kind everywhere.
///
/// Mutations go through `recordDismissal(of:)` (an atomic increment) rather
/// than a generic `create`/`update`, because the only user action is "the user
/// dismissed an insight of this kind" — there is no edit-an-arbitrary-count
/// affordance. The synchronous sync entry points the CKSyncEngine delegate
/// needs live on the concrete `GRDBInsightDismissalRepository`, not on this
/// protocol.
protocol InsightDismissalRepository: Sendable {
  /// Every persisted dismissal tally. Kinds never dismissed are absent.
  func fetchAll() async throws -> [InsightDismissal]

  /// Streams the full tally set whenever the underlying table changes
  /// (local mutation or remote sync). Initial value is the current state.
  func observeAll() -> AsyncStream<[InsightDismissal]>

  /// Out-of-band observation errors. See `guides/DATABASE_CODE_GUIDE.md` §2.
  func observeErrors() -> AsyncStream<any Error>

  /// Atomically increments the dismissal count for `kind` (creating the row
  /// with count 1 on first dismissal) and returns the updated tally.
  @discardableResult
  func recordDismissal(of kind: InsightKind) async throws -> InsightDismissal
}
```

- [ ] **Step 3: Build to verify the domain layer compiles**

Run: `just build-mac 2>&1 | tee .agent-tmp/build.txt | tail -20`
Expected: compiles (these types have no consumers yet; `InsightDismissalRepository` is not yet on `BackendProvider`).

- [ ] **Step 4: Commit**

```bash
git add Domain/Models/InsightDismissal.swift Domain/Repositories/InsightDismissalRepository.swift
git commit -m "Add InsightDismissal domain model + repository protocol (Phase D)"
```

---

## Task 2: GRDB schema migration (v16)

**Files:**
- Create: `Backends/GRDB/ProfileSchema+InsightDismissals.swift`
- Modify: `Backends/GRDB/ProfileSchema.swift` (register migration, bump `version`)
- Test: `MoolahTests/Backends/GRDB/ProfileSchemaInsightDismissalsTests.swift`

- [ ] **Step 1: Write the failing schema test**

`MoolahTests/Backends/GRDB/ProfileSchemaInsightDismissalsTests.swift`:

```swift
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema insight_dismissal table")
struct ProfileSchemaInsightDismissalsTests {
  @Test
  func tableExistsWithExpectedColumns() throws {
    let queue = try ProfileDatabase.openInMemory()
    try queue.read { db in
      #expect(try db.tableExists("insight_dismissal"))
      let columns = try db.columns(in: "insight_dismissal").map(\.name)
      #expect(columns.contains("id"))
      #expect(columns.contains("record_name"))
      #expect(columns.contains("kind"))
      #expect(columns.contains("count"))
      #expect(columns.contains("encoded_system_fields"))
    }
  }

  @Test
  func kindIsUnique() throws {
    let queue = try ProfileDatabase.openInMemory()
    let row = InsightDismissalRow(kind: .newRecurringDetected, count: 1)
    var dup = InsightDismissalRow(kind: .newRecurringDetected, count: 1)
    dup.id = UUID()  // distinct id, same kind → UNIQUE(kind) must reject
    dup.recordName = "InsightDismissalRecord|\(dup.id.uuidString)"
    try queue.write { db in try row.insert(db) }
    #expect(throws: (any Error).self) {
      try queue.write { db in try dup.insert(db) }
    }
  }
}
```

> NOTE: `InsightDismissalRow` and its `init(kind:count:)` convenience init are introduced in Task 3. This test will not compile until Task 3 Step 1 lands. Implement Task 2 Step 2/3 first (the migration), then Task 3, then run this test. (Order chosen so the migration ships in its own commit; the schema test rides with the row that exercises it.)

- [ ] **Step 2: Write the migration body**

`Backends/GRDB/ProfileSchema+InsightDismissals.swift`:

```swift
import Foundation
import GRDB

extension ProfileSchema {
  /// v16 migration body. Adds the `insight_dismissal` table — one row per
  /// `InsightKind` the user has dismissed, carrying a cumulative `count` that
  /// drives `InsightRanker`'s fatigue penalty. Synced via CKSyncEngine
  /// (`InsightDismissalRecord`).
  ///
  /// `kind` is `UNIQUE`: there is exactly one tally per kind. The primary key
  /// `id` is a deterministic UUID derived from `kind` (see
  /// `InsightDismissalRow.id(for:)`), so the same kind resolves to the same
  /// record on every device and cross-device upserts collapse rather than
  /// duplicate.
  ///
  /// `STRICT` per `guides/DATABASE_SCHEMA_GUIDE.md`. Rowid table (no
  /// `WITHOUT ROWID`): GRDB's `upsert` emits `RETURNING "rowid"` and
  /// `ValueObservation` hooks require a rowid table — same constraint as v14.
  static func addInsightDismissals(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE insight_dismissal (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            kind                   TEXT    NOT NULL UNIQUE,
            count                  INTEGER NOT NULL CHECK (count >= 0),
            encoded_system_fields  BLOB
        ) STRICT;
        """)
  }
}
```

- [ ] **Step 3: Register the migration and bump the version**

In `Backends/GRDB/ProfileSchema.swift`, change `static let version = 15` to `static let version = 16`, and after the `v15_account_group_ui_state` registration add:

```swift
    migrator.registerMigration(
      "v16_insight_dismissals", migrate: addInsightDismissals)
```

- [ ] **Step 4: Defer running the schema test to Task 3** (the test references `InsightDismissalRow`). Just build:

Run: `just build-mac 2>&1 | tee .agent-tmp/build.txt | tail -20`
Expected: compiles (migration body uses only GRDB + Database).

- [ ] **Step 5: Commit**

```bash
git add Backends/GRDB/ProfileSchema+InsightDismissals.swift Backends/GRDB/ProfileSchema.swift
git commit -m "Add v16 insight_dismissal table migration (Phase D)"
```

---

## Task 3: GRDB row + mapping + observable region

**Files:**
- Create: `Backends/GRDB/Records/InsightDismissalRow.swift`
- Create: `Backends/GRDB/Records/InsightDismissalRow+Mapping.swift`
- Create: `Backends/GRDB/Records/InsightDismissalRow+ObservableRegion.swift`
- Test: `MoolahTests/Backends/GRDB/InsightDismissalRowMappingTests.swift`

- [ ] **Step 1: Write the row**

`Backends/GRDB/Records/InsightDismissalRow.swift`:

```swift
import Foundation
import GRDB

/// One row in the `insight_dismissal` table: a cumulative dismissal `count`
/// for a single `InsightKind`. `id` is deterministic from `kind` (see
/// `InsightDismissalRow.id(for:)`), so the row is content-addressed and
/// cross-device upserts merge instead of duplicating.
struct InsightDismissalRow {
  static let databaseTableName = "insight_dismissal"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case kind
    case count
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case kind
    case count
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  /// Raw value of `InsightKind`. `UNIQUE` in the schema.
  var kind: String
  var count: Int
  var encodedSystemFields: Data?
}

extension InsightDismissalRow: Codable {}
extension InsightDismissalRow: Sendable {}
extension InsightDismissalRow: Identifiable {}
extension InsightDismissalRow: FetchableRecord {}
extension InsightDismissalRow: PersistableRecord {}
extension InsightDismissalRow: GRDBSystemFieldsStampable {}
```

- [ ] **Step 2: Write the mapping**

`Backends/GRDB/Records/InsightDismissalRow+Mapping.swift`:

```swift
import Foundation

extension InsightDismissalRow {
  /// The CloudKit recordType on the wire. Frozen contract.
  static let recordType = "InsightDismissalRecord"

  /// Deterministic primary key for a kind: identical on every device, so the
  /// per-kind tally resolves to one record cluster-wide. Namespaced with the
  /// record type so it can never collide with another deterministic-UUID
  /// keyspace.
  static func id(for kind: InsightKind) -> UUID {
    UUID.deterministic(from: "\(recordType)|\(kind.rawValue)")
  }

  /// Canonical CloudKit `recordName` for a UUID-keyed row.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Convenience init from a kind + count. Derives the deterministic id and
  /// record name; `encodedSystemFields` starts nil (stamped post-upsert).
  init(kind: InsightKind, count: Int) {
    let id = Self.id(for: kind)
    self.id = id
    self.recordName = Self.recordName(for: id)
    self.kind = kind.rawValue
    self.count = count
    self.encodedSystemFields = nil
  }

  /// Builds a row from a domain `InsightDismissal`.
  init(domain: InsightDismissal) {
    self.init(kind: domain.kind, count: domain.count)
  }

  /// Domain projection. An unknown `kind` raw value (e.g. a kind added by a
  /// newer build that synced down to this one) yields `nil`; the caller drops
  /// it — a fatigue tally for a kind this build cannot detect is inert.
  func toDomain() -> InsightDismissal? {
    guard let resolved = InsightKind(rawValue: kind) else { return nil }
    return InsightDismissal(kind: resolved, count: count)
  }
}
```

- [ ] **Step 3: Write the observable region**

`Backends/GRDB/Records/InsightDismissalRow+ObservableRegion.swift`:

```swift
import Foundation
import GRDB

extension InsightDismissalRow {
  /// Column-restricted region for UI `ValueObservation`s. Excludes
  /// `encoded_system_fields` so the per-batch sync-bookkeeping write
  /// CKSyncEngine performs after a successful send does not re-fire UI
  /// observers. `Columns: CaseIterable` means new columns auto-enrol.
  /// See issue #865.
  static var observableRegion: QueryInterfaceRequest<InsightDismissalRow> {
    let columns: [any SQLSelectable] = Columns.allCases
      .filter { $0 != .encodedSystemFields }
      .map { $0 as any SQLSelectable }
    return select(columns)
  }
}
```

- [ ] **Step 4: Write the row-mapping test**

`MoolahTests/Backends/GRDB/InsightDismissalRowMappingTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("InsightDismissalRow mapping")
struct InsightDismissalRowMappingTests {
  @Test
  func domainRoundTrips() {
    let domain = InsightDismissal(kind: .subscriptionPriceHike, count: 3)
    let row = InsightDismissalRow(domain: domain)
    #expect(row.kind == InsightKind.subscriptionPriceHike.rawValue)
    #expect(row.count == 3)
    #expect(row.toDomain() == domain)
  }

  @Test
  func idIsDeterministicPerKind() {
    #expect(
      InsightDismissalRow.id(for: .newRecurringDetected)
        == InsightDismissalRow.id(for: .newRecurringDetected))
    #expect(
      InsightDismissalRow.id(for: .newRecurringDetected)
        != InsightDismissalRow.id(for: .subscriptionPriceHike))
  }

  @Test
  func unknownKindProjectsNil() {
    var row = InsightDismissalRow(kind: .newRecurringDetected, count: 1)
    row.kind = "a_kind_this_build_does_not_know"
    #expect(row.toDomain() == nil)
  }
}
```

- [ ] **Step 5: Run the row-mapping + schema tests**

Run: `just test InsightDismissalRowMappingTests ProfileSchemaInsightDismissalsTests 2>&1 | tee .agent-tmp/t3.txt | tail -25`
Expected: PASS (schema test from Task 2 now compiles and passes).

- [ ] **Step 6: `just format-check` then commit**

```bash
just format
git add Backends/GRDB/Records/InsightDismissalRow.swift \
  Backends/GRDB/Records/InsightDismissalRow+Mapping.swift \
  Backends/GRDB/Records/InsightDismissalRow+ObservableRegion.swift \
  MoolahTests/Backends/GRDB/InsightDismissalRowMappingTests.swift \
  MoolahTests/Backends/GRDB/ProfileSchemaInsightDismissalsTests.swift
git commit -m "Add InsightDismissalRow + mapping + schema test (Phase D)"
```

---

## Task 4: GRDB repository (CRUD + sync entry points)

**Files:**
- Create: `Backends/GRDB/Repositories/GRDBInsightDismissalRepository.swift`
- Create: `Backends/GRDB/Repositories/GRDBInsightDismissalRepository+Observation.swift`
- Create: `Backends/GRDB/Repositories/GRDBInsightDismissalRepository+Sync.swift`
- Test: `MoolahTests/Backends/GRDB/InsightDismissalRepositorySyncHelpersTests.swift`

- [ ] **Step 1: Write the repository**

`Backends/GRDB/Repositories/GRDBInsightDismissalRepository.swift`:

```swift
import Foundation
import GRDB

/// GRDB-backed `InsightDismissalRepository`. One row per `InsightKind`;
/// `recordDismissal` increments atomically inside a single writer
/// transaction. Observation lives in the `+Observation` sibling, the
/// system-fields batch helper in `+Sync`.
///
/// **`@unchecked Sendable` justification.** All stored properties are `let`.
/// `database` is `Sendable` (GRDB protocol guarantee — its serial executor
/// mediates concurrent access). `onRecordChanged` / `onRecordDeleted` are
/// `@Sendable` closures captured at init. `errorChannel` is an `actor`.
/// Nothing mutates post-init. See `guides/CONCURRENCY_GUIDE.md` §2 Carve-out 3
/// (GRDB repositories).
final class GRDBInsightDismissalRepository: InsightDismissalRepository, @unchecked Sendable {
  let database: any DatabaseWriter
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void
  let errorChannel = ObservationErrorChannel()

  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - InsightDismissalRepository conformance

  func fetchAll() async throws -> [InsightDismissal] {
    try await database.read { database in
      try InsightDismissalRow
        .order(InsightDismissalRow.Columns.kind.asc)
        .fetchAll(database)
        .compactMap { $0.toDomain() }
    }
  }

  @discardableResult
  func recordDismissal(of kind: InsightKind) async throws -> InsightDismissal {
    // Read-modify-write inside ONE write block. GRDB's writer is serial, so
    // no other write interleaves — the increment is atomic without raw SQL.
    let row = try await database.write { database -> InsightDismissalRow in
      let id = InsightDismissalRow.id(for: kind)
      var row =
        try InsightDismissalRow
        .filter(InsightDismissalRow.Columns.id == id)
        .fetchOne(database) ?? InsightDismissalRow(kind: kind, count: 0)
      row.count += 1
      try row.upsert(database)
      return row
    }
    onRecordChanged(InsightDismissalRow.recordType, row.id)
    // `toDomain()` only returns nil for an unknown raw value; `kind` here is a
    // live case, so force is safe. Fall back defensively to a fresh tally.
    return row.toDomain() ?? InsightDismissal(kind: kind, count: row.count)
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  // Called from the CKSyncEngine delegate executor off `@MainActor`. Never
  // call these from the main actor. See GRDBAccountGroupRepository for the
  // shared rationale.

  func applyRemoteChangesSync(saved rows: [InsightDismissalRow], deleted ids: [UUID]) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  func applyRemoteChangesSync(
    saved rows: [InsightDismissalRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows { try row.upsert(database) }
    for id in ids {
      _ = try InsightDismissalRow.deleteOne(database, id: id)
    }
  }

  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try InsightDismissalRow
        .filter(InsightDismissalRow.Columns.id == id)
        .updateAll(database, [InsightDismissalRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try InsightDismissalRow
        .updateAll(
          database,
          [InsightDismissalRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try InsightDismissalRow
        .filter(InsightDismissalRow.Columns.encodedSystemFields == nil)
        .select(InsightDismissalRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try InsightDismissalRow
        .select(InsightDismissalRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func fetchRowSync(id: UUID) throws -> InsightDismissalRow? {
    try database.read { database in
      try InsightDismissalRow
        .filter(InsightDismissalRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  func fetchRowsSync(ids: [UUID]) throws -> [InsightDismissalRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try InsightDismissalRow
        .filter(idSet.contains(InsightDismissalRow.Columns.id))
        .fetchAll(database)
    }
  }

  func deleteAllSync() throws {
    try database.write { database in
      _ = try InsightDismissalRow.deleteAll(database)
    }
  }
}
```

- [ ] **Step 2: Write the observation extension**

`Backends/GRDB/Repositories/GRDBInsightDismissalRepository+Observation.swift`:

```swift
import Foundation
import GRDB

// Reactive observation surface for `InsightDismissalRepository`. Same domain
// projection as `fetchAll()`: every `insight_dismissal` row, ordered by kind,
// mapped through `toDomain()` (unknown raw values dropped). See
// `GRDBAccountGroupRepository+Observation` for the error-handling contract.
extension GRDBInsightDismissalRepository {
  func observeAll() -> AsyncStream<[InsightDismissal]> {
    ValueObservation
      .tracking(
        regions: [InsightDismissalRow.observableRegion],
        fetch: { database in
          try InsightDismissalRow
            .order(InsightDismissalRow.Columns.kind.asc)
            .fetchAll(database)
            .compactMap { $0.toDomain() }
        }
      )
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBInsightDismissalRepository.observeAll")
  }

  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
```

- [ ] **Step 3: Write the system-fields batch helper**

`Backends/GRDB/Repositories/GRDBInsightDismissalRepository+Sync.swift`:

```swift
import Foundation
import GRDB

extension GRDBInsightDismissalRepository {
  /// Batch counterpart to `setEncodedSystemFieldsSync` — writes every update
  /// in a single transaction so `databaseDidCommit` fires once. See
  /// `GRDBAccountGroupRepository+Sync` and issue #865.
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)]
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    return try database.write { database in
      var updatedCount = 0
      for (id, data) in updates {
        updatedCount +=
          try InsightDismissalRow
          .filter(InsightDismissalRow.Columns.id == id)
          .updateAll(
            database,
            [InsightDismissalRow.Columns.encodedSystemFields.set(to: data)])
      }
      return updatedCount
    }
  }
}
```

- [ ] **Step 4: Write the sync-helpers test**

`MoolahTests/Backends/GRDB/InsightDismissalRepositorySyncHelpersTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("GRDBInsightDismissalRepository sync helpers")
struct InsightDismissalRepositorySyncHelpersTests {
  private func makeRepo() throws -> (GRDBInsightDismissalRepository, DatabaseQueue) {
    let queue = try ProfileDatabase.openInMemory()
    return (GRDBInsightDismissalRepository(database: queue), queue)
  }

  @Test
  func recordDismissalIncrementsAtomically() async throws {
    let (repo, _) = try makeRepo()
    _ = try await repo.recordDismissal(of: .newRecurringDetected)
    _ = try await repo.recordDismissal(of: .newRecurringDetected)
    let third = try await repo.recordDismissal(of: .newRecurringDetected)
    #expect(third.count == 3)
    let all = try await repo.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.count == 3)
  }

  @Test
  func distinctKindsAreIndependent() async throws {
    let (repo, _) = try makeRepo()
    _ = try await repo.recordDismissal(of: .newRecurringDetected)
    _ = try await repo.recordDismissal(of: .subscriptionPriceHike)
    _ = try await repo.recordDismissal(of: .subscriptionPriceHike)
    let byKind = Dictionary(
      uniqueKeysWithValues: try await repo.fetchAll().map { ($0.kind, $0.count) })
    #expect(byKind[.newRecurringDetected] == 1)
    #expect(byKind[.subscriptionPriceHike] == 2)
  }

  @Test
  func applyRemoteChangesUpsertsAndDeletes() throws {
    let (repo, _) = try makeRepo()
    let row = InsightDismissalRow(kind: .feeSpend, count: 5)
    try repo.applyRemoteChangesSync(saved: [row], deleted: [])
    #expect(try repo.fetchRowSync(id: row.id)?.count == 5)
    try repo.applyRemoteChangesSync(saved: [], deleted: [row.id])
    #expect(try repo.fetchRowSync(id: row.id) == nil)
  }

  @Test
  func unsyncedRowIdsReportsRowsMissingSystemFields() throws {
    let (repo, _) = try makeRepo()
    let row = InsightDismissalRow(kind: .feeSpend, count: 1)
    try repo.applyRemoteChangesSync(saved: [row], deleted: [])
    #expect(try repo.unsyncedRowIdsSync() == [row.id])
    _ = try repo.setEncodedSystemFieldsSync(id: row.id, data: Data([0x01]))
    #expect(try repo.unsyncedRowIdsSync().isEmpty)
  }
}
```

> NOTE: replace `.feeSpend` / `.subscriptionPriceHike` with real `InsightKind` cases if those names differ — verify against `Domain/Insights/InsightKind.swift` before running.

- [ ] **Step 5: Run the repository tests**

Run: `just test InsightDismissalRepositorySyncHelpersTests 2>&1 | tee .agent-tmp/t4.txt | tail -25`
Expected: PASS.

- [ ] **Step 6: `just format` then commit**

```bash
just format
git add Backends/GRDB/Repositories/GRDBInsightDismissalRepository.swift \
  Backends/GRDB/Repositories/GRDBInsightDismissalRepository+Observation.swift \
  Backends/GRDB/Repositories/GRDBInsightDismissalRepository+Sync.swift \
  MoolahTests/Backends/GRDB/InsightDismissalRepositorySyncHelpersTests.swift
git commit -m "Add GRDBInsightDismissalRepository + sync helpers (Phase D)"
```

---

## Task 5: CloudKit schema + generated wire struct + adapter

**Files:**
- Modify: `CloudKit/schema.ckdb`
- Create: `Backends/GRDB/Sync/InsightDismissalRow+CloudKit.swift`
- Generated (via `just generate`, gitignored): `Backends/CloudKit/Sync/Generated/InsightDismissalRecordCloudKitFields.swift`
- Test: `MoolahTests/Sync/InsightDismissalRowCKRecordTests.swift`

- [ ] **Step 1: Add the record type to the schema**

In `CloudKit/schema.ckdb`, add (place it in the file's existing ordering — alphabetical by record type, so after `ImportRuleRecord` / before `InstrumentRecord`; match the surrounding block's exact formatting):

```
RECORD TYPE InsightDismissalRecord (
    "___createTime" TIMESTAMP,
    "___createdBy"  REFERENCE,
    "___etag"       STRING,
    "___modTime"    TIMESTAMP,
    "___modifiedBy" REFERENCE,
    "___recordID"   REFERENCE QUERYABLE,
    count           INT64 QUERYABLE SORTABLE,
    kind            STRING QUERYABLE SEARCHABLE SORTABLE,
    GRANT WRITE TO "_creator",
    GRANT CREATE TO "_icloud",
    GRANT READ TO "_world"
);
```

- [ ] **Step 2: Generate the wire struct + project**

Run: `just generate 2>&1 | tee .agent-tmp/gen.txt | tail -20`
Expected: succeeds; `Backends/CloudKit/Sync/Generated/InsightDismissalRecordCloudKitFields.swift` now exists with `count: Int64?` and `kind: String?`.

- [ ] **Step 3: Verify the schema change is additive**

Run: `just check-schema-additive 2>&1 | tee .agent-tmp/additive.txt | tail -20`
Expected: PASS (a new record type is additive). Do NOT edit `schema-prod-baseline.ckdb`.

- [ ] **Step 4: Write the CloudKit adapter**

`Backends/GRDB/Sync/InsightDismissalRow+CloudKit.swift`:

```swift
import CloudKit
import Foundation

// MARK: - InsightDismissalRow + CloudKitRecordConvertible
//
// The wire `recordType` ("InsightDismissalRecord") is the stable contract for
// this record, unchanged regardless of the local Swift type's name.

extension InsightDismissalRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    InsightDismissalRecordCloudKitFields(
      count: Int64(count),
      kind: kind
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> InsightDismissalRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = InsightDismissalRecordCloudKitFields(from: ckRecord)
    return InsightDismissalRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      // A record with no kind is malformed; "" projects to nil in toDomain and
      // is dropped downstream. Mirrors AccountGroupRow's defensive fallbacks.
      kind: fields.kind ?? "",
      count: Int(fields.count ?? 0),
      // Stamped by applyGRDBBatchSave after upsert; never read from the CKRecord.
      encodedSystemFields: nil
    )
  }
}
```

> NOTE: confirm the generated memberwise-init parameter order (`count`/`kind`) against the emitted `InsightDismissalRecordCloudKitFields.swift` — the generator orders fields as declared in the schema. Adjust the call if needed.

- [ ] **Step 5: Write the row↔CKRecord round-trip test**

`MoolahTests/Sync/InsightDismissalRowCKRecordTests.swift` (mirror `MoolahTests/Sync/AccountGroupRowCKRecordTests.swift` for the zoneID helper):

```swift
import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("InsightDismissalRow ↔ CKRecord")
struct InsightDismissalRowCKRecordTests {
  private let zoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)

  @Test
  func roundTripsThroughCKRecord() throws {
    let row = InsightDismissalRow(kind: .subscriptionPriceHike, count: 4)
    let record = row.toCKRecord(in: zoneID)
    #expect(record.recordType == "InsightDismissalRecord")
    let decoded = try #require(InsightDismissalRow.fieldValues(from: record))
    #expect(decoded.id == row.id)
    #expect(decoded.kind == row.kind)
    #expect(decoded.count == 4)
  }
}
```

> NOTE: verify the zoneID construction matches `AccountGroupRowCKRecordTests` — if that suite uses a shared helper (e.g. `CKRecordZone.ID(zoneName:ownerName:)` vs a test factory), reuse it verbatim.

- [ ] **Step 6: Run the CKRecord test**

Run: `just test InsightDismissalRowCKRecordTests 2>&1 | tee .agent-tmp/t5.txt | tail -25`
Expected: PASS.

- [ ] **Step 7: `just format` then commit** (generated files are gitignored — they won't appear in the diff)

```bash
just format
git add CloudKit/schema.ckdb Backends/GRDB/Sync/InsightDismissalRow+CloudKit.swift \
  MoolahTests/Sync/InsightDismissalRowCKRecordTests.swift
git commit -m "Add InsightDismissalRecord CloudKit schema + adapter (Phase D)"
```

---

## Task 6: Register the record type in the sync pipeline

This wires the new row into every per-record-type dispatch site. Each edit mirrors the existing `AccountGroupRow` case exactly. **For each file, open it, find the `AccountGroup` reference(s) at the line numbers below (re-grep — line numbers drift), and add a parallel `InsightDismissal` entry.**

**Files:**
- Modify: `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBDispatch.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBSaveHelpers.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+RecordLookup.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+SystemFields.swift`
- Modify: `Backends/CloudKit/Sync/ProfileGRDBRepositories.swift`

- [ ] **Step 1: `CloudKitRecordConvertible.swift`** — add three entries beside the `AccountGroupRow` ones:

```swift
extension InsightDismissalRow: IdentifiableRecord {}
```
```swift
extension InsightDismissalRow: ValueTypeSystemFieldsReadable {}
```
In `RecordTypeRegistry.allTypes`, add:
```swift
    InsightDismissalRow.recordType: InsightDismissalRow.self,
```

- [ ] **Step 2: `ProfileGRDBRepositories.swift`** — add the stored field beside `accountGroups`:
```swift
  let insightDismissals: GRDBInsightDismissalRepository
```
and in `makeForApply(...)`'s `ProfileGRDBRepositories(...)` initializer add:
```swift
      insightDismissals: GRDBInsightDismissalRepository(database: database),
```

- [ ] **Step 3: `ProfileDataSyncHandler+GRDBSaveHelpers.swift`** — add a save helper mirroring `applyBatchSaveAccountGroup`:
```swift
  nonisolated func applyBatchSaveInsightDismissal(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[InsightDismissal]")
    let rows = mapRows(
      context: context,
      fieldValues: InsightDismissalRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields)
    try writeRemote(site: context.site) {
      try grdbRepositories.insightDismissals.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }
```
> Verify the exact shape of `applyBatchSaveAccountGroup` (parameter labels, `mapRows`/`stampSystemFields` names) and copy it precisely.

- [ ] **Step 4: `ProfileDataSyncHandler+GRDBDispatch.swift`** — add a save-dispatch case (beside the `AccountGroupRow.recordType` case that routes to `applyBatchSaveAccountGroup`):
```swift
    case InsightDismissalRow.recordType:
      return handler.applyBatchSaveInsightDismissal(ckRecords:systemFields:in:)
```
and a delete-dispatch case (beside the `AccountGroupRow.recordType` deletion case):
```swift
    case InsightDismissalRow.recordType:
      try handler.writeRemote(site: "applyGRDBBatchDeletion[InsightDismissal]") {
        try handler.grdbRepositories.insightDismissals.applyRemoteChangesSync(
          saved: [], deleted: ids, in: database)
      }
```
> Match the surrounding case's exact return/closure shape — re-read the `AccountGroup` cases first.

- [ ] **Step 5: `ProfileDataSyncHandler+RecordLookup.swift`** — three sites, each beside an `AccountGroup` one:
  - single-row lookup dispatch:
    ```swift
    case InsightDismissalRow.recordType:
      return fetchInsightDismissalRow(id: uuid).map { row in
        // …mirror the AccountGroup arm's mapping closure exactly…
      }
    ```
  - batch lookup dispatch:
    ```swift
    case InsightDismissalRow.recordType:
      // …mirror AccountGroup: fetchRowsSync(ids:) → map to CKRecords…
      return try self.grdbRepositories.insightDismissals.fetchRowsSync(ids: ids)
        // …same trailing transform as the AccountGroup arm…
    ```
  - the private helper:
    ```swift
    private func fetchInsightDismissalRow(id: UUID) -> InsightDismissalRow? {
      fetchRowOrLog { try grdbRepositories.insightDismissals.fetchRowSync(id: id) }
    }
    ```
> Re-read the AccountGroup arms (single + batch) and reproduce their exact body — the map closure differs per handler version.

- [ ] **Step 6: `ProfileDataSyncHandler+QueueAndDelete.swift`** — three sites:
  - in the id-collection entry point, beside `collectAccountGroupIds(source:into:)`:
    ```swift
    collectInsightDismissalIds(source: source, into: &recordIDs)
    ```
  - the private collector mirroring `collectAccountGroupIds`:
    ```swift
    private func collectInsightDismissalIds(
      source: …, into recordIDs: inout …
    ) {
      let repo = grdbRepositories.insightDismissals
      // …mirror collectAccountGroupIds body: pull ids, call collectAllGRDBUUIDs…
      collectAllGRDBUUIDs(
        ids: ids, recordType: InsightDismissalRow.recordType, into: &recordIDs)
    }
    ```
  - in the deleteAll enumeration (the array of `(recordType, deleteAllClosure)`):
    ```swift
        InsightDismissalRow.recordType,
        { try self.grdbRepositories.insightDismissals.deleteAllSync() }
    ```
> Re-read `collectAccountGroupIds` for the exact parameter types and body.

- [ ] **Step 7: `ProfileDataSyncHandler+SystemFields.swift`** — two sites:
  - in the clear-all list (the `(recordType, clearAllSystemFieldsSync)` array):
    ```swift
      (InsightDismissalRow.recordType, grdbRepositories.insightDismissals.clearAllSystemFieldsSync),
    ```
  - in the batch system-fields dispatch switch:
    ```swift
    case InsightDismissalRow.recordType:
      return { try repos.insightDismissals.setEncodedSystemFieldsBatchSync($0) }
    ```

- [ ] **Step 8: Build**

Run: `just build-mac 2>&1 | tee .agent-tmp/t6build.txt | tail -30`
Expected: compiles. (`grdbRepositories.insightDismissals` resolves because Step 2 added the field; the apply-path constructor populates it.)

- [ ] **Step 9: `just format` then commit**

```bash
just format
git add Backends/CloudKit/Sync/
git commit -m "Register InsightDismissalRecord in the sync pipeline (Phase D)"
```

---

## Task 7: Backend wiring (`BackendProvider` + `CloudKitBackend` + hooks)

**Files:**
- Modify: `Domain/Repositories/BackendProvider.swift`
- Modify: `Backends/CloudKit/CloudKitBackend.swift`
- Modify: `App/ProfileSession+CloudKitBackendBuild.swift`
- Modify: `MoolahTests/Features/AuthStoreTests.swift`
- Modify: `MoolahTests/Support/CloudKitAnalysisTestBackend.swift`

- [ ] **Step 1: Add the protocol requirement**

In `Domain/Repositories/BackendProvider.swift`, after `var accountGroups: any AccountGroupRepository { get }` add:
```swift
  /// Per-`InsightKind` dismissal tallies driving `InsightRanker`'s fatigue
  /// penalty. Synced via CKSyncEngine so a dismissal propagates across devices.
  var insightDismissals: any InsightDismissalRepository { get }
```

- [ ] **Step 2: Wire `CloudKitBackend`** — five edits mirroring `accountGroups`:
  - protocol-typed stored property (beside `let accountGroups: any AccountGroupRepository`):
    ```swift
    let insightDismissals: any InsightDismissalRepository
    ```
  - concrete stored property (beside `let grdbAccountGroups: GRDBAccountGroupRepository`):
    ```swift
    let grdbInsightDismissals: GRDBInsightDismissalRepository
    ```
  - two hook fields in `CloudKitBackendHooks` (beside the `onAccountGroup*` pair):
    ```swift
    let onInsightDismissalChanged: @Sendable (String, UUID) -> Void
    let onInsightDismissalDeleted: @Sendable (String, UUID) -> Void
    ```
  - the matching pair in `CloudKitBackendHooks.noop`:
    ```swift
      onInsightDismissalChanged: { _, _ in },
      onInsightDismissalDeleted: { _, _ in },
    ```
  - `init` assignments (beside the `accountGroups` lines):
    ```swift
    self.grdbInsightDismissals = repos.insightDismissals
    ```
    ```swift
    self.insightDismissals = repos.insightDismissals
    ```
  - the `GRDBRepositoryBundle` field (beside `let accountGroups: GRDBAccountGroupRepository`):
    ```swift
    let insightDismissals: GRDBInsightDismissalRepository
    ```
  - the construction in `makeRepositories`'s `GRDBRepositoryBundle(...)` (beside the `accountGroups:` arg):
    ```swift
      insightDismissals: GRDBInsightDismissalRepository(
        database: database,
        onRecordChanged: hooks.onInsightDismissalChanged,
        onRecordDeleted: hooks.onInsightDismissalDeleted),
    ```

- [ ] **Step 3: Wire the hooks fan-out**

In `App/ProfileSession+CloudKitBackendBuild.swift`'s `makeBackendHooks`, add beside the `onAccountGroup*` pair:
```swift
      onInsightDismissalChanged: hooks.changed,
      onInsightDismissalDeleted: hooks.deleted,
```

- [ ] **Step 4: Fix the two test-double backends**

In `MoolahTests/Features/AuthStoreTests.swift` (`TestAuthBackend`), beside `let accountGroups` and its assignment, add:
```swift
  let insightDismissals: any InsightDismissalRepository
```
```swift
    self.insightDismissals = backend.insightDismissals
```
In `MoolahTests/Support/CloudKitAnalysisTestBackend.swift`, the same two additions beside its `accountGroups` lines.

- [ ] **Step 5: Build (whole app + tests)**

Run: `just build-mac 2>&1 | tee .agent-tmp/t7.txt | tail -30`
Expected: compiles — `BackendProvider`'s new requirement is satisfied by all three conformers.

- [ ] **Step 6: `just format` then commit**

```bash
just format
git add Domain/Repositories/BackendProvider.swift Backends/CloudKit/CloudKitBackend.swift \
  App/ProfileSession+CloudKitBackendBuild.swift \
  MoolahTests/Features/AuthStoreTests.swift MoolahTests/Support/CloudKitAnalysisTestBackend.swift
git commit -m "Expose insightDismissals on BackendProvider + CloudKitBackend (Phase D)"
```

---

## Task 8: Repository contract test + cross-device sync integration test

**Files:**
- Create: `MoolahTests/Domain/InsightDismissalRepositoryContractTests.swift`
- Create: `MoolahTests/Sync/InsightDismissalSyncIntegrationTests.swift`

- [ ] **Step 1: Write the contract test (incl. relaunch persistence)**

`MoolahTests/Domain/InsightDismissalRepositoryContractTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("InsightDismissalRepository contract")
struct InsightDismissalRepositoryContractTests {
  @Test
  func recordAndFetch() async throws {
    let (backend, _) = try TestBackend.create()
    _ = try await backend.insightDismissals.recordDismissal(of: .newRecurringDetected)
    let all = try await backend.insightDismissals.fetchAll()
    #expect(all.first { $0.kind == .newRecurringDetected }?.count == 1)
  }

  @Test
  func dismissalSurvivesReopen() async throws {
    // Same on-disk file reopened == relaunch. Use a temp file DB, not the
    // in-memory one, so the second open sees the first open's writes.
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("insight-dismissal-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let first = GRDBInsightDismissalRepository(database: try ProfileDatabase.open(at: url))
    _ = try await first.recordDismissal(of: .feeSpend)
    _ = try await first.recordDismissal(of: .feeSpend)

    let second = GRDBInsightDismissalRepository(database: try ProfileDatabase.open(at: url))
    let all = try await second.fetchAll()
    #expect(all.first { $0.kind == .feeSpend }?.count == 2)
  }
}
```

> NOTE: confirm the on-disk open API. If `ProfileDatabase.open(at:)` does not exist, use whatever opener the existing GRDB persistence tests use for a file-backed `DatabaseQueue` (grep `MoolahTests` for `temporaryDirectory` + `ProfileDatabase`). If only `openInMemory()` is available, open a single shared `DatabaseQueue` and build two repos over it — the relaunch semantics are equivalent because the table persists in the shared queue.

- [ ] **Step 2: Write the cross-device sync integration test**

`MoolahTests/Sync/InsightDismissalSyncIntegrationTests.swift` — mirror `MoolahTests/Sync/AccountGroupSyncIntegrationTests.swift` structure exactly (it stands up the sync handler with two GRDB databases / a fake CK zone and round-trips a record). Replace the AccountGroup record with:

```swift
    let row = InsightDismissalRow(kind: .subscriptionPriceHike, count: 2)
```
and assert the second database's `insightDismissals.fetchAll()` reports `count == 2` for `.subscriptionPriceHike` after applying the upload. Reuse the suite's existing harness helpers verbatim — do not invent a new sync-handler bring-up.

- [ ] **Step 3: Run both suites**

Run: `just test InsightDismissalRepositoryContractTests InsightDismissalSyncIntegrationTests 2>&1 | tee .agent-tmp/t8.txt | tail -30`
Expected: PASS.

- [ ] **Step 4: `just format` then commit**

```bash
just format
git add MoolahTests/Domain/InsightDismissalRepositoryContractTests.swift \
  MoolahTests/Sync/InsightDismissalSyncIntegrationTests.swift
git commit -m "Add InsightDismissal contract + sync integration tests (Phase D)"
```

---

## Task 9: Store integration — observe + write-through

**Files:**
- Modify: `Features/Insights/InsightStore.swift`
- Test: `MoolahTests/Features/Insights/InsightStoreTests.swift` (append)

- [ ] **Step 1: Write the failing store tests**

Append to `MoolahTests/Features/Insights/InsightStoreTests.swift` (match the file's existing `@MainActor` suite + construction helpers — re-read it first to reuse `makeStore`/seed helpers):

```swift
  @Test
  func dismissPersistsPerKindCount() async throws {
    let (backend, _) = try TestBackend.create()
    let store = makeStore(backend: backend)  // reuse the suite's factory
    // Seed a deterministic insight whose kind we can dismiss.
    let insight = ScoredInsight.fixture(kind: .newRecurringDetected)  // reuse existing fixture
    store.applyFixtureForTesting([insight])  // reuse whatever the suite uses to seed `insights`
    store.dismiss(insight)
    // Write-through is async; await the repository reflecting it.
    try await eventually {
      try await backend.insightDismissals.fetchAll()
        .first { $0.kind == .newRecurringDetected }?.count == 1
    }
  }

  @Test
  func persistedDismissalsSeedFatigueOnRefresh() async throws {
    let (backend, _) = try TestBackend.create()
    _ = try await backend.insightDismissals.recordDismissal(of: .newRecurringDetected)
    let store = makeStore(backend: backend)
    await store.refresh()
    // The store's fatigue table reflects the persisted count: a freshly built
    // store ranks `.newRecurringDetected` below an equal-strength insight of an
    // un-dismissed kind. Assert ordering against a seeded input.
    // …assert reorder using the suite's seeding utilities…
  }
```

> NOTE: this is the one task whose test scaffolding depends on helpers that already exist in `InsightStoreTests.swift`. Re-read that file and adapt: reuse its store factory, its insight fixtures, and its async-wait helper (if none exists, poll `fetchAll()` in a bounded loop — no `Task.sleep` races; follow `guides/TEST_GUIDE.md`). The two behaviours to prove are: (a) `dismiss` write-throughs to the repo; (b) a store built atop a repo with a pre-existing count downranks that kind.

- [ ] **Step 2: Inject the repository + observe + write-through**

In `Features/Insights/InsightStore.swift`:

(a) Add a stored dependency and source it from `backend` in `init` (the init already takes `backend: any BackendProvider`):
```swift
  private let dismissalRepository: any InsightDismissalRepository
```
In `init`, after `self.builder = InsightInputBuilder(backend: backend)`:
```swift
    self.dismissalRepository = backend.insightDismissals
```

(b) Add an observation task property beside `instrumentChangeObservationTask`:
```swift
  /// Observes persisted per-kind dismissal counts. Each emission reseeds
  /// `dismissals` (initial load on launch, local write-through echo, and
  /// remote sync) and re-ranks the cached input so the fatigue penalty stays
  /// current. Torn down by `stopObserving()` / `deinit`.
  private var dismissalObservationTask: Task<Void, Never>?
```

(c) Spawn it at the end of `init` (after the instrument-change block):
```swift
    let dismissalStream = dismissalRepository.observeAll()
    dismissalObservationTask = Task { [self] in
      await self.observePersistedDismissals(dismissalStream)
    }
```

(d) Cancel it in `deinit` and `stopObserving()` alongside the existing task:
```swift
      instrumentChangeObservationTask?.cancel()
      dismissalObservationTask?.cancel()
```
(in `stopObserving()`):
```swift
    instrumentChangeObservationTask?.cancel()
    dismissalObservationTask?.cancel()
```

(e) Add the observer method (in the same extension as `observeInstrumentRegistryChanges`):
```swift
  /// Consumes the persisted-dismissal stream. Each emission rebuilds the
  /// in-memory fatigue table from the authoritative DB state and re-ranks the
  /// cached input in place (no off-main rebuild) so any open surface reflects
  /// the new fatigue immediately. Re-checks cancellation around the await.
  private func observePersistedDismissals(_ stream: AsyncStream<[InsightDismissal]>) async {
    for await tallies in stream {
      if Task.isCancelled { return }
      dismissals = Dictionary(
        uniqueKeysWithValues: tallies.map { ($0.kind, $0.count) })
      if let lastInput {
        insights = visible(engine.generate(lastInput, dismissals: dismissals))
      }
    }
  }
```

(f) Change `dismiss(_:)` to write through (keep the optimistic bump + instant re-rank for snappy UX; the observation echo reconciles to the same value):
```swift
  func dismiss(_ insight: ScoredInsight) {
    dismissedIds.insert(insight.id)
    dismissals[insight.insight.kind, default: 0] += 1
    if let lastInput {
      insights = visible(engine.generate(lastInput, dismissals: dismissals))
    } else {
      insights = visible(insights)
    }
    // Persist the dismissal. The atomic increment in the repository is the
    // source of truth; the observation stream echoes the committed count back,
    // reconciling the optimistic bump above (idempotent — same value).
    let kind = insight.insight.kind
    Task { [dismissalRepository] in
      do {
        _ = try await dismissalRepository.recordDismissal(of: kind)
      } catch {
        // Best-effort: a failed persist leaves the optimistic in-memory bump
        // (this session still downranks); the next successful dismissal or a
        // synced remote write reconciles. Logged, not surfaced — dismissal is
        // not a user-blocking action.
        logger.error("Failed to persist insight dismissal: \(error)")
      }
    }
  }
```

(g) Update the now-stale doc comments on the `dismissals` and `dismissedIds` stored properties (lines ~85–94): `dismissals` is now persisted/synced; `dismissedIds` stays session-only. Replace "Not persisted — dismissal telemetry is a future PR." and "Phase D persists both across launches." with accurate text:
```swift
  /// In-memory projection of the persisted per-kind dismissal counts
  /// (`InsightDismissalRepository`). Seeded and kept current by
  /// `observePersistedDismissals`; `dismiss(_:)` bumps it optimistically and
  /// write-throughs to the repo. Drives the ranker's fatigue penalty.
  private var dismissals: [InsightKind: Int] = [:]

  /// Ids dismissed in this session. Filtered from every published list so a
  /// dismissed card stays gone until relaunch. Deliberately session-only:
  /// these ids reference specific insights that age out (e.g. a transaction
  /// anomaly whose transaction leaves the window), so persisting them would
  /// be unbounded and brittle. The *kind*-level fatigue (above) is what
  /// persists and syncs.
  private var dismissedIds: Set<String> = []
```

- [ ] **Step 3: Run the store tests**

Run: `just test InsightStoreTests 2>&1 | tee .agent-tmp/t9.txt | tail -30`
Expected: PASS (new + existing).

- [ ] **Step 4: `just format` then commit**

```bash
just format
git add Features/Insights/InsightStore.swift MoolahTests/Features/Insights/InsightStoreTests.swift
git commit -m "Persist + observe insight dismissals in InsightStore (Phase D)"
```

---

## Task 10: Concurrency review checkpoint (store + repo)

- [ ] **Step 1:** Dispatch `concurrency-review` over `Features/Insights/InsightStore.swift`, `Backends/GRDB/Repositories/GRDBInsightDismissalRepository*.swift`. Apply all Critical/Important/Minor findings (see memory `feedback_apply_all_review_findings`). Re-run affected tests after fixes.

- [ ] **Step 2:** Commit any review fixes with `git commit -m "Apply concurrency-review findings (Phase D)"`.

---

## Task 11: Full verification + review gauntlet

- [ ] **Step 1: Pre-stale-process hygiene then full test run** (per memory `reference_macos_test_runner_hang`)

```bash
pkill -f 'Moolah.*xctest' 2>/dev/null; pkill -f 'Moolah.app/Contents/MacOS/Moolah' 2>/dev/null; true
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/full-test.txt | tail -40
grep -iE 'failed|error:' .agent-tmp/full-test.txt || echo "no failures"
```
Expected: all green on both iOS sim + macOS.

- [ ] **Step 2: format-check (CI parity)**

```bash
just format-check 2>&1 | tee .agent-tmp/fmt.txt
```
Expected: no diff, no SwiftLint violations. Fix any with the `fixing-format-check` skill (split files/types/functions — never re-baseline; memory `feedback_swiftlint_fix_not_baseline`).

- [ ] **Step 3: Review gauntlet** — dispatch in parallel and apply ALL findings:
  - `database-schema-review` (the v16 migration, STRICT, UNIQUE, no FK, indexes).
  - `database-code-review` (the GRDB repo, query safety, transaction shape, plan pinning).
  - `sync-review` (record mapping, dispatch registration, conflict/last-writer-wins, account-change/zone purge paths, system-fields handling).
  - `code-review` (naming, thin-view discipline, optional discipline, extension organisation).

- [ ] **Step 4:** Commit review fixes; re-run `just test` + `just format-check` until both clean.

- [ ] **Step 5: `just check-schema-additive`** one more time to confirm the schema is still additive after any review edits.

---

## Task 12: PR

- [ ] **Step 1:** Push the branch (explicit `<src>:<dst>`, never `-u`):
```bash
git -C <worktree> push origin insights-phase-d-persist-dismissals:insights-phase-d-persist-dismissals
```

- [ ] **Step 2:** Open the PR with `gh pr create` (base `main`), body referencing the issue and the exit criteria:
  - Title: `Insights Phase D: persist + sync per-InsightKind dismissals`
  - Body: closes #1034; summarise the record type, the deterministic-UUID keying, the store observe/write-through, last-writer-wins semantics, and the dismissals-only / counts-only scope decision. Note the new CloudKit record type ships its schema via `cktool import-schema` on release per the schema runbook (Production is additive). Request `@sync-review` (exit-criteria requirement). Format the issue/PR refs as markdown links (memory `feedback_pr_link_format`).

- [ ] **Step 3:** Land via the `landing-prs` skill (`gh pr merge --auto --rebase`) — never `git push origin main` (branch protected).

---

## Self-review notes (spec coverage)

- **"per-`InsightKind` dismissal counts"** → Tasks 1–4 (model, schema, row, repo).
- **"New repository + CloudKit record type"** → Task 5 (schema + adapter) + Task 6 (sync registration).
- **"Follow the `modifying-cloudkit-schema` skill and `guides/SYNC_GUIDE.md`"** → Task 5 follows the runbook (edit `schema.ckdb`, `just generate`, `check-schema-additive`, never touch baseline/generated); Task 11 runs `sync-review`.
- **"Feed the persisted dismissals into `InsightStore`'s `generate(dismissals:)`"** → Task 9 (observe seeds `dismissals`, passed into `compute`/`engine.generate`).
- **Exit: "survives relaunch"** → Task 8 Step 1 `dismissalSurvivesReopen`.
- **Exit: "syncs across devices"** → Task 8 Step 2 sync integration test.
- **Exit: "fatigue penalty visibly reorders/suppresses"** → Task 9 Step 1 `persistedDismissalsSeedFatigueOnRefresh`.
- **Exit: "Sync-reviewed (`@sync-review`)"** → Task 11 Step 3 + PR request.
- **Interests deferred** → recorded as an explicit scope decision (confirmed with user); not in this plan.
```
