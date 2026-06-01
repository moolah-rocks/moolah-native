# Account Groups — Phase 4 Implementation Plan: Sidebar UX

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Initial-version plan.** Written ahead of Phases 2 and 3 landing on main. Open the codebase fresh at execution time and reconcile any drift; in particular, `SidebarView.swift` is the largest churn surface and other in-flight PRs may have moved things. The skeleton + decisions + acceptance criteria here are stable; the exact line numbers and surrounding code are advisory.

**Goal:** Render `AccountGroup`s in the sidebar as composite rows with optional expand/collapse, intermixed with standalone accounts by `position`. Drop semantics distinguish reorder (between rows / in gaps) from group-on (middle 50% of a row). Creation flows: drag account onto another account → new group, or right-click → "Group ▸" submenu with existing groups + "New Group…". Member auto-extract on drag-out; auto-delete on 0 members. All membership operations are persisted via the stores; inline rename reuses the Phase 2 component.

**Architecture:** New `AccountGroupStore` (parallel to `AccountStore`/`EarmarkStore`) provides reactive group state and the membership-mutation surface (add member, remove member, move group, create-from-account, create-from-pair). A new `Accounts+SidebarOrdering` overload returns a structured list of `SidebarBucketEntry`s (groups + standalone accounts intermixed). `SidebarView` renders the new structure, owns drop handlers, and dispatches actions to the stores. New `AccountGroupSidebarRow` and reuse of `AccountSidebarRow` (with a `member` styling hint) handle row visuals. `isExpandedInSidebar` is in-memory only this phase (per-process `@State`); Phase 8 adds persistence.

**Tech Stack:** SwiftUI (`.dropDestination`, `.draggable`, `Transferable`, `DisclosureGroup` or hand-rolled equivalent for fine drop-zone control), Swift Testing.

**Spec:** `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-groups-design/plans/2026-05-26-account-groups-design.md` — see "Sidebar UX" in full.

**Phase ordering:** Depends on **Phase 2** (inline rename component) AND **Phase 3** (`AccountGroup` model + `GRDBAccountGroupRepository`). Either base off `origin/main` if both have merged, or off whichever lands later. Independent of Phases 5 / 6 / 7 / 8.

---

## Worktree setup

- [ ] **Step 1: Create the worktree off the latest common base**

```bash
# Whichever of Phase 2 / Phase 3 merges later defines the base. If both
# are on main, use main.
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track \
  .worktrees/sidebar-groups -b sidebar-groups origin/main
```

If Phase 2 or Phase 3 has not yet merged, base off the later-landing branch. Stacked-PR conventions per `CLAUDE.md`.

- [ ] **Step 2: Generate Xcode project + clean build**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-groups \
     --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-groups/justfile generate
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-groups \
     --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-groups/justfile build-mac 2>&1 | tail -5
```

Expected: clean build with Phase 2 + Phase 3 already in.

---

## Task 1: `AccountGroupStore` (membership state + mutations)

**Files:**
- Create: `Features/Accounts/AccountGroupStore.swift`
- Create: `Features/Accounts/AccountGroupStore+Mutations.swift`
- Create: `MoolahTests/Features/AccountGroupStoreTests.swift`
- Create: `MoolahTests/Features/AccountGroupStoreMutationsTests.swift`

Mirror `EarmarkStore` / `AccountStore`. Reactive — subscribes to `repository.observeAll()` in `init`, exposes `groups: [AccountGroup]`, surfaces errors via `error: Error?`.

- [ ] **Step 1: Tests first (initial loading + observe path)**

```swift
@Suite("AccountGroupStore — load & observe")
@MainActor
struct AccountGroupStoreTests {
  @Test
  func initialLoadEmitsEmptyThenSeededRows() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForFirstEmission()

    #expect(store.groups.isEmpty)

    _ = try await backend.accountGroups.create(
      AccountGroup(name: "Trust Fund Crypto", bucket: .investments, instrument: .defaultTestInstrument))

