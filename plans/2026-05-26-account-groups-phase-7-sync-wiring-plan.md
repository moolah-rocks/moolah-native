# Account Groups — Phase 7 Implementation Plan: Sync wiring

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take `AccountGroup` from local-only (Phase 3) to fully cross-device synced. Implement `CloudKitRecordConvertible` on `AccountGroupRow`, add the sync helpers on `GRDBAccountGroupRepository`, register the new record type in every dispatch table inside `ProfileDataSyncHandler`, and prove the round-trip with both unit and integration tests.

**Architecture:** AccountGroup is **reference data** — it's an organisational construct, not part of the financial graph — so its dispatch wiring mirrors `TransferSuggestionRecord` (the most recent reference-data addition), not `AccountRecord`. The repository gets a single `applyRemoteChangesSync(saved:deleted:in:)` entry point (the reference-data shape), and the sync handler dispatch uses the `referenceSaveHandler` / `referenceDeleter` tables in `ProfileDataSyncHandler+GRDBDispatch.swift`.

**Tech Stack:** Swift, CloudKit (CKRecord + CKSyncEngine), GRDB (apply-batch transactions), Swift Testing.

**Spec:** `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-groups-design/plans/2026-05-26-account-groups-design.md` — see "Sync & schema" and "Sync conflict resolution".

**Phase ordering:** **Hard dependency on Phase 3** (the `AccountGroupRow`, `GRDBAccountGroupRepository`, CKDB record type, and GRDB migration must all exist). Independent of Phases 2, 4, 5, 6, 8 — can run in parallel with any UI work once Phase 3 lands.

**Reviewer reference:** every wire-up site below has an exact peer pattern in `TransferSuggestionRow` (the v13 record type added by the most recent parallel feature). Search for `TransferSuggestionRow.recordType` to find the corresponding line for each file modified here, and mirror the call.

---

## Worktree setup

- [ ] **Step 1: Confirm Phase 3 is merged on main**

```bash
gh pr list --state merged --search "account-group-model in:title" --json number,mergedAt --jq '.[0]'
```

If empty, Phase 3 isn't on `main` yet. You can still stack this PR on Phase 3's branch (`account-group-model`); the `landing-prs` skill will retarget once Phase 3 merges.

- [ ] **Step 2: Create the worktree**

```bash
# If Phase 3 has merged:
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track \
  .worktrees/account-group-sync -b account-group-sync origin/main

# If Phase 3 has NOT merged (stacked):
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track \
  .worktrees/account-group-sync -b account-group-sync origin/account-group-model
```

- [ ] **Step 3: Generate Xcode project + verify clean build**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync \
     --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync/justfile generate

just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync \
     --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync/justfile build-mac 2>&1 | tail -5
```

Expected: clean build (Phase 3's local-only state).

- [ ] **Step 4: Working directory is the worktree from here on**

`/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync`.

---

## Task 1: Add sync helpers + `applyRemoteChangesSync` on `GRDBAccountGroupRepository`

**Files:**
- Create: `Backends/GRDB/Repositories/GRDBAccountGroupRepository+Sync.swift`
- Modify: `Backends/GRDB/Repositories/GRDBAccountGroupRepository.swift` (add the methods directly or in an extension file — pattern below uses a `+Sync.swift` extension file matching `GRDBAccountGroupRepository+Sync.swift` for GRDBAccountRepository)

Mirror `GRDBTransferSuggestionRepository`'s sync extension. Read it first for the exact pattern:

```bash
cat /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync/Backends/GRDB/Repositories/GRDBTransferSuggestionRepository.swift | sed -n '95,160p'
```

- [ ] **Step 1: Write the failing tests**

Append to `MoolahTests/Backends/GRDB/AccountGroupsMigrationTests.swift` (or a new sibling `AccountGroupSyncHelpersTests.swift`):

```swift
@Suite("GRDBAccountGroupRepository sync helpers")
@MainActor
struct AccountGroupSyncHelpersTests {
  @Test
  func applyRemoteChangesSyncInsertsRows() async throws {
    let (backend, database) = try TestBackend.create()
    let repo = backend.accountGroups as! GRDBAccountGroupRepository

    let row = AccountGroupRow(
      domain: AccountGroup(name: "Cross-device", bucket: .investments, instrument: .defaultTestInstrument)
    )
    try await database.write { db in
      try repo.applyRemoteChangesSync(saved: [row], deleted: [], in: db)
    }

    let all = try await repo.fetchAll()
    #expect(all.contains(where: { $0.id == row.id }))
  }

