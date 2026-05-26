# Account Groups — Phase 8 Implementation Plan: Sidebar expand-state persistence

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Initial-version plan.** Smallest of the remaining phases. Touches one small new GRDB table and one swap in the sidebar's `expandedGroupIds` source-of-truth.

**Goal:** Persist each group's `isExpandedInSidebar` state per profile, so a user's "I always have Personal Crypto expanded" preference survives app launches. The state stays **local-only** — never synced via CloudKit (intentional per spec; expand/collapse is per-device UX state, not data).

**Architecture:** New `account_group_ui` GRDB table on the per-profile `data.sqlite` (same DB the rest of the per-profile records live on). The table is `STRICT`, has a single `group_id BLOB PRIMARY KEY` and `is_expanded INTEGER NOT NULL DEFAULT 0` column, and is excluded from CKSyncEngine wiring (not registered in `RecordTypeRegistry`). A small `GroupUIStateRepository` reads / writes; `SidebarView`'s in-memory `Set<UUID>` from Phase 4 is replaced by a `Binding` driven by the repo.

The table is the project's first **truly local-only persisted** state (per-device sync state from `wallet_sync_state` is similar but is conceptually different — it's protocol-level checkpointing, not UI preferences). The pattern this phase establishes is reusable for future local-only UI state.

**Tech Stack:** GRDB, Swift Testing.

**Spec:** `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-groups-design/plans/2026-05-26-account-groups-design.md` — see "Local-only state".

**Phase ordering:** Depends on **Phase 3** (`account_group` table must exist for the FK ON DELETE cascade) AND **Phase 4** (the in-memory `expandedGroupIds` set is what this phase replaces). Independent of Phases 5 / 6 / 7 — can run in parallel with any of them once Phases 3 + 4 land.

---

## Worktree setup

- [ ] Worktree off whichever of Phase 3 / Phase 4 merges later (or `origin/main`). Path: `.worktrees/group-ui-state-persistence`. Generate Xcode project.

---

## Task 1: GRDB migration — `account_group_ui` table

**Files:**
- Create: `Backends/GRDB/ProfileSchema+AccountGroupUIState.swift`
- Modify: `Backends/GRDB/ProfileSchema.swift` (register the migration)
- Tests: `MoolahTests/Backends/GRDB/AccountGroupUIStateMigrationTests.swift`

- [ ] **Step 1: Write the migration body**

```swift
// Backends/GRDB/ProfileSchema+AccountGroupUIState.swift

import Foundation
import GRDB

extension ProfileSchema {
  /// v15 migration. Adds the per-profile local-only `account_group_ui`
  /// table for sidebar expand / collapse state. Intentionally **not**
  /// synced via CloudKit — expand state is per-device UX preference,
  /// not data.
  ///
  /// `ON DELETE CASCADE` on `group_id` so the row is reaped automatically
  /// when the underlying group is deleted (locally or via incoming
  /// CKSyncEngine delete). This is the one FK in the account-groups
  /// schema; safe because both tables live in the same DB and FK
  /// enforcement is on (no sync-ordering hazard — the parent row was
  /// created first and any cascade fires within the same transaction
  /// as the parent delete).
  static func addAccountGroupUIState(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE account_group_ui (
            group_id     BLOB    NOT NULL PRIMARY KEY
                         REFERENCES account_group(id) ON DELETE CASCADE,
            is_expanded  INTEGER NOT NULL DEFAULT 0
        ) STRICT;
        """)
  }
}
```

Wait — Phase 3 explicitly chose **no FK** for `account.group_id` because of sync-ordering. The same concern doesn't apply here: `account_group_ui` is local-only (never receives writes from sync), and its `group_id` references the locally-persisted `account_group.id`. The parent row is guaranteed to exist when a UI-state row is written, because the UI-state write happens after the user has interacted with a group that is on-screen, which means it has been observed locally.

Confirm this reasoning at execution time; if you find a path where UI-state could be written before the group exists (e.g. background restore from a backup), drop the FK and rely on a periodic cleanup task instead.

- [ ] **Step 2: Register the migration**

In `Backends/GRDB/ProfileSchema.swift`:
1. Bump `static let version = 14` → `static let version = 15`.
2. Append the doc-comment history entry.
3. Register the migration after the v14 entry:

```swift
    migrator.registerMigration(
      "v15_account_group_ui_state", migrate: addAccountGroupUIState)
```

