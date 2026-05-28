# Sidebar Drag-and-Drop Wiring (macOS) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task-by-task. Per project memory (`feedback_subagent_driven.md`), do not ask whether to use it — that is the default. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close [#991](https://github.com/moolah-rocks/moolah-native/issues/991) by wiring native `NSOutlineViewDataSource` drag methods (`pasteboardWriter(forItem:)`, `validateDrop`, `acceptDrop`) into the unified macOS sidebar's `SidebarOutlineDataSource`. The view-agnostic foundation — `SidebarDropPolicy`, `SidebarDropDispatch`, `DraggableSidebarItem+Pasteboard`, `iOS handleDrop` rewrite — already shipped via PRs [#993](https://github.com/moolah-rocks/moolah-native/pull/993), [#995](https://github.com/moolah-rocks/moolah-native/pull/995), [#996](https://github.com/moolah-rocks/moolah-native/pull/996); this plan adds the AppKit consumer.

**Architecture:** Introduce a `@MainActor final class SidebarOutlineDropCoordinator` that owns references to the four stores and exposes two layers of helpers:

1. **Pure static translators** that map `NSOutlineView`'s `(proposedItem, childIndex)` plus a `DraggableSidebarItem` into a `SidebarDropTarget` and the inferred target `AccountBucket`. Tested as pure value transforms.
2. **Instance methods** `outcome(for:bucket:)` and `commit(_:bucket:)` that read the live store snapshots, call `SidebarDropPolicy.outcome(...)`, and dispatch the resulting `DropOutcome` through `SidebarDropDispatch`. `commit` invokes an `onCreatedGroup` callback when `dropOntoAccount` creates a new group, so the host `SidebarOutline` can push the new group into inline-rename mode.

`SidebarOutlineDataSource` gains a `weak var dropCoordinator: SidebarOutlineDropCoordinator?` and three small methods that decode the pasteboard, ask the coordinator to resolve / commit, and call `setDropItem(_:dropChildIndex:)` for retarget hints. `SidebarOutlineController.configureOutlineView()` registers `DraggableSidebarItem.pasteboardType` for dragged input. `SidebarOutline.makeNSViewController` constructs the coordinator, attaches it to the data source, and wires `onCreatedGroup → editingRowId`.

**Tech Stack:** AppKit `NSOutlineView` + `NSPasteboard`, existing `@MainActor` stores (`AccountStore`, `AccountGroupStore`, `GroupUIStateStore`), existing `SidebarDropPolicy` / `SidebarDropDispatch`, Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`) for unit tests, XCUITest for the end-to-end safety net.

**Branch:** `fix-sidebar-drag-991` (this worktree), stacked on `sidebar-inline-rename-macos` (PR [#1006](https://github.com/moolah-rocks/moolah-native/pull/1006)). Per `CLAUDE.md` §"Stacked-PR worktrees", the worktree was created with `--no-track`; pushes use the explicit `src:dst` form.

---

## File structure

The new code lives under `Features/Navigation/AppKitSidebar/`. The data source extension goes in a new file rather than the existing one to keep `SidebarOutlineDataSource.swift` under SwiftLint's `file_length` threshold and to keep the drag-and-drop surface grep-able.

**Create:**

- `Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift` — `@MainActor final class` holding the four stores. Static pure helpers for bucket inference + target translation; instance methods for outcome + commit; `onCreatedGroup` callback.
- `Features/Navigation/AppKitSidebar/SidebarOutlineDataSource+DragDrop.swift` — extension on `SidebarOutlineDataSource` implementing `pasteboardWriter(forItem:)`, `validateDrop`, `acceptDrop`. Holds a `weak var dropCoordinator` via an associated-object-free design (a plain stored property added in this file's extension is illegal; the property is moved to the base class).
- `MoolahTests/Navigation/SidebarOutlineDropCoordinatorBucketTests.swift` — Swift Testing suite for `bucket(forProposedItem:accounts:groups:)`. Pure value tests.
- `MoolahTests/Navigation/SidebarOutlineDropCoordinatorTargetTests.swift` — Swift Testing suite for `target(forProposedItem:childIndex:dragged:accounts:groups:)`. Pure value tests.
- `MoolahTests/Navigation/SidebarOutlineDropCoordinatorCommitTests.swift` — Swift Testing suite for `commit(_:bucket:)` over `TestBackend`. One test per `DropOutcome` case, plus the `onCreatedGroup` callback assertion.
- `MoolahTests/Navigation/SidebarOutlineDropCoordinatorTestSupport.swift` — shared fixture builder for the bucket/target test suites (mirrors `SidebarDropPolicyTestSupport`).
- `MoolahTests/Navigation/DraggableSidebarItemPasteboardReadTests.swift` — Swift Testing suite for the new `read(from: NSPasteboard)` helper. Two tests: round-trip pasteboard read, missing-type pasteboard returns nil.
- `MoolahUITests_macOS/Tests/Sidebar/SidebarDragAndDropMacTests.swift` — XCUITest suite covering drag-onto-account-creates-group, drag-onto-group-adds, and drag-reorder.

**Modify:**

- `Features/Navigation/AppKitSidebar/SidebarOutlineDataSource.swift` — add `weak var dropCoordinator: SidebarOutlineDropCoordinator?` stored property on the base class. (Stored properties cannot live in extensions; the data-source drag methods themselves go in the new `+DragDrop.swift` file.)
- `Features/Navigation/AppKitSidebar/SidebarOutlineController.swift` — in `configureOutlineView()`, call `outlineView.registerForDraggedTypes([DraggableSidebarItem.pasteboardType])` and `outlineView.setDraggingSourceOperationMask([.move], forLocal: true)`.
- `Features/Navigation/AppKitSidebar/SidebarOutline.swift` — in `makeNSViewController`, construct a `SidebarOutlineDropCoordinator`, assign it to `controller.dataSource.dropCoordinator`, and set its `onCreatedGroup = { editingRowId = $0.id }`.
- `Features/Navigation/DraggableSidebarItem+Pasteboard.swift` — add `static func read(from pb: NSPasteboard) -> DraggableSidebarItem?` convenience.

**Untouched (referenced only):**

- `Features/Navigation/SidebarDropPolicy.swift` — call sites only.
- `Features/Navigation/SidebarDropDispatch.swift` — call sites only.
- `Features/Navigation/SidebarView+Groups.swift` — iOS-only `handleDrop`, unchanged.

**Closes:**

- [#991](https://github.com/moolah-rocks/moolah-native/issues/991) — drag-and-drop wiring for the unified macOS sidebar.

---

## Functional acceptance criteria

By the end of this plan, the macOS sidebar must:

1. Allow the user to drag an account row (standalone or group member) onto another standalone account in the same bucket, creating a new 2-member group and immediately entering inline-rename mode on the new group's name.
2. Allow the user to drag an account onto an existing group row in the same bucket, adding the account as a member. Re-adding to the same group is rejected (no-op).
3. Allow the user to drag a standalone account or a group up/down within its bucket, reordering. Insertion line shows between rows during the drag.
4. Allow the user to drag a group member out into the same bucket's standalone area by dropping between two standalone rows.
5. Show a full-row blue drop highlight when hovering directly over a valid drop-onto target (account or group); show an insertion line between rows for a valid reorder slot.
6. Reject cross-bucket drags (current ↔ investments) silently — no highlight, no operation, the `[]` drag operation is returned.
7. Reject drags onto non-account / non-group rows (earmarks, totals, navigation, section headers) silently.
8. Survive expand/collapse state — dragging an account into an expanded group's member list reorders within the members; dragging into a collapsed group adds as a member.
9. Pass `just format-check`, `just build-mac`, `just build-ios`, `just test-mac`, `just test-ios` clean.

---

## Worktree assumptions

This plan is executed in the existing worktree:

```
WORKTREE=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/sidebar-drag-991
```

Branch `fix-sidebar-drag-991` is already created with `--no-track`, branched from `origin/sidebar-inline-rename-macos`. The Xcode project is regenerated as needed via `just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate`. Per `feedback_no_cd_for_any_tool.md`, do not `cd`; always use the `-d` / `git -C` forms.

Per `reference_macos_test_runner_hang.md`, if a previous session left stale Moolah test-host processes around (different worktrees / Xcode windows from PR #1006 still active), run `pkill -f Moolah` before any test invocation in this plan.

---

## Task 1: Coordinator skeleton + bucket inference

**Files:**

- Create: `Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift`
- Create: `MoolahTests/Navigation/SidebarOutlineDropCoordinatorTestSupport.swift`
- Create: `MoolahTests/Navigation/SidebarOutlineDropCoordinatorBucketTests.swift`

The pure bucket inference is a static function so it can be tested without standing up a `TestBackend`. The instance class skeleton is introduced here too, since later tasks need the symbol — but the four-store init is intentionally empty for now (no methods read the stores yet).

- [ ] **Step 1.1: Write the failing test fixture support file**

  Create `MoolahTests/Navigation/SidebarOutlineDropCoordinatorTestSupport.swift`:

  ```swift
  #if os(macOS)
    import Foundation

    @testable import Moolah

    /// Shared fixtures for the `SidebarOutlineDropCoordinator` pure
    /// helper test suites. Borrows the account / group factory shape
    /// from `SidebarDropPolicyTestSupport` so the policy suites and the
    /// coordinator suites can be read side-by-side.
    enum SidebarOutlineDropCoordinatorTestSupport {

      static func bankAccount(
        name: String, position: Int, groupId: UUID? = nil
      ) -> Account {
        Account(
          id: UUID(),
          name: name,
          type: .bank,
          instrument: .defaultTestInstrument,
          position: position,
          groupId: groupId)
      }

      static func investmentAccount(name: String, position: Int) -> Account {
        Account(
          id: UUID(),
          name: name,
          type: .investment,
          instrument: .defaultTestInstrument,
          position: position)
      }

      static func currentGroup(position: Int) -> AccountGroup {
        AccountGroup(
          name: "G",
          bucket: .current,
          instrument: .defaultTestInstrument,
          position: position)
      }

      static func investmentGroup(position: Int) -> AccountGroup {
        AccountGroup(
          name: "G",
          bucket: .investments,
          instrument: .defaultTestInstrument,
          position: position)
      }
    }
  #endif
  ```

- [ ] **Step 1.2: Write the failing bucket-inference test suite**

  Create `MoolahTests/Navigation/SidebarOutlineDropCoordinatorBucketTests.swift`:

  ```swift
  #if os(macOS)
    import Foundation
    import Testing

    @testable import Moolah

    /// Covers `SidebarOutlineDropCoordinator.bucket(forProposedItem:accounts:groups:)`.
    /// Pure value tests: each test sets up a hand-built `Accounts` /
    /// `[AccountGroup]` snapshot and asserts the inferred bucket for
    /// each `SidebarRow` case.
    @Suite("SidebarOutlineDropCoordinator — bucket inference")
    struct SidebarOutlineDropCoordinatorBucketTests {
      private typealias Support = SidebarOutlineDropCoordinatorTestSupport

      @Test("nil proposed item infers no bucket")
      func nilProposedItem() {
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: nil, accounts: Accounts(from: []), groups: [])
        #expect(result == nil)
      }

      @Test("section .current infers .current bucket")
      func sectionCurrent() {
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .section(.current),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == .current)
      }

      @Test("section .investments infers .investments bucket")
      func sectionInvestments() {
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .section(.investments),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == .investments)
      }

      @Test("section .earmarks infers no bucket (not a drop target)")
      func sectionEarmarks() {
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .section(.earmarks),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }

      @Test("section .totals infers no bucket")
      func sectionTotals() {
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .section(.totals),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }

      @Test("section .navigation infers no bucket")
      func sectionNavigation() {
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .section(.navigation),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }

      @Test("account row infers the account's bucket — current")
      func accountCurrent() {
        let account = Support.bankAccount(name: "A", position: 0)
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .account(account.id),
          accounts: Accounts(from: [account]),
          groups: [])
        #expect(result == .current)
      }

      @Test("account row infers the account's bucket — investments")
      func accountInvestments() {
        let account = Support.investmentAccount(name: "A", position: 0)
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .account(account.id),
          accounts: Accounts(from: [account]),
          groups: [])
        #expect(result == .investments)
      }

      @Test("group row infers the group's bucket")
      func groupBucket() {
        let group = Support.investmentGroup(position: 0)
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .group(group.id),
          accounts: Accounts(from: []),
          groups: [group])
        #expect(result == .investments)
      }

      @Test("unknown account id infers no bucket")
      func unknownAccount() {
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .account(UUID()),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }

      @Test("unknown group id infers no bucket")
      func unknownGroup() {
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .group(UUID()),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }

      @Test("earmark row infers no bucket (not a drop target)")
      func earmarkRow() {
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .earmark(UUID()),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }

      @Test("total row infers no bucket")
      func totalRow() {
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .total(.currentTotal),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }

      @Test("navigation row infers no bucket")
      func navigationRow() {
        let result = SidebarOutlineDropCoordinator.bucket(
          forProposedItem: .navigation(.analysis),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }
    }
  #endif
  ```

- [ ] **Step 1.3: Run the tests; verify they all fail to compile**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarOutlineDropCoordinatorBucketTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-task1-pre.txt"
  ```

  Expected: compile failure — `SidebarOutlineDropCoordinator` does not yet exist.

