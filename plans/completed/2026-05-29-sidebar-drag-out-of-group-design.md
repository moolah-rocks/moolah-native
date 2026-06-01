# Sidebar drag-out-of-group — Design

## Problem

The macOS sidebar lets the user drag an account *into* a group (by dropping onto another account or onto a group row), but does not let them drag an account *out* of a group. Today, dropping a member account between two top-level entries is rejected by the drop policy with `.deny`. The only way to extract a member is via the context-menu "Remove from group" action, which is undiscoverable for a user reaching for the drag they already learned.

Three related gestures are currently denied and in scope here:

1. **Member → root insertion slot.** Drag a group member; drop between two top-level entries (account or group). Should land at the dropped slot, no longer a group member.
2. **Source (member of A, or standalone) → between members of group B.** Currently the policy only allows reordering *within* the source's existing group. Dropping a non-member account between B's members should add it to B at the dropped position.
3. **Bottom-of-row retarget for member sources.** When the cursor hovers the lower half of a top-level account row, `NSOutlineView` reports `.account` + child index, and the policy retargets to a root insertion slot. Today that retarget then fails the second pass through `outcomeForRoot` because of row 3. Once row 3 is permissive, the retarget completes naturally.

A related latent bug, also in scope:

4. **Old-group leak on drop-onto.** `SidebarDropDispatch.dropOntoAccount` (when target is already a member) and `dropOntoGroup` (always) accept a member of group A as the source and set its `groupId` to the destination group, but neither auto-deletes A when the source was its sole remaining member. Today this is hard to trigger because there's no other gesture that moves a member account, but it's reachable: drag the sole member of A onto a member of B (or onto group B). With drag-out shipping, the leak becomes easier to discover. The fix is uniform with the new gestures (`removeAccount` first when source has an old group), so all four call sites are addressed in one pass.

## Non-goals

