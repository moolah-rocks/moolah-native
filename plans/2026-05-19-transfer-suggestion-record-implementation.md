# Transfer-Suggestion as a First-Class Record — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the denormalised `TransferSuggestion` transaction annotation and the `DismissedTransferPair` negative-assertion machinery with a single synced `TransferSuggestion` record (detect = upsert, dismiss/merge/unmerge = delete), and unify detection so it only ever runs over genuinely-new transactions.

**Architecture:** A new synced GRDB+CloudKit record type `TransferSuggestion` (content-addressed id from the unordered transaction-id pair) mirrors the existing `DismissedTransferPair` plumbing line-for-line. The detection coordinator writes/deletes that record instead of mutating two transaction rows. The crypto/exchange sync trigger is rewired to drive detection off `WalletApplyEngine.apply`'s already-returned genuinely-new survivor set instead of a 3-day rolling window. `DismissedTransferPair` and the two `transferSuggestion*` `TransactionRecord` columns are removed entirely (unshipped — no deprecation).

**Tech Stack:** Swift 6, Swift Testing (`@Suite`/`@Test`/`#expect` — NOT XCTest), GRDB, CKSyncEngine, `xcodegen`/`just`. Spec: `plans/2026-05-19-transfer-suggestion-record-design.md`.

---

## ⚠️ DECISION: FULL PHYSICAL REMOVAL — NON-NEGOTIABLE

`DismissedTransferPairRecord` **and** the two `TransactionRecord.transferSuggestionCounterpartId` / `transferSuggestionSuggestedAt` fields are **physically deleted** from `CloudKit/schema.ckdb` — they are NOT marked `// DEPRECATED`, NOT left additive.

This is a deliberate, approved decision, not an oversight:

- These record types/fields landed **after `v1.1.0-rc.21`** (the latest RC) and have **never shipped to production or TestFlight**. There is no production CloudKit zone, no on-device data, and no user with these fields. The additive-only rule exists to protect *shipped* schema; none of that applies here.
- Keeping deprecated-but-present fields would be permanent dead weight in the wire contract for a feature that never shipped. Removing them is the correct end state.

**Expect friction — push through it, do not retreat:**

- The general additive-only rule will make **`@database-schema-review`, `@sync-review`, and human reviewers repeatedly flag this**. That is anticipated. The response is NOT to deprecate instead — it is to point them at this decision, the design doc's "Stated assumptions", and the prod-baseline evidence. Record the rationale in the PR body and a one-line comment at the `schema.ckdb` edit site so it does not get re-litigated every review pass.
- **CI very likely enforces an additivity gate** (a `schema-prod-baseline.ckdb` diff / `tools/CKDBSchemaGen` additivity check). Removing a record type and fields **will** trip it. Working around that gate is in scope and expected: update the prod baseline to the new shape and/or apply the project's sanctioned additivity-override for these specific removals (the `modifying-cloudkit-schema` skill owns the exact mechanism). Falling back to deprecation to appease the gate is **explicitly not acceptable** — the user has decided the removal is worth the CI work.

Every task below that touches the schema assumes this decision is final. The only thing the prod-baseline check in Task 7 gates is *evidence for the PR* (proving these were never shipped) — it does **not** branch back to a deprecation path.

## Conventions (apply to EVERY task)