    try await store.waitForNextEmission(matching: { $0.groups.count == 1 }, description: "create observed")
    #expect(store.groups.first?.name == "Trust Fund Crypto")
  }

  @Test
  func groupsAreOrderedByPositionAscending() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForFirstEmission()

    _ = try await backend.accountGroups.create(AccountGroup(name: "B", bucket: .investments, instrument: .defaultTestInstrument, position: 2))
    _ = try await backend.accountGroups.create(AccountGroup(name: "A", bucket: .investments, instrument: .defaultTestInstrument, position: 1))

    try await store.waitForNextEmission(matching: { $0.groups.count == 2 }, description: "creates observed")
    #expect(store.groups.map(\.name) == ["A", "B"])
  }
}
```

Add a sibling test file for mutations covering:
- `addAccount(_:to:)` — sets `Account.groupId` and re-positions within group
- `removeAccount(_:)` — clears `Account.groupId`; auto-deletes group if it was the last member
- `createGroup(from:)` — single-member group from an existing account, returns the new group
- `createGroup(joining:and:)` — two-member group from two existing accounts
- `moveGroup(_:to:)` — sets `AccountGroup.position`
- `reorderMembers(of:to:)` — updates each member's `position` within the group

- [ ] **Step 2: Implement `AccountGroupStore`**

Skeleton (mirroring `EarmarkStore`'s reactive shape):

```swift
import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class AccountGroupStore {
  private(set) var groups: [AccountGroup] = []
  private(set) var error: Error?

  let repository: any AccountGroupRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "AccountGroupStore")
  private var observationTask: Task<Void, Never>?

  init(repository: any AccountGroupRepository) {
    self.repository = repository
    self.observationTask = Task { [weak self] in
      await self?.observe()
    }
  }

  private func observe() async {
    do {
      for try await snapshot in repository.observeAll() {
        groups = snapshot
      }
    } catch {
      surface(error: error)
    }
  }

  func stopObserving() { observationTask?.cancel() }
  deinit { MainActor.assumeIsolated { observationTask?.cancel() } }

  func by(id: UUID) -> AccountGroup? { groups.first { $0.id == id } }
  func members(of groupId: UUID, in accounts: Accounts) -> [Account] {
    accounts.ordered
      .filter { $0.groupId == groupId }
      .sorted(by: { $0.position < $1.position })
  }
}
```

Mutation surface in `AccountGroupStore+Mutations.swift` — depends on `AccountStore` for the `Account.groupId` writes (cross-store coordination; pass `AccountStore` as a dependency, or inject a smaller `accountMutator` protocol). Recommended: take `AccountStore` directly in the mutation methods rather than holding a reference — keeps the dependency direction explicit.

Key methods:

```swift
extension AccountGroupStore {
  @discardableResult
  func createGroup(from account: Account, name: String, accountStore: AccountStore) async throws -> AccountGroup {
    // 1. Create the group with derived bucket/instrument.
    let group = AccountGroup(
      name: name, bucket: account.bucket,
      instrument: accountStore.targetInstrument,
      position: nextPositionInBucket(account.bucket, accountStore: accountStore))
    let created = try await repository.create(group)
    // 2. Set the account's groupId.
    var moved = account
    moved.groupId = created.id
    moved.position = 0   // first member
    _ = try await accountStore.update(moved)
    return created
  }

  @discardableResult
  func createGroup(joining accountA: Account, and accountB: Account, name: String, accountStore: AccountStore) async throws -> AccountGroup {
    precondition(accountA.bucket == accountB.bucket, "cross-bucket grouping prohibited")
    let group = AccountGroup(/* … */)
    let created = try await repository.create(group)
    for (idx, var member) in [accountA, accountB].enumerated() {
      member.groupId = created.id
      member.position = idx
      _ = try await accountStore.update(member)
    }
    return created
  }

