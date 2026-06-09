# `needs_push` Transactional Dirty-Flag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fully close the residual single-device echo race (issue #1081) by tracking "has un-uploaded local change" as a per-row `needs_push` column that is read **inside the apply write transaction**, so a fetched echo can never clobber an in-flight local edit — with no main-actor snapshot gap.

**Architecture:** Adopt the WatermelonDB / Firestore discipline confirmed by deep research (run `wf_e84643db-263`): a per-record dirty flag set transactionally on every mutation, checked transactionally on apply (dirty rows skip the field-value upsert and take system-fields only, deferring to the next push), and cleared on successful upload **only if the row still matches what was sent** (so a newer edit made between send and ack stays dirty and re-pushes). The flag is a local-only column kept OUT of the `Codable` Row struct, managed by targeted SQL, so it never crosses the CloudKit wire and `upsert` leaves it untouched. This replaces the non-atomic `locallyPendingRecordNames` main-actor snapshot added in #1079.

**Tech Stack:** Swift, GRDB (SQLite, STRICT tables), CKSyncEngine. Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`). Tooling via `just`.

**Scope:** 12 syncable per-profile tables (account, account_group, category, earmark, earmark_budget_item, investment_value, transaction, transaction_leg, transfer_suggestion, insight_dismissal, csv_import_profile, import_rule) + the profile-index `profile` table. Instrument rows live in the shared registry and are out of scope (no per-profile instrument table). Deletions are out of scope — `needs_push` guards SAVES (field-value upserts) only; the deletion path is unchanged.

---

## Key invariants (read before starting)

1. **`needs_push` is local-only.** It is NOT in any Row struct's `CodingKeys`/stored properties, so `insert`/`update`/`upsert` (Codable-driven) never write it. It IS added to each Row's `Columns` enum so it can be set/read via the GRDB query builder. It is never mapped to/from a `CKRecord`.
2. **Set transactionally on mutation.** Every repository create/update/soft-delete sets `needs_push = 1` for the affected id(s) **inside the same `database.write`** as the row change.
3. **Checked transactionally on apply.** `applyRemoteChanges` reads `needs_push` for the incoming ids **inside its own write transaction**; dirty rows skip the field-value upsert and get a system-fields-only update; clean rows apply normally. There is no main-actor pre-snapshot.
4. **Cleared only when unchanged since send.** On `handleSentRecordZoneChanges.savedRecords`, clear `needs_push = 0` for a record **only if** the current row's user fields equal the just-saved record's user fields. A newer edit (different fields) leaves it dirty; CKSyncEngine has already re-queued that edit, and the next ack will clear it. This ordering is race-free under GRDB's serial write queue (a wrongly-cleared flag is re-set by the newer edit's own write; a correctly-skipped clear keeps protection).
5. **`upsert` preserves the column.** GRDB `upsert` emits `INSERT ... ON CONFLICT DO UPDATE SET <Codable columns>`; `needs_push` is not among them, so it is left unchanged on conflict-update and takes the schema `DEFAULT 0` on insert of a brand-new remote row (correct: a freshly-arrived remote row is clean).

---

## File Structure

- **Schema:** `Backends/GRDB/ProfileSchema.swift` (register v17), a new `Backends/GRDB/ProfileSchema+NeedsPush.swift` (the migration body), `Backends/GRDB/ProfileIndexSchema.swift` (register v4) + a new `Backends/GRDB/ProfileIndexSchema+NeedsPush.swift`.
- **Row Columns:** the 12 `Backends/GRDB/Records/*Row.swift` + `ProfileRow.swift` — one `Columns` case each.
- **Repository mutations:** the 13 `Backends/GRDB/Repositories/GRDB*Repository.swift` — set `needs_push=1` in mutations.
- **Repository sync helpers:** the 13 `Backends/GRDB/Repositories/GRDB*Repository+Sync.swift` (or the repo file for profile index) — add `markNeedsPushSync`, `dirtyIdsSync`, `clearNeedsPushBatchSync`.
- **Apply path:** `Backends/CloudKit/Sync/ProfileDataSyncHandler+ApplyRemoteChanges.swift`, `+GRDBSaveHelpers.swift`, `+SystemFields.swift`; `ProfileIndexSyncHandler.swift`.
- **Ack clear:** `ProfileDataSyncHandler+SystemFields.swift`, `ProfileIndexSyncHandler.swift`, + a new `CKRecord.hasSameUserFields(as:)` helper in `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift`.
- **Remove #1079 snapshot:** `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift` (`locallyPendingRecordNames(in:)` + param threading).
- **Tests:** `MoolahTests/Sync/NeedsPushApplyGuardTests.swift`, `MoolahTests/Sync/NeedsPushConditionalClearTests.swift`, `MoolahTests/Backends/GRDB/NeedsPushMutationTests.swift`, and an update to `MoolahTests/Sync/ApplyRemoteChangesPendingGuardTests.swift`.

---

## Per-type repeat list (the "12 syncable tables")

Where a task says "repeat for each syncable type", apply to all of:

| Table | Row file | Repo file | Repo property |
|---|---|---|---|
| account | AccountRow | GRDBAccountRepository | accounts |
| account_group | AccountGroupRow | GRDBAccountGroupRepository | accountGroups |
| category | CategoryRow | GRDBCategoryRepository | categories |
| earmark | EarmarkRow | GRDBEarmarkRepository | earmarks |
| earmark_budget_item | EarmarkBudgetItemRow | GRDBEarmarkBudgetItemRepository | earmarkBudgetItems |
| investment_value | InvestmentValueRow | GRDBInvestmentRepository | investmentValues |
| transaction | TransactionRow | GRDBTransactionRepository | transactions |
| transaction_leg | TransactionLegRow | GRDBTransactionLegRepository | transactionLegs |
| transfer_suggestion | TransferSuggestionRow | GRDBTransferSuggestionRepository | transferSuggestions |
| insight_dismissal | InsightDismissalRow | GRDBInsightDismissalRepository | insightDismissals |
| csv_import_profile | CSVImportProfileRow | GRDBCSVImportProfileRepository | csvImportProfiles |
| import_rule | ImportRuleRow | GRDBImportRuleRepository | importRules |

`profile` (ProfileRow / GRDBProfileIndexRepository) is handled separately in the profile-index tasks.

---

## Task 1: Schema migration — add `needs_push` to every syncable per-profile table

**Files:**
- Create: `Backends/GRDB/ProfileSchema+NeedsPush.swift`
- Modify: `Backends/GRDB/ProfileSchema.swift` (register migration; bump `version`)
- Test: `MoolahTests/Backends/GRDB/NeedsPushMutationTests.swift`

- [ ] **Step 1: Write the failing test** (column exists, default 0, STRICT-compatible)

Create `MoolahTests/Backends/GRDB/NeedsPushMutationTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("needs_push column migration")
struct NeedsPushMutationTests {
  private static let tables = [
    "account", "account_group", "category", "earmark", "earmark_budget_item",
    "investment_value", "\"transaction\"", "transaction_leg", "transfer_suggestion",
    "insight_dismissal", "csv_import_profile", "import_rule",
  ]

  @Test("every syncable table has needs_push INTEGER NOT NULL DEFAULT 0")
  func needsPushColumnPresent() throws {
    let database = try ProfileDatabase.openInMemory()
    try database.read { db in
      for table in Self.tables {
        let unquoted = table.replacingOccurrences(of: "\"", with: "")
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        let needsPush = columns.first { ($0["name"] as String?) == "needs_push" }
        let col = try #require(needsPush, "needs_push missing on \(unquoted)")
        #expect((col["notnull"] as Int?) == 1)
        #expect((col["dflt_value"] as String?) == "0")
      }
    }
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac NeedsPushMutationTests`
Expected: FAIL — `needs_push missing on account` (column not yet added).

- [ ] **Step 3: Write the migration body**

Create `Backends/GRDB/ProfileSchema+NeedsPush.swift`:

```swift
import Foundation
import GRDB

extension ProfileSchema {
  /// v17 — adds the local-only `needs_push` dirty flag to every syncable
  /// per-profile table. `needs_push = 1` means the row has a local change
  /// not yet confirmed uploaded to CloudKit; the fetched-changes apply
  /// path reads it inside its write transaction and refuses to overwrite
  /// such a row's field values (issue #1081). The column never crosses
  /// the CloudKit wire and is absent from every Row struct's CodingKeys,
  /// so `upsert` leaves it untouched. Existing rows default to 0 (clean):
  /// any genuinely-unpushed row already has `encoded_system_fields IS NULL`
  /// and is re-queued by the first-start self-heal, so a 0 default cannot
  /// lose an edit at migration time.
  static func addNeedsPush(_ database: Database) throws {
    let tables = [
      "account", "account_group", "category", "earmark", "earmark_budget_item",
      "investment_value", "\"transaction\"", "transaction_leg",
      "transfer_suggestion", "insight_dismissal", "csv_import_profile", "import_rule",
    ]
    for table in tables {
      try database.execute(
        sql: "ALTER TABLE \(table) ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0;")
    }
  }
}
```

- [ ] **Step 4: Register the migration**

In `Backends/GRDB/ProfileSchema.swift`, bump the `version` constant from `16` to `17`, and add after the `v16_insight_dismissals` line:

```swift
    migrator.registerMigration("v17_needs_push", migrate: addNeedsPush)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `just test-mac NeedsPushMutationTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Backends/GRDB/ProfileSchema.swift Backends/GRDB/ProfileSchema+NeedsPush.swift MoolahTests/Backends/GRDB/NeedsPushMutationTests.swift
git commit -m "feat(sync): add local-only needs_push column to syncable per-profile tables (v17)"
```

---

## Task 2: Schema migration — add `needs_push` to the profile-index `profile` table

**Files:**
- Create: `Backends/GRDB/ProfileIndexSchema+NeedsPush.swift`
- Modify: `Backends/GRDB/ProfileIndexSchema.swift` (register v4; bump `version` 3 → 4)
- Test: extend `NeedsPushMutationTests`

- [ ] **Step 1: Write the failing test**

Append to `NeedsPushMutationTests`:

```swift
  @Test("profile table has needs_push INTEGER NOT NULL DEFAULT 0")
  func profileNeedsPushColumnPresent() throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try database.read { db in
      let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(profile)")
      let needsPush = columns.first { ($0["name"] as String?) == "needs_push" }
      let col = try #require(needsPush, "needs_push missing on profile")
      #expect((col["notnull"] as Int?) == 1)
      #expect((col["dflt_value"] as String?) == "0")
    }
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac NeedsPushMutationTests/profileNeedsPushColumnPresent`
Expected: FAIL — `needs_push missing on profile`.

- [ ] **Step 3: Write the migration body**

Create `Backends/GRDB/ProfileIndexSchema+NeedsPush.swift`:

```swift
import Foundation
import GRDB

extension ProfileIndexSchema {
  /// v4 — adds the local-only `needs_push` dirty flag to the `profile`
  /// table (mirrors the per-profile v17 migration; see
  /// `ProfileSchema+NeedsPush.swift`). Instrument rows live in the shared
  /// registry and are out of scope.
  static func addNeedsPush(_ database: Database) throws {
    try database.execute(
      sql: "ALTER TABLE profile ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0;")
  }
}
```

- [ ] **Step 4: Register the migration**

In `Backends/GRDB/ProfileIndexSchema.swift` bump `version` 3 → 4 and add after the `v3_shared_instrument_registry` registration:

```swift
    migrator.registerMigration("v4_needs_push", migrate: addNeedsPush)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `just test-mac NeedsPushMutationTests`
Expected: PASS (both tests).

- [ ] **Step 6: Commit**

```bash
git add Backends/GRDB/ProfileIndexSchema.swift Backends/GRDB/ProfileIndexSchema+NeedsPush.swift MoolahTests/Backends/GRDB/NeedsPushMutationTests.swift
git commit -m "feat(sync): add needs_push column to profile-index profile table (v4)"
```

---

## Task 3: Add `Columns.needsPush` to every Row's `Columns` enum

**Files:** the 12 `Backends/GRDB/Records/*Row.swift` + `Backends/GRDB/Records/ProfileRow.swift`

> No test of its own — it is exercised by Task 4+. This is a pure additive query-builder change. Do NOT add `needsPush` to `CodingKeys` or to the struct's stored properties.

- [ ] **Step 1: Add the column case (exemplar: AccountRow)**

In `Backends/GRDB/Records/AccountRow.swift`, inside `enum Columns`, add (after `groupId`):

```swift
    /// Local-only dirty flag (issue #1081). Absent from `CodingKeys` so
    /// it never crosses the wire and `upsert` leaves it untouched; set
    /// via the query builder only.
    case needsPush = "needs_push"
```

- [ ] **Step 2: Repeat for each syncable type + ProfileRow**

Add the same `case needsPush = "needs_push"` to the `Columns` enum of every Row in the per-type list above, plus `ProfileRow.Columns`. Keep the doc comment only on AccountRow; the rest get the bare case.

- [ ] **Step 3: Verify it builds**

Run: `just build-mac`
Expected: `** BUILD SUCCEEDED **` (warnings-as-errors).

- [ ] **Step 4: Commit**

```bash
git add Backends/GRDB/Records/
git commit -m "feat(sync): add needsPush query-builder column to syncable Row types"
```

---

## Task 4: Repository sync helpers — mark / read / clear `needs_push`

**Files:** the 13 `Backends/GRDB/Repositories/GRDB*Repository+Sync.swift` (Account exemplar) and `GRDBProfileIndexRepository` for `profile`.
**Test:** `MoolahTests/Backends/GRDB/NeedsPushMutationTests.swift`

Add three helpers per repo, mirroring the existing `setEncodedSystemFieldsBatchSync` shape.

- [ ] **Step 1: Write the failing test** (mark, read dirty ids, clear)

Append to `NeedsPushMutationTests`:

```swift
  @Test("markNeedsPushSync sets the flag; dirtyIdsSync reports it; clear resets it")
  func markReadClearRoundTrip() async throws {
    let database = try ProfileIndexDatabase.openInMemory() == database  // placeholder
    fatalError("replaced below")
  }
```

Replace that placeholder with a real test against the account repo:

```swift
  @Test("markNeedsPushSync sets the flag; dirtyIdsSync reports it; clear resets it")
  func markReadClearRoundTrip() throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let repo = GRDBAccountRepository(
      database: database, instrumentResolver: registry, instrumentRegistrar: registry)
    let id = UUID()
    try database.write { db in
      try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "A").insert(db)
    }

    #expect(try repo.dirtyIdsSync(from: [id]) == [])

    try database.write { db in try repo.markNeedsPushSync(id: id, in: db) }
    #expect(try repo.dirtyIdsSync(from: [id]) == [id])

    _ = try repo.clearNeedsPushBatchSync([id])
    #expect(try repo.dirtyIdsSync(from: [id]) == [])
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac NeedsPushMutationTests/markReadClearRoundTrip`
Expected: FAIL — `markNeedsPushSync` / `dirtyIdsSync` / `clearNeedsPushBatchSync` not found.

- [ ] **Step 3: Add the helpers (exemplar: GRDBAccountRepository+Sync.swift)**

```swift
  /// Sets `needs_push = 1` for `id` inside the caller's write transaction.
  /// Called from every mutation so the apply path (issue #1081) can detect
  /// an in-flight local edit transactionally.
  func markNeedsPushSync(id: UUID, in database: Database) throws {
    _ =
      try AccountRow
      .filter(AccountRow.Columns.id == id)
      .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
  }

  /// Returns the subset of `ids` whose row currently has `needs_push = 1`.
  /// Read inside the apply write transaction (pass that `database`); the
  /// overload without `database` opens its own read for non-apply callers.
  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let idSet = Set(ids)
    let rows =
      try AccountRow
      .filter(idSet.contains(AccountRow.Columns.id))
      .filter(AccountRow.Columns.needsPush == true)
      .select(AccountRow.Columns.id, as: UUID.self)
      .fetchAll(database)
    return Set(rows)
  }

  func dirtyIdsSync(from ids: [UUID]) throws -> Set<UUID> {
    try database.read { db in try dirtyIdsSync(from: ids, in: db) }
  }

  /// Clears `needs_push` for the given ids in one transaction. Returns the
  /// number of rows updated.
  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID]) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return try database.write { database in
      try AccountRow
        .filter(Set(ids).contains(AccountRow.Columns.id))
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: false)])
    }
  }
```

- [ ] **Step 4: Repeat for each syncable type**

Add the same three helpers to every `GRDB*Repository+Sync.swift`, substituting the Row type and table. For `transaction_leg`, keys are `UUID` (`TransactionLegRow`). For `GRDBProfileIndexRepository`, add equivalents on `ProfileRow` (it lives in the main repo file, not a `+Sync.swift`).

- [ ] **Step 5: Run test to verify it passes**

Run: `just test-mac NeedsPushMutationTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Backends/GRDB/Repositories/
git commit -m "feat(sync): add markNeedsPush / dirtyIds / clearNeedsPush repo helpers"
```

---

## Task 5: Set `needs_push = 1` in every repository mutation

**Files:** the 13 `Backends/GRDB/Repositories/GRDB*Repository.swift` + `GRDBProfileIndexRepository`.
**Test:** `MoolahTests/Backends/GRDB/NeedsPushMutationTests.swift`

Every create/update/soft-delete that already calls `onRecordChanged` must also call `markNeedsPushSync(id:in:)` **inside its `database.write`** for the same id(s). For multi-record mutations (e.g. account create that also writes an opening-balance transaction + leg), mark each affected id.

- [ ] **Step 1: Write the failing test**

Append to `NeedsPushMutationTests`:

```swift
  @Test("account create/update set needs_push")
  func accountMutationsMarkDirty() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let repo = GRDBAccountRepository(
      database: database, instrumentResolver: registry, instrumentRegistrar: registry)
    let account = Account(
      id: UUID(), name: "Checking", type: .bank,
      instrument: .defaultTestInstrument, position: 0)

    _ = try await repo.create(account)
    #expect(try repo.dirtyIdsSync(from: [account.id]) == [account.id])

    _ = try repo.clearNeedsPushBatchSync([account.id])
    var renamed = account
    renamed.name = "Renamed"
    _ = try await repo.update(renamed)
    #expect(try repo.dirtyIdsSync(from: [account.id]) == [account.id])
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac NeedsPushMutationTests/accountMutationsMarkDirty`
Expected: FAIL — `needs_push` stays 0 after create (`dirtyIdsSync` returns `[]`).

- [ ] **Step 3: Add the mark calls (exemplar: GRDBAccountRepository)**

In `create`, inside `performAccountInsert`'s `database.write` (or the write block that inserts the rows), after each row insert, mark it. Concretely, in the `database.write { database -> OpeningBalanceInserts in ... }` block add before returning:

```swift
      try markNeedsPushSync(id: account.id, in: database)
      if let txnId = inserts.transactionId {
        try transactionsDelegateMarkNeedsPush(txnId, in: database)
      }
      if let legId = inserts.legId {
        try legsDelegateMarkNeedsPush(legId, in: database)
      }
```

> NOTE: account `create` also writes a `transaction` + `transaction_leg`. Those rows belong to other repos. Rather than reach across repos, mark them with inline `updateAll` on their tables within the same `database`:
>
> ```swift
> try TransactionRow.filter(TransactionRow.Columns.id == txnId)
>   .updateAll(database, [TransactionRow.Columns.needsPush.set(to: true)])
> try TransactionLegRow.filter(TransactionLegRow.Columns.id == legId)
>   .updateAll(database, [TransactionLegRow.Columns.needsPush.set(to: true)])
> ```
>
> Use the inline form for cross-table marks; use `markNeedsPushSync(id:in:)` for the repo's own table. Delete the `transactionsDelegate*` placeholders above — they are illustrative only.

In `update`, inside the `database.write` block after `try existing.update(database)`:

```swift
    try markNeedsPushSync(id: account.id, in: database)
```

In `delete` (soft-delete via `isHidden = true`), after `try existing.update(database)`:

```swift
    try markNeedsPushSync(id: id, in: database)
```

- [ ] **Step 4: Repeat for each syncable type**

For every repo, add `markNeedsPushSync(id:in:)` (or the inline cross-table form) inside the `database.write` of every mutation that calls `onRecordChanged`. Audit each repo: any mutation path that queues a sync save MUST mark the same id. Mutations that write multiple record types (transaction create writes transaction + legs; earmark writes budget items) must mark every affected id. For `GRDBProfileIndexRepository`, mark `profile` on create/update.

- [ ] **Step 5: Run test to verify it passes**

Run: `just test-mac NeedsPushMutationTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Backends/GRDB/Repositories/
git commit -m "feat(sync): mark needs_push on every repository mutation"
```

---

## Task 6: Add `CKRecord.hasSameUserFields(as:)` helper

**Files:** Modify `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift`
**Test:** `MoolahTests/Sync/NeedsPushConditionalClearTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Sync/NeedsPushConditionalClearTests.swift`:

```swift
@preconcurrency import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("CKRecord user-field comparison")
struct CKRecordUserFieldComparisonTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("equal user fields compare equal; a differing field compares unequal")
  func sameUserFields() {
    let id = UUID()
    let a = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "X")
      .toCKRecord(in: Self.zoneID)
    let b = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "X")
      .toCKRecord(in: Self.zoneID)
    let c = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "Y")
      .toCKRecord(in: Self.zoneID)
    #expect(a.hasSameUserFields(as: b))
    #expect(!a.hasSameUserFields(as: c))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac CKRecordUserFieldComparisonTests`
Expected: FAIL — `hasSameUserFields` not found.

- [ ] **Step 3: Add the helper**

In `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift`, in the `extension CKRecord` block:

```swift
  /// True when `self` and `other` carry identical user-field values
  /// (system fields / change tag ignored). Used by the upload-ack path to
  /// decide whether a row changed locally since the version that was
  /// uploaded: if the current row's `toCKRecord` still matches the saved
  /// record, the local edit has been confirmed and `needs_push` can be
  /// cleared; if a field differs, a newer edit is pending and the flag
  /// stays set (issue #1081). CKRecord user values are CloudKit-native
  /// types bridged to `NSObject` (`NSString`/`NSNumber`/`NSData`/`NSDate`),
  /// so `isEqual` compares them correctly.
  func hasSameUserFields(as other: CKRecord) -> Bool {
    let keys = Set(allKeys()).union(other.allKeys())
    for key in keys {
      let lhs = self[key] as? NSObject
      let rhs = other[key] as? NSObject
      if lhs != rhs { return false }
    }
    return true
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac CKRecordUserFieldComparisonTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/CloudKitRecordConvertible.swift MoolahTests/Sync/NeedsPushConditionalClearTests.swift
git commit -m "feat(sync): add CKRecord.hasSameUserFields(as:) for conditional clear"
```

---

## Task 7: Apply path — check `needs_push` inside the write transaction (ProfileDataSyncHandler)

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+ApplyRemoteChanges.swift`, `+GRDBSaveHelpers.swift`, `+GRDBDispatch.swift` as needed
- Test: `MoolahTests/Sync/NeedsPushApplyGuardTests.swift`

The apply currently partitions on the `locallyPendingRecordNames` set. Replace that with an **in-transaction** read of `needs_push`: inside the outer `database.write`, for the incoming saved records, query which ids are dirty (per type via `dirtyIdsSync(from:in:)`); dirty records skip the field-value upsert and are collected for a system-fields-only update; clean records upsert as today.

- [ ] **Step 1: Write the failing test** (edit lands as dirty → echo must not clobber)

Create `MoolahTests/Sync/NeedsPushApplyGuardTests.swift`:

```swift
@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Apply guards rows flagged needs_push")
struct NeedsPushApplyGuardTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("a dirty row's field values survive a stale echo; system fields update")
  func dirtyRowFieldValuesPreserved() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    // Local newer edit, flagged dirty (as a mutation would).
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { db in
      try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "LOCAL EDIT 2")
        .insert(db)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(db, [AccountRow.Columns.needsPush.set(to: true)])
    }
    let staleEcho = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "STALE SERVER EDIT 1"
    ).toCKRecord(in: Self.zoneID)
    let echoSystemFields = staleEcho.encodedSystemFields

    let result = harness.handler.applyRemoteChanges(saved: [staleEcho], deleted: [])
    if case .saveFailed(let m) = result { Issue.record("save failed: \(m)") }

    let row = try await harness.database.read { db in
      try AccountRow.fetchOne(db, key: id)
    }
    let saved = try #require(row)
    #expect(saved.name == "LOCAL EDIT 2")            // field values preserved
    #expect(saved.encodedSystemFields == echoSystemFields)  // system fields updated
  }

  @Test("a clean row applies the remote change normally")
  func cleanRowApplies() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { db in
      try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "OLD").insert(db)
      // needs_push defaults to 0 (clean).
    }
    let remote = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "REMOTE"
    ).toCKRecord(in: Self.zoneID)

    _ = harness.handler.applyRemoteChanges(saved: [remote], deleted: [])

    let row = try await harness.database.read { db in try AccountRow.fetchOne(db, key: id) }
    #expect(try #require(row).name == "REMOTE")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac NeedsPushApplyGuardTests`
Expected: `dirtyRowFieldValuesPreserved` FAILS (name becomes "STALE SERVER EDIT 1" — apply still blind-upserts dirty rows); `cleanRowApplies` PASSES.

- [ ] **Step 3: Add an in-transaction dirty-id lookup dispatch**

In `ProfileDataSyncHandler+GRDBSaveHelpers.swift` add a helper that, given a recordType and ids, returns the dirty subset using the repo's `dirtyIdsSync(from:in:)` inside the active `database`:

```swift
  nonisolated func dirtyIds(
    recordType: String, ids: [UUID], in database: Database
  ) throws -> Set<UUID> {
    let repos = grdbRepositories
    switch recordType {
    case AccountRow.recordType: return try repos.accounts.dirtyIdsSync(from: ids, in: database)
    case AccountGroupRow.recordType:
      return try repos.accountGroups.dirtyIdsSync(from: ids, in: database)
    case CategoryRow.recordType: return try repos.categories.dirtyIdsSync(from: ids, in: database)
    case EarmarkRow.recordType: return try repos.earmarks.dirtyIdsSync(from: ids, in: database)
    case EarmarkBudgetItemRow.recordType:
      return try repos.earmarkBudgetItems.dirtyIdsSync(from: ids, in: database)
    case InvestmentValueRow.recordType:
      return try repos.investmentValues.dirtyIdsSync(from: ids, in: database)
    case TransactionRow.recordType:
      return try repos.transactions.dirtyIdsSync(from: ids, in: database)
    case TransactionLegRow.recordType:
      return try repos.transactionLegs.dirtyIdsSync(from: ids, in: database)
    case TransferSuggestionRow.recordType:
      return try repos.transferSuggestions.dirtyIdsSync(from: ids, in: database)
    case InsightDismissalRow.recordType:
      return try repos.insightDismissals.dirtyIdsSync(from: ids, in: database)
    case CSVImportProfileRow.recordType:
      return try repos.csvImportProfiles.dirtyIdsSync(from: ids, in: database)
    case ImportRuleRow.recordType: return try repos.importRules.dirtyIdsSync(from: ids, in: database)
    default: return []
    }
  }
```

- [ ] **Step 4: Partition each per-type group by dirtiness in `applyBatchSaves`**

In `ProfileDataSyncHandler+ApplyRemoteChanges.swift`, change `applyBatchSaves` so that, for each `(recordType, ckRecords)` group, it computes the dirty ids inside `database`, splits the group, applies the clean records via the existing `applyGRDBBatchSave`, and writes system-fields-only for the dirty records **in the same transaction** via a new `applySystemFieldsInTransaction(recordType:ckRecords:in:)` (a sibling of the existing `setEncodedSystemFieldsBatchSync` that takes the active `database` and does `updateAll([encodedSystemFields.set(to:)])` per row):

```swift
  nonisolated func applyBatchSaves(
    _ records: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let grouped = Dictionary(grouping: records, by: \.recordType)
    for (recordType, ckRecords) in grouped {
      let ids = ckRecords.compactMap { $0.recordID.uuid }
      let dirty = try dirtyIds(recordType: recordType, ids: ids, in: database)
      let clean = dirty.isEmpty ? ckRecords
        : ckRecords.filter { $0.recordID.uuid.map { !dirty.contains($0) } ?? true }
      let echoed = dirty.isEmpty ? []
        : ckRecords.filter { $0.recordID.uuid.map { dirty.contains($0) } ?? false }

      if !echoed.isEmpty {
        try applySystemFieldsInTransaction(
          recordType: recordType, ckRecords: echoed, in: database)
      }
      if try applyGRDBBatchSave(
        recordType: recordType, ckRecords: clean, systemFields: systemFields, in: database)
      {
        continue
      }
      if recordType != ProfileRow.recordType && !clean.isEmpty {
        Self.batchLogger.warning(
          "applyBatchSaves: unknown record type '\(recordType)' — skipping")
      }
    }
  }
```

Add `applySystemFieldsInTransaction` in `+GRDBSaveHelpers.swift` dispatching per type to a new in-transaction `setEncodedSystemFieldsBatchSync(_:in:)` repo helper (add that overload alongside the existing one in each `+Sync.swift`, taking `in database: Database` and skipping its own `database.write`).

- [ ] **Step 5: Run test to verify it passes**

Run: `just test-mac NeedsPushApplyGuardTests ApplyRemoteChangesPendingGuardTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Backends/CloudKit/Sync/ Backends/GRDB/Repositories/ MoolahTests/Sync/NeedsPushApplyGuardTests.swift
git commit -m "feat(sync): guard apply with transactional needs_push check (ProfileDataSyncHandler)"
```

---

## Task 8: Apply path — same guard for ProfileIndexSyncHandler (`profile`)

**Files:** Modify `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift` and `Backends/GRDB/Repositories/GRDBProfileIndexRepository.swift` (add in-transaction variants + dirty helpers).
**Test:** add a case to `MoolahTests/Sync/ProfileIndexSyncHandlerTests.swift`.

> **This path MUST be fully transactional — no accepted residual.** Data loss is non-negotiable; a "narrow window bounded to the index zone" is still a defect. The dirty check, the clean-row upsert, and the dirty-row system-fields write all happen inside ONE `repository.database.write` so an in-flight profile rename can never be clobbered by an echo, identically to the per-profile path. (Instrument rows live in the separate shared-registry database and are out of scope here.)

- [ ] **Step 1: Write the failing test**

Append to `ProfileIndexSyncHandlerTests`:

```swift
  @Test("a needs_push profile row's label survives a stale echo")
  func dirtyProfileEchoPreservesRename() throws {
    let (handler, repository) = try makeHandler()
    let profileId = UUID()
    let local = Profile(
      id: profileId, label: "LOCAL RENAME", currencyCode: "AUD",
      financialYearStartMonth: 7)
    try repository.applyRemoteChangesSync(saved: [ProfileRow(domain: local)], deleted: [])
    try repository.markNeedsPushSync(id: profileId)  // simulate a pending local edit

    let staleEcho = CKRecord(
      recordType: ProfileRow.recordType,
      recordID: CKRecord.ID(
        recordType: ProfileRow.recordType, uuid: profileId, zoneID: handler.zoneID))
    staleEcho["label"] = "STALE OLD LABEL" as CKRecordValue
    staleEcho["currencyCode"] = "AUD" as CKRecordValue
    staleEcho["financialYearStartMonth"] = 7 as CKRecordValue
    staleEcho["createdAt"] = Date() as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [staleEcho], deleted: [])

    let row = try #require(try repository.fetchRowSync(id: profileId))
    #expect(row.label == "LOCAL RENAME")
  }
```

(Add the repo helpers below; a non-`in:` `markNeedsPushSync(id:)` convenience that opens its own write is used by this test.)

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac ProfileIndexSyncHandlerTests/dirtyProfileEchoPreservesRename`
Expected: FAIL — label becomes "STALE OLD LABEL".

- [ ] **Step 3: Add in-transaction repo variants to `GRDBProfileIndexRepository`**

The handler needs to do the dirty check, the clean-row upsert, and the dirty-row system-fields write in ONE transaction. Add these to `GRDBProfileIndexRepository` (alongside the existing self-write `applyRemoteChangesSync(saved:deleted:)`). The repo already holds `let database: any DatabaseWriter` — expose it to the handler if not already accessible.

```swift
  /// In-transaction profile upsert/delete (mirrors the self-write
  /// overload). Runs against the caller's `database` so the dirty check
  /// and the upsert share one transaction (issue #1081 — no echo race).
  func applyRemoteChangesSync(
    saved rows: [ProfileRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows { try row.upsert(database) }
    for id in ids { _ = try ProfileRow.deleteOne(database, id: id) }
  }

  /// Subset of `ids` whose profile row currently has `needs_push = 1`,
  /// read inside the caller's transaction.
  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let idSet = Set(ids)
    return Set(
      try ProfileRow
        .filter(idSet.contains(ProfileRow.Columns.id))
        .filter(ProfileRow.Columns.needsPush == true)
        .select(ProfileRow.Columns.id, as: UUID.self)
        .fetchAll(database))
  }

  func dirtyIdsSync(from ids: [UUID]) throws -> Set<UUID> {
    try database.read { db in try dirtyIdsSync(from: ids, in: db) }
  }

  /// In-transaction system-fields-only write (change tag), for dirty
  /// profile echoes that must NOT have their field values overwritten.
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)], in database: Database
  ) throws {
    for (id, data) in updates {
      _ =
        try ProfileRow
        .filter(ProfileRow.Columns.id == id)
        .updateAll(database, [ProfileRow.Columns.encodedSystemFields.set(to: data)])
    }
  }

  func markNeedsPushSync(id: UUID, in database: Database) throws {
    _ =
      try ProfileRow
      .filter(ProfileRow.Columns.id == id)
      .updateAll(database, [ProfileRow.Columns.needsPush.set(to: true)])
  }

  func markNeedsPushSync(id: UUID) throws {
    try database.write { db in try markNeedsPushSync(id: id, in: db) }
  }

  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID]) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return try database.write { db in
      try ProfileRow
        .filter(Set(ids).contains(ProfileRow.Columns.id))
        .updateAll(db, [ProfileRow.Columns.needsPush.set(to: false)])
    }
  }
```

- [ ] **Step 4: Make `ProfileIndexSyncHandler.applyRemoteChanges` apply profiles in ONE transaction**

Replace the current profile leg (the `do { try repository.applyRemoteChangesSync(saved: savedSplit.profileRows, deleted: deletedSplit.profileIds) } catch { ... }` block) with a single `database.write` that splits dirty vs clean inside the transaction. The instrument leg is unchanged (separate registry DB). The `saved` parameter is the original `[CKRecord]` available in `applyRemoteChanges`.

```swift
    do {
      try repository.database.write { database in
        let profileIds = savedSplit.profileRows.map(\.id)
        let dirty = try repository.dirtyIdsSync(from: profileIds, in: database)
        let clean = savedSplit.profileRows.filter { !dirty.contains($0.id) }
        try repository.applyRemoteChangesSync(
          saved: clean, deleted: deletedSplit.profileIds, in: database)
        // Dirty profile echoes: advance the change tag only, never field values.
        let echoes = saved.compactMap { record -> (id: UUID, data: Data?)? in
          guard let uuid = record.recordID.uuid, dirty.contains(uuid),
            record.recordType == ProfileRow.recordType
          else { return nil }
          return (uuid, record.encodedSystemFields)
        }
        if !echoes.isEmpty {
          try repository.setEncodedSystemFieldsBatchSync(echoes, in: database)
        }
      }
    } catch {
      logger.error("Failed to save remote profile changes: \(error, privacy: .public)")
      return .saveFailed(error.localizedDescription)
    }
```

> Keep the existing `changedTypes` computation (profiles changed iff `savedSplit.profileRows` or `deletedSplit.profileIds` is non-empty — the dirty split doesn't change that a profile fetch arrived). The instrument leg and its `onInstrumentRemoteChange()` fan-out remain exactly as-is below this block.

- [ ] **Step 5: Run test to verify it passes**

Run: `just test-mac ProfileIndexSyncHandlerTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift Backends/GRDB/Repositories/GRDBProfileIndexRepository.swift MoolahTests/Sync/ProfileIndexSyncHandlerTests.swift
git commit -m "feat(sync): guard profile-index apply with needs_push check (single transaction)"
```

---

## Task 9: Conditional clear on successful upload (ProfileDataSyncHandler)

**Files:** Modify `Backends/CloudKit/Sync/ProfileDataSyncHandler+SystemFields.swift`.
**Test:** `MoolahTests/Sync/NeedsPushConditionalClearTests.swift`

`handleSentRecordZoneChanges` already writes system fields for `savedRecords`. Add: for each saved record, fetch the current row, build its `toCKRecord`, and if it `hasSameUserFields(as: savedRecord)` clear `needs_push`; otherwise leave it (a newer edit is pending and is already re-queued).

- [ ] **Step 1: Write the failing test**

Append to `NeedsPushConditionalClearTests` (the suite created in Task 6 — add a second `@Suite` or extend; here a new suite):

```swift
@Suite("Upload ack clears needs_push only when unchanged")
struct NeedsPushAckClearTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("ack clears the flag when the row matches what was sent")
  func clearsWhenUnchanged() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    let row = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "Sent")
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { db in
      try row.insert(db)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(db, [AccountRow.Columns.needsPush.set(to: true)])
    }
    let sent = row.toCKRecord(in: Self.zoneID)  // matches current row

    _ = harness.handler.handleSentRecordZoneChanges(
      savedRecords: [sent], failedSaves: [], failedDeletes: [])

    #expect(try await harness.database.read { db in
      try AccountRow.fetchOne(db, key: id)?.needsPushFlag(db, id: id)
    } == false)
  }

  @Test("ack leaves the flag set when the row changed since send") 
  func keepsWhenChanged() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { db in
      try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "EDIT 2").insert(db)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(db, [AccountRow.Columns.needsPush.set(to: true)])
    }
    // The record that was actually sent carried the OLD value "EDIT 1".
    let sent = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "EDIT 1")
      .toCKRecord(in: Self.zoneID)

    _ = harness.handler.handleSentRecordZoneChanges(
      savedRecords: [sent], failedSaves: [], failedDeletes: [])

    let stillDirty = try await harness.database.read { db -> Bool in
      (try Bool.fetchOne(
        db, sql: "SELECT needs_push FROM account WHERE id = ?", arguments: [id])) ?? false
    }
    #expect(stillDirty)  // newer edit must remain pending
  }
}
```

> Use the raw-SQL `needs_push` read shown in `keepsWhenChanged` for both tests; delete the `needsPushFlag(...)` placeholder in `clearsWhenUnchanged` and replace with the same raw-SQL read.

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac NeedsPushAckClearTests`
Expected: both FAIL (flag never cleared / clear logic absent).

- [ ] **Step 3: Implement conditional clear**

In `ProfileDataSyncHandler+SystemFields.swift`, after `updateSystemFieldsForSaved(savedRecords)` in `handleSentRecordZoneChanges`, add `clearNeedsPushForConfirmed(savedRecords)`:

```swift
  /// Clears `needs_push` for each saved record whose current local row
  /// still matches the uploaded version. If the row changed since the
  /// send (a newer edit), the flag stays set — CKSyncEngine has already
  /// re-queued that edit, and its own later ack clears the flag. Race-free
  /// under the serial write queue: a wrongly-cleared flag is re-set by the
  /// newer edit's own write (issue #1081).
  private func clearNeedsPushForConfirmed(_ savedRecords: [CKRecord]) {
    var clearByType: [String: [UUID]] = [:]
    for saved in savedRecords {
      guard let uuid = saved.recordID.uuid else { continue }
      guard let current = currentCKRecord(recordType: saved.recordType, id: uuid)
      else { continue }
      if current.hasSameUserFields(as: saved) {
        clearByType[saved.recordType, default: []].append(uuid)
      }
    }
    for (recordType, ids) in clearByType {
      do { try clearNeedsPush(recordType: recordType, ids: ids) } catch {
        logger.error(
          "clearNeedsPush failed for \(recordType, privacy: .public): \(error, privacy: .public)")
      }
    }
  }
```

Add `currentCKRecord(recordType:id:)` (reuse the existing `fetchAndBuild`/record-lookup helpers from `+RecordLookup.swift`) and `clearNeedsPush(recordType:ids:)` (dispatch to each repo's `clearNeedsPushBatchSync`). Call `clearNeedsPushForConfirmed(savedRecords)` from `handleSentRecordZoneChanges` when `savedRecords` is non-empty.

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac NeedsPushAckClearTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileDataSyncHandler+SystemFields.swift MoolahTests/Sync/NeedsPushConditionalClearTests.swift
git commit -m "feat(sync): clear needs_push on upload ack only when row unchanged since send"
```

---

## Task 10: Conditional clear for ProfileIndexSyncHandler

**Files:** Modify `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift`.
**Test:** add a case to `ProfileIndexSyncHandlerTests`.

- [ ] **Step 1: Write the failing test**

Append to `ProfileIndexSyncHandlerTests`:

```swift
  @Test("profile ack clears needs_push only when unchanged since send")
  func profileAckConditionalClear() throws {
    let (handler, repository) = try makeHandler()
    let profileId = UUID()
    let row = ProfileRow(domain: Profile(
      id: profileId, label: "Sent", currencyCode: "AUD", financialYearStartMonth: 7))
    try repository.applyRemoteChangesSync(saved: [row], deleted: [])
    try repository.markNeedsPushSync(id: profileId)
    let sent = handler.buildCKRecord(for: row)

    _ = handler.handleSentRecordZoneChanges(
      savedRecords: [sent], failedSaves: [], failedDeletes: [])

    let dirty = try repository.dirtyIdsSync(from: [profileId])
    #expect(dirty.isEmpty)  // unchanged → cleared
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac ProfileIndexSyncHandlerTests/profileAckConditionalClear`
Expected: FAIL — flag not cleared.

- [ ] **Step 3: Implement**

In `ProfileIndexSyncHandler.persistSystemFields(for:)` (or alongside it in `handleSentRecordZoneChanges`), after persisting system fields, for each saved `ProfileRow`-typed record compare `buildCKRecord(for: currentRow).hasSameUserFields(as: saved)` and clear via `repository.clearNeedsPushBatchSync([id])` when equal. Ignore instrument-typed saved records (shared registry).

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac ProfileIndexSyncHandlerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift MoolahTests/Sync/ProfileIndexSyncHandlerTests.swift
git commit -m "feat(sync): clear profile needs_push on ack only when unchanged"
```

---

## Task 11: Remove the #1079 main-actor snapshot guard

**Files:** Modify `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift`, `ProfileDataSyncHandler+ApplyRemoteChanges.swift`, `ProfileIndexSyncHandler.swift`; update `MoolahTests/Sync/ApplyRemoteChangesPendingGuardTests.swift`.

The transactional `needs_push` check (Tasks 7–8) strictly supersedes the `locallyPendingRecordNames` snapshot. Remove the snapshot to avoid two overlapping mechanisms.

- [ ] **Step 1: Update the existing guard tests to the new mechanism**

In `ApplyRemoteChangesPendingGuardTests.swift`, the three tests pass `locallyPendingRecordNames:`. Change each to instead flag the seeded row dirty via `needs_push` (as in Task 7's test) and call `applyRemoteChanges(saved:deleted:)` without the param. Keep the assertions identical (field values preserved, system fields updated). This keeps the regression coverage while moving it to the new mechanism.

- [ ] **Step 2: Remove the parameter and snapshot**

- In `ProfileDataSyncHandler+ApplyRemoteChanges.swift`: delete the `locallyPendingRecordNames` parameter, `partitionPendingEchoes`, and the post-write `applySystemFieldsBatched(pendingEchoes)` block (the in-transaction split from Task 7 replaces it). `applyRemoteChanges(saved:deleted:preExtractedSystemFields:)` returns to a 3-arg signature.
- In `ProfileIndexSyncHandler.swift`: delete the `locallyPendingRecordNames` parameter and `partitionPendingEchoes` (Task 8's dirty split replaces it).
- In `SyncCoordinator+RecordChanges.swift`: delete `locallyPendingRecordNames(in:)` and the `MainActor.run` snapshot in both `applyFetchedProfileDataChanges` and `applyFetchedIndexChanges`; restore the plain `handler.applyRemoteChanges(saved:deleted:preExtractedSystemFields:)` / `profileIndexHandler.applyRemoteChanges(saved:deleted:)` calls.

- [ ] **Step 3: Run the full sync suites**

Run: `just test-mac NeedsPushApplyGuardTests NeedsPushConditionalClearTests NeedsPushAckClearTests ApplyRemoteChangesPendingGuardTests ProfileIndexSyncHandlerTests CoreFinancialGraphSyncRoundTripTests SyncRoundTripTransactionTests ApplyRemoteChangesOutOfOrderTests ApplyRemoteChangesAtomicityTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Sync/ MoolahTests/Sync/ApplyRemoteChangesPendingGuardTests.swift
git commit -m "refactor(sync): replace #1079 main-actor pending snapshot with transactional needs_push"
```

---

## Task 12: Full verification + reviews

- [ ] **Step 1: Format + lint**

Run: `just format && just format-check`
Expected: "All Swift files are correctly formatted." If a touched file now exceeds the 400-line limit, split it into a focused extension file (do NOT collapse lines or re-baseline).

- [ ] **Step 2: Full macOS suite**

Run: `pkill -f "Moolah.*xctest" 2>/dev/null; just test-mac 2>&1 | tee .agent-tmp/test-full-mac.txt | tail -3`
Expected: "All tests passed."

- [ ] **Step 3: Specialist reviews**

Run the `database-schema-review` (migrations v17/v4, STRICT, default, additive), `database-code-review` (the new repo helpers, `updateAll`/`dirtyIdsSync`, transaction discipline), `sync-review` (apply/ack changes both handlers, cross-handler rule), and `concurrency-review` (in-transaction reads, nonisolated dispatch) agents on the working tree. Apply all Critical/Important/Minor findings (separate PR only if genuinely out of scope, and ask first).

- [ ] **Step 4: Update issue + memory**

In the PR body, `Fixes #1081`. Update memory `reference_sync_pending_echo_guard.md` to note the residual window is now closed transactionally via `needs_push`.

- [ ] **Step 5: Open PR + auto-merge**

```bash
git -C "$PWD" push origin worktree-needs-push-dirty-flag:needs-push-dirty-flag
gh pr create --base main --head needs-push-dirty-flag --title "fix(sync): close the #1081 echo race with a transactional needs_push dirty flag" --body "<summary + Fixes #1081>"
gh pr merge <N> --auto
```

---

## Self-Review notes

- **Spec coverage:** migration (T1–2), Row columns (T3), helpers (T4), mutation marking (T5), comparison helper (T6), apply guard both handlers (T7–8), conditional clear both handlers (T9–10), remove old guard (T11), verify+review (T12). All research-recommended elements (transactional dirty check + value-comparison clear + defer-not-clobber) are present.
- **Type consistency:** helper names used uniformly — `markNeedsPushSync(id:in:)`, `dirtyIdsSync(from:in:)` + `dirtyIdsSync(from:)`, `clearNeedsPushBatchSync(_:)`, `setEncodedSystemFieldsBatchSync(_:in:)`, `CKRecord.hasSameUserFields(as:)`, `Columns.needsPush`.
- **No accepted residual.** Both handlers do the dirty check, clean-row upsert, and dirty-row system-fields write inside ONE transaction (per-profile: the existing outer `database.write` in T7; profile-index: a new `repository.database.write` in T8). Data loss is non-negotiable, so there is no "narrow window remains" caveat — the design is uniformly transactional across every syncable path. The conditional clear (T9/T10) is race-free under GRDB's serial write queue (a wrongly-cleared flag is re-set by the newer edit's own write).