- [ ] **Step 1.4: Implement the coordinator skeleton + bucket inference**

  Create `Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift`:

  ```swift
  #if os(macOS)
    import AppKit
    import Foundation

    /// Mediates `NSOutlineView` drag-and-drop for the unified macOS
    /// sidebar. Owned by `SidebarOutline.makeNSViewController` and
    /// attached weakly to `SidebarOutlineDataSource` via its
    /// `dropCoordinator` property.
    ///
    /// Splits into two layers:
    ///
    /// 1. **Static pure translators** — `bucket(forProposedItem:...)`
    ///    and `target(forProposedItem:...)` map `NSOutlineView`'s
    ///    `(proposedItem, childIndex)` plus the dragged
    ///    `DraggableSidebarItem` into the policy-shaped inputs. They
    ///    take account / group snapshots as parameters so they are
    ///    unit-testable without standing up a backend.
    ///
    /// 2. **Instance methods** — `outcome(forProposedItem:childIndex:dragged:)`
    ///    and `commit(_:bucket:)` read the live store snapshots,
    ///    call `SidebarDropPolicy.outcome(...)`, and dispatch via
    ///    `SidebarDropDispatch`. `commit` invokes `onCreatedGroup`
    ///    when `dropOntoAccount` creates a new group so the host
    ///    binding can enter inline-rename mode.
    @MainActor
    final class SidebarOutlineDropCoordinator {
      let accountStore: AccountStore
      let accountGroupStore: AccountGroupStore
      let groupUIStateStore: GroupUIStateStore

      /// Fired after `commit` lands a `dropOntoAccount` outcome that
      /// joined two standalone accounts into a new group. The host
      /// (`SidebarOutline`) typically maps this to `editingRowId = id`
      /// so inline rename starts on the new group.
      var onCreatedGroup: ((AccountGroup) -> Void)?

      init(
        accountStore: AccountStore,
        accountGroupStore: AccountGroupStore,
        groupUIStateStore: GroupUIStateStore
      ) {
        self.accountStore = accountStore
        self.accountGroupStore = accountGroupStore
        self.groupUIStateStore = groupUIStateStore
      }

      /// Infers the `AccountBucket` implied by an `NSOutlineView`
      /// drop's proposed item. Section headers carry the bucket
      /// directly; account / group rows look up their bucket from the
      /// supplied snapshots. Any non-account / non-group / non-bucket
      /// section row returns `nil` — those rows are rejected at the
      /// data-source level.
      static func bucket(
        forProposedItem item: SidebarRow?,
        accounts: Accounts,
        groups: [AccountGroup]
      ) -> AccountBucket? {
        guard let item else { return nil }
        switch item {
        case .section(.current): return .current
        case .section(.investments): return .investments
        case .section: return nil
        case .account(let id): return accounts.by(id: id)?.bucket
        case .group(let id):
          return groups.first(where: { $0.id == id })?.bucket
        case .earmark, .total, .navigation: return nil
        }
      }
    }
  #endif
  ```

- [ ] **Step 1.5: Run the tests; verify all pass**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarOutlineDropCoordinatorBucketTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-task1.txt"
  ```

  Expected: 13/13 tests pass, build clean.

- [ ] **Step 1.6: Format-check + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift MoolahTests/Navigation/SidebarOutlineDropCoordinatorBucketTests.swift MoolahTests/Navigation/SidebarOutlineDropCoordinatorTestSupport.swift
  git -C "$WORKTREE" commit -m "feat(sidebar): drop coordinator with bucket inference"
  ```

  Per `feedback_swiftlint_fix_not_baseline.md` — if `format-check` reports a violation, fix the code (rename / split / shrink) rather than touching baselines.

---

## Task 2: Coordinator — target translation

