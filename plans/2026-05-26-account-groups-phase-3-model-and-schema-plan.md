# Account Groups — Phase 3 Implementation Plan: Model + schema

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the `AccountGroup` domain model, `Account.groupId` back-reference, the CKDB record type, the GRDB table + migration, and the local repository — enough for groups to be created, edited, and rendered from local state. Sync wiring (uploading / receiving `AccountGroupRecord`s cross-device) is **Phase 7**; this PR ships local-only group support without breaking existing Account upload round-trips.

**Architecture:** New `AccountGroup` value type alongside `Account`. Membership is a single nullable `groupId: UUID?` field on `Account` (back-reference; no list field on the group — see spec for sync-conflict rationale). A new `account_group` GRDB table; an additive `group_id` column on `account` with **no FK constraint** (dangling resolves to nil at the lookup layer, same pattern as Category). `AccountGroupRepository` follows the existing `EarmarkRepository` shape: CRUD + observation. `BackendProvider` gains `accountGroups`. `DataFormatVersion` bumps 4 → 5.

**Tech Stack:** Swift, GRDB (STRICT tables, additive migrations), CKDB schema + `just generate`, Swift Testing.

**Spec:** `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-groups-design/plans/2026-05-26-account-groups-design.md` — see "Model" and "Sync & schema".