- Changing the iOS sidebar drop semantics. The iOS drop coordinator path in `SidebarView+Groups.swift` shares the dispatch layer; behaviour there changes only inasmuch as the new dispatch shape applies. No new iOS gestures are added in scope.
- Auto-dissolving 1-member groups. A drag-out that leaves one member behind keeps the 1-member group intact. Only *empty* groups are auto-deleted (matching the existing `AccountGroupStore.removeAccount(_:accountStore:)` behaviour).
- Cross-bucket drags. Same-bucket guards stay in force — a member of a "Current" group cannot be dragged to "Investments". Out of scope.
- Visual hint redesign for the new gestures. The existing drop indicator (`NSOutlineView`'s insertion line / row highlight) is reused as-is.

## Approach

Relax the two policy guards that reject the source's group membership, and absorb the membership transition inside the four dispatch entry points (`reorderRoot`, `reorderMembers`, `dropOntoAccount`, `dropOntoGroup`). The decision table grows zero new outcomes; the dispatch grows small "if source is currently in a group different from where it's heading, remove from old group first" branches.

The membership transition leans on the existing `AccountGroupStore.removeAccount(_:accountStore:)` — that method already clears `Account.groupId`, repositions the source to the end of its bucket's standalone list, and auto-deletes a group that becomes empty. The position-walk in `reorderRoot` / `reorderMembers` then overwrites the temp position with the dropped insertion-index position; for `dropOntoAccount` / `dropOntoGroup`, the subsequent `addAccount` (or join into a new group) sets the final state. Reusing `removeAccount` is one extra `accountStore.update` per cross-group transition vs. a hand-rolled minimal-write path, but reuses tested code and inherits the auto-delete bookkeeping for free.

## Architecture

### Policy — `Features/Navigation/SidebarDropPolicy.swift`

Two guards removed; everything else unchanged.

**`outcomeForRoot` — remove the row-3 guard.**

```swift
// REMOVE:
// row 3: dragging a member to root denies (no silent un-group).
guard sourceAccount.groupId == nil else { return .deny }
```

The account-source branch of `outcomeForRoot` falls through to `.reorderRoot(item: dragged, insertionIndex: idx)` regardless of whether the source is a member.

**`outcomeForGroup` — remove the row-9 guard.**

```swift
// REMOVE:
// row 9: an account NOT currently in this group cannot be
// dropped between its members (use drop-onto-group instead).
guard sourceAccount.groupId == gId else { return .deny }
```

The "drop between members" branch falls through to `.reorderMembers(groupId: gId, sourceAccountId: dragged.id, insertionIndex: idx)` whether the source is a member of this group, a member of another group, or standalone.

**`retargetForAccount` — no change.** With rows 3 and 9 now permissive, the retarget's second pass (after `outlineView.setDropItem(...)`) lands on the relaxed `outcomeForRoot` / `outcomeForGroup` and succeeds.

Decision-table cells that flip:

| Row | Trigger | Before | After |
|-----|---------|--------|-------|
| 3 | member dragged to root insertion slot | `.deny` | `.reorderRoot(item, idx)` |
| 9 | non-member dragged between group members | `.deny` | `.reorderMembers(gId, sourceId, idx)` |

The "drop *onto* a group row when source is already in that group" no-op guard (row 6 variant) stays — it covers a different gesture (full-row highlight, not insertion line) and avoids a no-op store write.

### Dispatch — `Features/Navigation/SidebarDropDispatch.swift`

**`reorderRoot` — handle a member source by removing it first.**

```swift
static func reorderRoot(
  dragged: DraggableSidebarItem,
  insertionIndex: Int,
  bucket: AccountBucket,
  accountStore: AccountStore,
  accountGroupStore: AccountGroupStore
) async throws {
  if case .account = dragged.kind,
     let source = accountStore.accounts.by(id: dragged.id),
     source.groupId != nil {
    try await accountGroupStore.removeAccount(source, accountStore: accountStore)
  }

  // EXISTING: walk-order position rewrite over bucket entries.
  let entries = bucketEntries(
    bucket: bucket,
    accountStore: accountStore,
    accountGroupStore: accountGroupStore)
  ...
}
```

`removeAccount` clears `groupId`, parks the source at end-of-standalone-list, and deletes the empty old group when the source was its last member. The subsequent walk overwrites position to the dropped insertion-index slot.

**`reorderMembers` — accept a different-group or standalone source.**

```swift
static func reorderMembers(
  groupId: UUID,
  sourceAccountId: UUID,
  insertionIndex: Int,
  accountStore: AccountStore,
  accountGroupStore: AccountGroupStore   // NEW parameter
) async throws {                          // NEW: now throws
  guard let source = accountStore.accounts.by(id: sourceAccountId) else { return }

  if source.groupId != groupId {
    if source.groupId != nil {
      try await accountGroupStore.removeAccount(source, accountStore: accountStore)
    }
    guard let refreshed = accountStore.accounts.by(id: sourceAccountId)
    else { return }
    var member = refreshed
    member.groupId = groupId
    _ = try await accountStore.update(member)
  }

  // EXISTING: rewrite member positions for `groupId`.
  var members = accountStore.accounts.ordered
    .filter { $0.groupId == groupId }
    .sorted { $0.position < $1.position }
  ...
}
```

For cross-group: `removeAccount` clears the source's `groupId` and auto-deletes the old group when empty. The subsequent `accountStore.update` sets `groupId = groupId` (target). The member walk then assigns the final position. For standalone-source: the first `if` skips `removeAccount` (no old group to handle) and falls through to the `groupId = groupId` write directly.

**`dropOntoAccount` — remove from old group first when source is a cross-group member.**

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

  // NEW: if source is currently in a group, and either the target is
  // standalone (will join a new group) or the target is in a different
  // group (will join target's group), clean up the source's old group
  // first. The exception is target.groupId == source.groupId — that's
  // a no-op transition and removeAccount would needlessly churn.
  if let sourceGroupId = source.groupId, sourceGroupId != target.groupId {
    try await accountGroupStore.removeAccount(source, accountStore: accountStore)
    // Refresh the source snapshot — its groupId is nil now.
    guard accountStore.accounts.by(id: sourceId) != nil else { return nil }
  }

  // EXISTING (unchanged): target-already-member adds to group; otherwise
  // creates a 2-member group joining the two.
  if let targetGroupId = target.groupId {
    guard let group = accountGroupStore.by(id: targetGroupId) else { return nil }
    // Re-read source post-removeAccount.
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

**`dropOntoGroup` — remove from old group first when source is a cross-group member.**

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

  // NEW: if source is currently in a different group, remove from it
  // first so the old group auto-deletes when emptied.
  if source.groupId != nil {
    try await accountGroupStore.removeAccount(source, accountStore: accountStore)
  }

  // Re-read post-removeAccount; addAccount sets groupId to target.
  guard let refreshed = accountStore.accounts.by(id: sourceId) else { return }
  try await accountGroupStore.addAccount(
    refreshed, to: group, accountStore: accountStore)
  await groupUIStateStore.setExpanded(true, for: group.id)
}
```

Both retain their existing same-bucket and not-already-in-this-group guards. The `source.groupId != group.id` (resp. `targetGroupId != source.groupId`) check above the `removeAccount` call avoids the wasteful "remove and re-add to the same group" sequence.

### Coordinator — `Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift`

Single callsite ripple inside `commit(_:bucket:)`:

```swift
case let .reorderMembers(groupId, sourceId, idx):
  do {
    try await SidebarDropDispatch.reorderMembers(
      groupId: groupId,
      sourceAccountId: sourceId,
      insertionIndex: idx,
      accountStore: accountStore,
      accountGroupStore: accountGroupStore)   // NEW
  } catch {
    // Error already surfaced reactively on accountGroupStore.error.
  }
  return true
```

`accountGroupStore` is already a stored property on the coordinator; wire-up is mechanical.

## Data flow

Member → root insertion slot, source's old group has ≥2 members:

1. User drags member `m` (in group `A`) between two root entries.
2. `validateDrop` → `outcome(...)` → `.reorderRoot(item: .account(m.id), idx)`. (Row 3 lifted.)
3. User releases. `acceptDrop` → `commit(.reorderRoot(...), bucket:)` → `SidebarDropDispatch.reorderRoot(...)`.
4. `removeAccount(m, accountStore:)`: writes `m` with `groupId = nil`, position = end-of-standalone. `A` still has members; no delete.
5. `bucketEntries(...)` reads the post-update snapshot; `m` is now a standalone entry.
6. Walk-order rewrite assigns each entry its position, including `m` at `clampedIndex`.

Member → root insertion slot, source is the sole member of its group:

1-3 unchanged.
4. `removeAccount(m, accountStore:)`: writes `m` with `groupId = nil`. Membership snapshot for `A` is now empty → `accountGroupStore.repository.delete(id: A.id)`. Reactive observation drops `A` from `accountGroupStore.groups`.
5. `bucketEntries(...)` no longer includes `A`; only the new standalone `m` and other root entries.
6. Walk-order rewrite assigns positions.

Standalone → between members of group `B`:

1. User drags standalone `s` between two members of `B`.
2. `validateDrop` → `outcome(...)` → `.reorderMembers(groupId: B.id, sourceAccountId: s.id, insertionIndex: idx)`. (Row 9 lifted.)
3. `commit(...)` → `reorderMembers(...)`.
4. `source.groupId != groupId` (B.id) → outer branch entered.
5. `source.groupId == nil` → skip `removeAccount`.
6. `accountStore.update(s with groupId = B.id)`.
7. Member walk reads `B`'s members from post-update snapshot, places `s` at `clampedIndex`, writes back updated positions.

Member of `A` → between members of `B`, `A` has ≥2 members:

1-3 as above, but with `s` = member of `A`.
4. `source.groupId != groupId` → entered.
5. `source.groupId != nil` → `removeAccount(s, accountStore:)` (clears `s.groupId`, `A` keeps remaining members).
6. `refreshed.groupId = B.id` → `accountStore.update`.
7. Member walk places `s` at `clampedIndex` in `B`'s member list.

Member of `A` → between members of `B`, `s` is sole member of `A`:

Same as above except step 5 also deletes `A` via the auto-delete branch inside `removeAccount`.

## Error handling

Existing error-surface contract is preserved:

- `accountStore.update` and `accountGroupStore.repository.delete` errors propagate up through `removeAccount` and out of `SidebarDropDispatch.reorderRoot` / `reorderMembers`. The coordinator's `do { try await … } catch { … }` blocks already absorb the throw; underlying stores capture the error reactively on their `error` properties for the UI to render.
- If `removeAccount` throws, the position walk does not run — the source stays in its old group at its old position. No partial state from the user's perspective; the drop animation completes (the dispatch returned `true`), but the reactive state stream restores the original positions on next emission.
- The post-`removeAccount` re-read of `accountStore.accounts.by(id:)` returns `nil` only if the account was concurrently deleted by some other actor; the dispatch returns silently and the reactive emission carries the deletion to the UI.

## Testing

### Unit — policy

`MoolahTests/Navigation/SidebarDropPolicyOutcomeTests.swift`:

- Row 3 case (member dragged to root insertion slot) — assertion flips from `.deny` to `.reorderRoot(item: .account(m.id), insertionIndex: idx)`.
- Row 9 case (non-member dragged between group members) — assertion flips from `.deny` to `.reorderMembers(groupId: gId, sourceAccountId: s.id, insertionIndex: idx)`.
- Add a row-9 variant covering a standalone source: same `.reorderMembers` outcome.
- Row 5 (cross-bucket) cases remain `.deny` for all three new gestures; add the three permutations.

`MoolahTests/Navigation/SidebarDropPolicyRetargetTests.swift`:

- Member-source retarget to root via bottom-of-standalone-row: assert `.retargetRoot(insertionIndex:)` then assert the recursive second pass yields `.reorderRoot` (not `.deny`).
- Member-of-A source retarget to a member-of-B row: assert `.retargetGroup(groupId: B.id, insertionIndex:)` then assert the second pass yields `.reorderMembers`.

### Unit — dispatch

`MoolahTests/Navigation/SidebarDropDispatchTests.swift` / `SidebarDropDispatchReorderTests.swift`:

For `reorderRoot`:

1. Standalone source dropped to root — regression; existing position walk produces the expected ordering.
2. Member of a 2-member group dropped to a root insertion slot — assert source's `groupId == nil`, source's position == dropped index in walk order, old group still exists with one member.
3. Sole member of a 1-member group dropped to root — assert source's `groupId == nil`, old group no longer in `accountGroupStore.groups`.

For `reorderMembers`:

1. Intra-group reorder — regression; positions for the target group reflect the new order.
2. Standalone source dropped between members of group B — assert source's `groupId == B.id`, position matches insertion index, B's other members' positions shift to accommodate.
3. Member of group A dropped between members of group B, A still has ≥2 members — assert source's `groupId == B.id`, A still exists with reduced membership.
4. Sole member of group A dropped between members of group B — assert source's `groupId == B.id`, A is deleted.

For `dropOntoAccount`:

1. Two standalones — regression; existing 2-member group is created joining them.
2. Standalone source dropped onto a member of existing group B — regression; source is added to B.
3. Member of A dropped onto a member of B, A still has ≥2 members — source joins B, A still exists with reduced membership.
4. Sole member of A dropped onto a member of B — source joins B, A is deleted.
5. Sole member of A dropped onto a standalone in the same bucket — source + standalone are joined into a new group; A is deleted.

For `dropOntoGroup`:

1. Standalone source dropped onto group B — regression; source is added to B.
2. Member of A dropped onto group B, A still has ≥2 members — source joins B, A still exists.
3. Sole member of A dropped onto group B — source joins B, A is deleted.

### Unit — coordinator

`MoolahTests/Navigation/SidebarOutlineDropCoordinatorCommitTests.swift`:

- One test exercising the now-throwing `reorderMembers` plumbing: dispatch a `.reorderMembers` outcome that triggers a cross-group transition; assert the coordinator awaits the throwing call and surfaces success.

### XCUITest — `MoolahUITests_macOS/Tests/Sidebar/SidebarDragAndDropMacTests.swift`

XCUITest's `press(forDuration:thenDragTo:)` primitive lands at the centre of the target row, which `SidebarDropPolicy` interprets as "drop onto" rather than "drop between". The drop-between gestures from §1, §2, §3 of this spec therefore cannot be exercised through the existing `SidebarScreen.dragAccount(...)` driver as drop-between gestures — those branches are covered by the policy / dispatch unit tests above.

The new XCUITest scenario that *is* exercisable via the existing centre-of-row drag is the cross-group drop-onto case (§4):

1. Drag the sole member of a 1-member group A onto a standalone account in the same bucket — verify A is no longer rendered in the sidebar after the drop completes (its row disappears from the accessibility tree).

The existing drag-into tests (`testDragAccountOntoAccountCreatesGroup`, `testDragAccountOntoGroupJoinsIt`, `testDragReordersStandaloneAccounts`) stay as regression coverage for the unchanged drop-onto paths.

## Risks

1. **`removeAccount` ordering vs. the position walk.** The post-`removeAccount` read of `bucketEntries(...)` (in `reorderRoot`) and `accountStore.accounts.ordered.filter(...)` (in `reorderMembers`) happens after the `try await accountStore.update(...)` inside `removeAccount` resolves. The reactive snapshot reflects the update by then; tracing the existing `removeAccount` callsites confirms the snapshot post-update is authoritative for subsequent reads.

2. **Intermediate position visible in reactive emission.** `removeAccount` parks the source at end-of-standalone temporarily before the position walk overwrites it. The two writes complete inside the same `Task` before any UI re-render lands, so the intermediate state should not produce visible flicker. Mitigation if observed in practice: collapse via a batched `accountStore.update` API — out of scope for now, gated on actually seeing flicker.

3. **Bottom-of-row retarget reliance on second-pass permissiveness.** The retarget machinery in `validateDrop` calls `outlineView.setDropItem(...)`, which triggers a second `validateDrop` pass with the retargeted `(item, childIndex)`. Both passes go through the same `outcome(...)` entry; once rows 3 and 9 are lifted, the second pass resolves to a positive outcome. Verified by the policy tests above.

4. **Concurrency.** The existing `Task { await coordinator.commit(...) }` in `SidebarOutlineDataSource+DragDrop.swift:89` serialises commits. `reorderRoot` / `reorderMembers` are now multi-write but stay within a single `Task` boundary; no additional Task hygiene needed.

## Open questions

None at present. All scope and behaviour questions were resolved in the brainstorm.

## References

- Existing remove-from-group precedent: `Features/Accounts/AccountGroupStore+Mutations.swift:124-152`
- Current policy: `Features/Navigation/SidebarDropPolicy.swift`
- Current dispatch: `Features/Navigation/SidebarDropDispatch.swift`
- Current coordinator: `Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift`
- AppKit data-source surface: `Features/Navigation/AppKitSidebar/SidebarOutlineDataSource+DragDrop.swift`
- Related GitHub issue: #991 (drag-and-drop feature for grouping)
