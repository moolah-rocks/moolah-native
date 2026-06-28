# CKSyncEngine Sync Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)

---

## 1. Architecture Overview

A single `SyncCoordinator` owns one `CKSyncEngine` instance and routes events to zone-specific handlers:

1. **ProfileIndexSyncHandler** -- handles `ProfileRecord` metadata for the `profile-index` zone
2. **ProfileDataSyncHandler** (one per active profile) -- handles per-profile data for `profile-{profileId}` zones

The coordinator receives all `CKSyncEngine` delegate events and dispatches them to the appropriate handler based on zone ID. Repository mutation methods explicitly call sync closures (`onRecordChanged`/`onRecordDeleted`) to queue changes for upload, ensuring only user-initiated mutations trigger sync — not derived-data updates like cached balance recomputation.

**Key files:**
- `Backends/CloudKit/Sync/SyncCoordinator.swift` -- single CKSyncEngine owner; routes events by zone ID
- `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift` -- per-profile zone handler
- `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift` -- profile index zone handler
- `Backends/GRDB/Records/*Row+Mapping.swift` and `Backends/GRDB/Sync/*Row+CloudKit.swift` -- CKRecord <-> GRDB row bidirectional mapping
- `Backends/CloudKit/Sync/LegacyZoneCleanup.swift` -- one-time cleanup of old automatic sync zone
- `Backends/GRDB/Repositories/GRDB*Repository.swift` -- repositories with sync closures

