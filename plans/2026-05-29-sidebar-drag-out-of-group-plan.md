# Sidebar drag-out-of-group Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users drag a group member back out of its group via the existing drop-between-entries gesture; relax two `SidebarDropPolicy` guards to allow it; and close the related latent old-group-leak in `dropOntoAccount` / `dropOntoGroup`.

**Architecture:** Generalize all four `SidebarDropDispatch` entry points (`reorderRoot`, `reorderMembers`, `dropOntoAccount`, `dropOntoGroup`) so each one removes the source from its old group via `AccountGroupStore.removeAccount(_:accountStore:)` before completing the destination transition — that helper already clears `groupId`, parks the source at end-of-standalone, and auto-deletes the now-empty old group. Then relax `outcomeForRoot` row 3 and `outcomeForGroup` row 9 to route the new gestures through the same `.reorderRoot` / `.reorderMembers` outcomes. No new outcome cases.

**Tech Stack:** Swift, AppKit (`NSOutlineView` for the macOS sidebar), GRDB-backed test backend. Unit tests use Swift Testing (`import Testing`, `@Test`, `@Suite`, `#expect`, `#require`). The macOS XCUITest target uses XCTest. All build/test/format goes through `just` targets.

**Project conventions (verbatim from CLAUDE.md & plans memory):**
- Use Swift Testing for new unit tests; **never** XCTest in `MoolahTests/`.
- Helpers live in existing `SidebarDropDispatchTestSupport` (`makeStores`, `bankAccount`, `DispatchTestStores`).
- Tests await reactive emissions with `waitForNextEmission(matching:description:)` — never `Task.sleep` / retry loops.
- After every code change: `just format`, `just format-check`, `just build-mac`, scoped `just test <ClassName>` for the affected suite, then `just test` once before the final task.
- Always commit; never amend.

**Reference points (read these before starting):**
- Spec: `plans/2026-05-29-sidebar-drag-out-of-group-design.md`
- Policy under change: `Features/Navigation/SidebarDropPolicy.swift`
- Dispatch under change: `Features/Navigation/SidebarDropDispatch.swift`
- Coordinator callsite (updated in Task 4): `Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift:184-235`
- The store helper everything leans on: `Features/Accounts/AccountGroupStore+Mutations.swift:118-152` (`removeAccount(_:accountStore:)` — clears groupId, parks at end-of-standalone, auto-deletes empty group).
- Existing test patterns: `MoolahTests/Navigation/SidebarDropDispatchReorderTests.swift`, `SidebarDropPolicyOutcomeTests.swift`.

**Task ordering rationale:** Dispatch first (Tasks 1-4) so that when the policy gates open (Tasks 5-6), every gesture lands in a dispatch entry that handles all source states correctly. Doing it the other way around would put the app into a temporarily broken state between commits — drags would succeed but leak old groups.

---

## Task 1: Generalize `dropOntoAccount` to clean up source's old group

**Files:**
- Modify: `Features/Navigation/SidebarDropDispatch.swift:40-69` (the existing `dropOntoAccount` function)
- Test: `MoolahTests/Navigation/SidebarDropDispatchTests.swift` (existing suite — add new `@Test` methods)

- [ ] **Step 1.1: Read the existing `dropOntoAccount` implementation and tests.**

Read `Features/Navigation/SidebarDropDispatch.swift:40-69` and `MoolahTests/Navigation/SidebarDropDispatchTests.swift` end-to-end. You need to know the existing same-bucket / self-drop / target-already-member branches so you don't regress them.

- [ ] **Step 1.2: Write the failing test for "member of A onto member of B, A keeps members".**

Append to `MoolahTests/Navigation/SidebarDropDispatchTests.swift` inside the `@Suite` struct:

```swift
@Test("dropOntoAccount moves source from group A to group B; A keeps members")
func dropOntoAccountCrossGroupKeepsOldGroup() async throws {
  let (backend, database) = try TestBackend.create()
  let aMember1 = SidebarDropDispatchTestSupport.bankAccount(name: "A1", position: 0)
  let aMember2 = SidebarDropDispatchTestSupport.bankAccount(name: "A2", position: 1)
  let bMember = SidebarDropDispatchTestSupport.bankAccount(name: "B1", position: 2)
  let stores = try await SidebarDropDispatchTestSupport.makeStores(
    seedAccounts: [aMember1, aMember2, bMember], in: database, backend: backend)

  let groupA = try await stores.accountGroupStore.createGroup(
    joining: aMember1, and: aMember2, name: "A",
    accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: {
      $0.accounts.by(id: aMember1.id)?.groupId == groupA.id
        && $0.accounts.by(id: aMember2.id)?.groupId == groupA.id
    },
    description: "group A members joined")

  let groupB = try await stores.accountGroupStore.createGroup(
    from: bMember, name: "B", accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: bMember.id)?.groupId == groupB.id },
    description: "B single-member group seeded")

  // Drag aMember1 onto bMember; target is in groupB, so source should
  // join groupB. Group A should still exist with aMember2.
  _ = try await SidebarDropDispatch.dropOntoAccount(
    sourceId: aMember1.id,
    targetId: bMember.id,
    accountStore: stores.accountStore,
    accountGroupStore: stores.accountGroupStore,
    groupUIStateStore: stores.groupUIStateStore)

  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: aMember1.id)?.groupId == groupB.id },
    description: "aMember1 now in groupB")
  #expect(stores.accountStore.accounts.by(id: aMember2.id)?.groupId == groupA.id)
  #expect(stores.accountGroupStore.by(id: groupA.id) != nil)
}
```

- [ ] **Step 1.3: Run the test and verify it fails.**