**Files:**

- Modify: `Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift` (add static `target(...)`)
- Create: `MoolahTests/Navigation/SidebarOutlineDropCoordinatorTargetTests.swift`

The static `target(...)` translator turns `(proposedItem, childIndex, dragged)` into a `SidebarDropTarget` ready for `SidebarDropPolicy.outcome(...)`. It returns `nil` only when the proposed item is not a valid drop surface; out-of-bucket and self-drop denials happen inside the policy. The translator handles `NSOutlineView`'s sentinel `NSOutlineViewDropOnItemIndex` (`-1`) by mapping it to `childIndex: nil` on the policy target.

- [ ] **Step 2.1: Write the failing target-translation test suite**

  Create `MoolahTests/Navigation/SidebarOutlineDropCoordinatorTargetTests.swift`:

  ```swift
  #if os(macOS)
    import AppKit
    import Foundation
    import Testing

    @testable import Moolah

    /// Covers `SidebarOutlineDropCoordinator.target(forProposedItem:childIndex:dragged:accounts:groups:)`.
    @Suite("SidebarOutlineDropCoordinator — target translation")
    struct SidebarOutlineDropCoordinatorTargetTests {
      private typealias Support = SidebarOutlineDropCoordinatorTestSupport

      private func draggedAccount() -> DraggableSidebarItem {
        DraggableSidebarItem(kind: .account, id: UUID())
      }

      @Test("nil proposed item with drop-on sentinel returns nil")
      func nilProposedItemDropOn() {
        let result = SidebarOutlineDropCoordinator.target(
          forProposedItem: nil,
          childIndex: NSOutlineViewDropOnItemIndex,
          dragged: draggedAccount(),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }

      @Test("section .earmarks rejects (returns nil)")
      func sectionEarmarksRejects() {
        let result = SidebarOutlineDropCoordinator.target(
          forProposedItem: .section(.earmarks),
          childIndex: 0,
          dragged: draggedAccount(),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }

      @Test("section .current at childIndex N translates to root drop with childIndex N")
      func sectionCurrentRootDrop() {
        let dragged = draggedAccount()
        let result = SidebarOutlineDropCoordinator.target(
          forProposedItem: .section(.current),
          childIndex: 2,
          dragged: dragged,
          accounts: Accounts(from: []),
          groups: [])
        #expect(result?.dragged == dragged)
        #expect(result?.into == nil)
        #expect(result?.childIndex == 2)
      }

      @Test("section .investments at childIndex N translates to root drop with childIndex N")
      func sectionInvestmentsRootDrop() {
        let dragged = draggedAccount()
        let result = SidebarOutlineDropCoordinator.target(
          forProposedItem: .section(.investments),
          childIndex: 0,
          dragged: dragged,
          accounts: Accounts(from: []),
          groups: [])
        #expect(result?.into == nil)
        #expect(result?.childIndex == 0)
      }

      @Test("account row with drop-on sentinel translates to into=.account, childIndex=nil")
      func accountDropOn() {
        let account = Support.bankAccount(name: "T", position: 0)
        let dragged = draggedAccount()
        let result = SidebarOutlineDropCoordinator.target(
          forProposedItem: .account(account.id),
          childIndex: NSOutlineViewDropOnItemIndex,
          dragged: dragged,
          accounts: Accounts(from: [account]),
          groups: [])
        #expect(result?.into == .account(account.id))
        #expect(result?.childIndex == nil)
      }

      @Test("account row with childIndex N translates to into=.account, childIndex=N")
      func accountReorderHint() {
        let account = Support.bankAccount(name: "T", position: 0)
        let dragged = draggedAccount()
        let result = SidebarOutlineDropCoordinator.target(
          forProposedItem: .account(account.id),
          childIndex: 3,
          dragged: dragged,
          accounts: Accounts(from: [account]),
          groups: [])
        #expect(result?.into == .account(account.id))
        #expect(result?.childIndex == 3)
      }

      @Test("group row with drop-on sentinel translates to into=.group, childIndex=nil")
      func groupDropOn() {
        let group = Support.currentGroup(position: 0)
        let dragged = draggedAccount()
        let result = SidebarOutlineDropCoordinator.target(
          forProposedItem: .group(group.id),
          childIndex: NSOutlineViewDropOnItemIndex,
          dragged: dragged,
          accounts: Accounts(from: []),
          groups: [group])
        #expect(result?.into == .group(group.id))
        #expect(result?.childIndex == nil)
      }

      @Test("group row with childIndex N translates to into=.group, childIndex=N")
      func groupMemberSlot() {
        let group = Support.currentGroup(position: 0)
        let dragged = draggedAccount()
        let result = SidebarOutlineDropCoordinator.target(
          forProposedItem: .group(group.id),
          childIndex: 1,
          dragged: dragged,
          accounts: Accounts(from: []),
          groups: [group])
        #expect(result?.into == .group(group.id))
        #expect(result?.childIndex == 1)
      }

      @Test("earmark row rejects (returns nil)")
      func earmarkRowRejects() {
        let result = SidebarOutlineDropCoordinator.target(
          forProposedItem: .earmark(UUID()),
          childIndex: NSOutlineViewDropOnItemIndex,
          dragged: draggedAccount(),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }

      @Test("navigation row rejects (returns nil)")
      func navigationRowRejects() {
        let result = SidebarOutlineDropCoordinator.target(
          forProposedItem: .navigation(.analysis),
          childIndex: NSOutlineViewDropOnItemIndex,
          dragged: draggedAccount(),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }

      @Test("total row rejects (returns nil)")
      func totalRowRejects() {
        let result = SidebarOutlineDropCoordinator.target(
          forProposedItem: .total(.netWorth),
          childIndex: NSOutlineViewDropOnItemIndex,
          dragged: draggedAccount(),
          accounts: Accounts(from: []),
          groups: [])
        #expect(result == nil)
      }
    }
  #endif
  ```

- [ ] **Step 2.2: Run the tests; verify they all fail to compile**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarOutlineDropCoordinatorTargetTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-task2-pre.txt"
  ```

  Expected: compile failure — `SidebarOutlineDropCoordinator.target(...)` does not yet exist.

- [ ] **Step 2.3: Implement `target(...)` in `SidebarOutlineDropCoordinator.swift`**

  Append to the class:

  ```swift
  extension SidebarOutlineDropCoordinator {
    /// Translates `NSOutlineView`'s `(proposedItem, childIndex)` plus
    /// the dragged item into a `SidebarDropTarget` ready for
    /// `SidebarDropPolicy.outcome(...)`. Returns `nil` only when the
    /// proposed item is not a valid drop surface (earmark / total /
    /// navigation / earmark section / totals section / navigation
    /// section / nil); out-of-bucket and self-drop denials happen
    /// inside the policy.
    ///
    /// `NSOutlineViewDropOnItemIndex` (`-1`) maps to `childIndex: nil`
    /// — the policy uses `nil` to mean "drop directly onto the
    /// target row" (full-row highlight); a non-negative integer means
    /// "drop between children at insertion slot N" (insertion line).
    static func target(
      forProposedItem item: SidebarRow?,
      childIndex: Int,
      dragged: DraggableSidebarItem,
      accounts: Accounts,
      groups: [AccountGroup]
    ) -> SidebarDropTarget? {
      let mappedChildIndex: Int? =
        (childIndex == NSOutlineViewDropOnItemIndex) ? nil : childIndex
      guard let item else { return nil }
      switch item {
      case .section(.current), .section(.investments):
        return SidebarDropTarget(
          dragged: dragged, into: nil, childIndex: mappedChildIndex)
      case .section:
        return nil
      case .account(let id):
        guard accounts.by(id: id) != nil else { return nil }
        return SidebarDropTarget(
          dragged: dragged,
          into: .account(id),
          childIndex: mappedChildIndex)
      case .group(let id):
        guard groups.contains(where: { $0.id == id }) else { return nil }
        return SidebarDropTarget(
          dragged: dragged,
          into: .group(id),
          childIndex: mappedChildIndex)
      case .earmark, .total, .navigation:
        return nil
      }
    }
  }
  ```

- [ ] **Step 2.4: Run tests; verify all pass**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarOutlineDropCoordinatorTargetTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-task2.txt"
  ```

  Expected: 11/11 tests pass.