**Key Sources:**
- [WWDC23: Sync to iCloud with CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/)
- [Apple's sample-cloudkit-sync-engine](https://github.com/apple/sample-cloudkit-sync-engine)
- [CKSyncEngine Apple Documentation](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)

---

## 2. Cross-Handler Review Rule

Any sync-related change must be reviewed against `SyncCoordinator`, `ProfileDataSyncHandler`, and `ProfileIndexSyncHandler` and applied wherever applicable. The handlers share the same patterns (system fields caching, error recovery, account change handling, zone deletion handling) but are maintained separately. When fixing a bug or adding a feature to one handler, always check whether the same change is needed in the other.

---

## 3. Core Principles

### Data Loss Is Non-Negotiable

Not losing user data is an absolute requirement, not a trade-off. Never frame a data-loss or data-corruption fix as "overkill", and never accept a "tiny, very unlikely" residual race — a rare race *will* happen in production and is evidence of an incorrect design, not an acceptable cost. Design for *uniform* correctness: every code path closed the same rigorous way, with no "narrow window remains" caveat in the self-review. If part of a design can only be made "almost" safe (e.g. a dirty-check and its write that aren't in one transaction), treat that as a sign the design is wrong and fix the design, rather than documenting-and-deferring the gap.

### Let CKSyncEngine Drive Scheduling

CKSyncEngine manages its own scheduling, batching, and retry logic. Your job is to respond to events and provide records when asked.

```swift
// CORRECT: Add to pending queue; engine decides when to send
syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

// WRONG: Manually triggering sync inside a delegate callback
func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    // Never do this -- causes infinite loops
    try await syncEngine.sendChanges()
    try await syncEngine.fetchChanges()
}
```

### One Engine Per Database

Never run multiple CKSyncEngine instances against the same CloudKit database. They interfere with each other's change tokens and event routing.

This project uses a single `CKSyncEngine` instance (owned by `SyncCoordinator`) that manages all zones. Zone-specific logic is delegated to `ProfileDataSyncHandler` and `ProfileIndexSyncHandler`, which handle non-overlapping zones.

### Initialize Early

Create and start CKSyncEngine as early as possible in the app lifecycle. The initializer is synchronous and immediately begins processing pending changes from the saved state serialization.

### Per-profile schema does not enforce FKs

- **The contract.** The per-profile `data.sqlite` schema declares no foreign keys. CKSyncEngine has no parent-before-child guarantee within a fetch session or across sessions; an FK-enforced child insert can fault the entire write transaction and trap the sync coordinator in an infinite re-fetch loop. See `Backends/GRDB/ProfileSchema+DropForeignKeys.swift` and the rc.12 incident write-up.
- **Cascade replication.** Sync delete paths in repositories must replicate the cascade / null-out semantics that the v3 FKs used to provide:
  - `GRDBAccountRepository.applyRemoteChangesSync` deletes `investment_value` rows for the account and nulls `transaction_leg.account_id` references.
  - `GRDBTransactionRepository.applyRemoteChangesSync` (and the domain `delete(id:)`) deletes `transaction_leg` rows for the transaction.
  - `GRDBEarmarkRepository.applyRemoteChangesSync` deletes `earmark_budget_item` rows and nulls `transaction_leg.earmark_id`.
  - `GRDBCategoryRepository.applyRemoteChangesSync` (or its `+Sync.swift`) nulls `transaction_leg.category_id`, deletes `earmark_budget_item` rows referencing the deleted category, and orphans child categories (`parent_id := NULL`).
- **Zombie rows are accepted.** A child whose parent CKRecord is deleted server-side or never delivered remains as an orphan row. This is intentional: the alternative (FK enforcement) traps the entire sync stream on a single delta. Repository read paths filter through known parents, so orphans do not surface in computed views; they occupy storage. Do not "fix" zombies by reintroducing FKs.

---

## 4. Rules

### Rule 1: Filter Notifications by Entity Type

**Bug found:** `NSManagedObjectContextDidSave` with `object: nil` catches saves from ALL ModelContainers. Without entity filtering, per-profile data saves (thousands of records) get queued as phantom pending changes in the ProfileIndexSyncEngine, bloating the sync state file and preventing real records from syncing.

**Rule:** Always filter notification objects by entity name before extracting IDs.

```swift
// CORRECT: Filter to only relevant entities
let inserted = (notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>)?
    .filter { $0.entity.name == "ProfileRecord" }

// WRONG: Processes ALL entities from ALL containers
let inserted = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>
```

### Rule 2: Only Queue Sync Changes From Repository Mutations

**Bug found (historical):** A notification-based `ChangeTracker` observed all `NSManagedObjectContextDidSave` events and queued every touched record for upload. It could not distinguish user edits from derived-data updates (e.g., `recomputeAllBalances` writing `cachedBalance`), causing infinite re-upload loops.

**Rule:** Sync changes are queued explicitly from repository mutation methods via `onRecordChanged`/`onRecordDeleted` closures, not from save notifications. This ensures only user-initiated mutations trigger uploads. Derived-data writes, balance cache updates, and remote change application never trigger uploads because they don't go through the repository mutation path.

```swift
// In a GRDB repository mutation method:
func create(_ account: Account) async throws -> Account {
    try await database.write { db in
        try AccountRow(domain: account).insert(db)
    }
    onRecordChanged(AccountRow.recordType, account.id)  // Explicitly queue for sync
    return account
}

// Derived-data updates do NOT call onRecordChanged:
func recomputeAllBalances() async throws {
    try await database.write { db in
        // ... update cachedBalance columns ...
        // No sync queueing — cachedBalance is local-only.
    }
}
```

**Do NOT use `NSManagedObjectContextDidSave` notifications** to drive sync change tracking. This pattern was removed because it is fundamentally unable to distinguish syncable changes from derived-data updates.

### Rule 3: Create Zones Proactively on Engine Start

**Bug found:** CKSyncEngine does NOT automatically create zones when sending records. If the zone doesn't exist, sends fail with inconsistent error codes: `.zoneNotFound` (26), `.limitExceeded` (27), `.userDeletedZone` (28), or `.invalidArguments` (12) depending on context. Reactive error handling is unreliable because:
1. Error codes vary unpredictably
2. When an entire batch fails, CKSyncEngine may stop retrying
3. Creating the zone after failure requires re-queuing all failed records

**Rule:** Create the zone proactively in `start()` using `ensureZoneExists()`, then explicitly call `sendChanges()` once the zone is confirmed. Error handlers should still handle `.zoneNotFound` and `.userDeletedZone` as a fallback.

```swift
// In start():
Task {
    await ensureZoneExists()
    if self.hasPendingChanges {
        await self.sendChanges()
    }
}

// ensureZoneExists:
func ensureZoneExists() async {
    do {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await CKContainer.default().privateCloudDatabase.save(zone)
    } catch {
        // Zone already exists or network error — engine will retry on send
    }
}
```

### Rule 4: Every Repository Mutation Must Queue Sync Changes

**Bug found (historical):** `ProfileIndexSyncEngine.addPendingSave()` existed but was never called -- profile records saved to SwiftData were never uploaded to CloudKit.

**Rule:** Every repository mutation method (create, update, delete) on a CloudKit repository must call `onRecordChanged(id)` or `onRecordDeleted(id)` after saving. When adding a new syncable record type, verify all mutation paths queue sync changes. Methods that only update derived data (caches, computed values) must NOT queue sync changes.

### Rule 4b: Queue Existing Records on First Start

**Bug found:** Migration imports data into a profile's GRDB database BEFORE the ProfileSyncEngine is created. The repository sync closures are not wired during import, so none of the imported records are queued for upload.

**Rule:** When a sync engine starts with no saved state (`loadStateSerialization()` returns nil), scan all existing records in the local store and queue them for upload. This also serves as a recovery mechanism for account sign-in, encrypted data reset, and sync state loss.

```swift
func start() {
    let hasSavedState = loadStateSerialization() != nil
    // ... create and start engine ...

    if !hasSavedState {
        queueAllExistingRecords()  // Scan and queue all local records
    }
}
```

### Rule 5: Preserve CKRecord System Fields (Change Tags)

**Rationale:** When CKSyncEngine sends a record to CloudKit, the server checks the record's change tag to detect conflicts. If you create a fresh `CKRecord` every time (without the server's change tag), CloudKit treats every upload as a new record, causing `.serverRecordChanged` conflicts on multi-device sync.

**Rule:** After a record is successfully saved to CloudKit, persist the server-returned `CKRecord`'s system fields. Use these as the base for subsequent uploads.

```swift
// CORRECT: Preserve system fields after successful send
for saved in sentChanges.savedRecords {
    // Store the server record's system fields for future uploads
    let data = saved.encodedSystemFields
    persistSystemFields(data, for: saved.recordID)
}

// When building a record for upload, start from cached system fields
func buildCKRecord(for localRecord: SomeRecord) -> CKRecord {
    let ckRecord: CKRecord
    if let cachedSystemFields = loadSystemFields(for: localRecord.id) {
        // Re-create from cached system fields (preserves change tag)
        let coder = try NSKeyedUnarchiver(forReadingFrom: cachedSystemFields)
        coder.requiresSecureCoding = true
        ckRecord = CKRecord(coder: coder)!
    } else {
        // First upload -- create fresh record
        let recordID = CKRecord.ID(recordName: localRecord.id.uuidString, zoneID: zoneID)
        ckRecord = CKRecord(recordType: SomeRecord.recordType, recordID: recordID)
    }
    // Set field values on the record
    ckRecord["name"] = localRecord.name as CKRecordValue
    return ckRecord
}
```

**Helper to encode system fields:**

```swift
extension CKRecord {
    var encodedSystemFields: Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
}
```

### Rule 6: Handle Conflict Resolution Explicitly

**Rationale:** When two devices modify the same record, the second upload receives `.serverRecordChanged`. The error's `userInfo` contains the server's current version. Ignoring this error means the second device's changes are silently lost.

**Rule:** On `.serverRecordChanged`, retrieve the server record from the error, merge or pick a winner, and re-queue the save.

```swift
// In handleSentRecordZoneChanges:
for failure in sentChanges.failedRecordSaves {
    switch failure.error.code {
    case .serverRecordChanged:
        // Server-wins strategy: accept server version, re-apply local fields if needed
        if let serverRecord = failure.error.serverRecord {
            persistSystemFields(serverRecord.encodedSystemFields, for: serverRecord.recordID)
            // Re-queue the save with updated system fields
            syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
        }
    // ... other error cases
    }
}
```

**Merge strategies (pick one per record type):**

| Strategy | When to Use | Complexity |
|----------|-------------|------------|
| **Server wins** | Single-user apps, records rarely edited concurrently | Low |
| **Last writer wins** | Simple multi-device, acceptable to lose concurrent edits | Low |
| **Field-level merge** | Multi-device, preserving all concurrent edits matters | Medium |

For this project, **server wins** is appropriate -- single-user, multi-device sync where concurrent edits to the same record are rare.

### Rule 7: Handle Zone Deletion Events Correctly

**Rationale:** Zone deletions arrive via `fetchedDatabaseChanges` with three distinct reasons that require different responses.

**Rule:** Check the deletion `reason` and respond appropriately.

```swift
func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
    for deletion in changes.deletions where deletion.zoneID == zoneID {
        switch deletion.reason {
        case .deleted:
            // Programmatic deletion. Remove local data for this zone.
            deleteLocalData()

        case .purged:
            // User cleared iCloud data via Settings. Full reset required.
            deleteLocalData()
            deleteStateSerialization()
            // Engine will re-fetch from scratch

        case .encryptedDataReset:
            // User reset encrypted data during account recovery.
            // Delete state but re-upload local data to minimize loss.
            deleteStateSerialization()
            reUploadAllLocalData()

        @unknown default:
            logger.warning("Unknown zone deletion reason")
        }
    }
}
```

### Rule 8: Handle Account Changes

**Rationale:** When the iCloud account changes, the locally cached change tokens and data belong to a different user. Continuing to sync would mix data between accounts.

**Rule:** Respond to all three account change types.

```swift
func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
    switch change.changeType {
    case .signIn:
        // Going from no account to signed in.
        // Re-upload all local data so it appears in the new account.
        reUploadAllLocalData()

    case .signOut:
        // Account removed. Delete local synced data and state.
        // The device may have changed hands.
        deleteLocalData()
        deleteStateSerialization()

    case .switchAccounts:
        // Different account on relaunch. Full reset.
        deleteLocalData()
        deleteStateSerialization()
        // Engine will fetch the new account's data on next sync

    @unknown default:
        break
    }
}
```

**Note:** Initializing CKSyncEngine without saved state always fires `.accountChange(.signIn)`, even if the user was already signed in. Guard against deleting data on this "synthetic" sign-in by checking whether it's a first launch.

### Rule 9: Handle All Critical Error Codes

**Rationale:** CKSyncEngine automatically retries transient errors (network, rate limiting, zone busy). But several error codes require your intervention -- the engine drops the failed item from its queue.

**Rule:** Handle these errors in `sentRecordZoneChanges`. Collect zone-missing failures into a single batch for zone creation, and **always re-queue on unexpected errors** (the `default` case) to prevent silent data loss:

```swift
var zoneNotFoundSaves: [CKRecord.ID] = []

for failure in sentChanges.failedRecordSaves {
    let error = failure.error
    let recordID = failure.record.recordID

    switch error.code {
    case .zoneNotFound, .userDeletedZone:
        // Collect for batch zone creation (Rule 3 fallback)
        zoneNotFoundSaves.append(recordID)

    case .serverRecordChanged:
        // Conflict -- merge and retry (see Rule 6)
        resolveConflict(failure)

    case .unknownItem:
        // Record was deleted on server. Clear cached system fields.
        clearSystemFields(for: recordID)
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

    case .quotaExceeded:
        // User's iCloud is full. Re-add to pending and notify user.
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

    case .limitExceeded:
        // Batch too large. Re-queue -- engine will try smaller batches.
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

    default:
        // Re-queue on unexpected errors. CKSyncEngine drops failed items
        // from its queue, so not re-queuing means silent data loss.
        logger.error("Save error (code=\(error.code.rawValue)): \(error) -- re-queuing")
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }
}

// Create zone once and re-queue all affected records
if !zoneNotFoundSaves.isEmpty {
    Task {
        try await createZone()
        syncEngine?.state.add(
            pendingRecordZoneChanges: zoneNotFoundSaves.map { .saveRecord($0) })
    }
}
```

**Errors CKSyncEngine handles automatically (do not retry manually):**
- `.networkFailure` / `.networkUnavailable`
- `.zoneBusy`
- `.serviceUnavailable`
- `.requestRateLimited` (respects server's `retryAfterSeconds`)
- `.notAuthenticated`
- `.operationCancelled`

### Rule 10: Use Stable Record Names from UUIDs

**Rationale:** Record names are the primary key for deduplication across devices. Using random or autogenerated names causes duplicate records.

**Rule:** Always use the local model's UUID as the CKRecord name. This is already the pattern in this project:

```swift
let recordID = CKRecord.ID(recordName: localRecord.id.uuidString, zoneID: zoneID)
```

### Rule 11: Use Strings for Enum-Like Fields in CKRecords

**Rationale:** CloudKit Production schemas are additive-only -- fields can be added but never removed or changed in type. If you store Swift enums as integers, adding a new case changes the integer mapping, breaking older app versions.

**Rule:** Store enum-like values as strings in CKRecords, and convert to/from local enums at the mapping layer.

```swift
// CORRECT: Store as string
record["type"] = "expense" as CKRecordValue

// WRONG: Store as enum raw value (Int)
record["type"] = TransactionType.expense.rawValue as CKRecordValue
```

This project already follows this pattern in the `*Row+Mapping.swift` extensions under `Backends/GRDB/Records/`.

### Rule 12: Deduplicate Record IDs in Batches

**Rationale:** CKSyncEngine's pending list does NOT deduplicate — calling `state.add(pendingRecordZoneChanges:)` multiple times with the same recordID adds multiple entries. This can happen legitimately (e.g., `queueAllExistingRecords` + a repository mutation for the same record).

**Rule:** Deduplicate in `nextRecordZoneChangeBatch` before building the batch. The implementation uses `seenSaves`/`seenDeletes` Sets to filter duplicates from CKSyncEngine's pending changes list.

```swift
// In nextRecordZoneChangeBatch:
var seenSaves = Set<CKRecord.ID>()
var seenDeletes = Set<CKRecord.ID>()
let pendingChanges = syncEngine.state.pendingRecordZoneChanges
    .filter { scope.contains($0) }
    .filter { change in
        switch change {
        case .saveRecord(let id): return seenSaves.insert(id).inserted
        case .deleteRecord(let id): return seenDeletes.insert(id).inserted
        @unknown default: return true
        }
    }
```

### Rule 13: Limit Batch Size in nextRecordZoneChangeBatch

**Bug found:** CKSyncEngine does NOT chunk batches. Whatever `nextRecordZoneChangeBatch` returns is sent as a single CloudKit operation. CloudKit rejects operations with more than ~400 records (`BatchTooLarge`, internal code 1020). When this happens, the entire batch fails and CKSyncEngine may stop retrying.

**Rule:** Return at most 400 records per call. CKSyncEngine calls `nextRecordZoneChangeBatch` repeatedly until it returns `nil`, so records are processed in chunks across multiple calls.

```swift
let batchLimit = 400
let batch = Array(pendingChanges.prefix(batchLimit))
```

### Rule 14: Queue Records in Dependency Order

**Rationale:** When a receiving device processes incoming records, foreign key references (e.g., a transaction's `accountId`) should point to records that already exist locally. If transactions arrive before accounts, the UI may show orphaned data until the referenced records arrive.

**Rule:** In `queueAllExistingRecords()`, queue records in dependency order: independent records first (categories, accounts, earmarks), then dependent records (budget items, investment values), and transactions last.

---

## 5. State Serialization

### How It Works

Every CKSyncEngine event triggers a `.stateUpdate` containing the complete `CKSyncEngine.State.Serialization`. This `Codable` type includes pending changes, change tokens, and internal engine state.

### Rules

- **Save on every `.stateUpdate` event.** Missing a save means the engine may re-process events on next launch.
- **Use atomic writes.** Prevents corruption from interrupted writes.
- **Pass saved state to `CKSyncEngine.Configuration`.** The engine resumes exactly where it left off. Without saved state, it performs a full re-fetch.
- **Delete state on account sign-out/switch.** The tokens are invalid for a different account.
- **Delete state on zone purge.** The tokens reference deleted server state.

### State File Locations

- macOS: `~/Library/Containers/rocks.moolah.app/Data/Library/Application Support/Moolah-*.syncstate`
- iOS Simulator: `~/Library/Developer/CoreSimulator/Devices/.../Application Support/Moolah-*.syncstate`

### Corruption Recovery

Phantom pending changes accumulate in `.syncstate` files and persist across launches. If sync behaves unexpectedly, check the sync state file size -- a multi-MB file for a small record set indicates corruption.

**Recovery:** Delete the `.syncstate` file. CKSyncEngine will perform a clean initial fetch on next launch.

---

## 6. Record Mapping

### CloudKitRecordConvertible Protocol

All syncable GRDB row types conform to `CloudKitRecordConvertible`:

```swift
protocol CloudKitRecordConvertible {
    static var recordType: String { get }
    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord
    // Returns nil when the CKRecord carries no valid identifier for this type.
    static func fieldValues(from ckRecord: CKRecord) -> Self?
}
```

### Mapping Rules

- Record type strings are the unprefixed `<Entity>Record` form (e.g. `AccountRecord`, `TransactionRecord`, `TransferSuggestionRecord`). The GRDB sync layer does **not** carry the legacy SwiftData `CD_` prefix; new record types follow the unprefixed convention used by every existing `*Row.recordType`.
- UUID fields are stored as strings in CKRecords: `id.uuidString as CKRecordValue`.
- Boolean fields are stored as integers: `(isHidden ? 1 : 0) as CKRecordValue`.
- Optional fields are only set if non-nil (avoids storing null values in CloudKit).
- The `fieldValues(from:)` method provides sensible defaults for missing fields (defensive against schema evolution).

### Adding a New Syncable Record Type

1. Create the GRDB row struct (a `Codable` `FetchableRecord`/`PersistableRecord`) and its table migration.
2. Add `CloudKitRecordConvertible` conformance in a `Backends/GRDB/Records/<Entity>Row+Mapping.swift` (or `Backends/GRDB/Sync/<Entity>Row+CloudKit.swift`) extension.
3. Add the record type to `RecordTypeRegistry.allTypes`.
4. Add `onRecordChanged`/`onRecordDeleted` closure calls to every mutation method in the GRDB repository.
5. Add upsert and fetch methods to `ProfileDataSyncHandler`.
6. Add cases to `applyRemoteSave` and `applyRemoteDeletion` switch statements.
7. Add the new record type to `queueAllExistingRecords()` in `ProfileDataSyncHandler`.
8. **Test:** Verify repository mutations trigger the sync closures.

---

## 7. Initial Sync and Fresh Devices

### How It Works

When CKSyncEngine initializes without saved `State.Serialization`:
1. It sends an `.accountChange(.signIn)` event (even if the user was already signed in).
2. It performs a full fetch from CloudKit, delivering all records via `fetchedRecordZoneChanges`.
3. Change tokens are established for future incremental fetches.

### Deletion Tombstone Replay

CloudKit replays deletion tombstones indefinitely. For apps with high deletion churn, a fresh device must process thousands of stale deletion records before seeing current data.

**Mitigations:**
- Prefer soft-deletes (a boolean flag) over hard-deletes for frequently churned records.
- Use `prioritizedZoneIDs` in fetch options to process critical zones first.
- Consider a "data loaded" flag to show existing local data while the sync engine catches up.

### Batch Limits

- Upload: ~400 records per batch. **CKSyncEngine does NOT chunk** — `nextRecordZoneChangeBatch` must self-limit to ≤400 records (Rule 13). Exceeding this causes `BatchTooLarge` (internal code 1020) and the entire batch is rejected.
- Download: much larger (100+ MB observed). The engine handles pagination via change tokens.

---

## 8. Testing Sync Code

### Layer Separation

Test the sync layer separately from the persistence layer:

| Layer | What to Test | How |
|-------|-------------|-----|
| GRDB repositories | CRUD, filtering, sorting | `TestBackend` with in-memory GRDB |
| Record mapping | CKRecord <-> GRDB row conversion | Unit tests, no CloudKit |
| Repository sync closures | Correct records queued on mutations | Mock closure that records calls |
| Sync engine delegate | Event handling, error recovery | `automaticallySync: false` or protocol abstraction |

### Testing Record Mapping

```swift
func testAccountRowRoundTrip() throws {
    let original = AccountRow(
        domain: Account(id: UUID(), name: "Checking", type: .bank, instrument: .AUD))
    let ckRecord = original.toCKRecord(in: testZoneID)
    let restored = try #require(AccountRow.fieldValues(from: ckRecord))
    #expect(restored.id == original.id)
    #expect(restored.name == original.name)
}
```

### Testing Repository Sync Closures

Verify that repository mutations trigger the sync closures with the correct IDs:

```swift
@MainActor
func testCreateQueuesSync() async throws {
    let (backend, _) = try TestBackend.create()
    let repo = backend.accounts as! CloudKitAccountRepository

    var changedIds: [UUID] = []
    repo.onRecordChanged = { changedIds.append($0) }

    let account = Account(id: UUID(), name: "Test", ...)
    _ = try await repo.create(account)

    #expect(changedIds.contains(account.id))
}
```

### Integration Testing with Two "Devices"

Apple's sample app demonstrates testing with `automaticallySync: false`:

```swift
// Create two sync engines, both with manual sync control
let deviceA = SyncEngine(configuration: .init(..., automaticallySync: false))
let deviceB = SyncEngine(configuration: .init(..., automaticallySync: false))

// Device A saves and sends
deviceA.addPendingChange(.saveRecord(recordID))
try await deviceA.syncEngine.sendChanges()

// Device B fetches and verifies
try await deviceB.syncEngine.fetchChanges()
// Assert Device B has the record
```

---

## 9. Debugging Sync Issues

### Logging

All sync components use `os.Logger` with the `com.moolah.app` subsystem. Filter by category:

```bash
# Sync coordinator
/usr/bin/log stream \
  --predicate 'subsystem == "com.moolah.app" && category == "SyncCoordinator"' \
  --level debug --style compact --timeout 45s

# Profile index sync
/usr/bin/log stream \
  --predicate 'subsystem == "com.moolah.app" && category == "ProfileIndexSyncHandler"' \
  --level debug --style compact --timeout 45s

# Per-profile sync
/usr/bin/log stream \
  --predicate 'subsystem == "com.moolah.app" && category == "ProfileDataSyncHandler"' \
  --level debug --style compact --timeout 45s
```

### Common Symptoms and Diagnosis

| Symptom | Likely Cause | Diagnosis |
|---------|-------------|-----------|
| No delegate events after start | iCloud account not available, or corrupted sync state | Check `CKContainer.default().accountStatus()` |
| Zone-related errors (codes 12, 26, 27, 28) | Zone doesn't exist | Check `ensureZoneExists()` ran; check `com.apple.cloudkit` subsystem logs |
| `BatchTooLarge` / internal code 1020 | `nextRecordZoneChangeBatch` returning >400 records | Verify batch limit in `nextRecordZoneChangeBatch` (Rule 13) |
| Thousands of pending changes / large syncstate file | Duplicate queueing or failed sends not clearing | Check `.syncstate` file size; check for re-queuing errors in logs |
| Records sent but not appearing on other devices | Change tag conflict, or second device not fetching | Check for `.serverRecordChanged` errors in logs |
| Records appear then disappear | Derived-data save triggering sync uploads | Verify only repository mutations call onRecordChanged (Rule 2) |
| Duplicate records across devices | Record names not derived from stable UUIDs | Check `CKRecord.ID` construction (Rule 10) |
| Sync works once then stops | State serialization not being saved, or records silently dropped | Check `.stateUpdate` handler; check `default` case re-queues (Rule 9) |
| `.serverRecordChanged` on every upload | Not preserving CKRecord system fields | Check `toCKRecord` implementation (Rule 5) |
| App jittery during bulk sync | `nextRecordZoneChangeBatch` runs on main actor | Move record lookup to a background GRDB read (planned optimization) |

### CloudKit Dashboard

Use the [CloudKit Dashboard](https://icloud.developer.apple.com/) to:
- Browse records and zones in the Development or Production environment
- Verify record types and field schemas
- Check for orphaned zones from failed cleanups
- Reset the Development environment when schemas need incompatible changes

---

## 10. Anti-Patterns

| Anti-Pattern | Why It's Bad | Do This Instead |
|-------------|--------------|-----------------|
| Calling `fetchChanges()`/`sendChanges()` in delegate callbacks | Causes infinite loops -- engine re-enters your delegate | Add to pending queue; engine schedules sends |
| Multiple CKSyncEngine instances on one database | They conflict on change tokens and event routing | One engine per database (owned by `SyncCoordinator`); delegate zone-specific logic to handlers |
| Creating fresh CKRecords without system fields | Every upload triggers `.serverRecordChanged` | Preserve and reuse `encodedSystemFields` |
| Ignoring `.serverRecordChanged` errors | Second device's changes silently lost | Implement conflict resolution (Rule 6) |
| Ignoring `.quotaExceeded` | Engine drops items; sync silently stops | Re-queue items and notify user (Rule 9) |
| Using `NSManagedObjectContextDidSave` to drive sync | Cannot distinguish user edits from derived-data updates, causes re-upload loops | Queue sync changes explicitly from repository mutations |
| Maintaining a shadow pending-changes set | Falls out of sync with CKSyncEngine's internal state, causes duplicates | Let CKSyncEngine own pending state; deduplicate in `nextRecordZoneChangeBatch` |
| Returning all pending records from `nextRecordZoneChangeBatch` | CloudKit rejects batches >400 records with `BatchTooLarge`; CKSyncEngine does NOT chunk | Limit to 400 records per call (Rule 13) |
| Relying on reactive zone creation in error handlers | Error codes for missing zones are inconsistent (26, 27, 28, 12); batch failures may not be retried | Create zones proactively on engine start (Rule 3) |
| Silently dropping records in `default` error case | CKSyncEngine removes failed items from its queue; not re-queuing means permanent data loss | Always re-queue on unexpected errors (Rule 9) |
| Hard-deleting high-churn records | Deletion tombstones replay on fresh devices forever | Use soft-delete flags where practical |
| Storing enums as integers in CKRecords | Adding new cases breaks older app versions | Store as strings (Rule 11) |
| `try?` on CloudKit operations without logging | Silent failures make debugging impossible | Log errors with `os.Logger` before discarding |
| Deleting state file on every launch "just in case" | Forces full re-fetch every time, wasting bandwidth | Only delete on account change or corruption |

---

## 11. Schema Management

`CloudKit/schema.ckdb` is the canonical source of truth for the CloudKit
schema. It is hand-authored, reviewed in PRs as plain text, and is the only
file a developer hand-edits when CloudKit fields change. The Swift wire
layer (`Backends/CloudKit/Sync/Generated/<RecordType>CloudKitFields.swift`)
is generated from it by `tools/CKDBSchemaGen` as part of `just generate`,
and CloudKit Development and Production are populated from it by `cktool`.
**Never** treat a live CloudKit environment, an exported file, or a
generated Swift file as the source of truth.

For procedural detail (how to add/remove/rename a field, what to do about
specific compile errors), see the `modifying-cloudkit-schema` skill in
`.claude/skills/`.

### Pipeline

```
schema.ckdb ──► ckdb-schema-gen ──► Generated/  ──► *Record+CloudKit.swift  ──► CKRecord
            │                       (wire struct)    (adapter, thin)
            │
            │ cktool import-schema
            ▼
       CloudKit Production
            │
            │ cktool export-schema (after promote)
            ▼
       schema-prod-baseline.ckdb (committed)
```

### Two containers: release vs test

Per issue #495, two CloudKit containers are in play:

- `iCloud.rocks.moolah.app.v2` — the **release container**. Holds production
  user data (Production environment) and is the staging area used by the
  release pipeline before a Console Deploy (Development environment). Reached
  only by fastlane-signed shipped builds (the App Store / TestFlight /
  Developer-ID Mac binary distributed via the GitHub release artefact) and
  by the four release-pipeline schema scripts: `verify-prod-deployed.sh`,
  `verify-prod-matches-baseline.sh`, `refresh-prod-baseline.sh`,
  `import-schema-to-dev.sh`. Each of those scripts pins
  `CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_RELEASE"`.

- `iCloud.rocks.moolah.app.test` — the **test container**. Reached by every
  locally-signed binary — i.e. every Debug build (`just run-mac`,
  `just build-mac` after `ENABLE_ENTITLEMENTS=1 just generate`) — and by
  the local-only convenience scripts `export-schema.sh`, `verify-schema.sh`,
  `dryrun-promote-schema.sh`, and `import-schema-to-test.sh`. Each of those
  scripts pins `CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_TEST"`.

There is no local Release path. To run a Release-signed copy of the app,
download the `Moolah-x.y.z.zip` artefact from the matching GitHub release.
This makes the local-vs-shipped split mechanical: anything you build on
your machine is Debug + test container; anything signed with the
production container is fastlane-built and shipped through the release
pipeline.

Container selection at runtime is driven by the `CLOUDKIT_CONTAINER_ID`
build setting in `project.yml`, which is per-configuration: Debug and
Debug-Tests resolve to the test container; Release resolves to the release
container. The setting is surfaced via the `MoolahCloudKitContainer`
Info.plist key and read by `Backends/CloudKit/CloudKitContainer.swift`.

This split exists so that the release pipeline's "import schema.ckdb to
the release container's Dev environment, pause for the developer to click
Deploy in the Console" handoff is safe: nothing else writes to the release
container's Dev between the import step and the manual deploy. Local
developer experimentation runs against a separate container that the
release pipeline never touches.

### Production additive-only

Production schema only grows. Once a field or record type is in
Production, it is in Production forever. The Swift wire layer can forget
about a field via `// DEPRECATED` (the generator skips deprecated lines),
but the `.ckdb` line stays so `cktool import-schema` keeps re-declaring
the field on Production. Type changes are not allowed; rename = add new
+ deprecate old.

### CI gates

- **PR-time:** `just check-schema-additive` is a pure-text comparison of
  `CloudKit/schema.ckdb` against `CloudKit/schema-prod-baseline.ckdb`.
  Fails on any non-additive change. No CloudKit calls.
- **Release-tag:** `just verify-prod-matches-baseline` exports the live
  Production schema and diffs it against the committed baseline (catches
  manual dashboard edits or partial prior promotes); `just promote-schema`
  imports the new manifest to Production with `--validate`, exports the
  result back into the baseline file, and opens a follow-up PR with the
  refreshed baseline.

### `dryrun-promote-schema`, `verify-schema`, `import-schema-to-test`

All three are manual local affordances, not CI gates, and all three target
the **test** container (`CLOUDKIT_CONTAINER_ID_TEST`).

- `verify-schema` imports `.ckdb` to the test container's Dev with
  `--validate`. Use this for belt-and-braces verification before opening
  a schema-touching PR.
- `dryrun-promote-schema` is Apple's Prod-equivalent dry-run
  (`reset-schema && import-schema --validate`) and is destructive to the
  test container's Dev — set `CKTOOL_ALLOW_DEV_RESET=1` to confirm.
- `import-schema-to-test` resets the test container's Dev and re-imports
  `.ckdb`. Use this once after creating the test container in App Store
  Connect, or any time you want to wipe the test container back to a
  known-good state. Same `CKTOOL_ALLOW_DEV_RESET=1` gate.

### Constraints summary

- Production additive-only forever.
- No type changes.
- Indexes are one-way too: `QUERYABLE SEARCHABLE SORTABLE` on STRING is
  the safe default; narrowing in Production is brittle.
- The wire layer uses CloudKit-native types only (`String?`, `Int64?`,
  `Date?`, `Data?`). Domain richness lives in adapters.

---

## 12. Implementation Checklist

### Before Implementing a New Sync Engine

- [ ] Define the zone name and ensure no other engine manages the same zone
- [ ] Determine the conflict resolution strategy (server-wins, field-level merge, etc.)
- [ ] Plan which record types will be synced in this zone
- [ ] Design the `CloudKitRecordConvertible` mapping for each type

### For Every New Syncable Record Type

- [ ] Add `CloudKitRecordConvertible` conformance in a `Backends/GRDB/Records/<Entity>Row+Mapping.swift` (or `Backends/GRDB/Sync/<Entity>Row+CloudKit.swift`) extension
- [ ] Add to `RecordTypeRegistry.allTypes`
- [ ] Add `onRecordChanged`/`onRecordDeleted` calls to every mutation method in the GRDB repository
- [ ] Add upsert/fetch methods to `ProfileDataSyncHandler`
- [ ] Add cases to `applyRemoteSave` and `applyRemoteDeletion`
- [ ] Add the record type to `queueAllExistingRecords()` in `ProfileDataSyncHandler`
- [ ] Write round-trip mapping tests
- [ ] Verify repository mutations trigger sync closures with correct IDs

### For Every Sync Engine

- [ ] Handle all event types in `handleEvent` (especially `.stateUpdate`, `.accountChange`, `.fetchedDatabaseChanges`, `.fetchedRecordZoneChanges`, `.sentRecordZoneChanges`)
- [ ] Save state serialization on every `.stateUpdate`
- [ ] Create zone proactively in `start()` with `ensureZoneExists()` (Rule 3)
- [ ] Handle `.zoneNotFound`/`.userDeletedZone` in sent changes as fallback (Rule 3)
- [ ] Handle `.serverRecordChanged` with conflict resolution (Rule 6)
- [ ] Handle `.quotaExceeded` by re-queuing and notifying user (Rule 9)
- [ ] Handle `.unknownItem` by clearing cached system fields (Rule 9)
- [ ] Re-queue on unexpected errors in `default` case (Rule 9)
- [ ] Handle all three zone deletion reasons (deleted, purged, encryptedDataReset)
- [ ] Handle all three account change types (signIn, signOut, switchAccounts)
- [ ] Wire repository `onRecordChanged`/`onRecordDeleted` closures to the sync engine in `ProfileSession`
- [ ] Deduplicate pending changes in `nextRecordZoneChangeBatch` (Rule 12)
- [ ] Limit batch size to ≤400 records in `nextRecordZoneChangeBatch` (Rule 13)
- [ ] Queue records in dependency order in `queueAllExistingRecords` (Rule 14)

### Before Shipping to Production

- [ ] Test multi-device sync (create on device A, verify on device B)
- [ ] Test conflict scenario (edit same record on two devices offline, then go online)
- [ ] Test account sign-out and sign-in flow
- [ ] Test fresh device sync (delete app, reinstall, verify data appears)
- [ ] Test with iCloud storage nearly full (quota handling)
- [ ] Verify schema in CloudKit Dashboard matches expectations
- [ ] Verify sync state file doesn't grow unexpectedly

---

## Version History

- **1.3** (2026-04-15): Updated for unified SyncCoordinator architecture. Replaced dual-engine model with SyncCoordinator + ProfileDataSyncHandler + ProfileIndexSyncHandler. Updated all references, logging categories, checklists, and anti-patterns accordingly.
- **1.2** (2026-04-13): Added proactive zone creation (Rule 3 rewritten), batch size limits (Rule 13), dependency ordering (Rule 14), default error re-queuing (Rule 9 updated). Updated anti-patterns, symptoms, and checklists with lessons from production debugging.
- **1.1** (2026-04-13): Replaced ChangeTracker with explicit repository-driven sync queueing. Removed shadow pending-changes sets. Updated rules 2, 4, 4b, 12 and all checklists.
- **1.0** (2026-04-13): Comprehensive sync guide -- architecture, rules, error handling, testing, debugging, schema evolution