**Phase ordering:** Depends on **Phase 1** ([#976](https://github.com/moolah-rocks/moolah-native/pull/976)) — `AccountGroup.bucket: AccountBucket` requires that type to exist. If Phase 1 is already merged, branch off `origin/main`. If not, branch off Phase 1's `account-bucket` branch and stack the PR; `landing-prs/land-pr.sh` handles the retargeting once Phase 1 merges.

**Out of scope** (Phase 7): `AccountGroupRow` does NOT conform to `CloudKitRecordConvertible`, is NOT in `RecordTypeRegistry.allTypes`, and is NOT in the apply-batch dispatch. Local writes commit to GRDB and stay local. The CKDB schema *does* declare the record type and `Account.groupId` field — without that declaration in place, the `Account.groupId` round-trip changes added in this PR would strip the field on every Account upload, corrupting other clients. With the schema declared and the `AccountRow` mapping round-tripping `groupId` end-to-end, the v4 → v5 build is safe to publish even though the `AccountGroupRecord`s themselves never reach CloudKit until Phase 7 ships.

---

## Worktree setup

- [ ] **Step 1: Decide base branch**

If [#976](https://github.com/moolah-rocks/moolah-native/pull/976) (Phase 1) is merged on `main`, base off `origin/main`. Otherwise base off `origin/account-bucket` (Phase 1's branch) and the resulting PR stacks on #976.

Confirm Phase 1's merge status:

```bash
gh pr view 976 --json state,mergedAt --jq '{state, mergedAt}'
```

- [ ] **Step 2: Create the worktree**

```bash
# If Phase 1 has merged:
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track \
  .worktrees/account-group-model -b account-group-model origin/main

# If Phase 1 has NOT merged (stacked):
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track \
  .worktrees/account-group-model -b account-group-model origin/account-bucket
```

`--no-track` is mandatory per `CLAUDE.md` — without it a stacked-PR first push would clobber the parent branch.

- [ ] **Step 3: Generate Xcode project + verify clean build**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model \
     --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model/justfile generate

just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model \
     --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model/justfile build-mac 2>&1 | tail -5
```

Expected: clean build, no warnings.

- [ ] **Step 4: Working directory is the worktree from here on**

Every command below assumes cwd `=/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model`.

---

## Task 1: Add the `AccountGroup` domain model

**Files:**
- Create: `Domain/Models/AccountGroup.swift`
- Create: `MoolahTests/Domain/AccountGroupTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Domain/AccountGroupTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountGroup")
struct AccountGroupTests {
  @Test
  func memberwiseInitDefaultsExpandedFalse() {
    let group = AccountGroup(
      name: "Trust Fund Crypto",
      bucket: .investments,
      instrument: .AUD
    )
    #expect(group.isExpandedInSidebar == false)
  }

  @Test
  func roundTripsThroughCodable() throws {
    let original = AccountGroup(
      id: UUID(),
      name: "Personal Crypto",
      bucket: .investments,
      instrument: .AUD,
      position: 3,
      isExpandedInSidebar: true
    )
    let encoded = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(AccountGroup.self, from: encoded)

    #expect(restored == original)
  }

  @Test
  func hashableUsesId() {
    let id = UUID()
    let a = AccountGroup(id: id, name: "A", bucket: .investments, instrument: .AUD)
    let b = AccountGroup(id: id, name: "B", bucket: .current, instrument: .USD)
    var set: Set<AccountGroup> = [a]
    set.insert(b)
    // Different content, same id → set still has both because Hashable uses
    // the synthesised field-hash. The point of this test is to lock in
    // value-semantics (no id-only equality) — if you change the Hashable
    // impl to id-only, this test fails and forces a design conversation.
    #expect(set.count == 2)
  }

  @Test
  func comparableSortsByPosition() {
    let g1 = AccountGroup(name: "A", bucket: .investments, instrument: .AUD, position: 2)
    let g2 = AccountGroup(name: "B", bucket: .investments, instrument: .AUD, position: 0)
    let g3 = AccountGroup(name: "C", bucket: .investments, instrument: .AUD, position: 1)
    let sorted = [g1, g2, g3].sorted()
    #expect(sorted.map(\.name) == ["B", "C", "A"])
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
just test AccountGroupTests 2>&1 | tee .agent-tmp/test-pg3-1.txt
```

Expected: build failure with "Cannot find 'AccountGroup' in scope".

- [ ] **Step 3: Create the `AccountGroup` model**

Create `Domain/Models/AccountGroup.swift`:

```swift
import Foundation

/// A named, ordered grouping of accounts that share a sidebar bucket.
/// Members are discovered by querying accounts whose `groupId` equals
/// this group's `id` — there is intentionally no member-list field
/// here (see `plans/2026-05-26-account-groups-design.md` for the
/// CloudKit-conflict rationale).
///
/// `bucket` is set on creation and immutable in v1; the UI enforces
/// same-bucket membership at the drop / move layer.
///
/// `isExpandedInSidebar` is a local-only preference and is never
/// persisted to CloudKit — Phase 8 introduces a sidecar GRDB table
/// for it; until then this field is best-effort in-memory only.
///
/// SyncBoundary — introducing this type requires bumping
/// `DataFormatVersion.current`.
struct AccountGroup {
  let id: UUID
  var name: String
  var bucket: AccountBucket
  var instrument: Instrument
  var position: Int
  var isExpandedInSidebar: Bool

  init(
    id: UUID = UUID(),
    name: String,
    bucket: AccountBucket,
    instrument: Instrument,
    position: Int = 0,
    isExpandedInSidebar: Bool = false
  ) {
    self.id = id
    self.name = name
    self.bucket = bucket
    self.instrument = instrument
    self.position = position
    self.isExpandedInSidebar = isExpandedInSidebar
  }
}

extension AccountGroup: Identifiable {}
extension AccountGroup: Sendable {}
extension AccountGroup: Hashable {}
extension AccountGroup: Codable {}

extension AccountGroup: Comparable {
  static func < (lhs: AccountGroup, rhs: AccountGroup) -> Bool {
    lhs.position < rhs.position
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
just test AccountGroupTests 2>&1 | tee .agent-tmp/test-pg3-1.txt
grep -i 'failed\|error:' .agent-tmp/test-pg3-1.txt || echo "OK"
```

Expected: all 4 tests pass.

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model add \
  Domain/Models/AccountGroup.swift \
  MoolahTests/Domain/AccountGroupTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model commit -m "feat(domain): add AccountGroup value type

A named, ordered grouping of accounts sharing a sidebar bucket.
Membership is back-referenced from Account.groupId (added in a
follow-up commit); no member-list field here, per the CloudKit
conflict rationale in the design spec."
```

---

## Task 2: Add `groupId` to `Account`

**Files:**
- Modify: `Domain/Models/Account.swift` (struct Account + extensions)
- Modify: `MoolahTests/Domain/AccountTypeTests.swift` (or a new sibling file — keep with the rest of Account domain tests)

- [ ] **Step 1: Write the failing tests**

Append to `MoolahTests/Domain/AccountTypeTests.swift` inside the existing `struct AccountTypeTests` suite:

```swift
  @Test
  func accountGroupIdDefaultsToNil() {
    let account = Account(name: "Chequing", type: .bank, instrument: .AUD)
    #expect(account.groupId == nil)
  }

  @Test
  func accountWithGroupIdIsCodable() throws {
    let id = UUID()
    let groupId = UUID()
    let account = Account(
      id: id,
      name: "Coinstash",
      type: .exchange,
      instrument: .AUD,
      exchangeProvider: .coinstash,
      groupId: groupId
    )
    let encoded = try JSONEncoder().encode(account)
    let restored = try JSONDecoder().decode(Account.self, from: encoded)
    #expect(restored.groupId == groupId)
  }

  @Test
  func accountWithoutGroupIdRoundTripsAsNil() throws {
    // Backwards-compat: a JSON blob from an older build (no groupId key)
    // must decode with groupId == nil. Pretend an older blob by writing
    // one without the field and decoding via Account's Codable.
    let json = Data(#"""
      {"id":"\#(UUID().uuidString)","name":"Legacy",
       "type":"bank","instrument":"AUD","position":0,"hidden":false,
       "valuationMode":"recordedValue"}
      """#.utf8)
    let account = try JSONDecoder().decode(Account.self, from: json)
    #expect(account.groupId == nil)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
just test AccountTypeTests 2>&1 | tee .agent-tmp/test-pg3-2.txt
```

Expected: build failure with "extra argument 'groupId' in call".

- [ ] **Step 3: Add the `groupId` field**

In `Domain/Models/Account.swift`:

(a) Add a `var groupId: UUID?` field to the `struct Account` body. Insert immediately after the existing `var valuationMode: ValuationMode` line (around line 65):

```swift
  /// Optional back-reference into `AccountGroup.id`. When non-nil, this
  /// account renders as a member of the group; when nil, it renders as
  /// a standalone row in its bucket. The lookup layer treats unknown
  /// ids (e.g. group not yet arrived via sync) as nil — there is no FK
  /// enforcement in GRDB and the resolver gracefully degrades.
  /// See `plans/2026-05-26-account-groups-design.md` "Sync & schema".
  var groupId: UUID?
```

(b) Add `groupId` to the memberwise initializer (around line 67-92). The initializer becomes:

```swift
  init(
    id: UUID = UUID(),
    name: String,
    type: AccountType,
    instrument: Instrument,
    positions: [Position] = [],
    position: Int = 0,
    isHidden: Bool = false,
    valuationMode: ValuationMode = .recordedValue,
    walletAddress: String? = nil,
    chainId: Int? = nil,
    exchangeProvider: ExchangeProvider? = nil,
    groupId: UUID? = nil
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.instrument = instrument
    self.positions = positions
    self.position = position
    self.isHidden = isHidden
    self.valuationMode = valuationMode
    self.walletAddress = walletAddress
    self.chainId = chainId
    self.exchangeProvider = exchangeProvider
    self.groupId = groupId
  }
```

(c) Add `groupId` to `CodingKeys` (around line 99-109):

```swift
  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case type
    case instrument
    case position
    case isHidden = "hidden"
    case valuationMode
    case walletAddress
    case chainId
    case exchangeProvider
    case groupId
  }
```

(d) Add the decode line in `init(from:)` (around line 138, after the `exchangeProvider` decode):

```swift
    groupId = try container.decodeIfPresent(UUID.self, forKey: .groupId)
```

(e) Add the encode line in `encode(to:)` (around line 153, after the `exchangeProvider` encode):

```swift
    try container.encodeIfPresent(groupId, forKey: .groupId)
```

(f) Add `groupId` to `Hashable`'s `==` and `hash(into:)` (around lines 157-180):

```swift
  static func == (lhs: Account, rhs: Account) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name && lhs.type == rhs.type
      && lhs.instrument == rhs.instrument
      && lhs.position == rhs.position && lhs.isHidden == rhs.isHidden
      && lhs.valuationMode == rhs.valuationMode
      && lhs.walletAddress == rhs.walletAddress && lhs.chainId == rhs.chainId
      && lhs.exchangeProvider == rhs.exchangeProvider
      && lhs.groupId == rhs.groupId
      && lhs.positions == rhs.positions
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(name)
    hasher.combine(type)
    hasher.combine(instrument)
    hasher.combine(position)
    hasher.combine(isHidden)
    hasher.combine(valuationMode)
    hasher.combine(walletAddress)
    hasher.combine(chainId)
    hasher.combine(exchangeProvider)
    hasher.combine(groupId)
    hasher.combine(positions)
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
just test AccountTypeTests 2>&1 | tee .agent-tmp/test-pg3-2.txt
grep -i 'failed\|error:' .agent-tmp/test-pg3-2.txt || echo "OK"
```

Expected: all `AccountTypeTests` pass (including pre-existing bucket / type tests).

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model add \
  Domain/Models/Account.swift \
  MoolahTests/Domain/AccountTypeTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model commit -m "feat(domain): add Account.groupId back-reference

Optional UUID pointing at an AccountGroup. Nil = standalone in
bucket. Unknown ids resolve to nil at the lookup layer (no FK in
GRDB; same pattern as Category resolution). Codable backward-compat
verified via a no-groupId JSON blob decoding as nil."
```

---

## Task 3: Update the CKDB schema and regenerate the wire layer

**Files:**
- Modify: `CloudKit/schema.ckdb`
- Regenerate (auto): `Backends/CloudKit/Sync/Generated/AccountGroupRecordCloudKitFields.swift` (new), `Backends/CloudKit/Sync/Generated/AccountRecordCloudKitFields.swift` (modified)

Follow the `modifying-cloudkit-schema` skill for the full procedure (lives at `.claude/skills/modifying-cloudkit-schema/`). Steps below are the moolah-specific edits.

- [ ] **Step 1: Add the new `AccountGroupRecord` record type**

In `CloudKit/schema.ckdb`, insert a new `RECORD TYPE AccountGroupRecord (…);` block in the alphabetical order — between `AccountRecord` and `CategoryRecord`. The block:

```ckdb
    RECORD TYPE AccountGroupRecord (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        bucket          STRING QUERYABLE SEARCHABLE SORTABLE,
        instrumentId    STRING QUERYABLE SEARCHABLE SORTABLE,
        name            STRING QUERYABLE SEARCHABLE SORTABLE,
        position        INT64 QUERYABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );
```

`isExpandedInSidebar` is intentionally NOT on the wire — it's local-only.

- [ ] **Step 2: Add the `groupId` field to `AccountRecord`**

In the same file, in the existing `RECORD TYPE AccountRecord (...);` block, add a new field. Keep alphabetical order in the field list:

```ckdb
        groupId         STRING QUERYABLE SEARCHABLE SORTABLE,
```

Insert immediately after the `exchangeProvider` line (or wherever alphabetical order puts it — `g` follows `e`/`f`). Store as `STRING` (not `REFERENCE`) so a dangling id is a benign string value rather than a CloudKit-reported broken reference; the lookup layer treats it as nil.

- [ ] **Step 3: Run `just generate` to regenerate the wire layer + Xcode project**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model \
     --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model/justfile generate
```

Expected output: `CKDBSchemaGen` produces `AccountGroupRecordCloudKitFields.swift` (new) under `Backends/CloudKit/Sync/Generated/` and updates `AccountRecordCloudKitFields.swift` to include a `groupId: String?` field. Xcodegen updates `Moolah.xcodeproj`.

If `just generate` errors with "schema not additive" — that's the additivity guard refusing the change. Re-read the diff to `schema.ckdb`; an additive change is: new record type, or new non-required field on an existing record type. The above changes meet both criteria.

- [ ] **Step 4: Run the CKDB schema-gen tool's tests**

```bash
swift test --package-path /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model/tools/CKDBSchemaGen 2>&1 | tail -20
```

Expected: all `EqualityTests`, `GeneratorTests`, `ParserTests`, `AdditivityTests` pass. If `AdditivityTests` fails, the schema change isn't additive — back out and rethink (e.g. you may have changed a field type or made an existing field required).

- [ ] **Step 5: Build the main project to confirm the regenerated wire layer compiles**

```bash
just build-mac 2>&1 | tee .agent-tmp/test-pg3-3.txt
grep -E 'error:' .agent-tmp/test-pg3-3.txt || echo "OK"
```

Expected: clean build. (No tests added in this task — the schema gen tool's tests above are the verification.)

- [ ] **Step 6: Commit the schema + generated files**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model add \
  CloudKit/schema.ckdb \
  Backends/CloudKit/Sync/Generated/AccountGroupRecordCloudKitFields.swift \
  Backends/CloudKit/Sync/Generated/AccountRecordCloudKitFields.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model commit -m "feat(cloudkit): add AccountGroupRecord schema + Account.groupId field

Additive CKDB change. Wire layer regenerated via just generate.
The new record type and field are declared but not yet uploaded /
downloaded — that's Phase 7 (sync wiring). Declaring the schema now
prevents Account uploads from this build from stripping a groupId
field that older clients might have written."
```

Note: production schema is **not** imported via `cktool` from this PR. Schema rollout happens at release time per `modifying-cloudkit-schema/SKILL.md`.

---

## Task 4: Add the `account_group` table migration

**Files:**
- Create: `Backends/GRDB/ProfileSchema+AccountGroups.swift`
- Modify: `Backends/GRDB/ProfileSchema.swift` (register the new migration)

- [ ] **Step 1: Write the migration body**

Create `Backends/GRDB/ProfileSchema+AccountGroups.swift`:

```swift
import Foundation
import GRDB

extension ProfileSchema {
  /// v14 migration body. Adds the `account_group` table (synced via
  /// CKSyncEngine — Phase 7) and an additive `group_id` column on
  /// `account` for the back-reference.
  ///
  /// Per the design spec (`plans/2026-05-26-account-groups-design.md`,
  /// "Sync & schema"), `account.group_id` is **not** declared as a
  /// foreign key. Sync delivery can place an Account ahead of its
  /// AccountGroup; an FK would reject the insert. The lookup layer
  /// treats unknown ids as nil and the account renders as standalone
  /// until the group arrives.
  ///
  /// `STRICT` per `guides/DATABASE_SCHEMA_GUIDE.md`. Rowid table (no
  /// `WITHOUT ROWID`) — same constraint as v12 / v13: `upsert` emits
  /// `RETURNING "rowid"` for the repository's optimistic write path,
  /// and `ValueObservation` hooks require a rowid table.
  static func addAccountGroups(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE account_group (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            name                   TEXT    NOT NULL,
            bucket                 TEXT    NOT NULL,
            instrument_id          TEXT    NOT NULL,
            position               INTEGER NOT NULL,
            encoded_system_fields  BLOB
        ) STRICT;

        CREATE INDEX account_group_by_bucket_position
            ON account_group (bucket, position);

        ALTER TABLE account ADD COLUMN group_id BLOB;
        CREATE INDEX account_by_group_id ON account (group_id);
        """)
  }
}
```

- [ ] **Step 2: Register the migration in `ProfileSchema.swift`**

In `Backends/GRDB/ProfileSchema.swift`:

(a) Append to the migration-history doc comment (after the `v13_transfer_suggestion_record` entry, around line 70-71):

```swift
/// `v14_account_groups` — adds the `account_group` table and an
/// additive `group_id` column on `account` (no FK; see
/// `ProfileSchema+AccountGroups.swift` for the sync-ordering
/// rationale). See `ProfileSchema+AccountGroups.swift`.
```

(b) Bump `static let version = 13` → `static let version = 14` (around line 91).

(c) Register the migration after the v13 line (around line 124):

```swift
    migrator.registerMigration(
      "v14_account_groups", migrate: addAccountGroups)
```

- [ ] **Step 3: Add a migration smoke test**

Find the existing migration smoke tests (search for `addTransferSuggestion` references in `MoolahTests/`):

```bash
grep -rln "addTransferSuggestion\|v13_transfer_suggestion" /Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests 2>/dev/null
```

Mirror that pattern in a new file `MoolahTests/Backends/GRDB/AccountGroupsMigrationTests.swift` (create the directory if it doesn't exist):

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v14_account_groups migration")
struct AccountGroupsMigrationTests {
  @Test
  func createsAccountGroupTableAndGroupIdColumnOnAccount() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)

    try queue.read { db in
      // account_group table exists
      let tables = try Row.fetchAll(db, sql:
        "SELECT name FROM sqlite_master WHERE type='table' AND name='account_group'"
      )
      #expect(tables.count == 1)

      // group_id column exists on account
      let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(account)")
        .map { $0["name"] as String }
      #expect(cols.contains("group_id"))

      // No FK constraint on group_id
      let fks = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(account)")
      let groupFK = fks.first { $0["from"] as? String == "group_id" }
      #expect(groupFK == nil, "account.group_id must not have a FK constraint")

      // Indexes present
      let indexes = try Row.fetchAll(db, sql:
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name IN ('account_group', 'account')"
      ).map { $0["name"] as String }
      #expect(indexes.contains("account_group_by_bucket_position"))
      #expect(indexes.contains("account_by_group_id"))
    }
  }

  @Test
  func accountGroupTableIsStrict() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)

    try queue.read { db in
      let row = try Row.fetchOne(db, sql:
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='account_group'"
      )
      let sql = row?["sql"] as String? ?? ""
      #expect(sql.uppercased().contains("STRICT"))
    }
  }
}
```

If the test directory `MoolahTests/Backends/GRDB/` doesn't exist, create it. Confirm with the project's test target by glancing at `project.yml` to make sure the new path is included — likely covered by a glob like `MoolahTests/**`.

- [ ] **Step 4: Run the migration tests**

```bash
just test AccountGroupsMigrationTests 2>&1 | tee .agent-tmp/test-pg3-4.txt
grep -i 'failed\|error:' .agent-tmp/test-pg3-4.txt || echo "OK"
```

Expected: all migration tests pass.

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model add \
  Backends/GRDB/ProfileSchema+AccountGroups.swift \
  Backends/GRDB/ProfileSchema.swift \
  MoolahTests/Backends/GRDB/AccountGroupsMigrationTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model commit -m "feat(grdb): v14 migration — account_group table + group_id column

STRICT account_group; no FK on account.group_id (sync ordering can
deliver Account before AccountGroup — lookup gracefully degrades).
Indexes on bucket+position and group_id. Migration smoke tests
assert table presence, STRICT, FK absence, and index presence."
```

---

## Task 5: Add `AccountGroupRow` (GRDB record)

**Files:**
- Create: `Backends/GRDB/Records/AccountGroupRow.swift`
- Create: `Backends/GRDB/Records/AccountGroupRow+Mapping.swift`
- Create: `Backends/GRDB/Records/AccountGroupRow+ObservableRegion.swift`

This mirrors the EarmarkRow / AccountRow file layout. No `CloudKitRecordConvertible` conformance — Phase 7 adds that.

- [ ] **Step 1: Create `AccountGroupRow.swift`**

```swift
// Backends/GRDB/Records/AccountGroupRow.swift

import Foundation
import GRDB

/// One row in the `account_group` table.
struct AccountGroupRow {
  static let databaseTableName = "account_group"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case name
    case bucket
    case instrumentId = "instrument_id"
    case position
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case name
    case bucket
    case instrumentId = "instrument_id"
    case position
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var name: String
  /// Raw value of `AccountBucket` (`"current"` / `"investments"`).
  var bucket: String
  var instrumentId: String
  var position: Int
  var encodedSystemFields: Data?
}

extension AccountGroupRow: Codable {}
extension AccountGroupRow: Sendable {}
extension AccountGroupRow: Identifiable {}
extension AccountGroupRow: FetchableRecord {}
extension AccountGroupRow: PersistableRecord {}
extension AccountGroupRow: GRDBSystemFieldsStampable {}
```

- [ ] **Step 2: Create `AccountGroupRow+Mapping.swift`**

```swift
// Backends/GRDB/Records/AccountGroupRow+Mapping.swift

import Foundation

extension AccountGroupRow {
  /// The CloudKit recordType on the wire. Frozen contract.
  static let recordType = "AccountGroupRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed group.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  init(domain: AccountGroup) {
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    self.name = domain.name
    self.bucket = domain.bucket.rawValue
    self.instrumentId = domain.instrument.id
    self.position = domain.position
    self.encodedSystemFields = nil
  }

  /// Domain projection. `isExpandedInSidebar` defaults to false — the
  /// expand state is local-only and lives in a separate sidecar
  /// (Phase 8); the row layer is unaware of it.
  func toDomain(defaultInstrument: Instrument) -> AccountGroup {
    let instrument: Instrument
    if let inst = Instrument.fiat(code: instrumentId) as Instrument? {
      instrument = inst
    } else {
      instrument = defaultInstrument
    }
    let resolvedBucket = AccountBucket(rawValue: bucket) ?? .current
    return AccountGroup(
      id: id,
      name: name,
      bucket: resolvedBucket,
      instrument: instrument,
      position: position,
      isExpandedInSidebar: false
    )
  }
}
```

Note on `bucket` fallback: if a future case is added and an older build reads it, the fallback is `.current` (matches the existing AccountType "unknown → asset" defensive pattern in `AccountRow.safeAccountTypeRaw`). The `DataFormatVersion` gate is the real protection; this is belt-and-braces.

- [ ] **Step 3: Create `AccountGroupRow+ObservableRegion.swift`**

```swift
// Backends/GRDB/Records/AccountGroupRow+ObservableRegion.swift

import Foundation
import GRDB

extension AccountGroupRow {
  /// Column-restricted region UI `ValueObservation`s pass to
  /// `tracking(regions:fetch:)`. Same pattern as
  /// `AccountRow+ObservableRegion.swift`; the encoded-system-fields
  /// blob is excluded so a system-fields write (sync metadata only,
  /// no user-visible change) doesn't trigger a UI recompute.
  static var observableRegion: QueryInterfaceRequest<AccountGroupRow> {
    let columns: [any SQLSelectable] = Columns.allCases
      .filter { $0 != .encodedSystemFields }
      .map { $0 as any SQLSelectable }
    return select(columns)
  }
}
```

- [ ] **Step 4: Add unit tests for the row → domain mapping**

Append to (or create) `MoolahTests/Backends/GRDB/AccountGroupsMigrationTests.swift`:

```swift
@Suite("AccountGroupRow mapping")
struct AccountGroupRowMappingTests {
  @Test
  func domainRoundTripsThroughRow() {
    let original = AccountGroup(
      name: "Trust Fund Crypto",
      bucket: .investments,
      instrument: .AUD,
      position: 3
    )
    let row = AccountGroupRow(domain: original)
    let restored = row.toDomain(defaultInstrument: .USD)

    #expect(restored.id == original.id)
    #expect(restored.name == original.name)
    #expect(restored.bucket == original.bucket)
    #expect(restored.instrument == original.instrument)
    #expect(restored.position == original.position)
    // isExpandedInSidebar is local-only; row never carries it.
    #expect(restored.isExpandedInSidebar == false)
  }

  @Test
  func recordNameIsStable() {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let name = AccountGroupRow.recordName(for: id)
    #expect(name == "AccountGroupRecord|12345678-1234-1234-1234-123456789ABC")
  }

  @Test
  func unknownBucketFallsBackToCurrent() {
    let row = AccountGroupRow(
      id: UUID(),
      recordName: "AccountGroupRecord|x",
      name: "From future build",
      bucket: "retirement",  // not a v1 case
      instrumentId: "AUD",
      position: 0,
      encodedSystemFields: nil
    )
    let restored = row.toDomain(defaultInstrument: .AUD)
    #expect(restored.bucket == .current)
  }
}
```

- [ ] **Step 5: Run the tests**

```bash
just test AccountGroupsMigrationTests AccountGroupRowMappingTests 2>&1 | tee .agent-tmp/test-pg3-5.txt
grep -i 'failed\|error:' .agent-tmp/test-pg3-5.txt || echo "OK"
```

Expected: all tests pass; the migration test from Task 4 still passes.

- [ ] **Step 6: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model add \
  Backends/GRDB/Records/AccountGroupRow.swift \
  Backends/GRDB/Records/AccountGroupRow+Mapping.swift \
  Backends/GRDB/Records/AccountGroupRow+ObservableRegion.swift \
  MoolahTests/Backends/GRDB/AccountGroupsMigrationTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model commit -m "feat(grdb): AccountGroupRow + Mapping + ObservableRegion

Mirrors EarmarkRow's file layout. Codable / PersistableRecord; no
CloudKitRecordConvertible conformance yet (Phase 7). Mapping
includes a defensive .current fallback for unknown bucket raw values
in case a future case slips past the DataFormatVersion gate."
```

---

## Task 6: Round-trip `Account.groupId` in `AccountRow`

**Files:**
- Modify: `Backends/GRDB/Records/AccountRow.swift` (add `group_id` column)
- Modify: `Backends/GRDB/Records/AccountRow+Mapping.swift` (round-trip the field)

Critical: without this, every Account written from this build strips the `groupId` from CloudKit, corrupting other devices' membership state. This task makes Account-side persistence groupId-aware locally and over CloudKit.

- [ ] **Step 1: Write the failing tests**

Locate `MoolahTests/Backends/GRDB/AccountRow+MappingTests.swift` (or whatever file holds AccountRow mapping tests — search):

```bash
grep -rln "AccountRow.*toDomain\|init(domain: Account" /Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests 2>/dev/null | head -5
```

Add tests to that file (or to a new sibling `MoolahTests/Backends/GRDB/AccountRowGroupIdTests.swift` if no obvious home):

```swift
@Suite("AccountRow.groupId round-trip")
struct AccountRowGroupIdTests {
  @Test
  func domainGroupIdRoundTripsThroughRow() {
    let groupId = UUID()
    let account = Account(
      name: "Coinstash",
      type: .exchange,
      instrument: .AUD,
      exchangeProvider: .coinstash,
      groupId: groupId
    )
    let row = AccountRow(domain: account)
    let restored = row.toDomain(instrument: .AUD)
    #expect(restored.groupId == groupId)
  }

  @Test
  func nilGroupIdRoundTripsAsNil() {
    let account = Account(name: "Chequing", type: .bank, instrument: .AUD)
    let row = AccountRow(domain: account)
    let restored = row.toDomain(instrument: .AUD)
    #expect(restored.groupId == nil)
  }
}
```

The exact signature of `AccountRow.toDomain(...)` may differ — open `AccountRow+Mapping.swift` to confirm the right call and adjust the test arguments. The semantic claim ("groupId round-trips") is what matters.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
just test AccountRowGroupIdTests 2>&1 | tee .agent-tmp/test-pg3-6.txt
```

Expected: build failure citing "extra argument 'groupId'" or similar.

- [ ] **Step 3: Add `groupId` to `AccountRow`**

In `Backends/GRDB/Records/AccountRow.swift`:

(a) Add to `Columns` enum (around line 28):

```swift
    case groupId = "group_id"
```

(b) Add to `CodingKeys` enum (around line 43):

```swift
    case groupId = "group_id"
```

(c) Add the stored property (around line 71):

```swift
  /// Optional back-reference into `account_group.id`. Nullable column;
  /// no FK constraint (sync delivery can place an Account ahead of its
  /// AccountGroup — see `ProfileSchema+AccountGroups.swift`). Domain
  /// lookup treats unknown ids as nil and renders the account as
  /// standalone in its bucket.
  var groupId: UUID?
```

(d) The memberwise init will need updating only if AccountRow uses a custom `init(...)` — Swift synthesises a memberwise init for structs, but if the file has an explicit one, add `groupId: UUID? = nil` as the last parameter. (Open the file and check.)

- [ ] **Step 4: Update `AccountRow+Mapping.swift` to round-trip `groupId`**

Read the existing `init(domain: Account)` and `toDomain(...)` and add the two lines:

```swift
  // In init(domain: Account), after exchangeProvider line:
  self.groupId = domain.groupId

  // In toDomain(...) — when constructing the Account, add groupId:
  return Account(
    // …existing args…
    groupId: groupId
  )
```

Open the file and apply both additions; preserve all existing argument ordering.

- [ ] **Step 5: Run the round-trip tests + the migration tests**

```bash
just test AccountRowGroupIdTests AccountGroupsMigrationTests AccountTypeTests 2>&1 | tee .agent-tmp/test-pg3-6.txt
grep -i 'failed\|error:' .agent-tmp/test-pg3-6.txt || echo "OK"
```

Expected: all pass.

- [ ] **Step 6: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model add \
  Backends/GRDB/Records/AccountRow.swift \
  Backends/GRDB/Records/AccountRow+Mapping.swift \
  MoolahTests/Backends/GRDB/AccountRowGroupIdTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model commit -m "feat(grdb): round-trip Account.groupId through AccountRow

Without this, Account writes from this build would silently strip
the groupId column (and the CloudKit field once Phase 7 wires the
upload), corrupting membership state on other devices. The mapping
is straight read/write — no resolution / defaulting (nil means
standalone)."
```

---

## Task 7: Add `AccountGroupRepository` (protocol + GRDB implementation)

**Files:**
- Create: `Domain/Repositories/AccountGroupRepository.swift`
- Create: `Backends/GRDB/Repositories/GRDBAccountGroupRepository.swift` (matches project convention `GRDB<Entity>Repository`, e.g. `GRDBEarmarkRepository`)
- Create: `MoolahTests/Domain/AccountGroupRepositoryContractTests.swift`

Mirror the `EarmarkRepository` shape. Use `EarmarkGRDBRepository` as the implementation template (look it up to mirror the observe / fetch / create / update / delete signatures).

- [ ] **Step 1: Read the existing patterns**

```bash
cat /Users/aj/Documents/code/moolah-project/moolah-native/Domain/Repositories/EarmarkRepository.swift
```

```bash
find /Users/aj/Documents/code/moolah-project/moolah-native/Backends/GRDB/Repositories -name "EarmarkGRDBRepository*.swift" -exec cat {} \;
```

These define the shape: an async-fetching repository with `observeAll()`, `fetchAll()`, `create(_:)`, `update(_:)`, `delete(id:)`.

- [ ] **Step 2: Write the contract tests**

Create `MoolahTests/Domain/AccountGroupRepositoryContractTests.swift` modeled on the existing EarmarkRepository contract tests (search for `EarmarkRepositoryContractTests` in MoolahTests):

```bash
grep -rln "EarmarkRepositoryContractTests\|@Suite.*Earmark.*Repository" /Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests 2>/dev/null
```

Mirror that suite's shape. Required test cases:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountGroupRepository contract")
struct AccountGroupRepositoryContractTests {
  @Test
  func createAndFetchById() async throws {
    let (backend, _) = try TestBackend.create()
    let group = AccountGroup(
      name: "Trust Fund Crypto",
      bucket: .investments,
      instrument: .defaultTestInstrument
    )
    let created = try await backend.accountGroups.create(group)
    let fetched = try await backend.accountGroups.fetchAll()
    #expect(fetched.contains(where: { $0.id == created.id && $0.name == "Trust Fund Crypto" }))
  }

  @Test
  func updateRenamesAndPersists() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.accountGroups.create(
      AccountGroup(name: "Old", bucket: .investments, instrument: .defaultTestInstrument)
    )
    var modified = created
    modified.name = "New"
    let updated = try await backend.accountGroups.update(modified)
    #expect(updated.name == "New")

    let fetched = try await backend.accountGroups.fetchAll()
    #expect(fetched.first { $0.id == created.id }?.name == "New")
  }

  @Test
  func deleteRemovesGroup() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.accountGroups.create(
      AccountGroup(name: "Temp", bucket: .investments, instrument: .defaultTestInstrument)
    )
    try await backend.accountGroups.delete(id: created.id)
    let fetched = try await backend.accountGroups.fetchAll()
    #expect(!fetched.contains(where: { $0.id == created.id }))
  }

  @Test
  func observeAllEmitsOnChanges() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.accountGroups.observeAll().makeAsyncIterator()

    // Initial emission (empty)
    let first = try await iterator.next()
    #expect(first?.isEmpty == true)

    _ = try await backend.accountGroups.create(
      AccountGroup(name: "A", bucket: .investments, instrument: .defaultTestInstrument)
    )

    let second = try await iterator.next()
    #expect(second?.count == 1)
  }

  @Test
  func bucketIsPersistedAndReadBack() async throws {
    let (backend, _) = try TestBackend.create()
    let current = try await backend.accountGroups.create(
      AccountGroup(name: "Joint", bucket: .current, instrument: .defaultTestInstrument)
    )
    let investments = try await backend.accountGroups.create(
      AccountGroup(name: "Stocks", bucket: .investments, instrument: .defaultTestInstrument)
    )
    let fetched = try await backend.accountGroups.fetchAll()
    #expect(fetched.first { $0.id == current.id }?.bucket == .current)
    #expect(fetched.first { $0.id == investments.id }?.bucket == .investments)
  }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
just test AccountGroupRepositoryContractTests 2>&1 | tee .agent-tmp/test-pg3-7.txt
```

Expected: build failure — `accountGroups` doesn't exist on `BackendProvider`, and `AccountGroupRepository` is undefined.

- [ ] **Step 4: Create the repository protocol**

Create `Domain/Repositories/AccountGroupRepository.swift`:

```swift
import Foundation

/// Repository for `AccountGroup` persistence and observation.
/// Follows the same async-fetching, observable contract as
/// `EarmarkRepository`.
protocol AccountGroupRepository: Sendable {
  /// Fetches all groups, ordered by `position` ascending.
  func fetchAll() async throws -> [AccountGroup]

  /// Hot stream of group lists. Emits an initial snapshot and again
  /// on every persisted change to the `account_group` table.
  func observeAll() -> AsyncThrowingStream<[AccountGroup], any Error>

  /// Inserts a new group. Returns the persisted instance.
  @discardableResult
  func create(_ group: AccountGroup) async throws -> AccountGroup

  /// Updates an existing group (matched by `id`). Returns the
  /// persisted instance.
  @discardableResult
  func update(_ group: AccountGroup) async throws -> AccountGroup

  /// Deletes a group by id. Does not affect member accounts —
  /// callers are responsible for clearing `Account.groupId` on
  /// members first if they want the back-reference removed from the
  /// child rows. The lookup layer treats orphaned ids as nil
  /// regardless, so leaving them is also safe.
  func delete(id: UUID) async throws
}
```

- [ ] **Step 5: Create the GRDB implementation**

Open `Backends/GRDB/Repositories/EarmarkGRDBRepository.swift` for the template. Create `Backends/GRDB/Repositories/GRDBAccountGroupRepository.swift` mirroring it:

```swift
import Foundation
import GRDB

/// GRDB-backed `AccountGroupRepository`. Plain CRUD over the
/// `account_group` table; observation via `ValueObservation` on the
/// column-restricted region declared by
/// `AccountGroupRow+ObservableRegion.swift`.
///
/// Sync wiring (system-fields stamping on upload, conflict resolution
/// on download) is added in Phase 7 — for now, writes commit locally
/// and the encoded-system-fields blob stays nil.
struct GRDBAccountGroupRepository: AccountGroupRepository {
  let database: DatabaseWriter
  let defaultInstrument: Instrument

  func fetchAll() async throws -> [AccountGroup] {
    try await database.read { db in
      try AccountGroupRow
        .order(AccountGroupRow.Columns.position.asc)
        .fetchAll(db)
        .map { $0.toDomain(defaultInstrument: defaultInstrument) }
    }
  }

  func observeAll() -> AsyncThrowingStream<[AccountGroup], any Error> {
    let observation = ValueObservation.tracking(
      regions: [AccountGroupRow.observableRegion]
    ) { db in
      try AccountGroupRow
        .order(AccountGroupRow.Columns.position.asc)
        .fetchAll(db)
    }
    return AsyncThrowingStream { continuation in
      let cancellable = observation.start(in: database) { error in
        continuation.finish(throwing: error)
      } onChange: { rows in
        continuation.yield(rows.map { $0.toDomain(defaultInstrument: defaultInstrument) })
      }
      continuation.onTermination = { _ in cancellable.cancel() }
    }
  }

  @discardableResult
  func create(_ group: AccountGroup) async throws -> AccountGroup {
    try await database.write { db in
      var row = AccountGroupRow(domain: group)
      try row.insert(db)
      return row.toDomain(defaultInstrument: defaultInstrument)
    }
  }

  @discardableResult
  func update(_ group: AccountGroup) async throws -> AccountGroup {
    try await database.write { db in
      var row = AccountGroupRow(domain: group)
      try row.update(db)
      return row.toDomain(defaultInstrument: defaultInstrument)
    }
  }

  func delete(id: UUID) async throws {
    _ = try await database.write { db in
      try AccountGroupRow
        .filter(AccountGroupRow.Columns.id == id)
        .deleteAll(db)
    }
  }
}
```

If your read of EarmarkGRDBRepository reveals additional invariants (e.g. `encodedSystemFields`-preserving update path, observation seeded with current state via `prepending(_:)`), mirror those into this implementation. The shape above is the minimal contract that makes the tests pass; adjust to fit the project's existing patterns.

- [ ] **Step 6: Wire it into `BackendProvider` (defer to Task 8)**

This step is split out — Task 8 adds `accountGroups` to the protocol and every conformer. Until then, the tests will still fail to compile. **Do not commit this task in isolation** — continue straight to Task 8.

---

## Task 8: Wire `accountGroups` into every `BackendProvider`

**Files:**
- Modify: `Domain/Repositories/BackendProvider.swift` (add protocol requirement)
- Modify: `Backends/CloudKit/CloudKitBackend.swift` (production conformer)
- Modify: `Backends/CloudKit/Sync/ProfileGRDBRepositories.swift` or wherever GRDB repos are constructed
- Modify: test backends (search for `TestBackend` conformer of `BackendProvider`)
- Modify: preview backend (search for `PreviewBackend`)

- [ ] **Step 1: Add the protocol requirement**

In `Domain/Repositories/BackendProvider.swift`, add to the protocol body (alphabetical placement after `accounts`):

```swift
  var accountGroups: any AccountGroupRepository { get }
```

Around line 8, after `var accounts: any AccountRepository { get }`.

- [ ] **Step 2: Find every conformer**

```bash
grep -rln "BackendProvider" /Users/aj/Documents/code/moolah-project/moolah-native --include='*.swift' 2>/dev/null | grep -v '\.worktrees/' | grep -v '/build/'
```

Typical conformers: `CloudKitBackend` (production), `TestBackend` (in-memory test backend), `PreviewBackend` (SwiftUI previews). Open each.

- [ ] **Step 3: Add `accountGroups` to each conformer**

For each conformer, add a stored property that constructs an `GRDBAccountGroupRepository` from the conformer's existing GRDB writer. Pattern (mirror however `earmarks` is constructed in the same file):

```swift
  let accountGroups: any AccountGroupRepository
```

…and initialise it in the conformer's `init` alongside `earmarks`:

```swift
  self.accountGroups = GRDBAccountGroupRepository(
    database: database,
    defaultInstrument: defaultInstrument
  )
```

For `PreviewBackend`, if the preview backend doesn't use GRDB and instead has an in-memory implementation, write a small `InMemoryAccountGroupRepository` conformer mirroring the in-memory implementations used for accounts / earmarks.

- [ ] **Step 4: Run the contract tests + the full build**

```bash
just build-mac 2>&1 | tee .agent-tmp/test-pg3-8.txt
grep -E 'error:' .agent-tmp/test-pg3-8.txt || echo "OK"
just test AccountGroupRepositoryContractTests 2>&1 | tee .agent-tmp/test-pg3-8-tests.txt
grep -i 'failed\|error:' .agent-tmp/test-pg3-8-tests.txt || echo "OK"
```

Expected: clean build; all contract tests pass against `TestBackend`.

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model add \
  Domain/Repositories/AccountGroupRepository.swift \
  Backends/GRDB/Repositories/GRDBAccountGroupRepository.swift \
  Domain/Repositories/BackendProvider.swift \
  Backends/CloudKit/CloudKitBackend.swift \
  Backends/CloudKit/Sync/ProfileGRDBRepositories.swift \
  MoolahTests/Domain/AccountGroupRepositoryContractTests.swift
# Plus whatever paths the TestBackend / PreviewBackend conformers live at:
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model add \
  $(grep -rln "BackendProvider" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model --include='*.swift' | grep -v '\.worktrees/' | grep -v '/build/' | xargs grep -l "accountGroups")
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model commit -m "feat(backend): wire AccountGroupRepository into BackendProvider

Protocol + GRDB impl + every conformer (CloudKitBackend, TestBackend,
PreviewBackend). Contract tests pass against TestBackend's in-memory
SwiftData / GRDB stack."
```

---

## Task 9: Bump `DataFormatVersion`

**Files:**
- Modify: `Domain/Models/DataFormatVersion.swift`

- [ ] **Step 1: Add the history note and bump**

In `Domain/Models/DataFormatVersion.swift`:

(a) Insert a new entry at the top of the History block (after `/// History (newest first):` on line 24):

```swift
/// - 5: account groups. Adds the synced `AccountGroupRecord` and a
///      `groupId` field on `AccountRecord` (back-reference into
///      `AccountGroup.id`). Older builds don't know about
///      `AccountGroupRecord` (rubric item 1) and silently drop
///      `groupId` on round-trip (rubric item 2 — older builds would
///      then re-upload Accounts with `groupId` stripped, corrupting
///      membership on other devices). The bump fences both
///      downgrades off from this build forward. `AccountGroup`
///      uploads themselves are wired in the follow-up phase; the
///      schema-and-bump pair is what makes a v5 build safe to publish
///      ahead of the sync wiring.
```

(b) Bump the constant (line 65):

```swift
  static let current: Int = 5
```

- [ ] **Step 2: Update `ExchangeAccountModelTests` regression guard if present**

Search:

```bash
grep -rn "DataFormatVersion.current" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model/MoolahTests 2>/dev/null
```

If a test asserts `DataFormatVersion.current >= 3` (or 4), no change needed — the inequality still holds. If a test pins `== N`, update to `== 5`.

- [ ] **Step 3: Run full test suite**

```bash
just test 2>&1 | tee .agent-tmp/test-pg3-9.txt
grep -i 'failed\|error:' .agent-tmp/test-pg3-9.txt || echo "OK"
```

Expected: every test passes.

- [ ] **Step 4: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model add \
  Domain/Models/DataFormatVersion.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model commit -m "feat(domain): bump DataFormatVersion 4 → 5 for account groups

New AccountGroupRecord type (rubric 1) + new Account.groupId field
(rubric 2). Fences older builds off from this profile so they can't
strip the new field on round-trip."
```

---

## Task 10: Final verify + open PR

- [ ] **Step 1: Full test suite, both targets**

```bash
just test 2>&1 | tee .agent-tmp/test-pg3-final.txt
grep -i 'failed\|error:' .agent-tmp/test-pg3-final.txt || echo "OK"
```

- [ ] **Step 2: Format-check**

```bash
just format-check
```

- [ ] **Step 3: Push and open PR**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model \
    push origin account-group-model:account-group-model

cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-group-model && \
gh pr create --base main --head account-group-model \
  --title "feat(domain): AccountGroup model + schema (Phase 3)" \
  --body "$(cat <<'EOF'
## Summary

Phase 3 of the Account Groups feature.

- `AccountGroup` domain value type — name, bucket, instrument, position, local-only expand state.
- `Account.groupId: UUID?` back-reference (no FK; lookup gracefully degrades on unknown ids).
- CKDB schema: new `AccountGroupRecord` + `groupId` field on `AccountRecord` (additive, regenerated wire layer).
- GRDB v14 migration: `account_group` table + `group_id` column on `account`, with the bucket+position and group_id indexes; STRICT; no FK.
- `AccountGroupRow` + Mapping + ObservableRegion (mirrors EarmarkRow shape; no CloudKit conformance yet — Phase 7).
- `AccountRow` round-trips `groupId` end-to-end (GRDB + Codable).
- `AccountGroupRepository` protocol + GRDB implementation; wired into every `BackendProvider` conformer.
- `DataFormatVersion` bumped 4 → 5.

## Why

Spec: `plans/2026-05-26-account-groups-design.md`.

Without the round-trip on `Account.groupId`, this build would silently strip the field when uploading Accounts to CloudKit — corrupting other devices' membership once the sync wiring (Phase 7) lands. Pairing the schema change with the round-trip in the same PR is what makes a v5 build safe to publish ahead of Phase 7.

## Out of scope (Phase 7)

`AccountGroupRow` does NOT conform to `CloudKitRecordConvertible` and is NOT in `RecordTypeRegistry.allTypes`. AccountGroup records are local-only in this build — they don't upload to CloudKit and incoming AccountGroup records are ignored. Phases 4 / 5 / 6 (UI work) can exercise groups fully against the local GRDB layer; cross-device sync of groups starts working when Phase 7 ships.

## Test plan

- [x] `just test AccountGroupTests AccountTypeTests AccountGroupsMigrationTests AccountGroupRowMappingTests AccountRowGroupIdTests AccountGroupRepositoryContractTests`
- [x] `just test` — full suite green on iOS + macOS
- [x] `just format-check` — clean
- [x] CKDBSchemaGen package tests (additivity / parser / generator)

EOF
)"
```

- [ ] **Step 4: Enable auto-merge**

```bash
./.claude/skills/landing-prs/scripts/land-pr.sh <pr-number>
```

(Or `gh pr merge <pr-number> --auto` if the script errors.) If this PR is stacked on Phase 1's branch, `land-pr.sh` will background a watcher that retargets to `main` once Phase 1 merges.

---

## Acceptance criteria for Phase 3

- `AccountGroup` and `Account.groupId` exist with tests.
- `CloudKit/schema.ckdb` declares `AccountGroupRecord` + `AccountRecord.groupId`; wire layer regenerated.
- `account_group` table and `account.group_id` column present after v14 migration; no FK; correct indexes; STRICT.
- `AccountGroupRow` + Mapping + ObservableRegion in place (no CloudKit conformance).
- `AccountRow` round-trips `groupId` (GRDB and Codable).
- `AccountGroupRepository` protocol + GRDBRepository implementation; available on every `BackendProvider` conformer.
- Contract tests pass against `TestBackend`.
- `DataFormatVersion.current == 5`.
- Full `just test` passes on iOS + macOS.
- `just format-check` clean.
- PR opened against `main` and auto-merge enabled.

---

## What's NOT in this phase

- **Phase 4** — sidebar rendering of groups + drop semantics + creation flows. Will consume `AccountGroupRepository` and `AccountGroup.bucket`.
- **Phase 5** — `AccountViewContext` + detail view threading.
- **Phase 6** — description rendering for in-group transactions.
- **Phase 7** — `AccountGroupRow: CloudKitRecordConvertible`, registry entry, apply-batch dispatch, cross-device sync round-trip tests.
- **Phase 8** — local-only sidecar table for `isExpandedInSidebar` persistence (today the field stays in-memory only).