- [ ] **Step 3: Migration smoke test**

```swift
@Suite("v15_account_group_ui_state migration")
struct AccountGroupUIStateMigrationTests {
  @Test
  func createsTableAndCascadeFK() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)

    try queue.read { db in
      let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(account_group_ui)")
        .map { $0["name"] as String }
      #expect(cols == ["group_id", "is_expanded"])

      let fks = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(account_group_ui)")
      #expect(fks.count == 1)
      let onDelete = fks.first?["on_delete"] as? String
      #expect(onDelete == "CASCADE")
    }
  }

  @Test
  func cascadeDeletesUIStateWhenGroupDeleted() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)

    let groupId = UUID()
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account_group (id, record_name, name, bucket, instrument_id, position)
          VALUES (?, ?, 'G', 'investments', 'AUD', 0)
          """,
        arguments: [groupId.data, "AccountGroupRecord|\(groupId.uuidString)"])
      try db.execute(
        sql: "INSERT INTO account_group_ui (group_id, is_expanded) VALUES (?, 1)",
        arguments: [groupId.data])
    }

    try queue.write { db in
      try db.execute(sql: "DELETE FROM account_group WHERE id = ?", arguments: [groupId.data])
    }

    try queue.read { db in
      let count = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM account_group_ui WHERE group_id = ?",
        arguments: [groupId.data])
      #expect(count == 0)
    }
  }
}
```

(`UUID.data` — verify this helper exists or use whatever the project uses to bind a UUID to a BLOB column. Search for `id.data` / `uuid.data` callers in existing GRDB code.)

---

## Task 2: `GroupUIStateRepository`

**Files:**
- Create: `Domain/Repositories/GroupUIStateRepository.swift` (protocol)
- Create: `Backends/GRDB/Repositories/GRDBGroupUIStateRepository.swift` (impl)
- Modify: `Domain/Repositories/BackendProvider.swift` (add `groupUIState`)
- Modify: every `BackendProvider` conformer
- Tests: `MoolahTests/Domain/GroupUIStateRepositoryContractTests.swift`

The protocol:

```swift
protocol GroupUIStateRepository: Sendable {
  /// Returns true if the group is currently expanded in the sidebar.
  /// Returns `false` when no row exists (default collapsed).
  func isExpanded(groupId: UUID) async throws -> Bool

  /// Persists the expand state for a single group.
  func setExpanded(_ expanded: Bool, for groupId: UUID) async throws

  /// Fetches all expanded group ids (everything not in the set is
  /// collapsed). Useful for seeding the sidebar in one query.
  func expandedGroupIds() async throws -> Set<UUID>

  /// Hot stream of expanded-id sets. Emits an initial snapshot and
  /// again on every persisted change. Used by `SidebarView` to drive
  /// the per-group binding.
  func observeExpandedGroupIds() -> AsyncThrowingStream<Set<UUID>, any Error>
}
```

GRDB implementation:

```swift
struct GRDBGroupUIStateRepository: GroupUIStateRepository {
  let database: DatabaseWriter

  func isExpanded(groupId: UUID) async throws -> Bool {
    try await database.read { db in
      let row = try Row.fetchOne(
        db, sql: "SELECT is_expanded FROM account_group_ui WHERE group_id = ?",
        arguments: [groupId.data])
      return (row?["is_expanded"] as? Int ?? 0) != 0
    }
  }

  func setExpanded(_ expanded: Bool, for groupId: UUID) async throws {
    try await database.write { db in
      // UPSERT on the primary key.
      try db.execute(
        sql: """
          INSERT INTO account_group_ui (group_id, is_expanded) VALUES (?, ?)
          ON CONFLICT(group_id) DO UPDATE SET is_expanded = excluded.is_expanded
          """,
        arguments: [groupId.data, expanded ? 1 : 0])
    }
  }

  func expandedGroupIds() async throws -> Set<UUID> {
    try await database.read { db in
      let rows = try Row.fetchAll(
        db, sql: "SELECT group_id FROM account_group_ui WHERE is_expanded = 1")
      return Set(rows.compactMap { ($0["group_id"] as? Data).flatMap { UUID(data: $0) } })
    }
  }

  func observeExpandedGroupIds() -> AsyncThrowingStream<Set<UUID>, any Error> {
    let observation = ValueObservation.tracking { db in
      try Row.fetchAll(
        db, sql: "SELECT group_id FROM account_group_ui WHERE is_expanded = 1"
      )
      .compactMap { ($0["group_id"] as? Data).flatMap { UUID(data: $0) } }
    }
    return AsyncThrowingStream { continuation in
      let cancellable = observation.start(in: database) { error in
        continuation.finish(throwing: error)
      } onChange: { ids in
        continuation.yield(Set(ids))
      }
      continuation.onTermination = { _ in cancellable.cancel() }
    }
  }
}
```