```bash
just test SidebarDropDispatchTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: the new test fails (the existing dispatch sets `aMember1.groupId = groupB.id` but A still references it — the assertion `aMember2.groupId == groupA.id` may pass, but `aMember1.groupId == groupB.id` succeeds via the existing `addAccount` path; the new test may currently *pass*. If so, sharpen it — add a sole-member-of-A test instead, see Step 1.4.)

If the test passes already (the cross-group-keeps-members case happens to work via current code paths), move on to Step 1.4 — that's the more definitive failure case.

- [ ] **Step 1.4: Write the failing test for "sole member of A onto member of B, A is deleted".**

Append:

```swift
@Test("dropOntoAccount onto cross-group member deletes empty old group")
func dropOntoAccountCrossGroupDeletesEmptyOldGroup() async throws {
  let (backend, database) = try TestBackend.create()
  let aSole = SidebarDropDispatchTestSupport.bankAccount(name: "ASole", position: 0)
  let bMember = SidebarDropDispatchTestSupport.bankAccount(name: "B1", position: 1)
  let stores = try await SidebarDropDispatchTestSupport.makeStores(
    seedAccounts: [aSole, bMember], in: database, backend: backend)

  let groupA = try await stores.accountGroupStore.createGroup(
    from: aSole, name: "A", accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: aSole.id)?.groupId == groupA.id },
    description: "aSole joined group A")
  let groupB = try await stores.accountGroupStore.createGroup(
    from: bMember, name: "B", accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: bMember.id)?.groupId == groupB.id },
    description: "bMember joined group B")

  _ = try await SidebarDropDispatch.dropOntoAccount(
    sourceId: aSole.id,
    targetId: bMember.id,
    accountStore: stores.accountStore,
    accountGroupStore: stores.accountGroupStore,
    groupUIStateStore: stores.groupUIStateStore)

  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: aSole.id)?.groupId == groupB.id },
    description: "aSole now in groupB")
  try await stores.accountGroupStore.waitForNextEmission(
    matching: { $0.by(id: groupA.id) == nil },
    description: "group A auto-deleted")
}
```

- [ ] **Step 1.5: Run the test and verify it fails.**

```bash
just test SidebarDropDispatchTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: `dropOntoAccountCrossGroupDeletesEmptyOldGroup` times out waiting for `group A auto-deleted` — the existing implementation never deletes group A.

- [ ] **Step 1.6: Update `dropOntoAccount` to remove the source from its old group first.**

Replace the body of `static func dropOntoAccount(...)` in `Features/Navigation/SidebarDropDispatch.swift:40-69` with:

```swift
static func dropOntoAccount(
  sourceId: UUID,
  targetId: UUID,
  accountStore: AccountStore,
  accountGroupStore: AccountGroupStore,
  groupUIStateStore: GroupUIStateStore
) async throws -> AccountGroup? {
  guard sourceId != targetId else { return nil }
  guard let source = accountStore.accounts.by(id: sourceId) else { return nil }
  guard let target = accountStore.accounts.by(id: targetId) else { return nil }
  guard source.bucket == target.bucket else { return nil }

  // If the source is currently in a group different from where it's
  // heading, clean up the old group first. `removeAccount` auto-deletes
  // the old group when it becomes empty. The target.groupId guard avoids
  // a wasteful remove/re-add when source and target are already in the
  // same group (caught downstream as a no-op anyway, but skipping the
  // remove keeps the write count down).
  if let sourceGroupId = source.groupId, sourceGroupId != target.groupId {
    try await accountGroupStore.removeAccount(source, accountStore: accountStore)
  }

  if let targetGroupId = target.groupId {
    guard let group = accountGroupStore.by(id: targetGroupId) else { return nil }
    guard let refreshed = accountStore.accounts.by(id: sourceId) else { return nil }
    try await accountGroupStore.addAccount(
      refreshed, to: group, accountStore: accountStore)
    return nil
  }

  guard let refreshed = accountStore.accounts.by(id: sourceId) else { return nil }
  let created = try await accountGroupStore.createGroup(
    joining: target,
    and: refreshed,
    name: "New Group",
    accountStore: accountStore)
  await groupUIStateStore.setExpanded(true, for: created.id)
  return created
}
```

- [ ] **Step 1.7: Run the new tests; expect pass.**

```bash
just test SidebarDropDispatchTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'failed|error:' .agent-tmp/test-output.txt
```

Expected: all `SidebarDropDispatchTests` pass.

- [ ] **Step 1.8: Format-check.**

```bash
just format
just format-check
```

Expected: clean, no diff after format, no SwiftLint violations.

- [ ] **Step 1.9: Build macOS.**

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
```

Expected: build succeeds.

- [ ] **Step 1.10: Commit.**

```bash
git -C $(pwd) add Features/Navigation/SidebarDropDispatch.swift MoolahTests/Navigation/SidebarDropDispatchTests.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
fix(sidebar): drop-onto-account cleans up source's old group

When dragging a member of one group onto a member or standalone of
another, the source previously had its groupId overwritten but the
old group was never re-checked for emptiness. Fixes the latent
empty-group-row bug; same root cause as the upcoming drag-out
support in reorderRoot / reorderMembers.

EOF
)"
```

Delete the temp test-output file:

```bash
rm -f .agent-tmp/test-output.txt .agent-tmp/build.txt
```

---

## Task 2: Generalize `dropOntoGroup` to clean up source's old group

**Files:**
- Modify: `Features/Navigation/SidebarDropDispatch.swift:79-94` (the existing `dropOntoGroup` function)
- Test: `MoolahTests/Navigation/SidebarDropDispatchTests.swift`

- [ ] **Step 2.1: Write the failing test for "sole member of A onto group B, A is deleted".**

Append to `MoolahTests/Navigation/SidebarDropDispatchTests.swift`:

```swift
@Test("dropOntoGroup from a sole-member-group deletes the old group")
func dropOntoGroupCrossGroupDeletesEmptyOldGroup() async throws {
  let (backend, database) = try TestBackend.create()
  let aSole = SidebarDropDispatchTestSupport.bankAccount(name: "ASole", position: 0)
  let bMember = SidebarDropDispatchTestSupport.bankAccount(name: "B1", position: 1)
  let stores = try await SidebarDropDispatchTestSupport.makeStores(
    seedAccounts: [aSole, bMember], in: database, backend: backend)

  let groupA = try await stores.accountGroupStore.createGroup(
    from: aSole, name: "A", accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: aSole.id)?.groupId == groupA.id },
    description: "aSole joined group A")
  let groupB = try await stores.accountGroupStore.createGroup(
    from: bMember, name: "B", accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: bMember.id)?.groupId == groupB.id },
    description: "bMember joined group B")

  try await SidebarDropDispatch.dropOntoGroup(
    sourceId: aSole.id,
    groupId: groupB.id,
    accountStore: stores.accountStore,
    accountGroupStore: stores.accountGroupStore,
    groupUIStateStore: stores.groupUIStateStore)

  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: aSole.id)?.groupId == groupB.id },
    description: "aSole now in groupB")
  try await stores.accountGroupStore.waitForNextEmission(
    matching: { $0.by(id: groupA.id) == nil },
    description: "group A auto-deleted")
}
```

- [ ] **Step 2.2: Run the test, verify failure.**

```bash
just test SidebarDropDispatchTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: the new test times out on `group A auto-deleted`.