  func addAccount(_ account: Account, to group: AccountGroup, accountStore: AccountStore) async throws {
    precondition(account.bucket == group.bucket, "cross-bucket grouping prohibited")
    var member = account
    member.groupId = group.id
    member.position = membersCount(of: group.id, in: accountStore)
    _ = try await accountStore.update(member)
  }

  func removeAccount(_ account: Account, accountStore: AccountStore) async throws {
    guard let groupId = account.groupId else { return }
    var member = account
    member.groupId = nil
    member.position = nextPositionInBucket(account.bucket, accountStore: accountStore)
    _ = try await accountStore.update(member)
    // Auto-delete empty group
    let remaining = accountStore.accounts.ordered.contains { $0.groupId == groupId }
    if !remaining {
      try await repository.delete(id: groupId)
    }
  }
}
```

The `nextPositionInBucket` / `membersCount` helpers compute positions consistently — be careful to use the same sorting key everywhere (`position` ascending) and tie-break by insertion order (e.g. `id` for determinism).

- [ ] **Step 3: Run tests + commit**

```bash
just test AccountGroupStoreTests AccountGroupStoreMutationsTests
just format-check
git ... commit -m "feat(accounts): AccountGroupStore + membership mutations"
```

---

## Task 2: Extend `Accounts+SidebarOrdering` for group-aware rendering

**Files:**
- Modify: `Domain/Models/Accounts+SidebarOrdering.swift`
- Modify: `MoolahTests/Domain/AccountsSidebarOrderingTests.swift`

The current return type is `SidebarGroups { current: [Account], investment: [Account] }`. Extend with a structured intermixed-entry list per bucket:

```swift
enum SidebarBucketEntry: Equatable {
  case account(Account)
  case group(AccountGroup, members: [Account])
}

extension Accounts {
  struct GroupAwareSidebarGroups: Equatable {
    let current: [SidebarBucketEntry]
    let investment: [SidebarBucketEntry]
  }

  /// Returns standalone accounts (groupId == nil) and groups intermixed
  /// per bucket, sorted by their shared `position`. Members of a group
  /// are returned alongside their group entry, sorted by member
  /// `position`. Honours the same hidden / exclusion rules as
  /// `sidebarGrouped(excluding:alwaysInclude:)`.
  func groupAwareSidebar(
    groups: [AccountGroup],
    excluding: UUID? = nil,
    alwaysInclude: UUID? = nil
  ) -> GroupAwareSidebarGroups
}
```

Implementation:

1. Filter `ordered` for visibility (existing logic).
2. Partition by `bucket`.
3. Within each bucket:
   - Find groups in this bucket (`groups.filter { $0.bucket == bucket }`).
   - Build standalone-account list: visible accounts with `groupId == nil`.
   - Build group entries: `(group, members)` where members are visible accounts with `groupId == group.id`, sorted by member `position`.
   - Combine standalone accounts + group entries; sort by their respective `position` (both compete in the same number space).

Tests cover:
- Empty groups list returns the existing shape (just standalone accounts).
- Standalone account and group with same `position` — tie-break by group-first (or test the deterministic order and lock it in).
- Group with a hidden member doesn't show that member but still rolls up balance (balance rollup is Phase 5; for now just confirm hidden members are excluded from the returned `members` array).
- Cross-bucket invariant: a group with bucket `.investments` only appears in the investment bucket even if a hypothetical member had a different bucket.

---

## Task 3: New row component — `AccountGroupSidebarRow`

**Files:**
- Create: `Features/Accounts/Views/AccountGroupSidebarRow.swift`
- Modify: `Features/Accounts/Views/AccountSidebarRow.swift` (add `isMember: Bool` style hint)

Group row renders:
- Disclosure triangle (▸ collapsed / ▾ expanded) bound to a `Binding<Bool>` for the group's expand state.
- Group icon (use a folder-like SF Symbol, e.g. `folder.fill` or `square.stack.3d.up.fill` — pick one that works visually beside `Account+Icon`).
- Group name (renders via inline-rename from Phase 2 — reuse `SidebarRowView`'s `isEditing` / `onRename`).
- Aggregated balance (Phase 5 wires this; for now use `nil` so the row shows a `ProgressView`, then Phase 5 substitutes the real aggregate).

```swift
struct AccountGroupSidebarRow: View {
  let group: AccountGroup
  let isSelected: Bool
  @Binding var isExpanded: Bool
  var aggregateBalance: InstrumentAmount?  // nil = ProgressView; Phase 5 wires this
  var isEditing: Binding<Bool>? = nil
  var onRename: ((String) -> Void)? = nil