Contract tests cover:
- Default `false` for unknown group.
- Set → read returns true; unset → read returns false.
- `expandedGroupIds()` returns the set of true rows.
- `observeExpandedGroupIds()` emits on changes.
- Cascade delete (covered by the migration test) — repo's `isExpanded` returns false after parent group is deleted.

Wire `groupUIState` into `BackendProvider`:

```swift
var groupUIState: any GroupUIStateRepository { get }
```

…and into every conformer (`CloudKitBackend`, `TestBackend`, `PreviewBackend`) — same shape as Phase 3 Task 8.

---

## Task 3: `GroupUIStateStore`

**Files:**
- Create: `Features/Accounts/GroupUIStateStore.swift`
- Tests: `MoolahTests/Features/GroupUIStateStoreTests.swift`

A small `@Observable @MainActor` store that subscribes to `repository.observeExpandedGroupIds()` and exposes:
- `var expandedGroupIds: Set<UUID> = []`
- `func toggle(_ groupId: UUID) async`
- `func setExpanded(_ expanded: Bool, for groupId: UUID) async`

The toggle method writes to the repo; the reactive observation fires back and updates `expandedGroupIds`. Same pattern as `EarmarkStore.update` / `AccountStore.update` — pass-through with reactive observation.

---

## Task 4: Wire `GroupUIStateStore` into `SidebarView`

**Files:**
- Modify: `Features/Navigation/SidebarView.swift` (replace Phase 4's `@State private var expandedGroupIds: Set<UUID> = []`)

Replace the in-memory state with:

```swift
@Environment(GroupUIStateStore.self) private var groupUIStateStore
```

…and the per-group binding in `groupRow`:

```swift
let expandBinding = Binding<Bool>(
  get: { groupUIStateStore.expandedGroupIds.contains(group.id) },
  set: { isExpanded in
    Task { await groupUIStateStore.setExpanded(isExpanded, for: group.id) }
  }
)
```

The reactive observation closes the loop: setExpanded → repo write → observation emits new set → `expandedGroupIds` updates → binding's `get` returns the new value → SwiftUI re-renders.

Inject `GroupUIStateStore` wherever the other stores are injected (search for `.environment(EarmarkStore`).

---

## Task 5: Manual verification

- Open the app; expand a group; quit + relaunch → still expanded.
- Expand on Device A; do NOT expect to see it expanded on Device B (the table is local-only). Confirm in the manual cross-device step.
- Delete a group whose UI-state row was 1 → migration test already covers the cascade; verify in the running app that no orphan row warning appears in logs.

---

## Task 6: Final verify + open PR

- [ ] `just test`; `just format-check`.
- [ ] Push; `gh pr create`; `land-pr.sh`.

---

## Acceptance criteria for Phase 8

- `account_group_ui` table exists after v15 migration; FK with `ON DELETE CASCADE` to `account_group(id)`.
- `GroupUIStateRepository` protocol + GRDB impl + wired into every `BackendProvider` conformer.
- `GroupUIStateStore` reactive store exposes `expandedGroupIds: Set<UUID>` and `setExpanded(_:for:)`.
- `SidebarView` drives expand bindings from the store (Phase 4's in-memory state removed).
- Expand state survives app relaunch.
- Cascade delete reaps UI-state row when parent group is deleted.
- Local-only — no CloudKit wiring; `account_group_ui` is NOT in `RecordTypeRegistry.allTypes`.
- Full `just test` passes; `just format-check` clean.

---

## What's NOT in this phase

- Cross-device sync of expand state (intentional — would be a different feature, not part of Account Groups).
- A "Reset all expand state" UI affordance (out of scope; user can drop the local DB if they want).
- Persistence of the bucket-section expand state (already handled by SwiftUI's `Section`; doesn't need our table).