- [ ] **Step 2.3: Update `dropOntoGroup` to remove the source from its old group first.**

Replace the body of `static func dropOntoGroup(...)` in `Features/Navigation/SidebarDropDispatch.swift:79-94` with:

```swift
static func dropOntoGroup(
  sourceId: UUID,
  groupId: UUID,
  accountStore: AccountStore,
  accountGroupStore: AccountGroupStore,
  groupUIStateStore: GroupUIStateStore
) async throws {
  guard let source = accountStore.accounts.by(id: sourceId) else { return }
  guard let group = accountGroupStore.by(id: groupId) else { return }
  guard source.bucket == group.bucket else { return }
  guard source.groupId != group.id else { return }

  // If the source is currently in a different group, remove from it
  // first so the old group auto-deletes when emptied.
  if source.groupId != nil {
    try await accountGroupStore.removeAccount(source, accountStore: accountStore)
  }

  guard let refreshed = accountStore.accounts.by(id: sourceId) else { return }
  try await accountGroupStore.addAccount(
    refreshed, to: group, accountStore: accountStore)
  await groupUIStateStore.setExpanded(true, for: group.id)
}
```

- [ ] **Step 2.4: Re-run tests; expect pass.**

```bash
just test SidebarDropDispatchTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'failed|error:' .agent-tmp/test-output.txt
```

- [ ] **Step 2.5: Format-check, build.**

```bash
just format
just format-check
just build-mac
```

- [ ] **Step 2.6: Commit.**

```bash
git -C $(pwd) add Features/Navigation/SidebarDropDispatch.swift MoolahTests/Navigation/SidebarDropDispatchTests.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
fix(sidebar): drop-onto-group cleans up source's old group

Mirrors the dropOntoAccount fix: cross-group drop-onto now removes
the source from its old group first, auto-deleting the old group
when the source was its sole member.

EOF
)"
rm -f .agent-tmp/test-output.txt
```

---

## Task 3: Generalize `reorderRoot` to handle member sources

**Files:**
- Modify: `Features/Navigation/SidebarDropDispatch.swift:116-152` (the existing `reorderRoot` function)
- Test: `MoolahTests/Navigation/SidebarDropDispatchReorderTests.swift`

- [ ] **Step 3.1: Write the failing test for "member of 2-member group dropped to root keeps old group with one member".**

Append to the `SidebarDropDispatchReorderTests` `@Suite` struct in `MoolahTests/Navigation/SidebarDropDispatchReorderTests.swift`:

```swift
@Test("reorderRoot clears groupId when source is a member; old group keeps its remaining member")
func reorderRootClearsGroupIdAndKeepsNonEmptyOldGroup() async throws {
  let (backend, database) = try TestBackend.create()
  let standalone = SidebarDropDispatchTestSupport.bankAccount(
    name: "Standalone", position: 0)
  let memberA = SidebarDropDispatchTestSupport.bankAccount(name: "MemberA", position: 1)
  let memberB = SidebarDropDispatchTestSupport.bankAccount(name: "MemberB", position: 2)
  let stores = try await SidebarDropDispatchTestSupport.makeStores(
    seedAccounts: [standalone, memberA, memberB], in: database, backend: backend)

  let group = try await stores.accountGroupStore.createGroup(
    joining: memberA, and: memberB, name: "G",
    accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: {
      $0.accounts.by(id: memberA.id)?.groupId == group.id
        && $0.accounts.by(id: memberB.id)?.groupId == group.id
    },
    description: "members joined")

  // Drop memberA at root insertion index 0 (ahead of standalone + group).
  try await SidebarDropDispatch.reorderRoot(
    dragged: DraggableSidebarItem(kind: .account, id: memberA.id),
    insertionIndex: 0,
    bucket: .current,
    accountStore: stores.accountStore,
    accountGroupStore: stores.accountGroupStore)

  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: memberA.id)?.groupId == nil },
    description: "memberA back to root")
  #expect(stores.accountStore.accounts.by(id: memberB.id)?.groupId == group.id)
  #expect(stores.accountGroupStore.by(id: group.id) != nil)
}
```

- [ ] **Step 3.2: Write the failing test for "sole member dropped to root deletes the old group".**

Append:

```swift
@Test("reorderRoot deletes the old group when the source was its sole member")
func reorderRootDeletesEmptyOldGroup() async throws {
  let (backend, database) = try TestBackend.create()
  let standalone = SidebarDropDispatchTestSupport.bankAccount(
    name: "Standalone", position: 0)
  let soleMember = SidebarDropDispatchTestSupport.bankAccount(
    name: "Sole", position: 1)
  let stores = try await SidebarDropDispatchTestSupport.makeStores(
    seedAccounts: [standalone, soleMember], in: database, backend: backend)

  let group = try await stores.accountGroupStore.createGroup(
    from: soleMember, name: "Lonely", accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: soleMember.id)?.groupId == group.id },
    description: "soleMember joined group")

  try await SidebarDropDispatch.reorderRoot(
    dragged: DraggableSidebarItem(kind: .account, id: soleMember.id),
    insertionIndex: 0,
    bucket: .current,
    accountStore: stores.accountStore,
    accountGroupStore: stores.accountGroupStore)

  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: soleMember.id)?.groupId == nil },
    description: "soleMember back to root")
  try await stores.accountGroupStore.waitForNextEmission(
    matching: { $0.by(id: group.id) == nil },
    description: "lonely group auto-deleted")
}
```