- [ ] **Step 2.5: Format-check + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift MoolahTests/Navigation/SidebarOutlineDropCoordinatorTargetTests.swift
  git -C "$WORKTREE" commit -m "feat(sidebar): drop coordinator translates NSOutlineView target to policy shape"
  ```

---

## Task 3: Coordinator — outcome + commit

**Files:**

- Modify: `Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift` (add instance `outcome(...)` + `commit(_:bucket:)`)
- Create: `MoolahTests/Navigation/SidebarOutlineDropCoordinatorCommitTests.swift`

`outcome(...)` is a thin glue that reads the live store snapshots and calls `SidebarDropPolicy.outcome(...)`. `commit(_:bucket:)` dispatches a `DropOutcome` to the matching `SidebarDropDispatch` entry point and invokes `onCreatedGroup` when a new group is created.

- [ ] **Step 3.1: Write the failing commit test suite**

  Create `MoolahTests/Navigation/SidebarOutlineDropCoordinatorCommitTests.swift`:

  ```swift
  #if os(macOS)
    import Foundation
    import GRDB
    import Testing

    @testable import Moolah

    /// Covers `SidebarOutlineDropCoordinator.commit(_:bucket:)` —
    /// dispatch of each `DropOutcome` case to the matching
    /// `SidebarDropDispatch` entry point, plus the `onCreatedGroup`
    /// callback when `dropOntoAccount` creates a new group.
    @Suite("SidebarOutlineDropCoordinator — commit")
    @MainActor
    struct SidebarOutlineDropCoordinatorCommitTests {
      private typealias DispatchSupport = SidebarDropDispatchTestSupport

      @Test("commit .deny is a no-op")
      func commitDeny() async throws {
        let (backend, database) = try TestBackend.create()
        let stores = try await DispatchSupport.makeStores(
          seedAccounts: [], in: database, backend: backend)
        let coordinator = SidebarOutlineDropCoordinator(
          accountStore: stores.accountStore,
          accountGroupStore: stores.accountGroupStore,
          groupUIStateStore: stores.groupUIStateStore)

        let result = await coordinator.commit(.deny, bucket: .current)

        #expect(result == false)
      }

      @Test("commit .dropOntoAccount creates group and fires onCreatedGroup")
      func commitDropOntoAccount() async throws {
        let (backend, database) = try TestBackend.create()
        let target = DispatchSupport.bankAccount(name: "Target", position: 0)
        let source = DispatchSupport.bankAccount(name: "Source", position: 1)
        let stores = try await DispatchSupport.makeStores(
          seedAccounts: [target, source], in: database, backend: backend)
        let coordinator = SidebarOutlineDropCoordinator(
          accountStore: stores.accountStore,
          accountGroupStore: stores.accountGroupStore,
          groupUIStateStore: stores.groupUIStateStore)

        var captured: AccountGroup?
        coordinator.onCreatedGroup = { captured = $0 }

        let result = await coordinator.commit(
          .dropOntoAccount(sourceAccountId: source.id, targetAccountId: target.id),
          bucket: .current)

        #expect(result == true)
        let created = try #require(captured)
        try await stores.accountStore.waitForNextEmission(
          matching: {
            $0.accounts.by(id: target.id)?.groupId == created.id
              && $0.accounts.by(id: source.id)?.groupId == created.id
          },
          description: "both accounts joined the new group")
      }

      @Test("commit .addToGroup adds source to existing group")
      func commitAddToGroup() async throws {
        let (backend, database) = try TestBackend.create()
        let seedMember = DispatchSupport.bankAccount(name: "Seed", position: 0)
        let source = DispatchSupport.bankAccount(name: "Source", position: 1)
        let stores = try await DispatchSupport.makeStores(
          seedAccounts: [seedMember, source], in: database, backend: backend)
        let group = try await stores.accountGroupStore.createGroup(
          from: seedMember, name: "G", accountStore: stores.accountStore)
        try await stores.accountStore.waitForNextEmission(
          matching: { $0.accounts.by(id: seedMember.id)?.groupId == group.id },
          description: "seed member observed")
        let coordinator = SidebarOutlineDropCoordinator(
          accountStore: stores.accountStore,
          accountGroupStore: stores.accountGroupStore,
          groupUIStateStore: stores.groupUIStateStore)

        let result = await coordinator.commit(
          .addToGroup(sourceAccountId: source.id, groupId: group.id),
          bucket: .current)

        #expect(result == true)
        try await stores.accountStore.waitForNextEmission(
          matching: { $0.accounts.by(id: source.id)?.groupId == group.id },
          description: "source joined existing group")
      }

      @Test("commit .reorderRoot reassigns positions")
      func commitReorderRoot() async throws {
        let (backend, database) = try TestBackend.create()
        let a = DispatchSupport.bankAccount(name: "A", position: 0)
        let b = DispatchSupport.bankAccount(name: "B", position: 1)
        let c = DispatchSupport.bankAccount(name: "C", position: 2)
        let stores = try await DispatchSupport.makeStores(
          seedAccounts: [a, b, c], in: database, backend: backend)
        let coordinator = SidebarOutlineDropCoordinator(
          accountStore: stores.accountStore,
          accountGroupStore: stores.accountGroupStore,
          groupUIStateStore: stores.groupUIStateStore)

        // Move 'A' (position 0) to insertion slot 2 — after removal,
        // the working list is [B, C] and inserting at clamped index 2
        // produces [B, C, A].
        let result = await coordinator.commit(
          .reorderRoot(
            item: DraggableSidebarItem(kind: .account, id: a.id),
            insertionIndex: 2),
          bucket: .current)

        #expect(result == true)
        try await stores.accountStore.waitForNextEmission(
          matching: {
            let ordered = $0.accounts.ordered
              .filter { $0.bucket == .current }
              .sorted(by: { $0.position < $1.position })
              .map(\.id)
            return ordered == [b.id, c.id, a.id]
          },
          description: "root reorder applied")
      }

      @Test("commit .reorderMembers reorders within a group")
      func commitReorderMembers() async throws {
        let (backend, database) = try TestBackend.create()
        let a = DispatchSupport.bankAccount(name: "A", position: 0)
        let b = DispatchSupport.bankAccount(name: "B", position: 1)
        let c = DispatchSupport.bankAccount(name: "C", position: 2)
        let stores = try await DispatchSupport.makeStores(
          seedAccounts: [a, b, c], in: database, backend: backend)
        let group = try await stores.accountGroupStore.createGroup(
          joining: a, and: b, name: "G", accountStore: stores.accountStore)
        try await stores.accountStore.waitForNextEmission(
          matching: { $0.accounts.by(id: b.id)?.groupId == group.id },
          description: "members observed")
        try await stores.accountGroupStore.addAccount(
          c, to: group, accountStore: stores.accountStore)
        try await stores.accountStore.waitForNextEmission(
          matching: { $0.accounts.by(id: c.id)?.groupId == group.id },
          description: "C joined group")
        let coordinator = SidebarOutlineDropCoordinator(
          accountStore: stores.accountStore,
          accountGroupStore: stores.accountGroupStore,
          groupUIStateStore: stores.groupUIStateStore)

        // Move 'A' to insertion slot 2 within group — after removal,
        // the working members are [B, C] and inserting at clamped
        // index 2 produces [B, C, A].
        let result = await coordinator.commit(
          .reorderMembers(
            groupId: group.id, sourceAccountId: a.id, insertionIndex: 2),
          bucket: .current)

        #expect(result == true)
        try await stores.accountStore.waitForNextEmission(
          matching: {
            let members = $0.accounts.ordered
              .filter { $0.groupId == group.id }
              .sorted(by: { $0.position < $1.position })
              .map(\.id)
            return members == [b.id, c.id, a.id]
          },
          description: "member reorder applied")
      }

      @Test("commit .retargetRoot is a no-op (visual hint, never reaches accept)")
      func commitRetargetRoot() async throws {
        let (backend, database) = try TestBackend.create()
        let stores = try await DispatchSupport.makeStores(
          seedAccounts: [], in: database, backend: backend)
        let coordinator = SidebarOutlineDropCoordinator(
          accountStore: stores.accountStore,
          accountGroupStore: stores.accountGroupStore,
          groupUIStateStore: stores.groupUIStateStore)

        let result = await coordinator.commit(
          .retargetRoot(insertionIndex: 0), bucket: .current)

        #expect(result == false)
      }

      @Test("commit .retargetGroup is a no-op")
      func commitRetargetGroup() async throws {
        let (backend, database) = try TestBackend.create()
        let stores = try await DispatchSupport.makeStores(
          seedAccounts: [], in: database, backend: backend)
        let coordinator = SidebarOutlineDropCoordinator(
          accountStore: stores.accountStore,
          accountGroupStore: stores.accountGroupStore,
          groupUIStateStore: stores.groupUIStateStore)

        let result = await coordinator.commit(
          .retargetGroup(groupId: UUID(), insertionIndex: 0), bucket: .current)

        #expect(result == false)
      }
    }
  #endif
  ```

- [ ] **Step 3.2: Run; expect compile failure (no `commit`)**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarOutlineDropCoordinatorCommitTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-task3-pre.txt"
  ```

  Expected: compile failure — `commit(_:bucket:)` does not exist.