  var body: some View {
    HStack(spacing: 4) {
      Button {
        isExpanded.toggle()
      } label: {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 12)
      }
      .buttonStyle(.plain)
      .accessibilityHidden(true)

      SidebarRowView(
        icon: "folder.fill",
        name: group.name,
        amount: aggregateBalance,
        isSelected: isSelected,
        isEditing: isEditing,
        onRename: onRename
      )
    }
  }
}
```

Member rows use the existing `AccountSidebarRow` with a small style hint (`isMember: Bool = false`) that adjusts indentation / secondary text. Member rows show a secondary line below the name with chain / address / exchange-provider context — extend `AccountSidebarRow` to render an optional secondary line.

Tests via SwiftUI `#Preview` only (the canvas exercise). No XCUITest in this phase.

---

## Task 4: Wire group rendering into `SidebarView`

**Files:**
- Modify: `Features/Navigation/SidebarView.swift` (substantial — both sections that render accounts become group-aware)
- Modify: `Features/Navigation/SidebarView+Previews.swift` (add a preview that seeds a group)

The two account-rendering sections (`currentAccountsSection`, `investmentsSection`) change shape: instead of `ForEach(accountStore.currentAccounts)`, iterate over the structured `[SidebarBucketEntry]` and switch on each entry:

```swift
private var investmentsSection: some View {
  let entries = accountStore.accounts.groupAwareSidebar(
    groups: groupStore.groups
  ).investment

  return Section("Investments") {
    ForEach(entries, id: \.sidebarKey) { entry in
      switch entry {
      case .account(let account):
        accountRow(account)
      case .group(let group, let members):
        groupRow(group, members: members)
      }
    }
    .onMove { /* reorder within bucket — see Task 5 */ }
    totalRow(label: "Investment Total", value: accountStore.convertedInvestmentTotal)
  }
}

@ViewBuilder
private func groupRow(_ group: AccountGroup, members: [Account]) -> some View {
  let expandBinding = Binding<Bool>(
    get: { expandedGroupIds.contains(group.id) },
    set: { isExpanded in
      if isExpanded { expandedGroupIds.insert(group.id) }
      else { expandedGroupIds.remove(group.id) }
    }
  )
  NavigationLink(value: SidebarSelection.group(group.id)) {
    AccountGroupSidebarRow(
      group: group,
      isSelected: selection == .group(group.id),
      isExpanded: expandBinding,
      aggregateBalance: nil,  // Phase 5 wires this
      isEditing: renameBinding(for: group.id),
      onRename: { newName in
        Task { _ = try? await groupStore.rename(id: group.id, to: newName) }
      })
  }
  .contextMenu { groupContextMenu(for: group) }

  if expandBinding.wrappedValue {
    ForEach(members) { member in
      memberRow(member)
    }
  }
}
```

Add new state on `SidebarView`:

```swift
@State private var expandedGroupIds: Set<UUID> = []  // Phase 8 persists; in-memory for now
```

Add `SidebarSelection.group(UUID)` case (in the existing enum). The Phase 5 plan will need to know the new case exists — leave a TODO comment for any feature that depends on the selection shape (the `transactionDescription` rule, for instance).

Add `groupContextMenu(for:)`:

```swift
@ViewBuilder
private func groupContextMenu(for group: AccountGroup) -> some View {
  Button("Rename", systemImage: "character.cursor.ibeam") {
    editingRowId = group.id
  }
  .accessibilityIdentifier(UITestIdentifiers.Sidebar.renameContextMenuItem)
}
```