- [ ] **Step 3.3: Run the new tests, verify failure.**

```bash
just test SidebarDropDispatchReorderTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: both new tests fail — the existing `reorderRoot` never clears `groupId` and never deletes the old group.

- [ ] **Step 3.4: Update `reorderRoot` to handle a member source.**

In `Features/Navigation/SidebarDropDispatch.swift`, at the top of the `static func reorderRoot(...)` body (before the existing `let entries = bucketEntries(...)` line), insert:

```swift
// If the dragged source is a group member, remove it from its group
// first. `removeAccount` clears `Account.groupId`, parks the source at
// end-of-standalone, and auto-deletes the now-empty old group. The
// walk-order rewrite below overwrites the temporary position with the
// dropped insertion-slot one.
if case .account = dragged.kind,
   let source = accountStore.accounts.by(id: dragged.id),
   source.groupId != nil {
  try await accountGroupStore.removeAccount(source, accountStore: accountStore)
}
```

Leave the existing `let entries = bucketEntries(...)` block and the walk-order rewrite below unchanged — they re-read the snapshot after the await above, so the source appears as a standalone entry.

- [ ] **Step 3.5: Re-run tests; expect pass.**

```bash
just test SidebarDropDispatchReorderTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'failed|error:' .agent-tmp/test-output.txt
```

- [ ] **Step 3.6: Format-check, build.**

```bash
just format
just format-check
just build-mac
```

- [ ] **Step 3.7: Commit.**

```bash
git -C $(pwd) add Features/Navigation/SidebarDropDispatch.swift MoolahTests/Navigation/SidebarDropDispatchReorderTests.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
feat(sidebar): reorderRoot handles a member source

When the policy emits .reorderRoot for a dragged account, the source
may now be a current group member (once the policy guard relaxes in
a follow-up commit). Generalise the dispatch to remove the source
from its group first via AccountGroupStore.removeAccount — the
existing helper auto-deletes the old group when emptied.

EOF
)"
rm -f .agent-tmp/test-output.txt
```

---

## Task 4: Generalize `reorderMembers` + update coordinator callsite

**Files:**
- Modify: `Features/Navigation/SidebarDropDispatch.swift:159-174` (the existing `reorderMembers` function)
- Modify: `Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift:228-234` (the `.reorderMembers` branch in `commit`)
- Test: `MoolahTests/Navigation/SidebarDropDispatchReorderTests.swift`

- [ ] **Step 4.1: Write the failing test for "standalone source dropped between members of group B joins B".**

Append to `SidebarDropDispatchReorderTests`:

```swift
@Test("reorderMembers adds a standalone source to the target group at the insertion index")
func reorderMembersAddsStandaloneToGroup() async throws {
  let (backend, database) = try TestBackend.create()
  let standalone = SidebarDropDispatchTestSupport.bankAccount(
    name: "Standalone", position: 0)
  let memberA = SidebarDropDispatchTestSupport.bankAccount(name: "MA", position: 1)
  let memberB = SidebarDropDispatchTestSupport.bankAccount(name: "MB", position: 2)
  let stores = try await SidebarDropDispatchTestSupport.makeStores(
    seedAccounts: [standalone, memberA, memberB], in: database, backend: backend)

  let group = try await stores.accountGroupStore.createGroup(
    joining: memberA, and: memberB, name: "G",
    accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: memberA.id)?.groupId == group.id },
    description: "group seeded")

  // Drop standalone between memberA (position 0) and memberB (position 1)
  // in the group's member list.
  try await SidebarDropDispatch.reorderMembers(
    groupId: group.id,
    sourceAccountId: standalone.id,
    insertionIndex: 1,
    accountStore: stores.accountStore,
    accountGroupStore: stores.accountGroupStore)

  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: standalone.id)?.groupId == group.id },
    description: "standalone joined group")
  let members = stores.accountStore.accounts.ordered
    .filter { $0.groupId == group.id }
    .sorted { $0.position < $1.position }
    .map(\.id)
  #expect(members == [memberA.id, standalone.id, memberB.id])
}
```

- [ ] **Step 4.2: Write the failing test for "cross-group: member of A dropped between members of B; A still has members".**

Append:

```swift
@Test("reorderMembers moves source from group A to group B; A keeps remaining members")
func reorderMembersCrossGroupKeepsOldGroup() async throws {
  let (backend, database) = try TestBackend.create()
  let a1 = SidebarDropDispatchTestSupport.bankAccount(name: "A1", position: 0)
  let a2 = SidebarDropDispatchTestSupport.bankAccount(name: "A2", position: 1)
  let b1 = SidebarDropDispatchTestSupport.bankAccount(name: "B1", position: 2)
  let b2 = SidebarDropDispatchTestSupport.bankAccount(name: "B2", position: 3)
  let stores = try await SidebarDropDispatchTestSupport.makeStores(
    seedAccounts: [a1, a2, b1, b2], in: database, backend: backend)

  let groupA = try await stores.accountGroupStore.createGroup(
    joining: a1, and: a2, name: "A", accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: a1.id)?.groupId == groupA.id },
    description: "group A seeded")
  let groupB = try await stores.accountGroupStore.createGroup(
    joining: b1, and: b2, name: "B", accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: b1.id)?.groupId == groupB.id },
    description: "group B seeded")

  // Drop a1 between b1 and b2 in group B.
  try await SidebarDropDispatch.reorderMembers(
    groupId: groupB.id,
    sourceAccountId: a1.id,
    insertionIndex: 1,
    accountStore: stores.accountStore,
    accountGroupStore: stores.accountGroupStore)

  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: a1.id)?.groupId == groupB.id },
    description: "a1 now in group B")
  #expect(stores.accountStore.accounts.by(id: a2.id)?.groupId == groupA.id)
  #expect(stores.accountGroupStore.by(id: groupA.id) != nil)
  let bMembers = stores.accountStore.accounts.ordered
    .filter { $0.groupId == groupB.id }
    .sorted { $0.position < $1.position }
    .map(\.id)
  #expect(bMembers == [b1.id, a1.id, b2.id])
}
```

- [ ] **Step 4.3: Write the failing test for "sole member of A dropped between members of B; A deleted".**

Append:

```swift
@Test("reorderMembers deletes empty old group when source was its sole member")
func reorderMembersDeletesEmptyOldGroup() async throws {
  let (backend, database) = try TestBackend.create()
  let aSole = SidebarDropDispatchTestSupport.bankAccount(name: "ASole", position: 0)
  let b1 = SidebarDropDispatchTestSupport.bankAccount(name: "B1", position: 1)
  let b2 = SidebarDropDispatchTestSupport.bankAccount(name: "B2", position: 2)
  let stores = try await SidebarDropDispatchTestSupport.makeStores(
    seedAccounts: [aSole, b1, b2], in: database, backend: backend)

  let groupA = try await stores.accountGroupStore.createGroup(
    from: aSole, name: "A", accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: aSole.id)?.groupId == groupA.id },
    description: "aSole joined A")
  let groupB = try await stores.accountGroupStore.createGroup(
    joining: b1, and: b2, name: "B", accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: b1.id)?.groupId == groupB.id },
    description: "group B seeded")

  try await SidebarDropDispatch.reorderMembers(
    groupId: groupB.id,
    sourceAccountId: aSole.id,
    insertionIndex: 1,
    accountStore: stores.accountStore,
    accountGroupStore: stores.accountGroupStore)

  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: aSole.id)?.groupId == groupB.id },
    description: "aSole now in group B")
  try await stores.accountGroupStore.waitForNextEmission(
    matching: { $0.by(id: groupA.id) == nil },
    description: "group A auto-deleted")
}
```

- [ ] **Step 4.4: Run the three new tests; verify they fail.**

```bash
just test SidebarDropDispatchReorderTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: all three fail to compile — they pass `accountGroupStore:` to `reorderMembers`, which doesn't yet accept that parameter. After Step 4.5 the signature lines up and tests proceed to assertion failures.