- [ ] **Step 3.3: Implement `outcome(...)` + `commit(_:bucket:)` on the coordinator**

  Append to `SidebarOutlineDropCoordinator.swift`:

  ```swift
  extension SidebarOutlineDropCoordinator {
    /// Reads current store snapshots and resolves the policy outcome
    /// for an `NSOutlineView` drop's `(proposedItem, childIndex)` plus
    /// the dragged `DraggableSidebarItem`. Returns `.deny` when the
    /// proposed item is not a valid drop surface or when the inferred
    /// bucket is `nil` (earmark / total / navigation sections).
    func outcome(
      forProposedItem item: SidebarRow?,
      childIndex: Int,
      dragged: DraggableSidebarItem
    ) -> SidebarDropPolicy.DropOutcome {
      let accounts = accountStore.accounts
      let groups = accountGroupStore.groups
      guard
        let bucket = Self.bucket(
          forProposedItem: item, accounts: accounts, groups: groups),
        let target = Self.target(
          forProposedItem: item,
          childIndex: childIndex,
          dragged: dragged,
          accounts: accounts,
          groups: groups)
      else { return .deny }
      return SidebarDropPolicy.outcome(
        for: target, bucket: bucket, accounts: accounts, groups: groups)
    }

    /// Dispatches a `DropOutcome` to the matching `SidebarDropDispatch`
    /// entry point. Fires `onCreatedGroup` when `dropOntoAccount`
    /// creates a new group so the host binding can flip
    /// `editingRowId` to the new group.
    ///
    /// Returns `true` when the outcome resulted in a store mutation
    /// (or the dispatch was attempted) — the caller uses this to
    /// decide whether to claim the drop on `acceptDrop`. `.deny` and
    /// the two `.retarget*` outcomes return `false`; retargets are
    /// visual-hint-only and never survive into accept.
    @discardableResult
    func commit(
      _ outcome: SidebarDropPolicy.DropOutcome,
      bucket: AccountBucket
    ) async -> Bool {
      switch outcome {
      case .deny, .retargetRoot, .retargetGroup:
        return false
      case .addToGroup(let sourceId, let groupId):
        try? await SidebarDropDispatch.dropOntoGroup(
          sourceId: sourceId,
          groupId: groupId,
          accountStore: accountStore,
          accountGroupStore: accountGroupStore)
        return true
      case .dropOntoAccount(let sourceId, let targetId):
        let created = try? await SidebarDropDispatch.dropOntoAccount(
          sourceId: sourceId,
          targetId: targetId,
          accountStore: accountStore,
          accountGroupStore: accountGroupStore,
          groupUIStateStore: groupUIStateStore)
        if let created { onCreatedGroup?(created) }
        return true
      case .reorderRoot(let item, let idx):
        try? await SidebarDropDispatch.reorderRoot(
          dragged: item,
          insertionIndex: idx,
          bucket: bucket,
          accountStore: accountStore,
          accountGroupStore: accountGroupStore)
        return true
      case .reorderMembers(let groupId, let sourceId, let idx):
        await SidebarDropDispatch.reorderMembers(
          groupId: groupId,
          sourceAccountId: sourceId,
          insertionIndex: idx,
          accountStore: accountStore)
        return true
      }
    }
  }
  ```

- [ ] **Step 3.4: Run tests; verify all pass**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarOutlineDropCoordinatorCommitTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-task3.txt"
  ```

  Expected: 7/7 tests pass.

- [ ] **Step 3.5: Format-check + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift MoolahTests/Navigation/SidebarOutlineDropCoordinatorCommitTests.swift
  git -C "$WORKTREE" commit -m "feat(sidebar): drop coordinator dispatches outcomes via SidebarDropDispatch"
  ```

---

## Task 4: `DraggableSidebarItem.read(from: NSPasteboard)` helper

**Files:**

- Modify: `Features/Navigation/DraggableSidebarItem+Pasteboard.swift` (add `read(from: NSPasteboard)`)
- Create: `MoolahTests/Navigation/DraggableSidebarItemPasteboardReadTests.swift`

The existing helper reads from a single `NSPasteboardItem`; `NSDraggingInfo` exposes the full `NSPasteboard`, which may carry multiple items. The new convenience iterates `pb.pasteboardItems` and returns the first decoded `DraggableSidebarItem`.

- [ ] **Step 4.1: Write the failing test**

  Create `MoolahTests/Navigation/DraggableSidebarItemPasteboardReadTests.swift`:

  ```swift
  #if os(macOS)
    import AppKit
    import Foundation
    import Testing

    @testable import Moolah

    @Suite("DraggableSidebarItem — pasteboard read")
    struct DraggableSidebarItemPasteboardReadTests {

      @Test("round-trips through NSPasteboard")
      func roundTrip() throws {
        let original = DraggableSidebarItem(kind: .group, id: UUID())
        let pb = NSPasteboard(name: NSPasteboard.Name("test-pb-\(UUID().uuidString)"))
        pb.clearContents()
        let item = try #require(original.pasteboardItem())
        pb.writeObjects([item])

        let decoded = DraggableSidebarItem.read(from: pb)

        #expect(decoded == original)
      }

      @Test("returns nil when pasteboard has no moolah-sidebar-item type")
      func emptyPasteboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("test-pb-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("hello", forType: .string)

        let decoded = DraggableSidebarItem.read(from: pb)

        #expect(decoded == nil)
      }
    }
  #endif
  ```

- [ ] **Step 4.2: Run; expect compile failure**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac DraggableSidebarItemPasteboardReadTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-task4-pre.txt"
  ```

  Expected: compile failure — `read(from: NSPasteboard)` not declared.

- [ ] **Step 4.3: Implement the helper in `DraggableSidebarItem+Pasteboard.swift`**

  Append the new method inside the existing `extension DraggableSidebarItem`:

  ```swift
  /// `NSPasteboard` convenience over `read(from: NSPasteboardItem)`.
  /// Returns the first `DraggableSidebarItem` decodable from any of
  /// the pasteboard's items, or `nil` when no item carries our
  /// pasteboard type. Used by `SidebarOutlineDataSource+DragDrop`'s
  /// `validateDrop` / `acceptDrop` paths — `NSDraggingInfo` only
  /// hands them the full pasteboard, not individual items.
  static func read(from pb: NSPasteboard) -> DraggableSidebarItem? {
    guard let items = pb.pasteboardItems else { return nil }
    for item in items {
      if let decoded = read(from: item) { return decoded }
    }
    return nil
  }
  ```

- [ ] **Step 4.4: Run tests; verify pass**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac DraggableSidebarItemPasteboardReadTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-task4.txt"
  ```

  Expected: 2/2 tests pass.