  @Test
  func applyRemoteChangesSyncDeletesRows() async throws {
    let (backend, database) = try TestBackend.create()
    let repo = backend.accountGroups as! GRDBAccountGroupRepository

    let created = try await repo.create(
      AccountGroup(name: "Ephemeral", bucket: .investments, instrument: .defaultTestInstrument)
    )

    try await database.write { db in
      try repo.applyRemoteChangesSync(saved: [], deleted: [created.id], in: db)
    }

    let all = try await repo.fetchAll()
    #expect(!all.contains(where: { $0.id == created.id }))
  }

  @Test
  func setEncodedSystemFieldsSyncPersists() async throws {
    let (backend, database) = try TestBackend.create()
    let repo = backend.accountGroups as! GRDBAccountGroupRepository

    let created = try await repo.create(
      AccountGroup(name: "Stamped", bucket: .investments, instrument: .defaultTestInstrument)
    )

    let payload = Data([0x01, 0x02, 0x03])
    let updated = try await database.write { db in
      try repo.setEncodedSystemFieldsSync(id: created.id, data: payload)
    }
    #expect(updated == true)

    try await database.read { db in
      let row = try AccountGroupRow
        .filter(AccountGroupRow.Columns.id == created.id)
        .fetchOne(db)
      #expect(row?.encodedSystemFields == payload)
    }
  }

  @Test
  func clearAllSystemFieldsSyncNullsBlobs() async throws {
    let (backend, database) = try TestBackend.create()
    let repo = backend.accountGroups as! GRDBAccountGroupRepository

    let created = try await repo.create(
      AccountGroup(name: "Cleared", bucket: .investments, instrument: .defaultTestInstrument)
    )
    _ = try await database.write { db in
      try repo.setEncodedSystemFieldsSync(id: created.id, data: Data([0x99]))
    }

    try await database.write { db in
      try repo.clearAllSystemFieldsSync()
    }

    try await database.read { db in
      let row = try AccountGroupRow
        .filter(AccountGroupRow.Columns.id == created.id)
        .fetchOne(db)
      #expect(row?.encodedSystemFields == nil)
    }
  }

  @Test
  func deleteAllSyncRemovesEveryRow() async throws {
    let (backend, _) = try TestBackend.create()
    let repo = backend.accountGroups as! GRDBAccountGroupRepository

    _ = try await repo.create(
      AccountGroup(name: "A", bucket: .investments, instrument: .defaultTestInstrument)
    )
    _ = try await repo.create(
      AccountGroup(name: "B", bucket: .current, instrument: .defaultTestInstrument)
    )

    try repo.deleteAllSync()

    let all = try await repo.fetchAll()
    #expect(all.isEmpty)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
just test AccountGroupSyncHelpersTests 2>&1 | tee .agent-tmp/test-pg7-1.txt
```

Expected: build failure — methods don't exist on the repository.

- [ ] **Step 3: Add the sync helpers**

Create `Backends/GRDB/Repositories/GRDBAccountGroupRepository+Sync.swift`:

```swift
// Backends/GRDB/Repositories/GRDBAccountGroupRepository+Sync.swift

import Foundation
import GRDB

extension GRDBAccountGroupRepository {
  /// Single entry point used by `ProfileDataSyncHandler` to apply a
  /// remote-change batch from CKSyncEngine. Saves and deletes are
  /// processed in one transaction so the `databaseDidCommit` hook
  /// fires once per fetched batch (see `applyRemoteChanges` doc-comment
  /// for the issue #872 rationale). Mirrors the
  /// `GRDBTransferSuggestionRepository.applyRemoteChangesSync` shape.
  func applyRemoteChangesSync(
    saved rows: [AccountGroupRow], deleted ids: [UUID], in database: Database
  ) throws {
    for var row in rows {
      try row.save(database)
    }
    if !ids.isEmpty {
      _ = try AccountGroupRow
        .filter(ids.contains(AccountGroupRow.Columns.id))
        .deleteAll(database)
    }
  }

  /// Persists the CKRecord system-fields blob for a single group.
  /// Used by the upload path after CKSyncEngine returns the post-save
  /// CKRecord with its updated change tag.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      let updated =
        try AccountGroupRow
        .filter(AccountGroupRow.Columns.id == id)
        .updateAll(
          database,
          [AccountGroupRow.Columns.encodedSystemFields.set(to: data)])
      return updated > 0
    }
  }