- [ ] **Step 4.5: Update `reorderMembers`: add the `accountGroupStore` parameter, throws, and the membership-transition logic.**

Replace the body of `static func reorderMembers(...)` in `Features/Navigation/SidebarDropDispatch.swift:159-174` with:

```swift
static func reorderMembers(
  groupId: UUID,
  sourceAccountId: UUID,
  insertionIndex: Int,
  accountStore: AccountStore,
  accountGroupStore: AccountGroupStore
) async throws {
  guard let source = accountStore.accounts.by(id: sourceAccountId) else { return }

  // If the source isn't already a member of the destination group,
  // transition membership before the member-list reorder.
  if source.groupId != groupId {
    if source.groupId != nil {
      // Cross-group: removeAccount clears groupId AND auto-deletes the
      // old group when emptied.
      try await accountGroupStore.removeAccount(source, accountStore: accountStore)
    }
    // Re-read after the (possibly skipped) removeAccount; groupId is
    // nil now. The member walk below overwrites the position.
    guard let refreshed = accountStore.accounts.by(id: sourceAccountId)
    else { return }
    var member = refreshed
    member.groupId = groupId
    _ = try await accountStore.update(member)
  }

  // Rewrite member positions for `groupId`. After the (possibly
  // no-op) membership update above, the source IS a member of
  // `groupId`, so the existing member-list reorder is unchanged.
  var members = accountStore.accounts.ordered
    .filter { $0.groupId == groupId }
    .sorted { $0.position < $1.position }
  guard let removalIndex = members.firstIndex(where: { $0.id == sourceAccountId })
  else { return }
  let dragged = members.remove(at: removalIndex)
  let clampedIndex = min(max(insertionIndex, 0), members.count)
  members.insert(dragged, at: clampedIndex)
  await accountStore.reorderAccounts(members)
}
```

- [ ] **Step 4.6: Update the coordinator callsite.**

In `Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift`, locate the `.reorderMembers` branch inside `commit(_:bucket:)` (around line 228-234) and replace it with:

```swift
case let .reorderMembers(groupId, sourceId, idx):
  do {
    try await SidebarDropDispatch.reorderMembers(
      groupId: groupId,
      sourceAccountId: sourceId,
      insertionIndex: idx,
      accountStore: accountStore,
      accountGroupStore: accountGroupStore)
  } catch {
    // Error already surfaced reactively on accountGroupStore.error.
  }
  return true
```

- [ ] **Step 4.7: Add a coordinator-commit test exercising the throwing reorderMembers plumbing.**

Append to `MoolahTests/Navigation/SidebarOutlineDropCoordinatorCommitTests.swift` inside the `@Suite` struct:

```swift
@Test("commit .reorderMembers routes a cross-group move through the throwing dispatch")
func commitReorderMembersCrossGroup() async throws {
  let (backend, database) = try TestBackend.create()
  let aSole = DispatchSupport.bankAccount(name: "ASole", position: 0)
  let b1 = DispatchSupport.bankAccount(name: "B1", position: 1)
  let b2 = DispatchSupport.bankAccount(name: "B2", position: 2)
  let stores = try await DispatchSupport.makeStores(
    seedAccounts: [aSole, b1, b2], in: database, backend: backend)
  let groupA = try await stores.accountGroupStore.createGroup(
    from: aSole, name: "A", accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: aSole.id)?.groupId == groupA.id },
    description: "aSole joined A")
  let groupB = try await stores.accountGroupStore.createGroup(
    joining: b1, and: b2, name: "B", accountStore: stores.accountStore)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: b1.id)?.groupId == groupB.id },
    description: "group B seeded")
  let coordinator = SidebarOutlineDropCoordinator(
    accountStore: stores.accountStore,
    accountGroupStore: stores.accountGroupStore,
    groupUIStateStore: stores.groupUIStateStore)

  let result = await coordinator.commit(
    .reorderMembers(groupId: groupB.id, sourceAccountId: aSole.id, insertionIndex: 1),
    bucket: .current)

  #expect(result == true)
  try await stores.accountStore.waitForNextEmission(
    matching: { $0.accounts.by(id: aSole.id)?.groupId == groupB.id },
    description: "aSole moved to B via coordinator commit")
  try await stores.accountGroupStore.waitForNextEmission(
    matching: { $0.by(id: groupA.id) == nil },
    description: "group A auto-deleted via coordinator commit")
}
```