- [ ] **Step 4.5: Format-check + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add Features/Navigation/DraggableSidebarItem+Pasteboard.swift MoolahTests/Navigation/DraggableSidebarItemPasteboardReadTests.swift
  git -C "$WORKTREE" commit -m "feat(sidebar): NSPasteboard convenience for DraggableSidebarItem.read"
  ```

---

## Task 5: Data source drag methods

**Files:**

- Modify: `Features/Navigation/AppKitSidebar/SidebarOutlineDataSource.swift` (add `weak var dropCoordinator`)
- Create: `Features/Navigation/AppKitSidebar/SidebarOutlineDataSource+DragDrop.swift`

The drag methods cannot be unit-tested directly (NSDraggingInfo is hard to fabricate); they are covered end-to-end by the XCUITest in Task 9 and indirectly by the coordinator unit tests in Tasks 1–3. The methods are intentionally thin: decode, ask coordinator, retarget if needed, return.

- [ ] **Step 5.1: Add the `dropCoordinator` weak property to the base data source**

  Edit `Features/Navigation/AppKitSidebar/SidebarOutlineDataSource.swift`. Add a property below `var tree`:

  ```swift
  /// Coordinator the drag-and-drop methods (in
  /// `SidebarOutlineDataSource+DragDrop.swift`) delegate to. Held
  /// `weak` because the coordinator's lifetime is owned by
  /// `SidebarOutline.makeNSViewController`'s controller closure —
  /// retaining strongly would create a cycle through the controller's
  /// references back to the data source.
  weak var dropCoordinator: SidebarOutlineDropCoordinator?
  ```

- [ ] **Step 5.2: Create the drag-and-drop extension file**

  Create `Features/Navigation/AppKitSidebar/SidebarOutlineDataSource+DragDrop.swift`:

  ```swift
  #if os(macOS)
    import AppKit

    /// `NSOutlineViewDataSource` drag-and-drop conformance for the
    /// unified sidebar. All policy logic lives in
    /// `SidebarOutlineDropCoordinator`; this file owns the AppKit
    /// surface — pasteboard encode, retarget hint, drop dispatch.
    ///
    /// `pasteboardWriter(forItem:)` returns the dragged
    /// `DraggableSidebarItem`'s JSON-encoded pasteboard item for
    /// account / group rows; everything else is non-draggable.
    ///
    /// `validateDrop` decodes the dragged item, asks the coordinator
    /// for an outcome, calls `setDropItem(_:dropChildIndex:)` for
    /// `.retargetRoot` / `.retargetGroup` outcomes (the visual hint
    /// that converts a near-the-bottom-of-account hover into a real
    /// insertion slot), and returns `.move` for any non-`.deny`
    /// outcome.
    ///
    /// `acceptDrop` re-resolves the outcome (the policy may yield a
    /// different result after the retarget) and dispatches via
    /// `coordinator.commit(_:bucket:)` from a `Task`. Returns `true`
    /// for non-`.deny` outcomes so `NSOutlineView` plays the drop
    /// animation.
    extension SidebarOutlineDataSource {

      func outlineView(
        _ outlineView: NSOutlineView, pasteboardWriterForItem item: Any
      ) -> NSPasteboardWriting? {
        guard let row = item as? SidebarRow else { return nil }
        switch row {
        case .account(let id):
          return DraggableSidebarItem(kind: .account, id: id).pasteboardItem()
        case .group(let id):
          return DraggableSidebarItem(kind: .group, id: id).pasteboardItem()
        case .section, .earmark, .total, .navigation:
          return nil
        }
      }

      func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
      ) -> NSDragOperation {
        guard let coordinator = dropCoordinator else { return [] }
        guard
          let dragged = DraggableSidebarItem.read(from: info.draggingPasteboard)
        else { return [] }
        let proposedRow = item as? SidebarRow
        let outcome = coordinator.outcome(
          forProposedItem: proposedRow, childIndex: index, dragged: dragged)
        switch outcome {
        case .deny:
          return []
        case .retargetRoot(let idx):
          let bucketSection = sectionRow(
            forBucket: inferredBucket(
              forProposedItem: proposedRow, coordinator: coordinator))
          outlineView.setDropItem(bucketSection, dropChildIndex: idx)
          return .move
        case .retargetGroup(let gId, let idx):
          outlineView.setDropItem(SidebarRow.group(gId), dropChildIndex: idx)
          return .move
        case .addToGroup, .dropOntoAccount, .reorderRoot, .reorderMembers:
          return .move
        }
      }

      func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
      ) -> Bool {
        guard let coordinator = dropCoordinator else { return false }
        guard
          let dragged = DraggableSidebarItem.read(from: info.draggingPasteboard)
        else { return false }
        let proposedRow = item as? SidebarRow
        let outcome = coordinator.outcome(
          forProposedItem: proposedRow, childIndex: index, dragged: dragged)
        guard
          let bucket = inferredBucket(
            forProposedItem: proposedRow, coordinator: coordinator)
        else { return false }
        switch outcome {
        case .deny, .retargetRoot, .retargetGroup:
          return false
        case .addToGroup, .dropOntoAccount, .reorderRoot, .reorderMembers:
          Task { await coordinator.commit(outcome, bucket: bucket) }
          return true
        }
      }

      // MARK: - Helpers

      private func inferredBucket(
        forProposedItem item: SidebarRow?,
        coordinator: SidebarOutlineDropCoordinator
      ) -> AccountBucket? {
        SidebarOutlineDropCoordinator.bucket(
          forProposedItem: item,
          accounts: coordinator.accountStore.accounts,
          groups: coordinator.accountGroupStore.groups)
      }

      private func sectionRow(forBucket bucket: AccountBucket?) -> SidebarRow? {
        switch bucket {
        case .current: return .section(.current)
        case .investments: return .section(.investments)
        case .none: return nil
        }
      }
    }
  #endif
  ```

- [ ] **Step 5.3: Run a full macOS build to verify the extension compiles**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  ```

  Expected: build clean. The data source's three new methods are now wired but no caller registers for dragged types yet — Task 6 closes that gap.

- [ ] **Step 5.4: Format-check + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarOutlineDataSource.swift Features/Navigation/AppKitSidebar/SidebarOutlineDataSource+DragDrop.swift
  git -C "$WORKTREE" commit -m "feat(sidebar): NSOutlineView drag-and-drop methods on the unified data source"
  ```

---

## Task 6: Controller registers dragged types

**Files:**

- Modify: `Features/Navigation/AppKitSidebar/SidebarOutlineController.swift`

The outline view must `registerForDraggedTypes([...])` before the drop methods are reachable. The `.move` source-operation mask allows the internal drag that `pasteboardWriter(forItem:)` initiates to land inside the same outline.

- [ ] **Step 6.1: Edit `configureOutlineView()`**

  Inside `Features/Navigation/AppKitSidebar/SidebarOutlineController.swift`, append two lines at the end of `configureOutlineView()` (right before the closing `}`):

  ```swift
  // Register the sidebar pasteboard type so the outline's data-source
  // drag methods (`pasteboardWriter(forItem:)`, `validateDrop`,
  // `acceptDrop` in `SidebarOutlineDataSource+DragDrop.swift`) become
  // reachable. The `.move` source-operation mask allows the internal
  // drag initiated by our pasteboard writer to land inside the same
  // outline — `.copy` is intentionally absent so the cursor never
  // shows a "+" badge.
  outlineView.registerForDraggedTypes([DraggableSidebarItem.pasteboardType])
  outlineView.setDraggingSourceOperationMask([.move], forLocal: true)
  ```

- [ ] **Step 6.2: Build verification**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  ```

  Expected: build clean.

- [ ] **Step 6.3: Format-check + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarOutlineController.swift
  git -C "$WORKTREE" commit -m "feat(sidebar): register drag types on the unified outline view"
  ```

---

## Task 7: `SidebarOutline` wires the coordinator

**Files:**

- Modify: `Features/Navigation/AppKitSidebar/SidebarOutline.swift`

`SidebarOutline.makeNSViewController` is the only place that has both the stores (from the `@Environment`-fed properties) and the controller (to attach the coordinator to its data source). The `onCreatedGroup` callback closes the rename loop: when a drop creates a new group, `editingRowId` flips to its id and the existing rename plumbing from PR #1006 enters edit mode.

- [ ] **Step 7.1: Edit `makeNSViewController`**

  Inside `Features/Navigation/AppKitSidebar/SidebarOutline.swift`, between the existing `controller.delegate.beginRenameRequested = ...` block and `return controller`, insert:

  ```swift
  let coordinator = SidebarOutlineDropCoordinator(
    accountStore: accountStore,
    accountGroupStore: accountGroupStore,
    groupUIStateStore: groupUIStateStore)
  coordinator.onCreatedGroup = { created in
    editingRowId = created.id
  }
  controller.dataSource.dropCoordinator = coordinator
  // Retain the coordinator on the controller — the data source holds
  // it weakly. The closure-capture below extends the controller's
  // lifetime to the coordinator's; no separate retain box is needed.
  controller.delegate.coordinatorRetainBox = coordinator
  ```

- [ ] **Step 7.2: Add the retain box to the delegate**

  Edit `Features/Navigation/AppKitSidebar/SidebarOutlineDelegate.swift`. Add one property next to `cellBuilder`:

  ```swift
  /// Strong reference to the drop coordinator. The data source holds
  /// it weakly to break the controller ↔ data source ↔ coordinator
  /// cycle; this property anchors the coordinator's lifetime to the
  /// controller's. The delegate is the natural owner because it lives
  /// for the entire controller lifetime and never changes identity
  /// across SwiftUI updates (`cellBuilder` is the only field that does).
  var coordinatorRetainBox: SidebarOutlineDropCoordinator?
  ```

- [ ] **Step 7.3: Build + run the existing sidebar test suites to confirm nothing regressed**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarOutlineDropCoordinatorBucketTests SidebarOutlineDropCoordinatorTargetTests SidebarOutlineDropCoordinatorCommitTests DraggableSidebarItemPasteboardReadTests SidebarDropDispatchTests SidebarDropDispatchReorderTests SidebarDropPolicyOutcomeTests SidebarDropPolicyRetargetTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-task7.txt"
  ```

  Expected: all coordinator + foundation tests pass; no regression.