- **Worktree:** all work happens in the existing worktree `/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/transfer-suggestion-record`, branch `feat/transfer-suggestion-record` (already off `origin/main`, includes merged #947). Run all `git`/`just` from there. Use `git -C <worktree> …`, never `cd && git`.
- **Tests are Swift Testing**, not XCTest: `import Testing`, `@Suite`, `@Test`, `#expect`, `#require`, `Issue.record`. Never `XCTestCase`/`XCTAssert`.
- **One extension per protocol/concern, own file** (CODE_GUIDE §2). Conformances are split exactly as the `DismissedTransferPair` stack splits them — mirror the file boundaries.
- **Per-task verification is build + targeted test + `just format-check`** (not just build). Capture test output to `.agent-tmp/` (gitignored); delete when reviewed.
- **`just` targets only** — never raw `swift-format`/`xcodebuild`/`swift test`/`swiftlint`. After editing `CloudKit/schema.ckdb` or adding/removing source files, run `just generate`.
- **NEVER edit `.swiftlint-baseline.yml`.** Fix the code instead. (The baseline was emptied/removed in #946 — zero tolerance.)
- **Review gates:** at the phase boundaries marked "REVIEW", run the named project agents and apply all Critical/Important/Minor findings before proceeding (do not defer without asking).
- **Commit after every GREEN+format-check step.** Conventional-commit messages, `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

## The rename map (DismissedTransferPair → TransferSuggestion)

When a task says "mirror the `DismissedTransferPair` sibling at `<path>`", copy that exact file and apply, verbatim, this substitution — then apply the per-task deltas shown:

| DismissedTransferPair token | TransferSuggestion token |
|---|---|
| `DismissedTransferPair` (domain type) | `TransferSuggestion` |
| `DismissedTransferPairRepository` | `TransferSuggestionRepository` |
| `GRDBDismissedTransferPairRepository` | `GRDBTransferSuggestionRepository` |
| `DismissedTransferPairRow` | `TransferSuggestionRow` |
| `DismissedTransferPairRecord` (wire recordType string) | `TransferSuggestionRecord` |
| `DismissedTransferPairRecordCloudKitFields` (generated) | `TransferSuggestionRecordCloudKitFields` |
| `dismissed_transfer_pair` (table) | `transfer_suggestion` |
| `dismissed_pair_by_tx_a` / `_b` (indexes) | `transfer_suggestion_by_tx_a` / `_b` |
| `dismissedTransferPairs` (BackendProvider/bundle member) | `transferSuggestions` |
| `dismissedAt` (field/column `dismissed_at`) | `suggestedAt` (column `suggested_at`) |
| `onDismissedTransferPairChanged/Deleted` (hooks) | `onTransferSuggestionChanged/Deleted` |
| `applyBatchSaveDismissedTransferPair` | `applyBatchSaveTransferSuggestion` |
| `collectDismissedTransferPairIds` | `collectTransferSuggestionIds` |
| `fetchDismissedTransferPairRow` | `fetchTransferSuggestionRow` |

**Semantic deltas vs. a pure rename** (these are NOT mechanical — apply them where the task says):
- The domain type loses `func covers(_:and:)` and the `dismissedAt`-named field; it gains `suggestedAt`. It keeps `id`, `transactionIds: Set<UUID>`, `static func contentAddressedID(for:)`. The content-addressed salt string changes from `"dismissed-transfer-pair:"` to `"transfer-suggestion:"`.
- The repository protocol drops `pairs(touching:)` semantics? **No — keep it**, renamed `suggestions(touching:)`: the UI read path needs "every suggestion referencing this transaction id" (replaces `transaction.transferSuggestion`). Keep the two single-column indexes + the query-plan test.
- There is **no** `TransferSuggestion` "both-sides annotation" type any more. The OLD value type `Domain/Models/TransferSuggestion.swift` (`{ counterpartTransactionId, suggestedAt }`) is **deleted** and replaced by the new entity below. `Transaction.transferSuggestion` is removed from the model.

---

## Phase 0 — Baseline

### Task 0: Confirm green baseline

**Files:** none.

- [ ] **Step 1: Build + format-check**

Run:
```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/transfer-suggestion-record
mkdir -p .agent-tmp
just build-mac 2>&1 | tail -5
just format-check 2>&1 | tail -2
```
Expected: `** BUILD SUCCEEDED **`, `All Swift files are correctly formatted.`

- [ ] **Step 2: Baseline the suites this plan will churn**

Run: `just test-mac TransferDetectionScanTests TransferDetectionMergeTests DismissedTransferPairRepoContractTests 2>&1 | tee .agent-tmp/baseline.txt | grep -E "Test run with|All tests passed"`
Expected: all passed. If not, STOP and report — do not build on a red baseline.

---

## Phase 1 — Domain model

### Task 1: New `TransferSuggestion` entity + content-addressed id

**Files:**
- Delete: `Domain/Models/TransferSuggestion.swift` (old value type)
- Create: `Domain/Models/TransferSuggestion.swift` (new entity, same path)
- Test: `MoolahTests/Domain/TransferSuggestionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Domain/TransferSuggestionTests.swift`:
```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransferSuggestion")
struct TransferSuggestionTests {
  @Test("id is order-independent for the same two ids")
  func deterministicId() {
    let a = UUID()
    let b = UUID()
    let first = TransferSuggestion(transactionIds: [a, b], suggestedAt: Date())
    let second = TransferSuggestion(transactionIds: [b, a], suggestedAt: Date())
    #expect(first.id == second.id)
  }

  @Test("contentAddressedID(for:) matches the instance id and is order-independent")
  func contentAddressedIDMatchesInstance() {
    let a = UUID()
    let b = UUID()
    let instance = TransferSuggestion(transactionIds: [a, b], suggestedAt: Date())
    #expect(TransferSuggestion.contentAddressedID(for: [a, b]) == instance.id)
    #expect(TransferSuggestion.contentAddressedID(for: [b, a]) == instance.id)
  }

  @Test("counterpart(of:) returns the other id")
  func counterpart() {
    let a = UUID()
    let b = UUID()
    let s = TransferSuggestion(transactionIds: [a, b], suggestedAt: Date())
    #expect(s.counterpart(of: a) == b)
    #expect(s.counterpart(of: b) == a)
    #expect(s.counterpart(of: UUID()) == nil)
  }
}
```

- [ ] **Step 2: Run it — expect RED (type does not exist / old type has no such init)**

Run: `just test-mac TransferSuggestionTests 2>&1 | tee .agent-tmp/red1.txt | grep -E "error:|Test run with" | head`
Expected: compile failure — `TransferSuggestion` has no `init(transactionIds:suggestedAt:)` / `contentAddressedID` / `counterpart`.

- [ ] **Step 3: Replace the type**

Overwrite `Domain/Models/TransferSuggestion.swift`:
```swift
import Foundation

/// A detected fuzzy-transfer candidate: two specific transactions that
/// look like the two sides of one cross-account transfer. Synced; a
/// device that detects a pair uploads this record, peers converge on it.
/// `id` is content-addressed from the unordered transaction-id pair, so
/// re-detecting the same pair on any device upserts the same row
/// (idempotent convergence). Dismiss / merge / unmerge delete the
/// record; there is no negative-assertion tombstone.
struct TransferSuggestion: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  let transactionIds: Set<UUID>
  let suggestedAt: Date

  init(transactionIds: Set<UUID>, suggestedAt: Date) {
    self.transactionIds = transactionIds
    self.suggestedAt = suggestedAt
    self.id = Self.contentAddressedID(for: transactionIds)
  }

  /// The other transaction id in the pair, or `nil` if `id` is not a
  /// member.
  func counterpart(of id: UUID) -> UUID? {
    guard transactionIds.contains(id) else { return nil }
    return transactionIds.first { $0 != id }
  }

  /// The content-addressed id this suggestion carries, derived from the
  /// unordered transaction-id set. Exposed so callers can build an O(1)
  /// membership / lookup set keyed by id.
  static func contentAddressedID(for transactionIds: Set<UUID>) -> UUID {
    let ordered = transactionIds.map(\.uuidString).sorted().joined(separator: ":")
    return UUID.deterministic(from: "transfer-suggestion:\(ordered)")
  }
}
```

- [ ] **Step 4: Run it — expect partial GREEN for this suite, RED elsewhere**

Run: `just test-mac TransferSuggestionTests 2>&1 | tee .agent-tmp/green1.txt | grep -E "Suite .TransferSuggestion. (passed|failed)|error:"`
Expected: the `TransferSuggestion` suite passes. The broader target will NOT compile yet (every `transaction.transferSuggestion` reader and the old `TransferSuggestion(counterpartTransactionId:…)` site is now broken) — that is expected and fixed in later tasks. Do not try to fix the whole target here.

- [ ] **Step 5: Commit**
```bash
git -C <worktree> add Domain/Models/TransferSuggestion.swift MoolahTests/Domain/TransferSuggestionTests.swift
git -C <worktree> commit -m "feat(transfer-detection): TransferSuggestion entity (content-addressed pair)"
```

### Task 2: `TransferSuggestionRepository` protocol

**Files:**
- Create: `Domain/Repositories/TransferSuggestionRepository.swift`
- Modify: `Domain/Repositories/BackendProvider.swift:10`

- [ ] **Step 1: Create the protocol** (mirror `Domain/Repositories/DismissedTransferPairRepository.swift`; apply rename map; replace the `pairs(touching:)` doc/role with `suggestions(touching:)`):
```swift
import Foundation

/// Persistence surface for detected transfer suggestions. Detection
/// upserts via `create`; dismiss / merge / unmerge `delete`. The UI
/// resolves the suggestion (if any) for a transaction via
/// `suggestions(touching:)`.
protocol TransferSuggestionRepository: Sendable {
  func fetchAll() async throws -> [TransferSuggestion]
  /// Reactive observation. Emits the full list once immediately, then
  /// on every `transfer_suggestion` table change. Backed by GRDB
  /// `ValueObservation` with `removeDuplicates()`. Cross-device
  /// convergence: a peer that detects/dismisses a pair uploads/deletes
  /// the record; CKSyncEngine applies it locally, firing this stream.
  func observeAll() -> AsyncStream<[TransferSuggestion]>
  /// Companion error stream — surface-then-finish, see
  /// `DismissedTransferPairRepository.observeErrors()` doc.
  func observeErrors() -> AsyncStream<any Error>
  func create(_ suggestion: TransferSuggestion) async throws -> TransferSuggestion
  func delete(id: UUID) async throws
  /// Every suggestion whose unordered transaction-id set includes
  /// `transactionId`. The UI read path + the dismiss/merge lookup.
  func suggestions(touching transactionId: UUID) async throws -> [TransferSuggestion]
}
```

- [ ] **Step 2: Wire `BackendProvider`** — in `Domain/Repositories/BackendProvider.swift`, replace line 10:
```swift
  var dismissedTransferPairs: any DismissedTransferPairRepository { get }
```
with:
```swift
  var transferSuggestions: any TransferSuggestionRepository { get }
```

- [ ] **Step 3: Build — expect RED (no conforming type yet)**

Run: `just build-mac 2>&1 | tee .agent-tmp/red2.txt | grep -E "error:" | head`
Expected: errors that `CloudKitBackend` / test backends do not satisfy `transferSuggestions`. Expected — resolved in Phase 2/3. Commit anyway (protocol is self-consistent):

- [ ] **Step 4: Commit**
```bash
git -C <worktree> add Domain/Repositories/TransferSuggestionRepository.swift Domain/Repositories/BackendProvider.swift
git -C <worktree> commit -m "feat(transfer-detection): TransferSuggestionRepository protocol; swap BackendProvider member"
```

---

## Phase 2 — GRDB layer

### Task 3: v13 migration (drop dismissed_transfer_pair + the 2 txn columns; create transfer_suggestion)

**Files:**
- Create: `Backends/GRDB/ProfileSchema+TransferSuggestion.swift`
- Modify: `Backends/GRDB/ProfileSchema.swift` (`static let version`; register migration; doc block)
- Test: `MoolahTests/Backends/GRDB/ProfileSchemaV13TransferSuggestionTests.swift`
- Modify: `MoolahTests/Backends/GRDB/ProfileSchemaTransferDetectionTests.swift` (drop the dropped-column expectations)

> **Migration policy decision (record in the PR):** a NEW migration `v13_…` is added (not an in-place edit of v12). v12 is unshipped but a developer/tester may already have run it; a forward migration converges everyone. `database-schema-review` (Phase 2 REVIEW) is the authority — if it rules the in-place edit acceptable, follow its ruling. `ALTER TABLE … DROP COLUMN` requires SQLite ≥ 3.35; the project already targets 26+ (fine). `dismissed_transfer_pair` data is dropped with no backfill (design-doc directive — tombstones have no meaning in the new model).

- [ ] **Step 1: Write the migration test**

Create `MoolahTests/Backends/GRDB/ProfileSchemaV13TransferSuggestionTests.swift`:
```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema v13 transfer suggestion")
struct ProfileSchemaV13TransferSuggestionTests {
  @Test("v13 creates transfer_suggestion, drops dismissed_transfer_pair and the 2 tx columns")
  func v13Shape() async throws {
    let database = try ProfileDatabase.openInMemory()
    try await database.read { db in
      // New table exists with exactly its six columns.
      let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(transfer_suggestion)")
        .map { $0["name"] as String }
      #expect(
        Set(cols) == [
          "id", "record_name", "transaction_id_a", "transaction_id_b",
          "suggested_at", "encoded_system_fields",
        ])

      // Old table is gone.
      let hasOld = try Int.fetchOne(
        db,
        sql: """
          SELECT count(*) FROM sqlite_master
          WHERE type='table' AND name='dismissed_transfer_pair'
          """) ?? -1
      #expect(hasOld == 0)

      // The two denormalised suggestion columns are gone from transaction.
      let txCols = try Row.fetchAll(db, sql: "PRAGMA table_info(\"transaction\")")
        .map { $0["name"] as String }
      #expect(!txCols.contains("transfer_suggestion_counterpart_id"))
      #expect(!txCols.contains("transfer_suggestion_suggested_at"))
    }
  }

  @Test("pairs/suggestions lookup uses the tx indexes, not a scan")
  func suggestionLookupUsesIndex() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txId = UUID()
    try await database.read { db in
      let plan = try Row.fetchAll(
        db,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM transfer_suggestion
          WHERE transaction_id_a = ? OR transaction_id_b = ?
          """,
        arguments: [txId, txId]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("USING INDEX transfer_suggestion_by_tx_") })
      #expect(!plan.contains { $0.contains("SCAN transfer_suggestion") })
    }
  }
}
```

- [ ] **Step 2: Run — expect RED**

Run: `just test-mac ProfileSchemaV13TransferSuggestionTests 2>&1 | tee .agent-tmp/red3.txt | grep -E "expect|error:|Test run with" | head`
Expected: fails — `transfer_suggestion` does not exist / `dismissed_transfer_pair` still present.

- [ ] **Step 3: Create the v13 body**

Create `Backends/GRDB/ProfileSchema+TransferSuggestion.swift`:
```swift
import Foundation
import GRDB

extension ProfileSchema {
  /// v13 migration body. Replaces the fuzzy-transfer-detection storage
  /// model: a detected suggestion is now a first-class synced record
  /// rather than a denormalised pair of `transaction` columns plus a
  /// negative-assertion `dismissed_transfer_pair` table.
  ///
  /// - Drops `dismissed_transfer_pair` (negative assertions carry no
  ///   meaning in the record model; no data is preserved).
  /// - Drops `transaction.transfer_suggestion_counterpart_id` and
  ///   `transaction.transfer_suggestion_suggested_at` (the denormalised
  ///   annotation; superseded by the new table).
  /// - Creates `transfer_suggestion` — synced (CKSyncEngine). `id` is a
  ///   content-addressed UUID of the unordered transaction-id pair, so
  ///   the repository's `upsert` on the PK is idempotent across devices.
  ///
  /// `WITHOUT ROWID` intentionally NOT used (same constraint as v12 /
  /// v4: `upsert` emits `RETURNING "rowid"`; ValueObservation hooks
  /// require a rowid table). Small rows; rowid overhead negligible.
  static func addTransferSuggestion(_ database: Database) throws {
    try database.execute(
      sql: """
        DROP TABLE IF EXISTS dismissed_transfer_pair;

        ALTER TABLE "transaction" DROP COLUMN transfer_suggestion_counterpart_id;
        ALTER TABLE "transaction" DROP COLUMN transfer_suggestion_suggested_at;

        CREATE TABLE transfer_suggestion (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            transaction_id_a       BLOB    NOT NULL,
            transaction_id_b       BLOB    NOT NULL,
            suggested_at           TEXT    NOT NULL,
            encoded_system_fields  BLOB
        ) STRICT;

        -- `suggestions(touching: id)` filters WHERE tx_a = ? OR tx_b = ?.
        -- SQLite resolves OR-of-two-indexed-columns via a two-scan
        -- union; both indexes are required and neither is a prefix of
        -- the other. Per DATABASE_SCHEMA_GUIDE §4.
        CREATE INDEX transfer_suggestion_by_tx_a ON transfer_suggestion(transaction_id_a);
        CREATE INDEX transfer_suggestion_by_tx_b ON transfer_suggestion(transaction_id_b);
        """)
  }
}
```

- [ ] **Step 4: Register it** — in `Backends/GRDB/ProfileSchema.swift`:
  - change `static let version = 12` → `static let version = 13`
  - immediately after the `"v12_add_transfer_detection"` registration line add:
    ```swift
    migrator.registerMigration(
      "v13_transfer_suggestion_record", migrate: addTransferSuggestion)
    ```
  - add a `v13` paragraph to the migrator doc block (lines 8–82) in the existing present-tense style, e.g.:
    > `v13_transfer_suggestion_record` — replaces the denormalised transfer-suggestion columns and the `dismissed_transfer_pair` table with the synced `transfer_suggestion` record table.

- [ ] **Step 5: Fix the v12 schema-pin test** — in `MoolahTests/Backends/GRDB/ProfileSchemaTransferDetectionTests.swift`, the v12 suite asserts the post-migration state of a fully-migrated DB. Since v13 now runs too, update its expectations: remove any assertion that `transaction` contains `transfer_suggestion_counterpart_id` / `transfer_suggestion_suggested_at` and that `dismissed_transfer_pair` exists (those are now dropped by v13). Keep the `import_origin_*` / `import_origin_incoming_*` / `import_origin_kind` assertions (merge feature, untouched). If the suite name implies "v12 end state" and that state no longer exists post-v13, rename the assertions to reflect the migrated end state, or move them into the v13 test — pick one, keep coverage of the `import_origin*` columns.

- [ ] **Step 6: Run — expect GREEN**

Run: `just test-mac ProfileSchemaV13TransferSuggestionTests ProfileSchemaTransferDetectionTests 2>&1 | tee .agent-tmp/green3.txt | grep -E "Test run with|error:|failed"`
Expected: both suites pass.

- [ ] **Step 7: format-check + commit**
```bash
just format && just format-check 2>&1 | tail -1
git -C <worktree> add Backends/GRDB/ProfileSchema+TransferSuggestion.swift Backends/GRDB/ProfileSchema.swift MoolahTests/Backends/GRDB/ProfileSchemaV13TransferSuggestionTests.swift MoolahTests/Backends/GRDB/ProfileSchemaTransferDetectionTests.swift
git -C <worktree> commit -m "feat(transfer-detection): v13 migration — transfer_suggestion table; drop dismissed_transfer_pair + denorm columns"
```

### Task 4: `TransferSuggestionRow` + Mapping + ObservableRegion

**Files:**
- Create: `Backends/GRDB/Records/TransferSuggestionRow.swift`
- Create: `Backends/GRDB/Records/TransferSuggestionRow+Mapping.swift`
- Create: `Backends/GRDB/Records/TransferSuggestionRow+ObservableRegion.swift`
- Test: `MoolahTests/Backends/TransferSuggestionRowTests.swift`

- [ ] **Step 1: Write the mapping test** (mirror `MoolahTests/Backends/DismissedTransferPairRowTests.swift`; rename map; assert `init(domain:)` sorts the two ids into `transactionIdA < transactionIdB` by `uuidString`, `recordName == "TransferSuggestionRecord|<id>"`, `toDomain()` round-trips `suggestedAt` and the id-set). Use `Date(timeIntervalSince1970:)` fixtures.

- [ ] **Step 2: Run — expect RED** (`TransferSuggestionRow` undefined).
Run: `just test-mac TransferSuggestionRowTests 2>&1 | grep -E "error:" | head`

- [ ] **Step 3: Create `TransferSuggestionRow.swift`** — copy `Backends/GRDB/Records/DismissedTransferPairRow.swift`, apply rename map, change the `dismissedAt`/`dismissed_at` column+property to `suggestedAt`/`suggested_at`. Drop the first-line `// path` header comment (CODE_GUIDE — no redundant path headers; the `DismissedTransferPair` originals carry one but new files must not). Final shape:
```swift
import Foundation
import GRDB

/// One row in the `transfer_suggestion` table. The two transaction ids
/// are stored sorted (`transactionIdA` < `transactionIdB` by
/// `uuidString`) so a re-detection on any device upserts the same row.
struct TransferSuggestionRow {
  static let databaseTableName = "transfer_suggestion"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case transactionIdA = "transaction_id_a"
    case transactionIdB = "transaction_id_b"
    case suggestedAt = "suggested_at"
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case transactionIdA = "transaction_id_a"
    case transactionIdB = "transaction_id_b"
    case suggestedAt = "suggested_at"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var transactionIdA: UUID
  var transactionIdB: UUID
  var suggestedAt: Date
  var encodedSystemFields: Data?
}

extension TransferSuggestionRow: Codable {}
extension TransferSuggestionRow: Sendable {}
extension TransferSuggestionRow: Identifiable {}
extension TransferSuggestionRow: FetchableRecord {}
extension TransferSuggestionRow: PersistableRecord {}
extension TransferSuggestionRow: GRDBSystemFieldsStampable {}
```

- [ ] **Step 4: Create `TransferSuggestionRow+Mapping.swift`** — mirror the `DismissedTransferPair` sibling; `recordType = "TransferSuggestionRecord"`; `init(domain: TransferSuggestion)` precondition `sorted.count == 2`; `toDomain()` returns `TransferSuggestion(transactionIds:[transactionIdA, transactionIdB], suggestedAt: suggestedAt)`. No path-header comment.

- [ ] **Step 5: Create `TransferSuggestionRow+ObservableRegion.swift`** — mirror exactly (rename map only), no path-header comment.

- [ ] **Step 6: Run — expect GREEN**, then format-check + commit.
Run: `just test-mac TransferSuggestionRowTests 2>&1 | grep -E "Test run with|failed"`
```bash
just format && just format-check 2>&1 | tail -1
git -C <worktree> add Backends/GRDB/Records/TransferSuggestionRow*.swift MoolahTests/Backends/TransferSuggestionRowTests.swift
git -C <worktree> commit -m "feat(transfer-detection): TransferSuggestionRow + mapping + observable region"
```

### Task 5: `GRDBTransferSuggestionRepository` (+Observation, +Sync)

**Files:**
- Create: `Backends/GRDB/Repositories/GRDBTransferSuggestionRepository.swift`
- Create: `Backends/GRDB/Repositories/GRDBTransferSuggestionRepository+Observation.swift`
- Create: `Backends/GRDB/Repositories/GRDBTransferSuggestionRepository+Sync.swift`
- Test: `MoolahTests/Domain/TransferSuggestionRepoContractTests.swift`

- [ ] **Step 1: Write the contract test** — mirror `MoolahTests/Domain/DismissedTransferPairRepoContractTests.swift` with the rename map; replace `pairs(touching:)` with `suggestions(touching:)`; replace `dismissedAt` with `suggestedAt`; `makeRepository()` returns `pair.backend.transferSuggestions`. Keep: create/fetch, idempotent-upsert (reversed order, later timestamp → 1 row, latest `suggestedAt`), `suggestions(touching:)` returns the two referencing + excludes unrelated, `delete(id:)`, `observeAll` emits after create.

- [ ] **Step 2: Run — expect RED** (repository + `backend.transferSuggestions` undefined). `just test-mac TransferSuggestionRepoContractTests 2>&1 | grep -E "error:" | head`

- [ ] **Step 3: Create the repository** — copy `GRDBDismissedTransferPairRepository.swift`, apply rename map; rename `pairs(touching:)` → `suggestions(touching:)` (body identical, column names via rename map); `order(...Columns.suggestedAt.asc)`. Keep every sync entry point (`applyRemoteChangesSync` ×2, `setEncodedSystemFieldsSync`, `clearAllSystemFieldsSync`, `unsyncedRowIdsSync`, `allRowIdsSync`, `fetchRowSync`, `fetchRowsSync`, `deleteAllSync`) verbatim-with-rename. No path-header comment.

- [ ] **Step 4: Create `+Observation.swift` and `+Sync.swift`** — mirror the two `DismissedTransferPair` siblings with the rename map (the `observeAll()` `.tracking(regions:fetch:)` body uses `TransferSuggestionRow.observableRegion` and orders by `suggestedAt.asc`; `setEncodedSystemFieldsBatchSync` body identical-with-rename). No path-header comments.

- [ ] **Step 5: Run — still RED at link** (no `backend.transferSuggestions` yet — provided in Task 7). Confirm the repo *compiles* in isolation by building; the contract test stays red until Task 7. Note in commit.

- [ ] **Step 6: format-check + commit**
```bash
just format && just format-check 2>&1 | tail -1
git -C <worktree> add Backends/GRDB/Repositories/GRDBTransferSuggestionRepository*.swift MoolahTests/Domain/TransferSuggestionRepoContractTests.swift
git -C <worktree> commit -m "feat(transfer-detection): GRDBTransferSuggestionRepository (+observation, +sync)"
```

### Task 6: GRDB rollback + hook-record-type tests

**Files:**
- Create: `MoolahTests/Backends/GRDB/TransferSuggestionRollbackTests.swift`
- Create: `MoolahTests/Backends/TransferSuggestionQueryPlanTests.swift`
- Modify: `MoolahTests/Sync/GRDBRepositoryHookRecordTypeTests.swift` (add the two `transferSuggestion` cases; remove the `dismissedTransferPair` cases — that repo is being deleted)

- [ ] **Step 1: Create the rollback test** — mirror `DismissedTransferPairRollbackTests.swift` (rename map; sentinel trigger names → `fail_transfer_suggestion_*`; table `transfer_suggestion`; helper builds `TransferSuggestionRow(domain: TransferSuggestion(transactionIds:[…], suggestedAt:…))`). Keep all three cases (saved-batch, delete-batch, sysfields-batch).

- [ ] **Step 2: Create the query-plan test** — mirror `DismissedTransferPairQueryPlanTests.swift`; assert `USING INDEX transfer_suggestion_by_tx_` and not `SCAN transfer_suggestion`.

- [ ] **Step 3: Update hook-record-type test** — in `GRDBRepositoryHookRecordTypeTests.swift` replace the `// MARK: - GRDBDismissedTransferPairRepository` block (the two `dismissedTransferPair*EmitsRecordType` tests + `makeDismissedPair()` helper) with the `TransferSuggestion` equivalents (rename map; helper `makeSuggestion()` → `TransferSuggestion(transactionIds:[UUID(),UUID()], suggestedAt: Date(timeIntervalSince1970: 1_700_000_000))`; assert `TransferSuggestionRow.recordType`).

- [ ] **Step 4: Run — expect RED then GREEN after Task 7** for the rollback/queryplan (they construct the repo directly with an in-memory DB, so they GO GREEN now); the hook test also GREEN now (direct repo construction).
Run: `just test-mac TransferSuggestionRollbackTests TransferSuggestionQueryPlanTests GRDBRepositoryHookRecordTypeTests 2>&1 | tee .agent-tmp/green6.txt | grep -E "Test run with|failed|error:"`
Expected: all green.

- [ ] **Step 5: format-check + commit**
```bash
just format && just format-check 2>&1 | tail -1
git -C <worktree> add MoolahTests/Backends/GRDB/TransferSuggestionRollbackTests.swift MoolahTests/Backends/TransferSuggestionQueryPlanTests.swift MoolahTests/Sync/GRDBRepositoryHookRecordTypeTests.swift
git -C <worktree> commit -m "test(transfer-detection): rollback + query-plan + hook-record-type for TransferSuggestion"
```

> **REVIEW (Phase 2):** run `@database-schema-review` (migration, STRICT, indexes, drop-and-recreate rule, retention, sidecar) and `@database-code-review` (records/mapping, query safety, repository, plan-pinning, GRDB concurrency). Apply all findings. The migration-policy decision (new v13 vs. in-place v12) is explicitly in `@database-schema-review`'s remit — follow its ruling and record it in the PR body.

---

## Phase 3 — CloudKit + sync wiring

### Task 7: CloudKit schema + generated wire layer + backend wiring

**Files:**
- Modify: `CloudKit/schema.ckdb` (remove `DismissedTransferPairRecord`; add `TransferSuggestionRecord`; drop the two `transferSuggestion*` fields from `TransactionRecord`)
- Regenerate: `Backends/CloudKit/Sync/Generated/*` via `just generate`
- Create: `Backends/GRDB/Sync/TransferSuggestionRow+CloudKit.swift`
- Modify (Step 3b — closes the migration↔Row correctness gap): `Backends/GRDB/Records/TransactionRow.swift`, `Backends/GRDB/Records/TransactionRow+Mapping.swift`, `Backends/GRDB/Sync/TransactionRow+CloudKit.swift` — remove the two `transferSuggestion*` columns/fields the v13 migration dropped
- Modify: `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift:34,58,101` (swap the three `DismissedTransferPairRow` lines for `TransferSuggestionRow`)
- Modify: `Backends/CloudKit/Sync/ProfileGRDBRepositories.swift:25,86`
- Modify: `Backends/CloudKit/CloudKitBackend.swift` (L9,37,59–60,81–82,115,127,144,181–184 — swap repo member, GRDB member, hooks, defaults, bundle field, init)
- Modify the four `ProfileDataSyncHandler+*` files (Task 8)

> **Schema-removal decision: FULL PHYSICAL REMOVAL (see the top-of-plan callout — this is final).** `DismissedTransferPairRecord` and the two `TransactionRecord.transferSuggestion*` fields are physically deleted from `schema.ckdb`, not deprecated. The prod-baseline check below is for **evidence-gathering only** (to document in the PR that these were never shipped) — it does **not** branch to a deprecation fallback. If the additivity gate / CI objects, work around the gate (next step); do not retreat.

- [ ] **Step 1: Invoke the `modifying-cloudkit-schema` skill** and follow its runbook for the `.ckdb` edit syntax, `just generate`, the generated-file diff review, and the `DataFormatVersion` rubric (Task 12). Use it to:
  - **Gather evidence (not a gate):** diff `CloudKit/schema.ckdb` against `CloudKit/schema-prod-baseline.ckdb` (or whatever the runbook names the shipped baseline) and confirm `DismissedTransferPairRecord` and the two `transferSuggestion*` fields are absent from the prod baseline. Capture that diff for the PR body as proof the removal touches only never-shipped schema. (If — unexpectedly — they ARE in the prod baseline, that contradicts the user's stated premise: STOP and report to the user before proceeding. Do NOT silently switch to deprecation.)
  - **Identify and neutralise the additivity gate:** locate the additive-only enforcement (`tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Additivity.swift`, any `schema-prod-baseline.ckdb` diff step, and the CI job that runs it). Apply the project's sanctioned mechanism to permit these specific removals — regenerate/advance the baseline to the new shape and/or the runbook's documented override — so CI passes with the removal intact. Record exactly what was done and why in the PR body and a brief comment at the `schema.ckdb` edit site. Working around this gate is expected and in scope; deprecating to avoid it is not.

- [ ] **Step 2: Edit `CloudKit/schema.ckdb`**
  - Delete the entire `RECORD TYPE DismissedTransferPairRecord ( … );` block.
  - Add (alphabetical placement consistent with the file ordering — between `TransactionLegRecord` and the next, matching how `DismissedTransferPairRecord` was ordered relative to peers):
    ```
    RECORD TYPE TransferSuggestionRecord (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        suggestedAt     TIMESTAMP QUERYABLE SORTABLE,
        transactionIdA  STRING QUERYABLE SEARCHABLE SORTABLE,
        transactionIdB  STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );
    ```
  - In `RECORD TYPE TransactionRecord` delete the two lines `transferSuggestionCounterpartId STRING …` and `transferSuggestionSuggestedAt TIMESTAMP …`.

- [ ] **Step 3: Regenerate + verify**

Run: `just generate 2>&1 | tail -3`
Then confirm `Backends/CloudKit/Sync/Generated/TransferSuggestionRecordCloudKitFields.swift` now exists with `suggestedAt: Date?`, `transactionIdA: String?`, `transactionIdB: String?` (+ `init`, `init(from:)`, `write(to:)`, `allFieldNames`), `DismissedTransferPairRecordCloudKitFields.swift` is gone, and the generated `TransactionRecord` fields struct no longer has the two `transferSuggestion*` members. (The `Generated/` dir is gitignored — do not `git add` it.)

- [ ] **Step 3b: Remove the two `transferSuggestion*` columns from the `TransactionRow` GRDB layer (REQUIRED — closes a correctness gap).** The v13 migration (Task 3) drops `transaction.transfer_suggestion_counterpart_id` / `transfer_suggestion_suggested_at`, and Step 3 just regenerated `TransactionRecordCloudKitFields` without the two `transferSuggestion*` members. `TransactionRow` and its mapping/CloudKit siblings still reference both — under `STRICT` this is a runtime crash on any `transaction` read/write against a v13 DB, and a compile failure now that the generated struct lost the members. In the **same task** (so the GRDB schema, the Row, and the regenerated wire struct move together):
  - `Backends/GRDB/Records/TransactionRow.swift` — delete `transferSuggestionCounterpartId` / `transferSuggestionSuggestedAt` from `Columns`, from `CodingKeys`, and from the stored properties.
  - `Backends/GRDB/Records/TransactionRow+Mapping.swift` — delete the read/write of those two columns in `init(domain:)` / `toDomain()` (the domain `Transaction.transferSuggestion` property is removed in Task 12; here just stop persisting the columns — map nothing for them).
  - `Backends/GRDB/Sync/TransactionRow+CloudKit.swift` — delete the `transferSuggestionCounterpartId` / `transferSuggestionSuggestedAt` read/write against `TransactionRecordCloudKitFields` (those generated members no longer exist after Step 3).
  - Grep to confirm no other `transferSuggestion`-named member of `TransactionRow`/`TransactionRecordCloudKitFields` remains: `git -C <worktree> grep -n "transferSuggestion" -- 'Backends/GRDB/Records/TransactionRow*' 'Backends/GRDB/Sync/TransactionRow+CloudKit.swift'` → expect no hits.
  - Note: `Transaction.transferSuggestion` (the **domain** model property) is intentionally still present until Task 12; `TransactionRow+Mapping` must compile against the domain type as it exists at this point — if the mapping currently sources those columns from `domain.transferSuggestion`, drop that wiring entirely (the column is gone; the domain property's removal is Task 12's job and the mapping simply no longer touches it).

- [ ] **Step 4: Create `Backends/GRDB/Sync/TransferSuggestionRow+CloudKit.swift`** — copy `DismissedTransferPairRow+CloudKit.swift`, rename map; the `CloudKitRecordConvertible` body writes/reads `TransferSuggestionRecordCloudKitFields(suggestedAt:transactionIdA:transactionIdB:)`; `fieldValues(from:)` parses both UUIDs and falls back `suggestedAt ?? Date(timeIntervalSince1970: 0)`. Keep the "frozen wire contract" comment but reword: the recordType string is `"TransferSuggestionRecord"` (new — there is no legacy zone to preserve, so phrase as "the wire `recordType` is the stable contract for this record" without the legacy-zone clause).

- [ ] **Step 5: Swap the three `CloudKitRecordConvertible.swift` lines** (`IdentifiableRecord`, `ValueTypeSystemFieldsReadable`, and the `recordType: type` registry map entry) from `DismissedTransferPairRow` to `TransferSuggestionRow`.

- [ ] **Step 6: Swap `ProfileGRDBRepositories.swift`** L25 field + L86 constructor (`transferSuggestions: GRDBTransferSuggestionRepository(database: database)`).

- [ ] **Step 7: Swap `CloudKitBackend.swift`** — apply the rename map at L9 (`let transferSuggestions: any TransferSuggestionRepository`), L37 (`let grdbTransferSuggestions: GRDBTransferSuggestionRepository`), L59–60 (`onTransferSuggestionChanged/Deleted`), L81–82 (`.noop` defaults), L115/L127 (assignments), L144 (bundle field), L181–184 (init with the renamed hooks). The protocol member name is now `transferSuggestions` (Task 2).

- [ ] **Step 8: Delete the obsolete `DismissedTransferPair` GRDB+sync files** now that nothing references them: `Domain/Models/DismissedTransferPair.swift`, `Domain/Repositories/DismissedTransferPairRepository.swift`, `Backends/GRDB/Records/DismissedTransferPairRow*.swift`, `Backends/GRDB/Sync/DismissedTransferPairRow+CloudKit.swift`, `Backends/GRDB/Repositories/GRDBDismissedTransferPairRepository*.swift`. (Tests that referenced them were rehomed in Tasks 5/6; remaining test/support references handled in Task 9/11.) Run `just generate` (source set changed).

- [ ] **Step 9: Build — expect remaining RED only in the coordinator + UI readers + test-support backends** (Phases 4/6/Task 9). Run: `just build-mac 2>&1 | tee .agent-tmp/build7.txt | grep -E "error:" | sort -u | head -40`. Confirm there are NO errors mentioning `DismissedTransferPair` (all such references must now be gone except the deliberately-pending coordinator/UI ones referencing the OLD `transaction.transferSuggestion`, which are addressed next).

- [ ] **Step 10: format-check + commit** (do not add `Generated/`):
```bash
just format && just format-check 2>&1 | tail -1
git -C <worktree> add CloudKit/schema.ckdb Backends/GRDB/Sync/TransferSuggestionRow+CloudKit.swift Backends/CloudKit/Sync/CloudKitRecordConvertible.swift Backends/CloudKit/Sync/ProfileGRDBRepositories.swift Backends/CloudKit/CloudKitBackend.swift
git -C <worktree> add -u Domain/Models/DismissedTransferPair.swift Domain/Repositories/DismissedTransferPairRepository.swift 'Backends/GRDB/Records/DismissedTransferPairRow*' 'Backends/GRDB/Sync/DismissedTransferPairRow+CloudKit.swift' 'Backends/GRDB/Repositories/GRDBDismissedTransferPairRepository*'
git -C <worktree> commit -m "feat(transfer-detection): CloudKit TransferSuggestionRecord; remove DismissedTransferPair stack"
```

### Task 8: ProfileDataSyncHandler dispatch / lookup / system-fields / queue-delete

**Files:** `Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBSaveHelpers.swift`, `+GRDBDispatch.swift`, `+SystemFields.swift`, `+RecordLookup.swift`, `+QueueAndDelete.swift`.

- [ ] **Step 1: Apply the rename map at the exact sites** enumerated in the research dossier (verbatim line refs):
  - `+GRDBSaveHelpers.swift` L110–126 — rename `applyBatchSaveDismissedTransferPair` → `applyBatchSaveTransferSuggestion`, site string `applyGRDBBatchSave[TransferSuggestion]`, `fieldValues: TransferSuggestionRow.fieldValues(from:)`, `grdbRepositories.transferSuggestions`.
  - `+GRDBDispatch.swift` L60–63 (save dispatch) & L144–150 (delete dispatch) — `case TransferSuggestionRow.recordType:` → the renamed save helper / `transferSuggestions.applyRemoteChangesSync`.
  - `+SystemFields.swift` L39–42 (clear-all tuple) & L240–241 (`setEncodedSystemFieldsBatchSync` switch case).
  - `+RecordLookup.swift` L98–101 (single fetch), L183–189 (batch fetch), L303–305 (`fetchTransferSuggestionRow`).
  - `+QueueAndDelete.swift` L82 (collect call), L203–215 (`collectTransferSuggestionIds`), L254–257 (deleteAll tuple).

- [ ] **Step 2: Build — expect GREEN for this layer**

Run: `just build-mac 2>&1 | tee .agent-tmp/build8.txt | grep -E "error:" | grep -i "transferSuggestion\|dismissed" | head`
Expected: no errors mentioning either token in the sync handler. (Coordinator/UI errors from the OLD `transaction.transferSuggestion` may still remain — Phases 4/6.)

- [ ] **Step 3: format-check + commit**
```bash
just format && just format-check 2>&1 | tail -1
git -C <worktree> add Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBSaveHelpers.swift Backends/CloudKit/Sync/ProfileDataSyncHandler+GRDBDispatch.swift Backends/CloudKit/Sync/ProfileDataSyncHandler+SystemFields.swift Backends/CloudKit/Sync/ProfileDataSyncHandler+RecordLookup.swift Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift
git -C <worktree> commit -m "feat(transfer-detection): sync-handler dispatch/lookup/system-fields for TransferSuggestionRecord"
```

### Task 9: Test-support backends + sync queue / mapping tests

**Files:**
- Modify: `MoolahTests/Support/CloudKitAnalysisTestBackend.swift` (L17/L73), `MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift` (L244), `MoolahTests/Features/AuthStoreTests.swift` (L120) — these conform fake `BackendProvider`s; swap `dismissedTransferPairs` → `transferSuggestions` returning the GRDB repo (rename map).
- Modify: `MoolahTests/Sync/ProfileDataSyncHandlerQueueTests.swift` (L162–229) and `MoolahTests/Sync/RecordMappingTests.swift` (L245–247) — rehome the `DismissedTransferPair` queue/round-trip + malformed-id mapping tests onto `TransferSuggestion` (rename map; `suggestedAt` fixture).

- [ ] **Step 1: Apply rename map / rehome tests at the listed sites.** For `RecordMappingTests` add the `TransferSuggestionRow.fieldValues(from:)` malformed-id peer (a CKRecord missing/garbled `transactionIdA` → `nil`).

- [ ] **Step 2: Run the affected suites — expect GREEN**

Run: `just test-mac ProfileDataSyncHandlerQueueTests RecordMappingTests AuthStoreTests TransferSuggestionRepoContractTests 2>&1 | tee .agent-tmp/green9.txt | grep -E "Test run with|failed|error:"`
Expected: green. The repo contract test (Task 5) now links (backend exposes `transferSuggestions`) and passes.

- [ ] **Step 3: format-check + commit**
```bash
just format && just format-check 2>&1 | tail -1
git -C <worktree> add MoolahTests/Support/CloudKitAnalysisTestBackend.swift MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift MoolahTests/Features/AuthStoreTests.swift MoolahTests/Sync/ProfileDataSyncHandlerQueueTests.swift MoolahTests/Sync/RecordMappingTests.swift
git -C <worktree> commit -m "test(transfer-detection): rehome sync/mapping/support coverage onto TransferSuggestion"
```

> **REVIEW (Phase 3):** run `@sync-review` (record mapping, queue/delete, system fields, account-change/zone, conflict) and `@concurrency-review` (the new `@unchecked Sendable` repo, sync entry-point isolation). Apply all findings.

---

## Phase 4 — Detection coordinator

### Task 10: Coordinator writes/deletes the record (detect/dismiss/merge/unmerge)

**Files:**
- Modify: `Features/TransferDetection/TransferDetectionCoordinator.swift`
- Modify: `MoolahTests/Features/TransferDetectionScanTests.swift`, `MoolahTests/Features/TransferDetectionMergeTests.swift`
- Check: `MoolahTests/Support/TransferDetectionFixture.swift` (`makeCoordinator` injects `dismissedPairs:` — becomes `suggestions:`)

The coordinator currently: `annotate` sets `transaction.transferSuggestion` and `transactions.update`s both sides; `clearSuggestion` nils it; `dismiss` writes a `DismissedTransferPair` + clears both; `unmerge` splits + writes a `DismissedTransferPair`; `runDetection`'s `isDismissed` reads `dismissedPairs`. New behaviour:

- `init` takes `suggestions: any TransferSuggestionRepository` instead of `dismissedPairs:`.
- Detect: for each detected pair, `suggestions.create(TransferSuggestion(transactionIds:[a,b], suggestedAt: clock()))` (idempotent upsert). No `transactions.update`. **No `isDismissed` filter at all** — dismissal is now "the record does not exist", and detection only runs over genuinely-new transactions (Phase 5), so a previously-dismissed pair is never re-evaluated. Delete the `isDismissed` closure and the `dismissedPairs.fetchAll()` snapshot.
- `dismiss(_:_:)`: `suggestions.delete(id: TransferSuggestion.contentAddressedID(for: [sideA.id, sideB.id]))`. Nothing else (no transaction writes).
- `merge` / `manualMerge`: after the `transactions.replace(...)`, `suggestions.delete(id: TransferSuggestion.contentAddressedID(for: [sideA.id, sideB.id]))`.
- `unmerge`: split via `transactions.replace`; **remove** the `DismissedTransferPair` create entirely (design §Lifecycle — split products are not genuinely-new so never re-suggested; no tombstone). Drop the now-obsolete docstring paragraph about the best-effort dismissal write.
- Remove `annotate` and `clearSuggestion` (their callers are gone).

- [ ] **Step 1: Rewrite the Scan tests** for the record model. Replace assertions that read `outRow.transferSuggestion?…` with repository reads. Example replacement for `detectionWritesSuggestionOnBothSides`:
```swift
  @Test
  func detectionWritesOneSuggestionRecord() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let stamp = Date(timeIntervalSince1970: 1_700_500_000)
    let coordinator = Fixture.makeCoordinator(backend: backend, clock: { stamp })

    await coordinator.runDetection(
      newlyImported: [outgoing],
      participatingAccountIds: [Fixture.accountA],
      windowLowerBound: date.addingTimeInterval(-86_400))

    #expect(coordinator.error == nil)
    let suggestions = try await backend.transferSuggestions.fetchAll()
    #expect(suggestions.count == 1)
    let s = try #require(suggestions.first)
    #expect(s.transactionIds == [outgoing.id, incoming.id])
    #expect(s.suggestedAt == stamp)
    #expect(s.counterpart(of: outgoing.id) == incoming.id)
    // The transactions themselves are untouched (no denormalised write).
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }
```
  - `detectionSkipsDismissedPairs` → delete (there is no dismissed-pair concept). Replace with `dismissDeletesTheSuggestionRecord`:
```swift
  @Test
  func dismissDeletesTheSuggestionRecord() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)
    await coordinator.runDetection(
      newlyImported: [outgoing], participatingAccountIds: [Fixture.accountA],
      windowLowerBound: date.addingTimeInterval(-86_400))
    #expect(try await backend.transferSuggestions.fetchAll().count == 1)

    await coordinator.dismiss(outgoing, incoming)

    #expect(coordinator.error == nil)
    #expect(try await backend.transferSuggestions.fetchAll().isEmpty)
  }
```
  - `detectionIsIdempotent` → assert one record after 3 runs (`backend.transferSuggestions.fetchAll().count == 1`).
  - `alreadyMergedTransferIsNotResuggested` → after merge, `runDetection([mergedTx])`; assert `fetchAll().isEmpty` (a two-`.transfer`-leg tx is detection-ineligible).

- [ ] **Step 2: Rewrite the Merge tests.** `unmergeRoundTripsAndRecordsDismissal` → `unmergeRoundTripsAndDoesNotResuggest`:
```swift
  @Test
  func unmergeRoundTripsAndDoesNotResuggest() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Fixture.cashTx(account: Fixture.accountA, amount: -250, type: .expense, on: date)
    let incoming = Fixture.cashTx(account: Fixture.accountB, amount: 250, type: .income, on: date)
    TestBackend.seed(transactions: [incoming, outgoing], in: database)
    let coordinator = Fixture.makeCoordinator(backend: backend)
    await coordinator.merge(outgoing, incoming)
    let merged = try #require(try await backend.transactions.fetchAll(filter: TransactionFilter()).first)

    await coordinator.unmerge(merged)

    #expect(coordinator.error == nil)
    let splits = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(splits.count == 2)
    // No suggestion exists (merge deleted it; unmerge writes no tombstone).
    #expect(try await backend.transferSuggestions.fetchAll().isEmpty)
    // Unmerge feeds nothing to detection; the split products are not
    // genuinely-new so the next sync/import pass never re-evaluates them.
  }
```
  Update the atomicity/re-entrancy tests that construct `TransferDetectionCoordinator(transactions:dismissedPairs:)` → `(transactions:suggestions:)` using `backend.transferSuggestions`.

- [ ] **Step 3: Run — expect RED** (`backend.transferSuggestions` exists from Task 7/9, but the coordinator still uses `dismissedPairs`/annotate). Run: `just test-mac TransferDetectionScanTests TransferDetectionMergeTests 2>&1 | grep -E "error:|expect" | head`

- [ ] **Step 4: Rewrite `TransferDetectionCoordinator.swift`** per the bullets above. Key bodies:
```swift
  init(
    transactions: any TransactionRepository,
    suggestions: any TransferSuggestionRepository,
    detector: FuzzyTransferDetector = .init(),
    builder: TransferMergeBuilder = .init(),
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transactions = transactions
    self.suggestions = suggestions
    self.detector = detector
    self.builder = builder
    self.clock = clock
  }
```
  `runDetection` (drop the dismissed snapshot + `isDismissed`; detector now called with no dismissal filter — adjust `FuzzyTransferDetector.detect` signature to drop `isDismissed` (Task 10a)):
```swift
  func runDetection(
    newlyImported: [Transaction],
    participatingAccountIds: Set<UUID>,
    windowLowerBound: Date
  ) async {
    await mutate {
      let dateFloor = TransactionFilter(dateRange: windowLowerBound...Date.distantFuture)
      let candidatesInWindow = try await self.transactions.fetchAll(filter: dateFloor)
      let newlyImportedIds = Set(newlyImported.map(\.id))
      let existingNearby = candidatesInWindow.filter { transaction in
        !newlyImportedIds.contains(transaction.id)
          && transaction.accountIds.isDisjoint(with: participatingAccountIds)
      }
      let pairs = self.detector.detect(
        newlyImported: newlyImported, existingNearby: existingNearby)
      let stamp = self.clock()
      for pair in pairs {
        _ = try await self.suggestions.create(
          TransferSuggestion(
            transactionIds: [pair.newlyImported.id, pair.existingCounterpart.id],
            suggestedAt: stamp))
      }
    }
  }
```
  `dismiss` / `merge` / `manualMerge` / `unmerge`:
```swift
  func dismiss(_ sideA: Transaction, _ sideB: Transaction) async {
    await mutate {
      try await self.suggestions.delete(
        id: TransferSuggestion.contentAddressedID(for: [sideA.id, sideB.id]))
    }
  }

  func merge(_ sideA: Transaction, _ sideB: Transaction) async {
    await mutate {
      let merged = try self.builder.merged(from: sideA, sideB)
      _ = try await self.transactions.replace(
        deletingIds: [sideA.id, sideB.id], creating: [merged])
      try await self.suggestions.delete(
        id: TransferSuggestion.contentAddressedID(for: [sideA.id, sideB.id]))
    }
  }
  // manualMerge: identical tail (validate → builder.merged → replace → suggestions.delete(...)).

  func unmerge(_ transfer: Transaction) async {
    await mutate {
      let splits = try self.builder.split(transfer)
      _ = try await self.transactions.replace(
        deletingIds: [transfer.id], creating: splits)
    }
  }
```
  Delete `annotate`, `clearSuggestion`, the `dismissedPairs` stored property; rename it `suggestions`. Update class docstring (no "annotating both sides", no "recording a not-a-transfer dismissal" — now "writing/deleting a `TransferSuggestion` record").

- [ ] **Step 4a: Update `FuzzyTransferDetector.detect`** (`Shared/TransferDetection/FuzzyTransferDetector.swift`) — drop the `isDismissed` parameter and the `!isDismissed(imported.id, other.id)` guard. Update its unit tests in `MoolahTests/Shared/FuzzyTransferDetectorTests.swift` to drop the `isDismissed:` argument (rename map; the suite otherwise unchanged — pure pairing logic).

- [ ] **Step 5: Update `TransferDetectionFixture.makeCoordinator`** — inject `suggestions: backend.transferSuggestions`.

- [ ] **Step 6: Run — expect GREEN**

Run: `just test-mac TransferDetectionScanTests TransferDetectionMergeTests FuzzyTransferDetectorTests 2>&1 | tee .agent-tmp/green10.txt | grep -E "Test run with|failed|error:"`
Expected: all green.

- [ ] **Step 7: format-check + commit**
```bash
just format && just format-check 2>&1 | tail -1
git -C <worktree> add Features/TransferDetection/TransferDetectionCoordinator.swift Shared/TransferDetection/FuzzyTransferDetector.swift MoolahTests/Features/TransferDetectionScanTests.swift MoolahTests/Features/TransferDetectionMergeTests.swift MoolahTests/Shared/FuzzyTransferDetectorTests.swift MoolahTests/Support/TransferDetectionFixture.swift
git -C <worktree> commit -m "feat(transfer-detection): coordinator writes/deletes TransferSuggestion record; drop dismissal filter"
```

> **REVIEW (Phase 4):** run `@code-review` and `@concurrency-review` on the coordinator + detector. Apply all findings.

---

## Phase 5 — Sync trigger: genuinely-new only

### Task 11: `runApplyPass` returns survivors; `syncAccounts` feeds them to detection; delete the window

**Files:**
- Modify: `Features/Sync/SyncedAccountStore+Internals.swift` (`runApplyPass`, `runTransferDetection`)
- Modify: `Features/Sync/SyncedAccountStore.swift` (`syncAccounts`)
- Test: `MoolahTests/Features/` — add `SyncedAccountTransferTriggerTests.swift`

- [ ] **Step 1: Write the trigger test** — proves detection drives off `WalletApplyEngine`'s genuinely-new survivors, NOT a date window: seed an *existing* opposing-leg transaction on a non-synced account dated inside the 3-day window; run a sync whose apply pass persists exactly one genuinely-new opposing transaction on the synced account; assert exactly one `TransferSuggestion` for the new+existing pair; then add a SECOND existing pair (both pre-existing, both inside the window, none synced this pass) and re-run sync that creates nothing → assert NO new suggestion for the purely-existing pair (the deleted window behaviour would have suggested it). Use the existing crypto-sync test harness pattern (see `MoolahTests/Features/` crypto sync tests + `CryptoSyncBenchmarks` for `WalletApplyEngine.AccountInput` construction). If the harness cannot inject a deterministic apply-survivor set, drive `runApplyPass` via a seam: have it return `[Transaction]` and assert `syncAccounts` calls `transferDetection.runDetection(newlyImported:)` with exactly that set (spy coordinator).

- [ ] **Step 2: Run — expect RED.**

- [ ] **Step 3: Change `runApplyPass`** to return the survivors:
```swift
  func runApplyPass(
    perAccountResults: [PerAccountBuildResult]
  ) async -> [Transaction] {
    let inputs: [WalletApplyEngine.AccountInput] = perAccountResults.compactMap {
      if case let .success(input) = $0 { return input }
      return nil
    }
    do {
      return try await walletApplyEngine.apply(perAccount: inputs)
    } catch {
      Self.internalsLogger.warning(
        "WalletApplyEngine apply pass failed: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }
```

- [ ] **Step 4: Replace `runTransferDetection`** — it no longer fetches a window; it forwards the genuinely-new set:
```swift
  /// Runs detection over exactly the transactions this sync pass
  /// genuinely created (`WalletApplyEngine.apply`'s merged-and-deduped
  /// survivors). No date-window scan: a previously-existing transaction
  /// is never re-evaluated, so a dismissed/merged pair is never
  /// re-suggested (the record model has no negative-assertion tombstone).
  func runTransferDetection(
    genuinelyNew: [Transaction], participatingAccountIds: Set<UUID>
  ) async {
    guard !transferDetection.isMutating else {
      Self.internalsLogger.notice(
        "Transfer detection skipped — coordinator busy; a later pass covers new rows")
      return
    }
    let eligible = genuinelyNew.filter { $0.transferDetectionValueLeg != nil }
    guard !eligible.isEmpty else { return }
    let windowLowerBound = clock().addingTimeInterval(-FuzzyTransferDetector.windowSeconds)
    await transferDetection.runDetection(
      newlyImported: eligible,
      participatingAccountIds: participatingAccountIds,
      windowLowerBound: windowLowerBound)
  }
```
  (`windowLowerBound` still bounds the `existingNearby` counterpart fetch inside the coordinator — the pairing tolerance — it just no longer selects the *driver* set.)

- [ ] **Step 5: Update `syncAccounts`** — thread the survivors through:
```swift
    let perAccountResults = await runParallelBuilds(for: inputs)
    updateGlobalError(from: perAccountResults)
    let genuinelyNew = await runApplyPass(perAccountResults: perAccountResults)
    await refreshStateFromRepository()
    await runTransferDetection(
      genuinelyNew: genuinelyNew,
      participatingAccountIds: Set(inputs.map(\.id)))
```
  Update the comment above the detection call (the "candidate fetch" rationale no longer applies).

- [ ] **Step 6: Run — expect GREEN** (trigger test + the crypto-sync regression suites).
Run: `just test-mac SyncedAccountTransferTriggerTests SyncedAccountStoreTests 2>&1 | tee .agent-tmp/green11.txt | grep -E "Test run with|failed|error:"`
(Use the actual crypto-sync suite names present; discover with `git -C <worktree> ls-files MoolahTests | grep -i synced`.)

- [ ] **Step 7: format-check + commit**
```bash
just format && just format-check 2>&1 | tail -1
git -C <worktree> add Features/Sync/SyncedAccountStore.swift Features/Sync/SyncedAccountStore+Internals.swift MoolahTests/Features/SyncedAccountTransferTriggerTests.swift
git -C <worktree> commit -m "feat(transfer-detection): drive sync detection off genuinely-new survivors; delete 3-day window"
```

> **REVIEW (Phase 5):** run `@concurrency-review` (apply-pass return across awaits/actors) and `@code-review`. Apply findings.

---

## Phase 6 — UI/store read redirect + model cleanup

### Task 12: Redirect readers; remove `Transaction.transferSuggestion`; DataFormatVersion

**Files:**
- Modify: `Features/Transactions/TransactionStore+TransferDetection.swift` (L79–86 `suggestedCounterpart`)
- Modify: `Features/Import/RecentlyAddedViewModel.swift` (L123–136 `counterpart`, L170–194 `rowAccessibilityLabel`)
- Modify: `Features/Import/Views/RecentlyAddedRow.swift` (L91, L116–123)
- Modify: `Features/Transactions/Views/Detail/TransactionDetailTransferSuggestion.swift` (L33 body gate; `#Preview` L83/L108)
- Modify: `Shared/TransferDetection/TransferMergeBuilder.swift` (L49/L135 — drop the `transferSuggestion: nil` argument now that the field is gone)
- Modify: `App/UITestSeedHydrator+Upserts.swift` (L274 — drop seeding `transferSuggestion:`; seed a `TransferSuggestion` record via the repo instead if a seed needs the pill)
- Modify: `Domain/Models/Transaction.swift` (remove the `transferSuggestion` stored property + init param + assignment, lines 12/32/42)
- Modify: `Domain/Models/DataFormatVersion.swift` + its docstring (L31–36) per the `modifying-cloudkit-schema` rubric — incl. removing the stale `DismissedTransferPairRecord` reference at ~L36 and writing the v4 `History` entry
- **Parameter-label rename + ALL call sites (closes a Phase-4-review gap — REQUIRED).** Task 10 renamed the `TransferDetectionCoordinator` init param `dismissedPairs:` → `suggestions:`, but `TransactionStore.init` still declares `dismissedTransferPairs: (any DismissedTransferPairRepository)? = nil` and passes it as `dismissedPairs:`. Until this is fixed the app/benchmark targets do not build. In this task also:
  - `Features/Transactions/TransactionStore.swift` (~L147/151/153): rename the init parameter+stored member `dismissedTransferPairs: (any DismissedTransferPairRepository)?` → `transferSuggestions: (any TransferSuggestionRepository)?` and pass it to the coordinator as `suggestions:`. (The type `DismissedTransferPairRepository` no longer exists.)
  - Every `TransactionStore`/`TransferDetectionCoordinator` construction call site, updating both the argument label and (where still wrong) the value: `App/ProfileSession+Factories.swift` (~L283), `App/ProfileSession+CryptoSync.swift` (~L92), `App/ProfileSession+Imports.swift` (~L101) — pass `transferSuggestions: backend.transferSuggestions` / `suggestions: backend.transferSuggestions`.
  - `Features/Sync/SyncedAccountHeaderView+Previews.swift` (~L65): `session.backend.dismissedTransferPairs` → `session.backend.transferSuggestions`, label → `suggestions:`/`transferSuggestions:` as appropriate.
  - `MoolahBenchmarks/ImportPipelineBenchmarks.swift` (~L219) and `MoolahBenchmarks/CryptoSyncBenchmarks.swift` (~L191): `backend.dismissedTransferPairs` → `backend.transferSuggestions`, label updated. The benchmark target must compile.
  - After: `git -C <worktree> grep -rn "dismissedTransferPairs\|dismissedPairs\|DismissedTransferPair" -- Features/ App/ MoolahBenchmarks/ UITestSupport/ MoolahUITests_macOS/` → ZERO hits (production, benchmark, and UI-test-support). Stale comments in `UITestSupport/UITestSeed.swift` / `MoolahUITests_macOS/.../RecentlyAddedScreen.swift` are reworded by Task 10's fix commit; verify none remain here.
- Test: store/VM suites for the redirected reads

**Read-path design:** the UI needs "the suggested counterpart of transaction T (if any)". Provide it once, in the store layer (thin-view rule), backed by `transferSuggestions.suggestions(touching: T.id)` → take the single suggestion → `counterpart(of: T.id)` → fetch that transaction. Add a focused accessor on `TransactionStore` (or a small repository-backed helper the VM/store already owns) — do NOT read the repository from a view.

- [ ] **Step 1: Write/adjust the failing tests first** for each redirected behaviour:
  - `TransactionStore+TransferDetection` tests: `mergeSuggestedTransfer`/`dismissSuggestedTransfer` resolve the counterpart from the repo (seed a `TransferSuggestion` via `backend.transferSuggestions.create`, assert merge collapses to one tx and the record is deleted; dismiss deletes the record and leaves both tx).
  - `RecentlyAddedViewModel` tests: `counterpart(of:)` resolves via injected suggestions; `rowAccessibilityLabel` includes the pill phrase iff a suggestion record touches the row.
  - A model test asserting `Transaction` no longer has `transferSuggestion` is unnecessary (compile-time); instead ensure existing `Transaction` round-trip/codable tests still pass after removal.

- [ ] **Step 2: Run — expect RED.**

- [ ] **Step 3: Implement the store/VM accessor** and redirect every Section-5 reader to it. `TransactionStore+TransferDetection.suggestedCounterpart(of:)`:
```swift
  private func suggestedCounterpart(
    of transaction: Transaction
  ) async throws -> Transaction? {
    let touching = try await transferSuggestions.suggestions(touching: transaction.id)
    guard
      let counterpartId = touching.first?.counterpart(of: transaction.id)
    else { return nil }
    let all = try await repository.fetchAll(filter: TransactionFilter())
    return all.first { $0.id == counterpartId }
  }
```
  (Inject `transferSuggestions` into `TransactionStore` from `BackendProvider` where it is constructed — follow the existing repo-injection pattern in `TransactionStore`'s init.) For `RecentlyAddedViewModel`/`RecentlyAddedRow`/`TransactionDetailTransferSuggestion`, replace each `transaction.transferSuggestion != nil` gate and each `transaction.transferSuggestion?.counterpartTransactionId` lookup with the VM/store-resolved value (the VM holds a `[UUID: TransferSuggestion]` snapshot it loads from `transferSuggestions.observeAll()` / `suggestions(touching:)`; views read that, not the model). Update the `#Preview`s to build a `PreviewBackend` (or in-memory) with a seeded `TransferSuggestion` record rather than `Transaction(... transferSuggestion:)`.

- [ ] **Step 4: Remove `Transaction.transferSuggestion`** — delete the property (Transaction.swift line 12), the init parameter (line 32), and the assignment (line 42). Fix `TransferMergeBuilder` L49/L135 (drop the argument). Fix `UITestSeedHydrator+Upserts.swift` L274.

- [ ] **Step 5: DataFormatVersion — BINDING RULING: bump `current` 3 → 4.** The Phase 2 `@database-schema-review` gate (the binding authority for this decision per the plan) ruled that adding the new `TransferSuggestionRecord` record type AND removing `DismissedTransferPairRecord` + the two `TransactionRecord.transferSuggestion*` fields are forward-incompatible changes (DataFormatVersion rubric items 1 + 6), so `DataFormatVersion.current` MUST bump from `3` to `4` with a new `History` entry describing the transfer-suggestion-record reshape. (The earlier "keep 3 with revised meaning" option is now closed — the gate decided.) Edit `Domain/Models/DataFormatVersion.swift`: set `current = 4`; add the new `History` case/entry following the existing pattern for v3; update the docstring (L31–36) to describe v4. `MoolahTests/Domain/DataFormatVersionTests.swift` asserts only `>= 1` so it still passes (no edit needed — verify); `MoolahTests/App/DataFormatVersionBumpTests.swift` references `current` symbolically (uses `current - 1`) so it auto-tracks — verify it still compiles/passes. Do this via the `modifying-cloudkit-schema` runbook (invoked in Task 7) so the `History` entry wording matches the runbook's required form.

- [ ] **Step 6: Run the redirected suites + a broad sanity pass — expect GREEN.**
Run: `just test-mac TransactionStoreTransferDetectionTests RecentlyAddedViewModelTests TransactionDetailTransferSuggestionTests DataFormatVersionTests DataFormatVersionBumpTests 2>&1 | tee .agent-tmp/green12.txt | grep -E "Test run with|failed|error:"`
(Discover exact suite names via `git -C <worktree> ls-files MoolahTests | grep -iE "RecentlyAdded|TransactionStore|TransferSuggestion"`.)

- [ ] **Step 7: format-check + commit**
```bash
just format && just format-check 2>&1 | tail -1
git -C <worktree> add -A
git -C <worktree> commit -m "feat(transfer-detection): record-backed suggestion read path; remove Transaction.transferSuggestion"
```

---

## Phase 7 — Full verification & ship

### Task 13: Whole-suite green, reviews, PR, merge queue

- [ ] **Step 1: Clean generate + full build (both platforms) + format-check**
```bash
just generate 2>&1 | tail -2
just build-mac 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | grep -v Preview | tail -5
just format-check 2>&1 | tail -1
```
Expected: BUILD SUCCEEDED (no Swift warnings — warnings are errors), format-check clean.

- [ ] **Step 2: Full test suite**
```bash
just test 2>&1 | tee .agent-tmp/full.txt | grep -E "Test run with|All tests passed|failed|error:"
grep -iE '\bfailed\b|error:' .agent-tmp/full.txt | grep -v "0 failures" | head
```
Expected: all tests passed on iOS sim + macOS. Investigate any failure with `systematic-debugging`; never weaken a test to pass. If the macOS UI host wedges, gate on the PR's CI UI-Test job instead (see `feedback_pr_ci_gate_when_ui_host_blocked`).

- [ ] **Step 3: Grep for leftover references** — there must be NONE outside git history:
```bash
git -C <worktree> grep -nE "DismissedTransferPair|dismissed_transfer_pair|dismissedTransferPairs|\.transferSuggestion\b|transferSuggestionCounterpartId|transfer_suggestion_counterpart_id" -- ':!plans/*' ':!*.md' || echo "clean"
```
Expected: `clean`. (`plans/` design+plan docs legitimately mention the old names.)

- [ ] **Step 4: Final review gate** — run `@code-review`, `@concurrency-review`, `@sync-review`, `@database-schema-review`, `@database-code-review`, and `@ui-review` (the redirected pill/banner/Recently-Added views). Apply every Critical/Important/Minor finding. Re-run the relevant suite + `just format-check` after fixes; commit.

- [ ] **Step 5: Clean temp + open the PR**
```bash
rm -f .agent-tmp/*.txt .agent-tmp/dossier.md
git -C <worktree> push origin feat/transfer-suggestion-record:feat/transfer-suggestion-record
gh pr create --title "feat(transfer-detection): transfer suggestion as a first-class synced record" --body "$(cat <<'EOF'
## Summary
- Replaces the denormalised `TransferSuggestion` transaction annotation + the `DismissedTransferPair` negative-assertion table with a single synced `TransferSuggestion` record (detect = upsert, dismiss/merge/unmerge = delete).
- Unifies the detection trigger: crypto/exchange sync now drives detection off `WalletApplyEngine`'s genuinely-new survivor set instead of a 3-day rolling window, so no tombstone is needed to stop re-suggestion.
- Removes `DismissedTransferPair` and the two `TransactionRecord.transferSuggestion*` columns entirely (unshipped — no deprecation; validated against the prod schema baseline via the modifying-cloudkit-schema runbook).
- v13 GRDB migration: drop `dismissed_transfer_pair` + the two denormalised columns, create `transfer_suggestion`. No data backfill (tombstones have no meaning in the new model).

Design: `plans/2026-05-19-transfer-suggestion-record-design.md`. Plan: `plans/2026-05-19-transfer-suggestion-record-implementation.md`.

Migration-policy decision (per @database-schema-review): <record the new-v13-vs-in-place ruling here>.
DataFormatVersion decision (per modifying-cloudkit-schema runbook): <record keep-3 vs bump-4 ruling + baseline-check result here>.

## Test plan
- [ ] `just test` green (iOS sim + macOS)
- [ ] New: TransferSuggestion entity/repo-contract/rollback/query-plan/hook-record-type/migration-v13/sync-trigger suites
- [ ] Rehomed: scan/merge/mapping/queue/support suites
- [ ] `just format-check` clean; warning-free build
- [ ] Reviews applied: code, concurrency, sync, database-schema, database-code, ui

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 6: Add the PR to the merge queue** (per project policy — every PR goes through the merge-queue skill, not a manual merge):
```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR_NUMBER>
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh status
```

---

## Self-review notes (author)

- **Spec coverage:** data model (Task 1), repository (Task 2), removal of DismissedTransferPair + columns (Tasks 3/7/8), v13 migration no-backfill (Task 3), CloudKit record + generated layer (Task 7), sync plumbing (Tasks 7–9), detect/dismiss/merge/unmerge lifecycle (Task 10), unmerge-does-not-resuggest (Task 10 test), genuinely-new trigger for crypto/exchange (Task 11), CSV path already correct (unchanged — verified: `ImportStore` passes `imported`), UI read redirect (Task 12), cross-device correctness (record create/delete syncs — Tasks 7–9 sync suites), testing (every phase), DataFormatVersion (Task 12 via runbook). All spec sections map to a task.
- **Full physical removal is final (not a gate):** the top-of-plan callout and Task 7 Step 1 state the decision unambiguously. The prod-baseline check is evidence-gathering for the PR, NOT a branch back to deprecation. The CI additivity gate is expected to object; the plan pre-authorises working around it (baseline advance / sanctioned override) and explicitly forbids retreating to deprecation. Reviewers will re-raise this every pass — the schema-site comment + PR rationale exist to short-circuit that.
- **Type consistency:** `transferSuggestions` (BackendProvider member), `TransferSuggestion` (entity), `TransferSuggestionRow`, `TransferSuggestionRecord` (wire), `transfer_suggestion` (table), `suggested_at`/`suggestedAt`, `contentAddressedID(for:)`, `counterpart(of:)`, `suggestions(touching:)`, `runTransferDetection(genuinelyNew:participatingAccountIds:)`, `runApplyPass -> [Transaction]` — used consistently across Tasks 1–12.
- **No placeholders:** every code step shows full code or an exact copy-from-path + rename-map + explicit deltas; every run step has an exact `just` command and expected output.