- [ ] **Step 4.8: Re-run dispatch + coordinator tests; expect pass.**

```bash
just test-mac SidebarDropDispatchReorderTests SidebarOutlineDropCoordinatorCommitTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'failed|error:' .agent-tmp/test-output.txt
```

- [ ] **Step 4.9: Format-check, build.**

```bash
just format
just format-check
just build-mac
```

- [ ] **Step 4.10: Commit.**

```bash
git -C $(pwd) add Features/Navigation/SidebarDropDispatch.swift Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift MoolahTests/Navigation/SidebarDropDispatchReorderTests.swift MoolahTests/Navigation/SidebarOutlineDropCoordinatorCommitTests.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
feat(sidebar): reorderMembers accepts cross-group / standalone source

Generalise reorderMembers so the source may already be in a different
group or standalone. Removes from any old group first via
removeAccount (auto-deletes empty old group), then sets the new
groupId and runs the existing member-list position walk. Coordinator
callsite passes accountGroupStore and propagates the throw.

EOF
)"
rm -f .agent-tmp/test-output.txt
```

---

## Task 5: Relax `SidebarDropPolicy` row 3 (`outcomeForRoot` member guard)

**Files:**
- Modify: `Features/Navigation/SidebarDropPolicy.swift:113-115` (the row-3 guard)
- Modify: `MoolahTests/Navigation/SidebarDropPolicyOutcomeTests.swift` (flip the existing row-3 test)

- [ ] **Step 5.1: Locate the existing row-3 test.**

`grep -n "row 3" MoolahTests/Navigation/SidebarDropPolicyOutcomeTests.swift` to find the test that currently asserts `.deny` for a member-source dragged-to-root. Open the test and identify its name and current shape.

- [ ] **Step 5.2: Update the row-3 test to assert `.reorderRoot`.**

Replace the existing row-3 assertion (which currently checks `#expect(outcome == .deny)` for a member source). The updated test should:

1. Build a group with one member account via `Support.currentGroup(position: 0)` + a bank account with `groupId` set to the group's id.
2. Build a `target` with `dragged: .account(member.id)`, `intoElement: nil` (root), `childIndex: 1`.
3. Assert: `#expect(outcome == .reorderRoot(item: DraggableSidebarItem(kind: .account, id: member.id), insertionIndex: 1))`.

Use the existing test as a structural template (check the `Support` shorthand and the `Support.target(...)` helper signature in `MoolahTests/Navigation/SidebarDropPolicyTestSupport.swift` before writing).

- [ ] **Step 5.3: Run the policy test, verify it fails.**

```bash
just test SidebarDropPolicyOutcomeTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: the updated row-3 test fails — the current policy still returns `.deny` because of the guard.

- [ ] **Step 5.4: Remove the row-3 guard from `outcomeForRoot`.**

In `Features/Navigation/SidebarDropPolicy.swift`, find the `outcomeForRoot` function and delete these three lines:

```swift
// row 3: dragging a member to root denies (no silent un-group).
guard sourceAccount.groupId == nil else { return .deny }
```

The surrounding `case .account:` branch should now look like:

```swift
case .account:
  guard let sourceAccount = context.accounts.by(id: dragged.id) else {
    return .deny
  }
  // row 5: cross-bucket drop.
  guard sourceAccount.bucket == context.bucket else { return .deny }
  // row 2.
  return .reorderRoot(item: dragged, insertionIndex: idx)
```

(Note: the `// row 2.` comment moves up since row 3 is gone — leave it inline as shown.)

- [ ] **Step 5.5: Re-run policy tests; verify pass.**

```bash
just test SidebarDropPolicyOutcomeTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'failed|error:' .agent-tmp/test-output.txt
```

- [ ] **Step 5.6: Verify retarget tests still pass.**

```bash
just test SidebarDropPolicyRetargetTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: pass. The retarget path now naturally completes its second pass for member sources targeting standalone-account rows.

- [ ] **Step 5.7: Format-check, build.**

```bash
just format
just format-check
just build-mac
```

- [ ] **Step 5.8: Commit.**

```bash
git -C $(pwd) add Features/Navigation/SidebarDropPolicy.swift MoolahTests/Navigation/SidebarDropPolicyOutcomeTests.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
feat(sidebar): allow dragging a group member to a root insertion slot

Drops the row-3 deny in SidebarDropPolicy.outcomeForRoot. The
dispatch (reorderRoot) already handles the membership cleanup in a
previous commit, so the gesture now lands end-to-end: the dragged
member appears at the dropped slot and its old group auto-deletes
when emptied.

EOF
)"
rm -f .agent-tmp/test-output.txt
```

---

## Task 6: Relax `SidebarDropPolicy` row 9 (`outcomeForGroup` non-member guard)

**Files:**
- Modify: `Features/Navigation/SidebarDropPolicy.swift:148-150` (the row-9 guard)
- Modify: `MoolahTests/Navigation/SidebarDropPolicyOutcomeTests.swift` (flip the existing row-9 test, add standalone-source variant)

- [ ] **Step 6.1: Locate and update the existing row-9 test.**

`grep -n "row 9" MoolahTests/Navigation/SidebarDropPolicyOutcomeTests.swift`. Update its body so:

1. The dragged source is a member of group `A` (created via `Support.bankAccount` + setting `groupId` to `groupA.id`).
2. The target is group `B` (a separate `Support.currentGroup`) with `intoElement: .group(groupB.id)` and `childIndex: 1`.
3. Assert: `#expect(outcome == .reorderMembers(groupId: groupB.id, sourceAccountId: source.id, insertionIndex: 1))`.