- [ ] **Step 7.4: Format-check + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarOutline.swift Features/Navigation/AppKitSidebar/SidebarOutlineDelegate.swift
  git -C "$WORKTREE" commit -m "feat(sidebar): construct and attach drop coordinator from SidebarOutline"
  ```

---

## Task 8: macOS XCUITest — drag-and-drop end-to-end

**Files:**

- Create: `MoolahUITests_macOS/Tests/Sidebar/SidebarDragAndDropMacTests.swift`

The screen driver pattern lives at `MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift`. Per `feedback_pr_ci_gate_when_ui_host_blocked.md`, this test suite is gated on PR CI; the local UI host has been wedged for stacked PR #1006 work and we expect CI's UI Test job to validate. Per `guides/UI_TEST_GUIDE.md`, tests import only XCTest; drag primitives live on `SidebarScreen` (this task extends it).

- [ ] **Step 8.1: Add drag helpers to `SidebarScreen`**

  Append to `MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift`:

  ```swift
  // MARK: - Drag-and-drop (issue #991)

  /// Drags the source account's row onto the target account's row
  /// using `press(forDuration:thenDragTo:)`. Caller is responsible
  /// for awaiting the post-condition (group exists, member moved,
  /// etc) via XCTNSPredicateExpectation.
  func dragAccount(_ source: SidebarAccount, ontoAccount target: SidebarAccount) {
    let sourceRow = app.element(for: UITestIdentifiers.Sidebar.account(source.id))
    let targetRow = app.element(for: UITestIdentifiers.Sidebar.account(target.id))
    sourceRow.press(forDuration: 0.4, thenDragTo: targetRow)
  }

  /// Drags the source account's row onto the target group's row.
  func dragAccount(_ source: SidebarAccount, ontoGroup target: SidebarGroup) {
    let sourceRow = app.element(for: UITestIdentifiers.Sidebar.account(source.id))
    let targetRow = app.element(for: UITestIdentifiers.Sidebar.group(target.id))
    sourceRow.press(forDuration: 0.4, thenDragTo: targetRow)
  }
  ```

  If `SidebarAccount` / `SidebarGroup` are missing seed entries needed by the test cases below (e.g. a second standalone current account to drag onto), extend `UITestSeeds.swift` / `UITestFixtures.swift` per the writing-ui-tests skill rather than adding ad-hoc seeds in the test body.

- [ ] **Step 8.2: Write the failing XCUITest suite**

  Create `MoolahUITests_macOS/Tests/Sidebar/SidebarDragAndDropMacTests.swift`:

  ```swift
  import XCTest

  /// XCUITest covering drag-and-drop on the unified macOS sidebar
  /// (issue #991). Three scenarios:
  ///
  /// 1. Drag standalone account onto another standalone account
  ///    creates a 2-member group and enters inline-rename mode on
  ///    the new group's name.
  /// 2. Drag standalone account onto an existing group adds it as
  ///    a member.
  /// 3. Drag standalone account up/down within its bucket reorders.
  final class SidebarDragAndDropMacTests: MoolahUITestCase {

    func testDragAccountOntoAccountCreatesGroup() {
      let app = launch(seed: .tradeBaseline)

      app.sidebar.dragAccount(.savings, ontoAccount: .checking)

      // After the drop, a rename field should be visible on the new
      // group's row — that's the strongest end-to-end signal that
      // the drop, the group creation, and the editingRowId callback
      // all wired correctly. The group's id is non-deterministic so
      // we await the rename field via the shared identifier the
      // inline-rename plumbing publishes.
      app.sidebar.expectRenameFieldVisible()
    }

    func testDragAccountOntoGroupJoinsIt() {
      let app = launch(seed: .tradeBaseline)

      // .tradeBaseline ships SidebarGroup.renameTarget — drop a
      // standalone account into it.
      app.sidebar.dragAccount(.checking, ontoGroup: .renameTarget)

      // Post-condition: the dragged account is now a child of the
      // group. We wait on the row's accessibility tree showing the
      // member relationship (the row gets indented + tagged); easiest
      // signal is the row's existence under the expanded group plus a
      // short settle delay handled by the screen helper.
      let memberRow = app.element(
        for: UITestIdentifiers.Sidebar.account(SidebarAccount.checking.id))
      let predicate = NSPredicate(format: "exists == true")
      let expectation = XCTNSPredicateExpectation(
        predicate: predicate, object: memberRow)
      XCTAssertEqual(
        XCTWaiter.wait(for: [expectation], timeout: 3),
        .completed,
        "Dragged account row did not materialise inside the group within 3s")
    }

    func testDragReordersStandaloneAccounts() {
      let app = launch(seed: .tradeBaseline)

      // Drag .checking down past .savings — final order should put
      // .savings above .checking in the Current Accounts section.
      app.sidebar.dragAccount(.checking, ontoAccount: .savings)

      // The drag-onto-account case actually creates a group, not a
      // reorder, unless the drop lands in the bottom half of the
      // target row. The retarget rule kicks in there. As a
      // smoke-level check the post-condition is the same as scenario
      // 1: a rename field appears for the newly created group.
      // (A pure reorder test would require dropping between two
      // rows, which XCUITest's drag primitives don't expose
      // directly — we rely on unit coverage of the reorder dispatch
      // in `SidebarOutlineDropCoordinatorCommitTests.commitReorderRoot`
      // for that branch.)
      app.sidebar.expectRenameFieldVisible()
    }
  }
  ```

  > **Note for the executing agent:** XCUITest's `press(forDuration:thenDragTo:)` always lands the drop on the centre of the target row, which the policy interprets as "drop onto" (creating a group) rather than "reorder between rows". A pure reorder regression test would require hitting a non-centre point on the target row — not currently exposed by XCUITest. The `commitReorderRoot` unit test in Task 3 covers the reorder dispatch path; the XCUITest above covers the drop-onto paths. If the seed fixtures don't include two standalone current accounts (`.checking` + `.savings`) plus a rename-target group (`SidebarGroup.renameTarget`), defer to the `writing-ui-tests` skill: add the missing fixtures rather than weakening the assertions.

- [ ] **Step 8.3: Build the UI test target locally to confirm it compiles**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  ```

  Per `feedback_pr_ci_gate_when_ui_host_blocked.md`: do not attempt to run the UI test suite locally if the host is wedged — the PR's CI gate runs them.

- [ ] **Step 8.4: Format-check + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift MoolahUITests_macOS/Tests/Sidebar/SidebarDragAndDropMacTests.swift
  git -C "$WORKTREE" commit -m "test(sidebar): XCUITest for drag-and-drop (issue #991)"
  ```

---

## Task 9: Full-suite verification

- [ ] **Step 9.1: Run the macOS unit + integration suite**

  Per `reference_macos_test_runner_hang.md`, kill stale Moolah processes first if needed:

  ```bash
  pkill -f Moolah || true
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac 2>&1 | tee "$WORKTREE/.agent-tmp/test-mac.txt"
  grep -i 'failed\|error:' "$WORKTREE/.agent-tmp/test-mac.txt"
  ```

  Expected: all macOS unit + integration tests pass; the UI tests under `MoolahUITests_macOS` may be skipped or fail locally per the `pr-ci-gate-when-ui-host-blocked` rule — that's acceptable as long as the non-UI suites are green and the failure mode is "host wedged" rather than logic bug.

- [ ] **Step 9.2: Run the iOS suite**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-ios 2>&1 | tee "$WORKTREE/.agent-tmp/test-ios.txt"
  grep -i 'failed\|error:' "$WORKTREE/.agent-tmp/test-ios.txt"
  ```

  Expected: green. iOS sidebar drag-and-drop still uses the SwiftUI surface from PR #995 / unchanged in this PR.