(No Hide, no Delete per spec.)

Update the account context menu (Phase 2's `accountContextMenu`) to add the "Group ▸" submenu — see Task 6.

---

## Task 5: Drop semantics + creation flows

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`
- Create: `Features/Navigation/SidebarDropZone.swift` (drop-zone shape constants + helpers)

This is the spiciest piece — SwiftUI's `.dropDestination` doesn't natively distinguish "middle 50%" from "edge 25%"; you implement it via the row's geometry + a `DropProposal` returned from the proposal callback.

The cleanest approach uses a custom modifier per row that observes the drop location:

```swift
/// Returns a Transferable-conforming wrapper around an Account / Group
/// so SwiftUI's drag-drop system can shuttle ids.
struct DraggableSidebarItem: Codable, Transferable {
  enum Kind: String, Codable { case account, group }
  let kind: Kind
  let id: UUID

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .moolahSidebarItem)
  }
}

extension UTType {
  static var moolahSidebarItem = UTType(exportedAs: "com.moolah.sidebar-item")
}
```

For each row, attach `.draggable(DraggableSidebarItem(kind: ..., id: ...))` and `.dropDestination(for: DraggableSidebarItem.self)` with a proposal callback:

```swift
.dropDestination(for: DraggableSidebarItem.self) { items, location in
  guard let item = items.first else { return false }
  // Determine drop mode from `location` relative to the row bounds.
  // location.y in 0..rowHeight; middle 50% = ~0.25..0.75; edges = reorder.
  let mode = dropMode(at: location, rowHeight: ROW_HEIGHT)
  Task { await handleDrop(item, mode: mode, targetAccount: account) }
  return true
} isTargeted: { isTargeted in
  // Show full-row highlight for .on mode, no indicator for .reorder modes.
}
```

`handleDrop(item:mode:targetAccount:)` is the policy gate:
1. Source = account, target = account, mode = `.on` → `createGroup(joining: source, and: target, name: "New Group", accountStore: ...)`; enter rename mode on the new group via `editingRowId = createdGroup.id`.
2. Source = account, target = group, mode = `.on` → `addAccount(source, to: group, accountStore: ...)`. Reject if source.bucket ≠ group.bucket.
3. Source = group, target = anything, mode = `.on` → reject (no nesting).
4. Any source, mode = `.reorder above` → mutate `position` to one less than target's, persist via the relevant store.
5. Cross-bucket → reject early.

This is the highest-risk piece of Phase 4. Pre-existing tests should cover policy via `AccountGroupStore` mutations (Task 1). UX is exercised manually in Xcode + previews. If `.dropDestination` proves too lossy, fall back to a small AppKit `NSView` overlay for accurate hit-testing — but try the SwiftUI path first.

For the **right-click "Group ▸" submenu**, extend `accountContextMenu(for:)` from Phase 2:

```swift
@ViewBuilder
private func accountContextMenu(for account: Account) -> some View {
  Button("Rename", systemImage: "character.cursor.ibeam") {
    editingRowId = account.id
  }
  .accessibilityIdentifier(UITestIdentifiers.Sidebar.renameContextMenuItem)

  Menu("Group", systemImage: "folder") {
    let groupsInBucket = groupStore.groups
      .filter { $0.bucket == account.bucket && $0.id != account.groupId }
    ForEach(groupsInBucket) { group in
      Button(group.name) {
        Task {
          try? await groupStore.addAccount(account, to: group, accountStore: accountStore)
        }
      }
    }
    if !groupsInBucket.isEmpty { Divider() }
    Button("New Group\u{2026}") {
      Task {
        let created = try? await groupStore.createGroup(from: account, name: "New Group", accountStore: accountStore)
        if let created { editingRowId = created.id }
      }
    }
    if account.groupId != nil {
      Divider()
      Button("Remove from Group") {
        Task { try? await groupStore.removeAccount(account, accountStore: accountStore) }
      }
    }
  }

  // Existing items (Edit Account, View Transactions, etc.) follow.
}
```

---

## Task 6: Wire `AccountGroupStore` into `ProfileSession` + every consumer

**Files:**
- Modify: wherever `EarmarkStore` is constructed in the profile session (search for `EarmarkStore(repository:`)
- Modify: `SidebarView` (add `@Environment(AccountGroupStore.self)`)
- Modify: any preview / test entry points

The store is a `MainActor` `@Observable`; it gets injected into the SwiftUI environment alongside `EarmarkStore`. Find every site that constructs the stores together and add the new line. Mirror the rename mutation method (`rename(id:to:)`) on the store — Phase 2 added the `rename` shape on `AccountStore` / `EarmarkStore`; mirror it here.

---

## Task 7: UITestIdentifiers for groups

**Files:**
- Modify: `UITestSupport/UITestIdentifiers.swift`

Add:

```swift
extension UITestIdentifiers.Sidebar {
  /// Sidebar row for a specific group. `id` is the group's UUID, lowercased.
  public static func group(_ id: UUID) -> String {
    "sidebar.group.\(id.uuidString.lowercased())"
  }

  /// "Group ▸" submenu trigger in the account context menu.
  public static let groupSubmenu = "sidebar.contextMenu.groupSubmenu"
}
```

Apply `.accessibilityIdentifier(UITestIdentifiers.Sidebar.group(group.id))` to each group row in `SidebarView`.

---

## Task 8: Manual exercise + sidebar preview

Verify in Xcode:
1. Create two accounts in the same bucket; drag one onto the other → new group appears with both as members, rename field auto-focused.
2. Drag a third account onto the group → member added.
3. Drag a member out → reverts to standalone; group remains (1-member groups allowed).
4. Drag the last member out → group disappears.
5. Right-click an account → "Group ▸" submenu lists existing groups + "New Group…".
6. Cross-bucket drag (drag a bank account onto a crypto account) → drop indicator does not appear; nothing happens on release.
7. Click a group row → selection changes to `.group(id)`; detail view is empty / placeholder (Phase 5 wires this).
8. Click a member row → selection changes to `.account(id)`; standard detail view (unchanged from today).
9. Press Return on a selected group row → enters inline rename (Phase 2 path).
10. Disclosure triangle expands / collapses; state persists across navigation within the same process (lost on app restart — Phase 8 persists).

Document any deviation in the PR description as a known issue + follow-up.

---

## Task 9: Final verify + open PR

- [ ] Full `just test`; `just format-check`.
- [ ] Push and `gh pr create` — include the manual exercise checklist in the PR body.
- [ ] `./.claude/skills/landing-prs/scripts/land-pr.sh <N>`.

---

## Acceptance criteria for Phase 4

- `AccountGroupStore` exists with reactive observe + mutation surface (create, add, remove, rename, reorder).
- `Accounts.groupAwareSidebar(groups:)` returns intermixed `[SidebarBucketEntry]` per bucket.
- Sidebar renders group rows with disclosure + inline rename; members appear indented when expanded.
- Drop on middle 50% of an account creates / joins a group; drops in gaps reorder; cross-bucket rejected.
- "Group ▸" submenu on account right-click lists existing groups + "New Group…" + "Remove from Group" when applicable.
- 1-member groups allowed; 0-member groups auto-delete.
- `expandedGroupIds` in-memory state (Phase 8 persists later).
- `SidebarSelection.group(UUID)` case added.
- `UITestIdentifiers.Sidebar.group(id)` and `.groupSubmenu` available.
- All store mutations covered by tests.
- Sidebar group detail view selection routes to whatever placeholder Phase 5 will fill in (unblocked; can be empty for this PR).
- Full `just test` passes; `just format-check` clean.

---

## What's NOT in this phase

- **Phase 5** — composite detail view (the group's right-pane render).
- **Phase 6** — description rendering for group transactions.
- **Phase 7** — sync (groups still local-only).
- **Phase 8** — `isExpandedInSidebar` persistence.