- [ ] **Step 6.2: Add a "standalone source between members" variant test.**

Append a new `@Test` that asserts the same `.reorderMembers` outcome when the dragged source is a standalone account with `groupId == nil`. The target is `intoElement: .group(group.id)`, `childIndex: 0`. This is a *new* row-9 sub-case that the relaxed policy now allows.

- [ ] **Step 6.3: Run the policy tests, verify failure.**

```bash
just test SidebarDropPolicyOutcomeTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: both row-9 tests fail — the current policy still returns `.deny` for non-members.

- [ ] **Step 6.4: Remove the row-9 guard from `outcomeForGroup`.**

In `Features/Navigation/SidebarDropPolicy.swift`, find `outcomeForGroup` and inside the `if let idx = childIndex {` branch, delete these three lines:

```swift
// row 9: an account NOT currently in this group cannot be
// dropped between its members (use drop-onto-group instead).
guard sourceAccount.groupId == gId else { return .deny }
```

The branch should now look like:

```swift
if let idx = childIndex {
  // row 8.
  return .reorderMembers(
    groupId: gId, sourceAccountId: dragged.id, insertionIndex: idx)
} else {
  ...
}
```

(The drop-onto-group no-op guard on the `else` branch — `guard sourceAccount.groupId != gId else { return .deny }` — stays as-is. That covers the different "drop onto the group row when source is already a member" gesture.)

- [ ] **Step 6.5: Re-run policy tests; verify pass.**

```bash
just test SidebarDropPolicyOutcomeTests 2>&1 | tee .agent-tmp/test-output.txt
grep -E 'failed|error:' .agent-tmp/test-output.txt
```

- [ ] **Step 6.6: Verify retarget tests still pass.**

```bash
just test SidebarDropPolicyRetargetTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: pass. The retarget path now completes for member sources targeting member-of-other-group rows.

- [ ] **Step 6.7: Format-check, build.**

```bash
just format
just format-check
just build-mac
```

- [ ] **Step 6.8: Commit.**

```bash
git -C $(pwd) add Features/Navigation/SidebarDropPolicy.swift MoolahTests/Navigation/SidebarDropPolicyOutcomeTests.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
feat(sidebar): allow non-member sources between group members

Drops the row-9 deny in SidebarDropPolicy.outcomeForGroup. With
reorderMembers in a previous commit handling both standalone and
cross-group sources, this completes the drag-out-of-group feature
end-to-end.

EOF
)"
rm -f .agent-tmp/test-output.txt
```

---

## Task 7: Add XCUITest scenario — sole member of A dropped onto standalone in same bucket

**Files:**
- Modify: `MoolahUITests_macOS/Tests/Sidebar/SidebarDragAndDropMacTests.swift`

This is the only end-to-end gesture exercisable through `SidebarScreen.dragAccount(_:ontoAccount:)`, which lands at the centre of the target row (drop-between gestures from §1-§3 of the spec aren't reachable through the existing driver — those are covered by the unit tests above).

**Seed/identifier ground truth (verified at plan-time):**
- `.tradeBaseline` seed (`UITestSeed.tradeBaseline`) gives us, in the investments bucket: `.brokerage` (standalone), `.tradesBrokerage` (standalone), `.renameTarget` group (0 members — see `App/UITestSeedHydrator.swift:299-317`).
- `SidebarScreen.dragAccount(_:ontoAccount:)` and `SidebarScreen.dragAccount(_:ontoGroup:)` are the two centre-of-row drag primitives.
- The investments bucket is the one we drag in because `.tradeBaseline` has two standalones there; the `.current` bucket only has `.checking`, so cross-bucket drags would be denied.

**Scenario built from existing seed (no seed extension required):**

1. Drag `.brokerage` onto group `.renameTarget` (0 → 1 member; uses unchanged `dropOntoGroup` no-old-group path; existing code).
2. Drag `.brokerage` (now sole member of `.renameTarget`) onto `.tradesBrokerage` (standalone). With T1 in place, the source removes from `.renameTarget` (which empties and auto-deletes), then joins `.tradesBrokerage` in a newly created 2-member group.
3. Assert the `.renameTarget` group row is gone from the sidebar.

The on-created-group inline-rename callback will fire from step 2 (a new group was created), surfacing a rename TextField on the *new* group — not on `.renameTarget`. The new-group field doesn't interfere with the `.renameTarget` group-row-gone assertion.

- [ ] **Step 7.1: Write the failing XCUITest.**

Append to `MoolahUITests_macOS/Tests/Sidebar/SidebarDragAndDropMacTests.swift` (inside the existing `final class SidebarDragAndDropMacTests: MoolahUITestCase` body, after the third test):

```swift
/// Cross-group drop-onto: drag the sole member of a 1-member group onto
/// another standalone account in the same bucket. With the dropOnto
/// dispatch generalised to remove the source from its old group first,
/// the old group auto-deletes when emptied — its row should disappear
/// from the sidebar. Built from `.tradeBaseline` without seed
/// extensions: drag `.brokerage` onto the empty `.renameTarget` group
/// first to make it a 1-member group, then drag it back out onto
/// `.tradesBrokerage`.
func testDragSoleMemberOntoStandaloneDeletesOldGroup() {
  let app = launch(seed: .tradeBaseline)

  // Step 1: populate the empty .renameTarget group with .brokerage.
  app.sidebar.dragAccount(.brokerage, ontoGroup: .renameTarget)
  let brokerageRow = app.element(
    for: UITestIdentifiers.Sidebar.account(SidebarAccount.brokerage.id))
  let brokerageExists = XCTNSPredicateExpectation(
    predicate: NSPredicate(format: "exists == true"), object: brokerageRow)
  XCTAssertEqual(
    XCTWaiter.wait(for: [brokerageExists], timeout: 3), .completed,
    "Brokerage row missing after dropping into renameTarget group")

  // Step 2: drag .brokerage (now sole member of .renameTarget) onto
  // .tradesBrokerage. With the new dropOntoAccount path, .renameTarget
  // is emptied + auto-deleted.
  app.sidebar.dragAccount(.brokerage, ontoAccount: .tradesBrokerage)

  // Post-condition: the renameTarget group row disappears.
  let groupRow = app.element(
    for: UITestIdentifiers.Sidebar.group(SidebarGroup.renameTarget.id))
  let groupGone = XCTNSPredicateExpectation(
    predicate: NSPredicate(format: "exists == false"), object: groupRow)
  XCTAssertEqual(
    XCTWaiter.wait(for: [groupGone], timeout: 3), .completed,
    "renameTarget group row still present 3s after sole member dragged out")
}
```

- [ ] **Step 7.2: Run the UI test, verify it passes against the now-completed code.**

```bash
just test SidebarDragAndDropMacTests 2>&1 | tee .agent-tmp/uitest-output.txt
```

Expected: the new test passes. (Tasks 1-6 already make the underlying behaviour correct; this task only adds the end-to-end safety net.)

If `just test` reports "hung before establishing connection", a stale `Moolah` test-host or `xctest` process from another worktree may be holding the port — see `reference_macos_test_runner_hang` in memory. Resolve with:

```bash
pkill -f Moolah.app/Contents/MacOS/Moolah || true
pkill -f xctest || true
just test SidebarDragAndDropMacTests 2>&1 | tee .agent-tmp/uitest-output.txt
```

- [ ] **Step 7.3: Format-check, build.**

```bash
just format
just format-check
just build-mac
```

- [ ] **Step 7.4: Commit.**

```bash
git -C $(pwd) add MoolahUITests_macOS/Tests/Sidebar/SidebarDragAndDropMacTests.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
test(sidebar): XCUITest for drop-onto deletes empty old group

End-to-end coverage for the cross-group drop-onto path. Drop-between
gestures aren't reachable through XCUITest's centre-of-row drag
primitive; those are covered by SidebarDropDispatchReorderTests and
SidebarDropPolicyOutcomeTests.

EOF
)"
rm -f .agent-tmp/uitest-output.txt
```

---

## Task 8: Full-suite verification

**Files:** (no modifications — verification only)

- [ ] **Step 8.1: Run the full test suite.**

```bash
just test 2>&1 | tee .agent-tmp/full-test.txt
grep -E 'failed|error:' .agent-tmp/full-test.txt
```

Expected: no failures, no errors. If anything failed, diagnose — the most likely culprits are:

- A coordinator-commit test that calls `reorderMembers` without `accountGroupStore:` (Task 4 should have updated the only callsite, but a search-and-update grep is safer).
- A policy retarget test that asserted a `.deny` on a now-permissive case.
- A SwiftLint baseline violation if `just format-check` was skipped in a previous task.

- [ ] **Step 8.2: Re-run format-check, scoped tests.**

```bash
just format-check
just test SidebarDropDispatchTests SidebarDropDispatchReorderTests SidebarDropPolicyOutcomeTests SidebarDropPolicyRetargetTests SidebarOutlineDropCoordinatorCommitTests
```

Expected: clean format, all suites pass.

- [ ] **Step 8.3: Check Xcode navigator for warnings.**

Use `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` and scan for any user-code warnings in `Features/Navigation/SidebarDropDispatch.swift`, `SidebarDropPolicy.swift`, `SidebarOutlineDropCoordinator.swift`, and the test files touched.

Expected: zero warnings in user code (preview macro warnings can be ignored — see CLAUDE.md §Pre-Commit Checklist).

- [ ] **Step 8.4: Clean up temp files.**

```bash
rm -f .agent-tmp/full-test.txt
```

- [ ] **Step 8.5: Open a PR.**

```bash
git -C $(pwd) push -u origin worktree-close-999-move-rename-plans:worktree-close-999-move-rename-plans
gh pr create --title "feat(sidebar): drag account back out of a group" --body "$(cat <<'EOF'
## Summary
- Lets users drag a group member back out of its group via the existing drop-between-entries gesture (root insertion slot and cross-group member-list both supported).
- Closes the latent old-group-leak in `dropOntoAccount` / `dropOntoGroup` — a member of a 1-member group dropped onto another group no longer leaves an empty group row behind.
- Generalises all four `SidebarDropDispatch` entry points to remove the source from its old group (via `AccountGroupStore.removeAccount`) before completing the destination transition.
- Relaxes `SidebarDropPolicy` row 3 and row 9 to route the new gestures through existing `.reorderRoot` / `.reorderMembers` outcomes — zero new outcome cases.

## Test plan
- [x] `just test` — full suite green
- [x] New unit tests for each generalised dispatch entry (cross-group, sole-member-of-old-group, standalone-into-group cases)
- [x] New XCUITest for the sole-member-of-A → standalone-in-same-bucket end-to-end case
- [x] Policy decision-table tests for the flipped row 3 / row 9 cells

## Design
See [`plans/2026-05-29-sidebar-drag-out-of-group-design.md`](./plans/2026-05-29-sidebar-drag-out-of-group-design.md) for the full design.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Then queue with the landing-prs skill / `gh pr merge --auto --rebase` per the user's `feedback_prs_to_merge_queue` memory.

---

## Self-review checklist (run before handing off)

- All four dispatch entry points have a code task: `dropOntoAccount` (T1), `dropOntoGroup` (T2), `reorderRoot` (T3), `reorderMembers` (T4). ✓
- Both policy guards have a code task: row 3 (T5), row 9 (T6). ✓
- Coordinator callsite update is in T4 alongside the `reorderMembers` signature change so the build never breaks between commits. ✓
- All test types referenced: Swift Testing for unit, XCTest for UI. ✓
- Every code-change step includes verification (test + format-check + build) before commit. ✓
- No placeholders, TODOs, or "implement later" left in steps. All identifiers (seeds, accounts, group ids) resolved at plan-time and inlined. ✓
- Helper identifiers (`SidebarDropDispatchTestSupport.bankAccount`, `makeStores`, etc.) used consistently throughout. ✓