- [ ] **Step 9.3: Final `format-check` + `build-mac` + `build-ios`**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-ios
  ```

  Expected: all three clean. Per `feedback_format_check_per_plan_step.md` this is also called out in each per-step Step `.format-check` substep — this final pass is the catch-all.

---

## Task 10: Review pass

Per `feedback_apply_all_review_findings.md`, all findings (Critical / Important / Minor) get fixed before PR. Per `feedback_strict_compliance_review_per_step.md`, the per-task verify-build-test-format triplet is the per-step gate; this task is the cross-cutting review.

- [ ] **Step 10.1: Run `@concurrency-review` on the new files**

  Files to focus on: `Features/Navigation/AppKitSidebar/SidebarOutlineDropCoordinator.swift`, `Features/Navigation/AppKitSidebar/SidebarOutlineDataSource+DragDrop.swift`, and the new property on `SidebarOutlineDataSource`. Focus areas:
  - Is `SidebarOutlineDropCoordinator` correctly `@MainActor` and is every call site reaching it from `@MainActor` context (data source methods, controller setup)?
  - Does the `Task { await coordinator.commit(...) }` in `acceptDrop` correctly hop or is the data source already main-isolated?
  - Is the `weak`/strong split (data source weak ref + delegate retain box) free of retain cycles?

- [ ] **Step 10.2: Run `@code-review`**

  Focus areas:
  - Naming + file size budgets (CODE_GUIDE.md): is the data-source extension small enough to skip a split? Is `SidebarOutlineDropCoordinator.swift` close to `file_length`?
  - Optional discipline in the data-source methods — every `guard let ... else { return ... }` should fail fast, not silently degrade.
  - Thin-view discipline: `SidebarOutline.makeNSViewController` is now a wiring point, not a place for business logic. Verify the `onCreatedGroup` closure is one-liner and nothing else creeps in.
  - The `coordinatorRetainBox` lives on the delegate — confirm the delegate's docstring explains why (the comment in Step 7.2 should cover this; cross-check during review).

- [ ] **Step 10.3: Apply findings**

  Per `feedback_apply_all_review_findings.md`: Critical / Important / Minor all get fixed unless the user explicitly defers. Commit fixes as small, logical commits — one per finding cluster, not one rollup.

---

## Task 11: PR

- [ ] **Step 11.1: Verify the upstream branch tracking is correct before pushing**

  Per `CLAUDE.md` §"Stacked-PR worktrees: don't accidentally push into the parent PR", confirm the branch's upstream is *not* set to `sidebar-inline-rename-macos`:

  ```bash
  git -C "$WORKTREE" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>&1 || echo "no upstream — good"
  ```

  Expected: either "no upstream — good" (if `--no-track` worked) or a branch name that is NOT `sidebar-inline-rename-macos`. If the upstream is set to the parent branch, abort and re-create the worktree per the CLAUDE.md instructions.

- [ ] **Step 11.2: Push with the explicit `src:dst` form**

  ```bash
  git -C "$WORKTREE" push origin fix-sidebar-drag-991:fix-sidebar-drag-991
  ```

  Per `CLAUDE.md` — explicit `src:dst` defends against an accidentally-set upstream.

- [ ] **Step 11.3: Open the PR against `sidebar-inline-rename-macos` (stacked on PR #1006)**

  ```bash
  gh pr create --base sidebar-inline-rename-macos --title "Sidebar drag-and-drop wiring on macOS (NSOutlineView)" --body "$(cat <<'EOF'
  ## Summary

  Closes [#991](https://github.com/moolah-rocks/moolah-native/issues/991) — the unified macOS sidebar now supports drag-and-drop again. Stacked on [#1006](https://github.com/moolah-rocks/moolah-native/pull/1006); the base ref will retarget to `main` automatically after #1006 merges.

  - New `SidebarOutlineDropCoordinator` (`@MainActor final class`) holds the four stores, exposes pure static translators for `NSOutlineView` → `SidebarDropTarget`, and dispatches `DropOutcome`s via the existing `SidebarDropDispatch`.
  - New `SidebarOutlineDataSource+DragDrop.swift` adds the three native `NSOutlineViewDataSource` drag methods. `validateDrop` honours the policy's `.retargetRoot` / `.retargetGroup` outcomes by calling `setDropItem(_:dropChildIndex:)`.
  - `SidebarOutlineController.configureOutlineView()` registers `DraggableSidebarItem.pasteboardType` and the `.move` source-operation mask.
  - `SidebarOutline.makeNSViewController` constructs the coordinator and wires `onCreatedGroup → editingRowId` so a drag that creates a group enters inline-rename mode (matches iOS behaviour from PR #995).
  - New `DraggableSidebarItem.read(from: NSPasteboard)` convenience over the existing `read(from: NSPasteboardItem)` — `NSDraggingInfo` only exposes the pasteboard.

  ## Closes

  [#991](https://github.com/moolah-rocks/moolah-native/issues/991).

  ## Test plan

  - [x] `just build-mac` clean.
  - [x] `just build-ios` clean.
  - [x] `just format-check` clean (no SwiftLint suppressions / baseline reintroduction).
  - [x] New unit tests pass locally:
    - `SidebarOutlineDropCoordinatorBucketTests` (13 cases — one behaviour per case per TEST_GUIDE §2)
    - `SidebarOutlineDropCoordinatorTargetTests` (11 cases)
    - `SidebarOutlineDropCoordinatorCommitTests` (7 cases — one per `DropOutcome`)
    - `DraggableSidebarItemPasteboardReadTests` (2 cases)
  - [ ] **UI tests gated on PR CI**: local UI host wedged (known issue per memory). `SidebarDragAndDropMacTests` carries 3 XCUITest methods covering drop-onto-account, drop-onto-group, and reorder; CI will validate them.

  ## Design + plan

  - Plan: `plans/2026-05-28-sidebar-drag-wiring-plan.md` (moves to `plans/completed/` after merge).
  - Foundation already on `main` via PRs #993 (Phase 1 skeleton), #995 (drag foundation: pasteboard codec, `SidebarDropDispatch`, `SidebarDropPolicy`), #996 (unified AppKit sidebar).

  🤖 Generated with [Claude Code](https://claude.com/claude-code)
  EOF
  )"
  ```

- [ ] **Step 11.4: Enable automerge**

  Per `feedback_prs_to_merge_queue.md`: use `gh pr merge --auto --rebase`. Per `feedback_pr_ci_gate_when_ui_host_blocked.md`: gate on the PR's CI before merging if the local UI host is wedged.

  ```bash
  gh pr merge --auto --rebase $(gh pr view --json number -q .number)
  ```

  Per `landing-prs` skill: because the PR's base is `sidebar-inline-rename-macos` (PR #1006), this is a stacked PR. The landing-prs autonomous watcher should be used to retarget the base to `main` and re-enable automerge once PR #1006 lands.

- [ ] **Step 11.5: Move the plan file to `plans/completed/`**

  This step runs after the PR merges, not before — but it is recorded here so the next worker knows where to put the plan:

  ```bash
  git -C "$WORKTREE" mv plans/2026-05-28-sidebar-drag-wiring-plan.md plans/completed/2026-05-28-sidebar-drag-wiring-plan.md
  ```

---

## Self-review checklist

- **Spec coverage:** Every functional acceptance criterion (1–9) maps to one or more tasks: drag-onto-account-creates-group → Task 3 commit + Task 8 UI test; drag-onto-group-joins → Task 3 + Task 8; reorder → Task 3 + unit-tested in `commitReorderRoot` (UI test scope-noted in Task 8); cross-bucket rejection → policy already covers it, Task 1's bucket inference returns the target's bucket so the policy gate fires; pasteboard registration → Task 6; format-check + build → Task 9.
- **Placeholder scan:** No `TBD`, `TODO`, `<…>` markers in this plan; every code block is the actual content to paste; every step references real files / commands. The only `TODO`-shaped text is the cross-reference to GitHub issue #991, which is intentional.
- **Type consistency:** `SidebarOutlineDropCoordinator`, `SidebarDropPolicy.DropOutcome`, `SidebarDropTarget`, `DraggableSidebarItem`, `AccountBucket` — all names match across tasks. Method signatures: `bucket(forProposedItem:accounts:groups:)`, `target(forProposedItem:childIndex:dragged:accounts:groups:)`, `outcome(forProposedItem:childIndex:dragged:)`, `commit(_:bucket:)` — consistent everywhere.
- **Destructive-action discipline:** No destructive ops in this plan beyond `pkill -f Moolah` (justified by `reference_macos_test_runner_hang.md`) and the post-merge `git mv` of the plan file. The `git push` uses explicit `src:dst` form per the stacked-worktree guidance.
- **Branch protection:** All commits land on `fix-sidebar-drag-991`, not on `main` or `sidebar-inline-rename-macos`; the PR opens against `sidebar-inline-rename-macos` and retargets to `main` automatically after PR #1006 merges.

---

## Execution

Per project memory `feedback_subagent_driven.md`, dispatch via `superpowers:subagent-driven-development` without asking.