  /// Batch counterpart used during multi-row uploads. Single
  /// transaction → single `databaseDidCommit` fire (issue #865).
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)]
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    return try database.write { database in
      var updatedCount = 0
      for (id, data) in updates {
        updatedCount +=
          try AccountGroupRow
          .filter(AccountGroupRow.Columns.id == id)
          .updateAll(
            database,
            [AccountGroupRow.Columns.encodedSystemFields.set(to: data)])
      }
      return updatedCount
    }
  }

  /// Nulls every system-fields blob. Used by the "reset and refetch"
  /// recovery path when the user toggles iCloud accounts or chooses
  /// "Reset Sync" in Settings.
  func clearAllSystemFieldsSync() throws {
    _ = try database.write { database in
      try AccountGroupRow.updateAll(
        database,
        [AccountGroupRow.Columns.encodedSystemFields.set(to: nil as Data?)])
    }
  }

  /// Deletes every account-group row. Used by sign-out / profile-switch
  /// flows; safe to call from a recovery path because no FK references
  /// `account_group` from another table (the `account.group_id` column
  /// has no FK — see `ProfileSchema+AccountGroups.swift`).
  func deleteAllSync() throws {
    _ = try database.write { database in
      try AccountGroupRow.deleteAll(database)
    }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
just test AccountGroupSyncHelpersTests 2>&1 | tee .agent-tmp/test-pg7-1.txt
grep -i 'failed\|error:' .agent-tmp/test-pg7-1.txt || echo "OK"
```

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync add \
  Backends/GRDB/Repositories/GRDBAccountGroupRepository+Sync.swift \
  MoolahTests/Backends/GRDB/AccountGroupSyncHelpersTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync commit -m "feat(grdb): sync helpers on GRDBAccountGroupRepository

applyRemoteChangesSync (single-tx saves+deletes),
setEncodedSystemFieldsSync (single + batch), clearAllSystemFieldsSync,
deleteAllSync. Same shape as GRDBTransferSuggestionRepository — the
reference-data dispatch shape used by ProfileDataSyncHandler."
```

---

## Task 2: `CloudKitRecordConvertible` conformance on `AccountGroupRow`

**Files:**
- Create: `Backends/GRDB/Records/AccountGroupRow+CloudKit.swift`
- Modify: `MoolahTests/Backends/GRDB/AccountGroupsMigrationTests.swift` (add a round-trip test suite)

Mirror `EarmarkRow`'s CloudKit extension. Read it first:

```bash
grep -l "EarmarkRow.*CloudKitRecordConvertible\|extension EarmarkRow.*toCKRecord" \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync/Backends/GRDB/Records/*.swift
```

If the CloudKit conformance lives in a separate `+CloudKit.swift` file, mirror that filename. If it lives in `+Mapping.swift`, add to the mapping file instead. The file structure isn't strict — pick whichever home keeps the new code adjacent to peer code.

- [ ] **Step 1: Write the failing round-trip tests**

Append a new suite to `MoolahTests/Backends/GRDB/AccountGroupsMigrationTests.swift`:

```swift
@Suite("AccountGroupRow CKRecord round-trip")
struct AccountGroupRowCKRecordTests {
  private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test
  func toCKRecordCarriesAllFields() {
    let group = AccountGroup(
      name: "Trust Fund Crypto",
      bucket: .investments,
      instrument: .AUD,
      position: 3
    )
    let row = AccountGroupRow(domain: group)
    let ckRecord = row.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "AccountGroupRecord")
    #expect((ckRecord["name"] as? String) == "Trust Fund Crypto")
    #expect((ckRecord["bucket"] as? String) == "investments")
    #expect((ckRecord["instrumentId"] as? String) == "AUD")
    #expect((ckRecord["position"] as? Int) == 3)
  }

  @Test
  func fieldValuesReconstructsRowFromCKRecord() {
    let id = UUID()
    let recordID = CKRecord.ID(
      recordName: AccountGroupRow.recordName(for: id), zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "AccountGroupRecord", recordID: recordID)
    ckRecord["name"] = "Personal Crypto" as CKRecordValue
    ckRecord["bucket"] = "investments" as CKRecordValue
    ckRecord["instrumentId"] = "AUD" as CKRecordValue
    ckRecord["position"] = 0 as CKRecordValue

    let row = AccountGroupRow.fieldValues(from: ckRecord)
    #expect(row != nil)
    #expect(row?.id == id)
    #expect(row?.name == "Personal Crypto")
    #expect(row?.bucket == "investments")
    #expect(row?.instrumentId == "AUD")
    #expect(row?.position == 0)
  }

  @Test
  func fieldValuesReturnsNilForRecordIDWithoutUUID() {
    let recordID = CKRecord.ID(recordName: "NotAUUID", zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "AccountGroupRecord", recordID: recordID)
    ckRecord["name"] = "X" as CKRecordValue
    ckRecord["bucket"] = "current" as CKRecordValue
    ckRecord["instrumentId"] = "AUD" as CKRecordValue
    ckRecord["position"] = 0 as CKRecordValue

    let row = AccountGroupRow.fieldValues(from: ckRecord)
    #expect(row == nil, "Malformed recordName should produce nil — caller logs and skips")
  }

  @Test
  func fullDomainCKRecordRoundTrip() {
    let original = AccountGroup(
      id: UUID(),
      name: "Joint Accounts",
      bucket: .current,
      instrument: .USD,
      position: 7
    )
    let outboundRow = AccountGroupRow(domain: original)
    let ckRecord = outboundRow.toCKRecord(in: zoneID)
    let inboundRow = AccountGroupRow.fieldValues(from: ckRecord)
    let restored = inboundRow?.toDomain(defaultInstrument: .AUD)

    #expect(restored?.id == original.id)
    #expect(restored?.name == original.name)
    #expect(restored?.bucket == original.bucket)
    #expect(restored?.instrument == original.instrument)
    #expect(restored?.position == original.position)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
just test AccountGroupRowCKRecordTests 2>&1 | tee .agent-tmp/test-pg7-2.txt
```

Expected: build failure — `toCKRecord` and `fieldValues` don't exist.

- [ ] **Step 3: Add the CloudKit extension**

Create `Backends/GRDB/Records/AccountGroupRow+CloudKit.swift`:

```swift
// Backends/GRDB/Records/AccountGroupRow+CloudKit.swift

import CloudKit
import Foundation

extension AccountGroupRow: CloudKitRecordConvertible {
  /// Frozen wire `recordType`. Declared in `+Mapping.swift`; re-stated
  /// here as the protocol requirement.
  // `static let recordType = "AccountGroupRecord"` is already on
  // `AccountGroupRow+Mapping.swift`; do not redeclare.

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    let ckRecord: CKRecord
    if let encodedSystemFields,
       let restored = CKRecord.fromEncodedSystemFields(encodedSystemFields) {
      ckRecord = restored
    } else {
      ckRecord = CKRecord(recordType: Self.recordType, recordID: recordID)
    }
    ckRecord["name"] = name as CKRecordValue
    ckRecord["bucket"] = bucket as CKRecordValue
    ckRecord["instrumentId"] = instrumentId as CKRecordValue
    ckRecord["position"] = position as CKRecordValue
    return ckRecord
  }

  static func fieldValues(from ckRecord: CKRecord) -> AccountGroupRow? {
    // Mirror the EarmarkRow / TransferSuggestionRow pattern: recordName
    // must contain a valid UUID after the "RecordType|" prefix, else
    // the caller logs and skips. See `CloudKitRecordConvertible` proto
    // doc for why malformed records return nil rather than a phantom
    // row with a fresh random id.
    guard let uuid = ckRecord.recordID.uuid else { return nil }
    let name = ckRecord["name"] as? String ?? ""
    let bucket = ckRecord["bucket"] as? String ?? AccountBucket.current.rawValue
    let instrumentId = ckRecord["instrumentId"] as? String ?? "AUD"
    let position = ckRecord["position"] as? Int ?? 0

    return AccountGroupRow(
      id: uuid,
      recordName: AccountGroupRow.recordName(for: uuid),
      name: name,
      bucket: bucket,
      instrumentId: instrumentId,
      position: position,
      encodedSystemFields: ckRecord.encodedSystemFields
    )
  }
}
```

The `ckRecord.recordID.uuid` extension is defined elsewhere in `Backends/CloudKit/Sync/CKRecordIDRecordName.swift`; verify it returns `UUID?` parsed from the trailing `|<uuid>` segment of `recordName`. If the extension's name differs, adjust.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
just test AccountGroupRowCKRecordTests 2>&1 | tee .agent-tmp/test-pg7-2.txt
grep -i 'failed\|error:' .agent-tmp/test-pg7-2.txt || echo "OK"
```

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync add \
  Backends/GRDB/Records/AccountGroupRow+CloudKit.swift \
  MoolahTests/Backends/GRDB/AccountGroupsMigrationTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync commit -m "feat(cloudkit): CloudKitRecordConvertible on AccountGroupRow

toCKRecord preserves encoded system fields when present (avoids
.serverRecordChanged on subsequent uploads). fieldValues returns nil
for recordIDs without a parseable UUID — caller logs and skips."
```

---

## Task 3: Register `AccountGroupRow` in `CloudKitRecordConvertible.swift`

**Files:**
- Modify: `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift`

Three registration sites in this file:

- [ ] **Step 1: Add to `IdentifiableRecord` conformance list**

Around line 35 (after `extension EarmarkRow: IdentifiableRecord {}`):

```swift
extension AccountGroupRow: IdentifiableRecord {}
```

Keep alphabetical or grouped-by-topic ordering — `AccountGroupRow` sits naturally after `AccountRow` (line 30):

```swift
extension AccountRow: IdentifiableRecord {}
extension AccountGroupRow: IdentifiableRecord {}
extension TransactionRow: IdentifiableRecord {}
…
```

- [ ] **Step 2: Add to `ValueTypeSystemFieldsReadable` conformance list**

Around line 59 (after `extension EarmarkRow: ValueTypeSystemFieldsReadable {}`). Insert after `AccountRow`:

```swift
extension AccountRow: ValueTypeSystemFieldsReadable {}
extension AccountGroupRow: ValueTypeSystemFieldsReadable {}
extension CategoryRow: ValueTypeSystemFieldsReadable {}
…
```

- [ ] **Step 3: Register in `RecordTypeRegistry.allTypes`**

Around line 97-107, insert after `AccountRow.recordType`:

```swift
    AccountRow.recordType: AccountRow.self,
    AccountGroupRow.recordType: AccountGroupRow.self,
    TransactionRow.recordType: TransactionRow.self,
    …
```

- [ ] **Step 4: Build to confirm registration compiles**

```bash
just build-mac 2>&1 | tee .agent-tmp/test-pg7-3.txt
grep -E 'error:' .agent-tmp/test-pg7-3.txt || echo "OK"
```

Expected: clean build. The registry entry requires the type to conform to `CloudKitRecordConvertible`, which Task 2 just added.

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync add \
  Backends/CloudKit/Sync/CloudKitRecordConvertible.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync commit -m "feat(cloudkit): register AccountGroupRow in dispatch tables

IdentifiableRecord + ValueTypeSystemFieldsReadable conformances +
RecordTypeRegistry entry. The registry entry is what lets the apply-
batch dispatch route incoming AccountGroupRecord CKRecords to a
typed handler."
```

---

## Task 4: Wire `AccountGroupRow` into `ProfileDataSyncHandler` dispatch tables

**Files (all under `Backends/CloudKit/Sync/`):**
- Modify: `ProfileDataSyncHandler+GRDBSaveHelpers.swift`
- Modify: `ProfileDataSyncHandler+GRDBDispatch.swift`
- Modify: `ProfileDataSyncHandler+RecordLookup.swift`
- Modify: `ProfileDataSyncHandler+SystemFields.swift`
- Modify: `ProfileDataSyncHandler+QueueAndDelete.swift`

Five files, each gets a one-or-two-case-statement addition mirroring `TransferSuggestionRow`. Bite-sized; bundled as one task with named sub-steps so all five land in a single commit.

- [ ] **Step 1: `+GRDBSaveHelpers.swift` — add `applyBatchSaveAccountGroup`**

Around line 110 (right after `applyBatchSaveTransferSuggestion` ends, before `applyBatchSaveEarmark`), insert:

```swift
  nonisolated func applyBatchSaveAccountGroup(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[AccountGroup]")
    let rows = mapRows(
      context: context,
      fieldValues: AccountGroupRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields)
    try writeRemote(site: context.site) {
      try grdbRepositories.accountGroups.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }
```

`grdbRepositories.accountGroups` requires `ProfileGRDBRepositories` to expose the new repo — that wiring was done in Phase 3 Task 8. If `grdbRepositories.accountGroups` doesn't exist at build time, return to Phase 3 — the field is a Phase 3 deliverable, not Phase 7.

- [ ] **Step 2: `+GRDBDispatch.swift` — add to `referenceSaveHandler` and `referenceDeleter`**

(a) Find the `referenceSaveHandler` switch (around line 50 — search for `case TransferSuggestionRow.recordType` followed by `applyBatchSaveTransferSuggestion`). Insert before the `default:` arm:

```swift
    case AccountGroupRow.recordType:
      return { handler in
        handler.applyBatchSaveAccountGroup(ckRecords:systemFields:in:)
      }
```

(b) Find the `referenceDeleter` switch (around line 144 — search for `case TransferSuggestionRow.recordType` inside `referenceDeleter`). Insert before the `default:` arm:

```swift
    case AccountGroupRow.recordType:
      return { handler, ids, database in
        try handler.writeRemote(site: "applyGRDBBatchDeletion[AccountGroup]") {
          try handler.grdbRepositories.accountGroups.applyRemoteChangesSync(
            saved: [], deleted: ids, in: database)
        }
      }
```

- [ ] **Step 3: `+RecordLookup.swift` — add fetch + apply cases**

(a) Find the case dispatch around line 132 (the `fetchEarmarkRow` site). Insert:

```swift
    case AccountGroupRow.recordType:
      return fetchAccountGroupRow(id: uuid).map { row in
        (row, row.encodedSystemFields)
      }
```

(b) Find the second dispatch around line 231 (the `EarmarkRow.recordType` case in the per-record-type "extract id" path). Insert an `AccountGroupRow.recordType` case mirroring `EarmarkRow`.

(c) Add a `fetchAccountGroupRow` helper at the bottom of the file (around line 307 where `fetchEarmarkRow` lives):

```swift
  private func fetchAccountGroupRow(id: UUID) -> AccountGroupRow? {
    try? grdbRepositories.databaseReader.read { db in
      try AccountGroupRow
        .filter(AccountGroupRow.Columns.id == id)
        .fetchOne(db)
    }
  }
```

Adjust to the exact pattern `fetchEarmarkRow` uses (the project's repo / reader access might differ slightly).

- [ ] **Step 4: `+SystemFields.swift` — add to clearAll table + per-record dispatch**

(a) Around line 29 (the table-of-tuples passed to a batch clear), insert:

```swift
      (AccountGroupRow.recordType, grdbRepositories.accountGroups.clearAllSystemFieldsSync),
```

(b) Around line 255 (the per-record-type dispatch switch), insert:

```swift
    case AccountGroupRow.recordType:
      try grdbRepositories.accountGroups.setEncodedSystemFieldsBatchSync(updates)
```

- [ ] **Step 5: `+QueueAndDelete.swift` — add to collect + deleteAll**

(a) Around line 122 (the `collectAllGRDBUUIDs` calls):

```swift
    collectAllGRDBUUIDs(ids: ids, recordType: AccountGroupRow.recordType, into: &recordIDs)
```

(b) Around line 235 (the table-of-tuples for `deleteAllSync`):

```swift
      (AccountGroupRow.recordType, { try self.grdbRepositories.accountGroups.deleteAllSync() }),
```

- [ ] **Step 6: Build and run the unit test suite**

```bash
just build-mac 2>&1 | tee .agent-tmp/test-pg7-4-build.txt
grep -E 'error:' .agent-tmp/test-pg7-4-build.txt || echo "OK"
just test 2>&1 | tee .agent-tmp/test-pg7-4-tests.txt
grep -i 'failed\|error:' .agent-tmp/test-pg7-4-tests.txt || echo "OK"
```

Expected: clean build, all tests pass. No new unit tests needed for this task — the dispatch glue is exercised by the integration test in Task 5.

- [ ] **Step 7: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync add \
  Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBSaveHelpers.swift \
  Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBDispatch.swift \
  Backends/CloudKit/Sync/ProfileDataSyncHandler+RecordLookup.swift \
  Backends/CloudKit/Sync/ProfileDataSyncHandler+SystemFields.swift \
  Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync commit -m "feat(sync): wire AccountGroupRow into ProfileDataSyncHandler

Five dispatch sites, all mirroring TransferSuggestionRow:
- +GRDBSaveHelpers: applyBatchSaveAccountGroup
- +GRDBDispatch: referenceSaveHandler + referenceDeleter cases
- +RecordLookup: fetchAccountGroupRow + dispatch cases
- +SystemFields: clearAll entry + setEncodedSystemFieldsBatchSync
- +QueueAndDelete: collect-uuids + deleteAllSync"
```

---

## Task 5: End-to-end sync integration test

**Files:**
- Create: `MoolahTests/Backends/CloudKit/AccountGroupSyncIntegrationTests.swift`

The goal: drive `ProfileDataSyncHandler.applyRemoteChanges` with synthetic CKRecords representing inserts and deletes of `AccountGroupRecord`, and verify the local GRDB state matches.

Mirror the existing `TransferSuggestion` integration test if one exists. Search:

```bash
grep -rln "applyRemoteChanges.*AccountRecord\|applyRemoteChanges.*EarmarkRecord\|TransferSuggestion.*applyRemoteChanges" \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync/MoolahTests 2>/dev/null
```

If a `*SyncIntegrationTests.swift` pattern exists, mirror it. If not, the following minimal shape exercises the dispatch end-to-end:

- [ ] **Step 1: Write the integration test**

```swift
@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("AccountGroup sync integration")
@MainActor
struct AccountGroupSyncIntegrationTests {
  @Test
  func applyRemoteChangesInsertsThenDeletesAccountGroup() async throws {
    // Stand up the full handler stack on a TestBackend's in-memory DB.
    // The exact factory differs per existing integration test — copy
    // the construction from the EarmarkRecord integration test if one
    // exists, otherwise use whatever exists for AccountRecord.
    let (backend, _) = try TestBackend.create()
    let handler = try await TestProfileDataSyncHandler.make(for: backend)

    let zoneID = CKRecordZone.ID(zoneName: "Test", ownerName: CKCurrentUserDefaultName)
    let groupId = UUID()
    let recordID = CKRecord.ID(
      recordName: AccountGroupRow.recordName(for: groupId), zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "AccountGroupRecord", recordID: recordID)
    ckRecord["name"] = "Trust Fund Crypto" as CKRecordValue
    ckRecord["bucket"] = "investments" as CKRecordValue
    ckRecord["instrumentId"] = "AUD" as CKRecordValue
    ckRecord["position"] = 0 as CKRecordValue

    // Apply incoming save
    _ = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    var fetched = try await backend.accountGroups.fetchAll()
    #expect(fetched.contains(where: { $0.id == groupId && $0.name == "Trust Fund Crypto" }))

    // Apply incoming delete
    _ = handler.applyRemoteChanges(
      saved: [], deleted: [(recordID, "AccountGroupRecord")])

    fetched = try await backend.accountGroups.fetchAll()
    #expect(!fetched.contains(where: { $0.id == groupId }))
  }
}
```

If `TestProfileDataSyncHandler.make(for:)` doesn't exist as a test helper, look for whatever factory other integration tests use (e.g. a `withSyncHandler` block, or direct construction). The semantic claim is what matters: an incoming save of an AccountGroup CKRecord ends up as a domain `AccountGroup`; an incoming delete removes it.

If you can't find a working integration-test scaffold for the sync handler, leave a placeholder test annotated with the construction call needed and flag it in the PR description as a known follow-up. Don't ship broken integration tests.

- [ ] **Step 2: Run the test**

```bash
just test AccountGroupSyncIntegrationTests 2>&1 | tee .agent-tmp/test-pg7-5.txt
grep -i 'failed\|error:' .agent-tmp/test-pg7-5.txt || echo "OK"
```

- [ ] **Step 3: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync add \
  MoolahTests/Backends/CloudKit/AccountGroupSyncIntegrationTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync commit -m "test(sync): end-to-end AccountGroup save/delete via ProfileDataSyncHandler

Synthetic CKRecord through applyRemoteChanges → AccountGroupRepository
fetch confirms the dispatch routes correctly. Mirrors the
TransferSuggestion integration test (if present) or AccountRecord's."
```

---

## Task 6: Manual cross-device verification (out-of-band; not blocking the PR)

This is **not** a code task — it's the smoke test the user will want to run before flipping the feature on for daily use. Document the procedure in the PR description so the reviewer knows the manual gate exists.

Suggested procedure:
1. Run the build on Device A; create two groups; assign two accounts to each.
2. Wait for sync to settle (CKSyncEngine should upload within a minute).
3. Run the same build on Device B (or another simulator with the same iCloud account); confirm both groups appear in the sidebar with the same members.
4. On Device A, rename one group + add a new member.
5. Confirm Device B reflects both changes within a sync cycle.
6. On Device A, delete one group.
7. Confirm Device B drops the group and the former member accounts render as standalone (because their `groupId` resolves to nil — no FK cascade).

The PR description should reference this checklist; the PR doesn't block on the user running it.

---

## Task 7: Final verify + open PR

- [ ] **Step 1: Full test suite, both targets**

```bash
just test 2>&1 | tee .agent-tmp/test-pg7-final.txt
grep -i 'failed\|error:' .agent-tmp/test-pg7-final.txt || echo "OK"
```

- [ ] **Step 2: Format-check**

```bash
just format-check
```

- [ ] **Step 3: Push and open PR**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync \
    push origin account-group-sync:account-group-sync

cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync && \
gh pr create --base main --head account-group-sync \
  --title "feat(sync): AccountGroup CloudKit sync wiring (Phase 7)" \
  --body "$(cat <<'EOF'
## Summary

Phase 7 of the Account Groups feature. Takes `AccountGroup` from local-only (Phase 3) to fully cross-device synced.

- `CloudKitRecordConvertible` conformance on `AccountGroupRow` (`toCKRecord` + `fieldValues`) — preserves encoded system fields on round-trip; returns nil for recordIDs without a parseable UUID.
- Sync helpers on `GRDBAccountGroupRepository`: `applyRemoteChangesSync`, `setEncodedSystemFieldsSync` (single + batch), `clearAllSystemFieldsSync`, `deleteAllSync` — same shape as `GRDBTransferSuggestionRepository`.
- Registration in `RecordTypeRegistry.allTypes`, `IdentifiableRecord`, and `ValueTypeSystemFieldsReadable`.
- Dispatch wired into all five `ProfileDataSyncHandler` extension files (`+GRDBSaveHelpers`, `+GRDBDispatch`, `+RecordLookup`, `+SystemFields`, `+QueueAndDelete`).
- Unit tests for CKRecord ↔ row round-trip; integration test driving `applyRemoteChanges` end-to-end.

## Why

Without this, `AccountGroup` writes from Phase 3's build stay local and never appear on other devices. The CKDB schema for `AccountGroupRecord` is already declared (Phase 3), so this PR just plugs the new record type into the dispatch tables that the sync handler already uses.

## Phase ordering

Depends on **Phase 3** (`AccountGroupRow`, `GRDBAccountGroupRepository`, `Account.groupId` round-trip, CKDB schema). Independent of Phases 2 / 4 / 5 / 6 / 8 — UI work can land in parallel.

## Manual cross-device verification

Recommended smoke test before flipping the feature on for daily use (does **not** block this PR):

1. Device A: create two groups, assign members.
2. Wait for sync.
3. Device B: confirm both groups appear with the same members.
4. Device A: rename a group + add a member.
5. Device B: confirm changes within a sync cycle.
6. Device A: delete a group.
7. Device B: confirm group disappears and former members render standalone (no FK cascade — `groupId` resolves to nil).

## Test plan

- [x] `just test AccountGroupSyncHelpersTests AccountGroupRowCKRecordTests AccountGroupSyncIntegrationTests`
- [x] `just test` — full suite green on iOS + macOS
- [x] `just format-check` — clean
- [ ] Manual cross-device verification (see above)

## Out of scope

- Per-member sync-status aggregation surface on `AccountGroup` (Phase 5 — `AccountViewContext` + detail-view header).
- Local-only `isExpandedInSidebar` persistence (Phase 8).

EOF
)"
```

- [ ] **Step 4: Enable auto-merge**

```bash
./.claude/skills/landing-prs/scripts/land-pr.sh <pr-number>
```

(Or `gh pr merge <pr-number> --auto`.) If this PR is stacked on Phase 3's branch, the script will background a watcher that retargets once Phase 3 merges.

---

## Acceptance criteria for Phase 7

- `AccountGroupRow` conforms to `CloudKitRecordConvertible` with toCKRecord + fieldValues; round-trip tests pass.
- `GRDBAccountGroupRepository+Sync.swift` provides `applyRemoteChangesSync`, `setEncodedSystemFieldsSync` (single + batch), `clearAllSystemFieldsSync`, `deleteAllSync`.
- `RecordTypeRegistry.allTypes` contains an `AccountGroupRow` entry; `IdentifiableRecord` + `ValueTypeSystemFieldsReadable` conformances added.
- All five `ProfileDataSyncHandler` extension files dispatch `AccountGroupRecord`.
- Integration test exercises `applyRemoteChanges` for insert + delete and verifies local state.
- Full `just test` passes on iOS + macOS.
- `just format-check` clean.
- PR opened against `main` and auto-merge enabled.
- PR description includes the manual cross-device smoke-test procedure.

---

## What's NOT in this phase

- **Phase 4** — sidebar rendering / drop semantics / creation flows.
- **Phase 5** — `AccountViewContext`; this includes the aggregated `AggregatedSyncStatus` surface, which is read-side computation over per-member sync states (no new sync wiring).
- **Phase 6** — description rendering for in-group transactions.
- **Phase 8** — local-only `account_group_ui` sidecar table for `isExpandedInSidebar` persistence.

---

## Reviewer cheat-sheet

For each dispatch site, the peer line (TransferSuggestion equivalent) is one `grep` away:

```bash
grep -rn "TransferSuggestionRow" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-sync/Backends/CloudKit/Sync \
  --include='*.swift' | head -20
```

The reviewer can audit Phase 7 by walking each `TransferSuggestionRow` line in `Backends/CloudKit/Sync/` and verifying an `AccountGroupRow` peer line landed adjacent in this PR.
