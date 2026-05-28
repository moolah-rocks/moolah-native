# Sidebar Inline Rename on macOS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Per project memory (`feedback_subagent_driven.md`), do not ask whether to use it — that is the default. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reach iOS parity for inline rename on the macOS sidebar — for accounts (current + investments), earmarks, and account-group rows — triggered by Return on a selected row, double-click on the name, or a "Rename" item in the row's right-click menu. Commit on Return / focus loss; cancel on Esc. Closes [#999](https://github.com/moolah-rocks/moolah-native/issues/999).

**Architecture:** Thread `editingRowId` from `SidebarView` (already used by iOS) through `SidebarOutline` → `SidebarCellBuilder` → the existing iOS row views (`AccountSidebarRow`, `EarmarkRowView`, `AccountGroupSidebarRow`). The existing SwiftUI `InlineRenameField` inside `SidebarRowView` renders the field; a spike on `Large Test Profile` confirmed SwiftUI `@FocusState` inside `NSHostingView` wins keyboard focus on appear with no `makeFirstResponder` plumbing. The three triggers land in: an `NSOutlineView` subclass (Return-key intercept), the existing SwiftUI `.onTapGesture(count: 2)` already in `SidebarRowView` (double-click), and three new `NSMenu` builders (context-menu Rename).

**Tech Stack:** SwiftUI, AppKit (`NSOutlineView`, `NSHostingView`, `NSMenu`), Swift Testing for unit tests, XCUITest for the macOS UI tests, GRDB for the seed hydrator. Justfile targets (`just build-mac`, `just test-mac`, `just format-check`) drive verification.

**Design spec:** `plans/2026-05-28-sidebar-inline-rename-macos-design.md`.

---

## File structure

**Create:**
- `Features/Navigation/AppKitSidebar/SidebarKeyHandlingOutlineView.swift` — `NSOutlineView` subclass with a Return-key intercept that fires an `onReturnKey: (() -> Void)?` closure.
- `MoolahTests/Navigation/SidebarRenameBindingTests.swift` — Swift Testing suite for the pure `renameBinding(for:editingId:)` helper.
- `MoolahTests/Navigation/SidebarContextMenuBuilderTests.swift` — Swift Testing suite for the new menu builders.
- `MoolahUITests_macOS/Tests/Sidebar/SidebarInlineRenameMacTests.swift` — XCUITest covering all three triggers across all three row types.

**Modify:**
- `Features/Navigation/SidebarView.swift` — lift `renameBinding(for:)` + `renameAction(for:)` overloads out of `#if os(iOS)`, extract a pure static `renameBinding(for:editingId:)`, pass `$editingRowId` + rename closures into `SidebarOutline`.
- `Features/Navigation/AppKitSidebar/SidebarOutline.swift` — accept `editingRowId` binding + three rename closures; wire `delegate.beginRenameRequested`.
- `Features/Navigation/AppKitSidebar/Cells/SidebarCellBuilder.swift` — accept new fields, attach new menus, pass `isEditing` + `onRename` to row views.
- `Features/Navigation/AppKitSidebar/SidebarContextMenuBuilder.swift` — add "Rename" item to `accountMenu`; add `earmarkMenu` and `groupMenu` builders.
- `Features/Navigation/AppKitSidebar/SidebarOutlineDelegate.swift` — add `beginRenameRequested: (() -> Void)?` callback.
- `Features/Navigation/AppKitSidebar/SidebarOutlineController.swift` — use the new outline subclass; wire `onReturnKey` to fire `delegate.beginRenameRequested` only when the selected row is renamable.
- `UITestSupport/UITestFixtures.swift` — add earmark + group fixture ids/names to `TradeBaseline`.
- `App/UITestSeedHydrator.swift` — seed one earmark + one group inside `hydrateTradeBaseline`.
- `MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift` — driver methods for context-menu Rename / Return / double-click + inline `TextField` resolution.

**Minor modifications (one-line additions, cross-platform):**
- `Features/Accounts/Views/AccountSidebarRow.swift` (the file that hosts `InlineRenameField`) — attach `.accessibilityIdentifier(UITestIdentifiers.Sidebar.renameNameField)` to the inline `TextField` so XCUITest can resolve it deterministically inside `NSHostingView`. The accessibility label `"Name"` stays as-is for VoiceOver.
- `UITestSupport/UITestIdentifiers+Sidebar.swift` — add `public static let renameNameField = "sidebar.row.renameField"`.

**Untouched (referenced only):**
- `Features/Earmarks/Views/EarmarkRowView.swift`, `Features/Accounts/Views/AccountGroupSidebarRow.swift` — both delegate to `SidebarRowView` (where the field actually lives), so the identifier added in `AccountSidebarRow.swift` covers them too.
- iOS path in `SidebarView+Sections.swift` / `SidebarView+Groups.swift` — unchanged.
- `*Store.rename(id:to:)` — already trim / handle empty + same-name as no-op; no changes needed.

---

## Task 1: Lift rename helpers cross-platform and extract pure static binding

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`

The existing `#if os(iOS)` extension on `SidebarView` contains `renameBinding(for:)` plus three `renameAction(for:)` overloads. Their bodies contain no platform-conditional code; macOS will use them too. Also extract the binding factory to a pure static helper so it is unit-testable without a SwiftUI view.

- [ ] **Step 1.1: Remove the `#if os(iOS)` / `#endif` wrapping of the rename helpers**

  In `Features/Navigation/SidebarView.swift`, the iOS-only extension block currently includes:

  ```swift
  #if os(iOS)
    extension SidebarView {
      // ... view builders ...

      // MARK: - State Coordination
      // renameBinding, renameAction

      func renameBinding(for id: UUID) -> Binding<Bool> { ... }
      func renameAction(for account: Account) -> (String) -> Void { ... }
      func renameAction(for earmark: Earmark) -> (String) -> Void { ... }
      func renameAction(for group: AccountGroup) -> (String) -> Void { ... }

      // ... earmarkContextMenu ...
    }
  #endif
  ```

  Move the four rename helpers out into a separate, unconditional extension. Leave the view-builder helpers (`recentlyAddedLabel`, `totalRow`, `accountContextMenu`, `sectionHeader`, `earmarkContextMenu`, `accountGroupSubmenu`) inside the existing `#if os(iOS)` extension — they ARE iOS-only (they render SwiftUI view content that the macOS path doesn't use).

  The new cross-platform extension should look like:

  ```swift
  extension SidebarView {
    // MARK: - Inline Rename State Coordination
    // renameBinding, renameAction — shared by iOS list rows and the
    // macOS AppKit outline cells.

    /// Returns a binding that reports `true` when this row id is the one
    /// currently being inline-renamed, and (on `set(true)`) makes it so.
    /// Centralises the one-at-a-time invariant.
    func renameBinding(for id: UUID) -> Binding<Bool> {
      Self.renameBinding(for: id, editingId: $editingRowId)
    }

    /// Pure factory used by both `SidebarView` (above) and the AppKit
    /// `SidebarCellBuilder` so the one-at-a-time invariant has a single
    /// definition.
    static func renameBinding(
      for id: UUID, editingId: Binding<UUID?>
    ) -> Binding<Bool> {
      Binding(
        get: { editingId.wrappedValue == id },
        set: { newValue in editingId.wrappedValue = newValue ? id : nil }
      )
    }

    /// Returns the `onRename` closure for an account row — single source
    /// of truth for the inline-rename dispatch shape, used by both the
    /// Current and Investments sections on iOS and by the AppKit outline
    /// cells on macOS.
    func renameAction(for account: Account) -> (String) -> Void {
      { newName in
        Task { _ = try? await accountStore.rename(id: account.id, to: newName) }
      }
    }

    /// Returns the `onRename` closure for an earmark row.
    func renameAction(for earmark: Earmark) -> (String) -> Void {
      { newName in
        Task { _ = await earmarkStore.rename(id: earmark.id, to: newName) }
      }
    }

    /// Returns the `onRename` closure for an account-group row.
    func renameAction(for group: AccountGroup) -> (String) -> Void {
      { newName in
        Task { _ = try? await accountGroupStore.rename(id: group.id, to: newName) }
      }
    }
  }
  ```

  Delete the four functions from the existing `#if os(iOS)` block.

- [ ] **Step 1.2: Verify both platforms still compile**

  Run: `just build-mac`
  Expected: `** BUILD SUCCEEDED **`

  Run: `just build-ios`
  Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 1.3: Run the existing test suite to confirm no regression**

  Run: `mkdir -p .agent-tmp && just test-mac 2>&1 | tee .agent-tmp/test-mac.txt`
  Expected: all tests pass. Check with `grep -E "Test Suite '.+' (passed|failed)" .agent-tmp/test-mac.txt | tail -5`.

- [ ] **Step 1.4: format-check**

  Run: `just format-check`
  Expected: no diff, no SwiftLint violations.

- [ ] **Step 1.5: Commit**

  ```bash
  git add Features/Navigation/SidebarView.swift
  git commit -m "$(cat <<'EOF'
  refactor(sidebar): lift inline-rename helpers cross-platform

  Move renameBinding(for:) and the three renameAction(for:) overloads
  out of the #if os(iOS) extension so macOS AppKit cells can call them.
  Extract a pure static renameBinding(for:editingId:) so the helper is
  unit-testable without a SwiftUI view. No behavior change.

  For #999.
  EOF
  )"
  ```

---

## Task 2: Unit tests for the pure rename binding helper

**Files:**
- Create: `MoolahTests/Navigation/SidebarRenameBindingTests.swift`

- [ ] **Step 2.1: Write the failing test file**

  Create `MoolahTests/Navigation/SidebarRenameBindingTests.swift`:

  ```swift
  import Foundation
  import SwiftUI
  import Testing

  @testable import Moolah

  @Suite("SidebarView.renameBinding(for:editingId:)")
  struct SidebarRenameBindingTests {
    @Test("Reports true when editingId matches and false otherwise")
    func reportsEditingState() {
      let a = UUID()
      let b = UUID()
      var editingId: UUID? = a
      let editing = Binding<UUID?>(
        get: { editingId }, set: { editingId = $0 })

      #expect(SidebarView.renameBinding(for: a, editingId: editing).wrappedValue)
      #expect(!SidebarView.renameBinding(for: b, editingId: editing).wrappedValue)
    }

    @Test("Setting true assigns this id; setting false clears")
    func toggleSetsAndClears() {
      let a = UUID()
      var editingId: UUID?
      let editing = Binding<UUID?>(
        get: { editingId }, set: { editingId = $0 })

      let binding = SidebarView.renameBinding(for: a, editingId: editing)
      binding.wrappedValue = true
      #expect(editingId == a)
      binding.wrappedValue = false
      #expect(editingId == nil)
    }

    @Test("Setting true for B while A is editing replaces A")
    func switchingBetweenRowsReplacesEditingId() {
      let a = UUID()
      let b = UUID()
      var editingId: UUID? = a
      let editing = Binding<UUID?>(
        get: { editingId }, set: { editingId = $0 })

      SidebarView.renameBinding(for: b, editingId: editing).wrappedValue = true
      #expect(editingId == b)
    }

    @Test("Setting false on a non-editing row leaves editingId unchanged")
    func clearingNonEditingRowIsNoop() {
      let a = UUID()
      let b = UUID()
      var editingId: UUID? = a
      let editing = Binding<UUID?>(
        get: { editingId }, set: { editingId = $0 })

      SidebarView.renameBinding(for: b, editingId: editing).wrappedValue = false
      // Even though `set` writes `nil`, semantically this row was never
      // editing — `editingRowId` becomes `nil`, clearing A's edit. This
      // matches existing iOS behaviour; document it in the test.
      #expect(editingId == nil)
    }
  }
  ```

  Note the fourth test documents an intentional quirk: any `set(false)` clears `editingRowId` outright. This matches existing iOS behaviour (`renameBinding` on iOS uses the same logic) and is fine in practice because the only call site that sets `false` is the field commit, which only fires for the editing row.

- [ ] **Step 2.2: Run the test to verify it passes**

  Run: `just test-mac SidebarRenameBindingTests 2>&1 | tee .agent-tmp/test-rename-binding.txt | tail -30`
  Expected: 4 tests, all pass.

- [ ] **Step 2.3: format-check**

  Run: `just format-check`
  Expected: no diff.

- [ ] **Step 2.4: Commit**

  ```bash
  git add MoolahTests/Navigation/SidebarRenameBindingTests.swift
  git commit -m "$(cat <<'EOF'
  test(sidebar): cover renameBinding(for:editingId:) invariants

  Pure-data tests for the one-at-a-time edit-state binding shared
  by iOS list rows and the macOS AppKit outline cells.

  For #999.
  EOF
  )"
  ```

---

## Task 3: Add the Return-key intercepting `NSOutlineView` subclass

**Files:**
- Create: `Features/Navigation/AppKitSidebar/SidebarKeyHandlingOutlineView.swift`

The subclass is the smallest possible: it overrides `keyDown(with:)` to recognise Return and fires an `onReturnKey: (() -> Void)?` closure unconditionally. All gating (was a row selected? is it a renamable kind?) lives in the controller — keeping the subclass minimal so it stays purely about key dispatch.

- [ ] **Step 3.1: Create the file**

  Create `Features/Navigation/AppKitSidebar/SidebarKeyHandlingOutlineView.swift`:

  ```swift
  #if os(macOS)
    import AppKit

    /// `NSOutlineView` subclass that intercepts Return and forwards it as
    /// a high-level "begin rename on the current selection" signal via
    /// the `onReturnKey` closure. All other keys fall through to the
    /// default `keyDown` so arrow-key navigation, expand/collapse, Esc
    /// handoff, and Tab cycling behave normally.
    ///
    /// The closure is intentionally unconditional — the controller that
    /// wires this view decides whether the current selection is
    /// renamable and only fires the delegate-level callback when it is.
    /// Keeping the subclass minimal avoids leaking knowledge of
    /// `SidebarRow` into the key-handling surface.
    @MainActor
    final class SidebarKeyHandlingOutlineView: NSOutlineView {
      var onReturnKey: (() -> Void)?

      override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 {  // Return
          onReturnKey?()
          return
        }
        super.keyDown(with: event)
      }
    }
  #endif
  ```

  `keyCode == 36` is the documented value for the Return key on macOS (`kVK_Return`). The numpad Enter (`kVK_ANSI_KeypadEnter`, 76) is intentionally excluded — the iOS path also doesn't fire on it.

- [ ] **Step 3.2: Verify the file builds**

  Run: `just build-mac`
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3.3: format-check**

  Run: `just format-check`
  Expected: no diff.

- [ ] **Step 3.4: Commit**

  ```bash
  git add Features/Navigation/AppKitSidebar/SidebarKeyHandlingOutlineView.swift
  git commit -m "$(cat <<'EOF'
  feat(sidebar): add NSOutlineView subclass intercepting Return

  Minimal subclass that fires onReturnKey on Return (kVK_Return / 36)
  and falls through for every other key. The controller will gate
  whether the current selection is renamable before propagating.

  For #999.
  EOF
  )"
  ```

---

## Task 4: Add `beginRenameRequested` callback to `SidebarOutlineDelegate`

**Files:**
- Modify: `Features/Navigation/AppKitSidebar/SidebarOutlineDelegate.swift`

- [ ] **Step 4.1: Add the property**

  In `Features/Navigation/AppKitSidebar/SidebarOutlineDelegate.swift`, add a third callback alongside `selectionChanged` and `expansionChanged`:

  ```swift
  var cellBuilder: SidebarCellBuilder?
  var selectionChanged: ((SidebarRow?) -> Void)?
  var expansionChanged: ((SidebarRow, Bool) -> Void)?
  /// Fired when the user requests "rename current selection" via a
  /// keyboard / menu trigger. The receiver (`SidebarOutline`) is
  /// expected to map the current selection to its row id and flip
  /// `editingRowId`.
  var beginRenameRequested: (() -> Void)?
  var suppressExpansionCallbacks = false
  ```

- [ ] **Step 4.2: Verify the file builds**

  Run: `just build-mac`
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4.3: format-check + commit**

  ```bash
  just format-check
  git add Features/Navigation/AppKitSidebar/SidebarOutlineDelegate.swift
  git commit -m "$(cat <<'EOF'
  feat(sidebar): add beginRenameRequested callback on outline delegate

  Outline → controller → SidebarOutline signal for "start renaming
  the currently selected row." Wired up in subsequent tasks.

  For #999.
  EOF
  )"
  ```

---

## Task 5: Wire the new subclass into `SidebarOutlineController`

**Files:**
- Modify: `Features/Navigation/AppKitSidebar/SidebarOutlineController.swift`

- [ ] **Step 5.1: Change the outline-view property to the subclass type**

  In `SidebarOutlineController.swift`, change:

  ```swift
  let outlineView = NSOutlineView()
  ```

  to:

  ```swift
  let outlineView = SidebarKeyHandlingOutlineView()
  ```

  Leave the rest of `configureOutlineView`, `configureScrollView`, `installScrollView`, `apply(tree:expandedGroupIds:selection:)`, and `reconcileSelection(_:)` unchanged.

- [ ] **Step 5.2: Wire the Return-key closure with renamable-row gating**

  At the bottom of `configureOutlineView()`, after `outlineView.delegate = delegate`, add:

  ```swift
    // Return on a renamable selected row → ask SidebarOutline to start
    // inline rename. Non-renamable selections (navigation / total rows
    // are non-selectable anyway; section headers likewise) are
    // silently ignored.
    outlineView.onReturnKey = { [weak self] in
      guard let self,
        self.outlineView.selectedRow >= 0,
        let row = self.outlineView.item(atRow: self.outlineView.selectedRow)
          as? SidebarRow
      else { return }
      switch row {
      case .account, .earmark, .group:
        self.delegate.beginRenameRequested?()
      case .section, .total, .navigation:
        return
      }
    }
  ```

  The `[weak self]` capture matches the existing controller's lifetime model (the outline owns the controller's view, so retain cycles via strong captures would be subtle).

- [ ] **Step 5.3: Build + format-check**

  Run: `just build-mac`
  Expected: `** BUILD SUCCEEDED **`.

  Run: `just format-check`
  Expected: no diff.

- [ ] **Step 5.4: Commit**

  ```bash
  git add Features/Navigation/AppKitSidebar/SidebarOutlineController.swift
  git commit -m "$(cat <<'EOF'
  feat(sidebar): use key-handling outline subclass on macOS controller

  Wire onReturnKey to fire delegate.beginRenameRequested only when the
  current selection is an account, earmark, or group row. Non-renamable
  selections fall through silently.

  For #999.
  EOF
  )"
  ```

---

## Task 6: Failing unit tests for the new context-menu builders

**Files:**
- Create: `MoolahTests/Navigation/SidebarContextMenuBuilderTests.swift`

This task adds tests before implementing the new menu surface. The tests reference methods that don't yet exist (`SidebarContextMenuBuilder.earmarkMenu`, `groupMenu`) and an updated `accountMenu` signature with `onBeginRename:`. The test file therefore **fails to compile** until Task 7 lands — that is the "red" state for this TDD pair.

- [ ] **Step 6.1: Create the test file**

  Create `MoolahTests/Navigation/SidebarContextMenuBuilderTests.swift`:

  ```swift
  #if os(macOS)
    import AppKit
    import Foundation
    import SwiftUI
    import Testing

    @testable import Moolah

    @Suite("SidebarContextMenuBuilder")
    @MainActor
    struct SidebarContextMenuBuilderTests {
      @Test("accountMenu first item is Rename and fires onBeginRename")
      func accountMenuRenameFiresClosure() async throws {
        let backend = PreviewBackend.create()
        let accountStore = AccountStore(
          repository: backend.accounts,
          conversionService: backend.conversionService,
          targetInstrument: .AUD)

        let account = Account(name: "Checking", type: .bank, instrument: .AUD)
        _ = try await accountStore.create(account)

        var beginRenameFired = false
        let menu = SidebarContextMenuBuilder.accountMenu(
          accountId: account.id,
          accountStore: accountStore,
          selection: .constant(nil),
          accountToEdit: .constant(nil),
          onBeginRename: { beginRenameFired = true })

        let first = try #require(menu.items.first)
        #expect(first.title == "Rename")
        #expect(
          first.accessibilityIdentifier()
            == UITestIdentifiers.Sidebar.renameContextMenuItem)

        // Trigger via the target/action sink directly — XCTest can't drive
        // an NSMenu programmatically without a real event loop.
        if let action = first.action, let target = first.target {
          _ = target.perform(action, with: first)
        }
        #expect(beginRenameFired)
      }

      @Test("earmarkMenu has a single Rename item that fires onBeginRename")
      func earmarkMenuRenameFiresClosure() {
        var beginRenameFired = false
        let menu = SidebarContextMenuBuilder.earmarkMenu(
          earmarkId: UUID(),
          onBeginRename: { beginRenameFired = true })

        #expect(menu.items.count == 1)
        let first = try? #require(menu.items.first)
        #expect(first?.title == "Rename")
        #expect(
          first?.accessibilityIdentifier()
            == UITestIdentifiers.Sidebar.renameContextMenuItem)

        if let item = first, let action = item.action, let target = item.target {
          _ = target.perform(action, with: item)
        }
        #expect(beginRenameFired)
      }

      @Test("groupMenu has a single Rename item that fires onBeginRename")
      func groupMenuRenameFiresClosure() {
        var beginRenameFired = false
        let menu = SidebarContextMenuBuilder.groupMenu(
          groupId: UUID(),
          onBeginRename: { beginRenameFired = true })

        #expect(menu.items.count == 1)
        let first = try? #require(menu.items.first)
        #expect(first?.title == "Rename")
        #expect(
          first?.accessibilityIdentifier()
            == UITestIdentifiers.Sidebar.renameContextMenuItem)

        if let item = first, let action = item.action, let target = item.target {
          _ = target.perform(action, with: item)
        }
        #expect(beginRenameFired)
      }
    }
  #endif
  ```

- [ ] **Step 6.2: Verify the test target fails to compile (red state)**

  Run: `just build-mac 2>&1 | tee .agent-tmp/build-red.txt | tail -20`
  Expected: build fails with errors referencing `accountMenu` extra argument `onBeginRename`, `earmarkMenu` not found on `SidebarContextMenuBuilder`, `groupMenu` not found.

- [ ] **Step 6.3: Commit the failing tests**

  ```bash
  git add MoolahTests/Navigation/SidebarContextMenuBuilderTests.swift
  git commit -m "$(cat <<'EOF'
  test(sidebar): add failing tests for new macOS context-menu builders

  Red state for the TDD pair: SidebarContextMenuBuilder.accountMenu
  gains an onBeginRename closure and a Rename item; earmarkMenu and
  groupMenu are net-new. Implementation follows in the next commit.

  For #999.
  EOF
  )"
  ```

---

## Task 7: Implement the context-menu surface

**Files:**
- Modify: `Features/Navigation/AppKitSidebar/SidebarContextMenuBuilder.swift`

The existing `accountMenu` keeps its current "Edit Account…" and "View Transactions" items but gains a leading "Rename" item and a new `onBeginRename` parameter. Two new builders (`earmarkMenu`, `groupMenu`) each carry a single "Rename" item.

The existing `CellMenuActions` target/action sink keeps its current methods; add a `renameAction(_:)` selector. Each new builder gets its own small sink instance, retained via `objc_setAssociatedObject` on the menu (mirroring the existing pattern).

- [ ] **Step 7.1: Rewrite `SidebarContextMenuBuilder.swift`**

  Replace the entire contents of `Features/Navigation/AppKitSidebar/SidebarContextMenuBuilder.swift` with:

  ```swift
  #if os(macOS)
    import AppKit
    import SwiftUI

    /// Builds the AppKit `NSMenu` attached to each sidebar row's
    /// right-click menu. UI tests find menu items by accessibility
    /// identifier (e.g. `renameContextMenuItem`, `editAccountContextMenuItem`)
    /// and dispatch fires the associated `on…` closure.
    ///
    /// Using an AppKit `NSMenu` (rather than a SwiftUI `.contextMenu` on
    /// the hosted row) keeps the menu open across re-renders of the
    /// hosted SwiftUI tree: AppKit's menu-tracking session owns the menu
    /// independent of any view replacement.
    enum SidebarContextMenuBuilder {
      @MainActor
      static func accountMenu(
        accountId: UUID,
        accountStore: AccountStore,
        selection: Binding<SidebarSelection?>,
        accountToEdit: Binding<Account?>,
        onBeginRename: @escaping () -> Void
      ) -> NSMenu {
        let actions = AccountMenuActions(
          onRename: onBeginRename,
          onEdit: {
            guard let fresh = accountStore.accounts.by(id: accountId) else { return }
            accountToEdit.wrappedValue = fresh
          },
          onViewTransactions: { selection.wrappedValue = .account(accountId) })

        let menu = NSMenu()

        let renameItem = NSMenuItem(
          title: "Rename",
          action: #selector(AccountMenuActions.renameAction(_:)),
          keyEquivalent: "")
        renameItem.target = actions
        renameItem.image = NSImage(
          systemSymbolName: "character.cursor.ibeam",
          accessibilityDescription: nil)
        renameItem.setAccessibilityIdentifier(
          UITestIdentifiers.Sidebar.renameContextMenuItem)
        menu.addItem(renameItem)

        let editItem = NSMenuItem(
          title: "Edit Account\u{2026}",
          action: #selector(AccountMenuActions.editAction(_:)),
          keyEquivalent: "")
        editItem.target = actions
        editItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        editItem.setAccessibilityIdentifier(UITestIdentifiers.Sidebar.editAccountContextMenuItem)
        menu.addItem(editItem)

        let viewItem = NSMenuItem(
          title: "View Transactions",
          action: #selector(AccountMenuActions.viewTransactionsAction(_:)),
          keyEquivalent: "")
        viewItem.target = actions
        viewItem.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        viewItem.setAccessibilityIdentifier(
          UITestIdentifiers.Sidebar.viewTransactionsContextMenuItem)
        menu.addItem(viewItem)

        objc_setAssociatedObject(
          menu, &AssociationKeys.cellActions, actions, .OBJC_ASSOCIATION_RETAIN)
        return menu
      }

      @MainActor
      static func earmarkMenu(
        earmarkId: UUID,
        onBeginRename: @escaping () -> Void
      ) -> NSMenu {
        let actions = RenameOnlyMenuActions(onRename: onBeginRename)
        let menu = NSMenu()
        let renameItem = NSMenuItem(
          title: "Rename",
          action: #selector(RenameOnlyMenuActions.renameAction(_:)),
          keyEquivalent: "")
        renameItem.target = actions
        renameItem.image = NSImage(
          systemSymbolName: "character.cursor.ibeam",
          accessibilityDescription: nil)
        renameItem.setAccessibilityIdentifier(
          UITestIdentifiers.Sidebar.renameContextMenuItem)
        menu.addItem(renameItem)
        objc_setAssociatedObject(
          menu, &AssociationKeys.cellActions, actions, .OBJC_ASSOCIATION_RETAIN)
        return menu
      }

      @MainActor
      static func groupMenu(
        groupId: UUID,
        onBeginRename: @escaping () -> Void
      ) -> NSMenu {
        let actions = RenameOnlyMenuActions(onRename: onBeginRename)
        let menu = NSMenu()
        let renameItem = NSMenuItem(
          title: "Rename",
          action: #selector(RenameOnlyMenuActions.renameAction(_:)),
          keyEquivalent: "")
        renameItem.target = actions
        renameItem.image = NSImage(
          systemSymbolName: "character.cursor.ibeam",
          accessibilityDescription: nil)
        renameItem.setAccessibilityIdentifier(
          UITestIdentifiers.Sidebar.renameContextMenuItem)
        menu.addItem(renameItem)
        objc_setAssociatedObject(
          menu, &AssociationKeys.cellActions, actions, .OBJC_ASSOCIATION_RETAIN)
        return menu
      }
    }

    /// Target/action sink for the account context menu. Each menu gets
    /// its own instance, retained via `objc_setAssociatedObject` on the
    /// menu (matches the lifetime of the cell it is attached to).
    @MainActor
    private final class AccountMenuActions: NSObject {
      private let onRename: () -> Void
      private let onEdit: () -> Void
      private let onViewTransactions: () -> Void

      init(
        onRename: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onViewTransactions: @escaping () -> Void
      ) {
        self.onRename = onRename
        self.onEdit = onEdit
        self.onViewTransactions = onViewTransactions
      }

      @objc func renameAction(_ sender: Any?) { onRename() }
      @objc func editAction(_ sender: Any?) { onEdit() }
      @objc func viewTransactionsAction(_ sender: Any?) { onViewTransactions() }
    }

    /// Target/action sink for the earmark and group context menus —
    /// both expose a single "Rename" entry.
    @MainActor
    private final class RenameOnlyMenuActions: NSObject {
      private let onRename: () -> Void

      init(onRename: @escaping () -> Void) {
        self.onRename = onRename
      }

      @objc func renameAction(_ sender: Any?) { onRename() }
    }

    @MainActor
    private enum AssociationKeys {
      static var cellActions: UInt8 = 0
    }
  #endif
  ```

  Notes:
  - The pre-existing `accountMenu` had items in order Edit Account → View Transactions. The new ordering puts Rename first, mirroring iOS where the inline rename item is the leading action in `accountContextMenu`.
  - `objc_setAssociatedObject` retains the per-menu actions instance — same pattern as before. The sink subclass split (`AccountMenuActions` vs `RenameOnlyMenuActions`) keeps each builder simple.

- [ ] **Step 7.2: Run the unit tests to verify green**

  Run: `just test-mac SidebarContextMenuBuilderTests 2>&1 | tee .agent-tmp/test-menu.txt | tail -30`
  Expected: 3 tests pass.

- [ ] **Step 7.3: format-check**

  Run: `just format-check`
  Expected: no diff.

- [ ] **Step 7.4: Commit**

  ```bash
  git add Features/Navigation/AppKitSidebar/SidebarContextMenuBuilder.swift
  git commit -m "$(cat <<'EOF'
  feat(sidebar): context-menu Rename for account / earmark / group on macOS

  accountMenu gains a leading Rename item and an onBeginRename closure;
  earmarkMenu and groupMenu are net-new, each carrying a single Rename
  entry. All three share UITestIdentifiers.Sidebar.renameContextMenuItem.

  For #999.
  EOF
  )"
  ```

---

## Task 8: Thread editing state through `SidebarCellBuilder`

**Files:**
- Modify: `Features/Navigation/AppKitSidebar/Cells/SidebarCellBuilder.swift`

The builder accepts a `Binding<UUID?>` and three rename closures. Inside the cell factories, the builder constructs the per-row `Binding<Bool>` (via `SidebarView.renameBinding(for:editingId:)`), passes `isEditing` / `onRename` to the iOS row views, and attaches the new menus.

- [ ] **Step 8.1: Add the four new fields and the per-row binding helper**

  In `Features/Navigation/AppKitSidebar/Cells/SidebarCellBuilder.swift`, change the `SidebarCellBuilder` declaration to include four new stored properties, and add a private `renameBinding(for:)` helper that delegates to the static factory on `SidebarView`:

  ```swift
  @MainActor
  struct SidebarCellBuilder {
    let accountStore: AccountStore
    let accountGroupStore: AccountGroupStore
    let earmarkStore: EarmarkStore
    let importStore: ImportStore
    let availableFunds: () -> InstrumentAmount?
    let selectionBinding: Binding<SidebarSelection?>
    let accountToEditBinding: Binding<Account?>
    /// `nil` when no row is being inline-renamed.
    let editingRowIdBinding: Binding<UUID?>
    /// Factories returning the `onRename` closure for a single row of
    /// each type. The closure is invoked with the trimmed text on
    /// commit; stores handle empty / same-name as no-ops.
    let onRenameAccount: (Account) -> (String) -> Void
    let onRenameEarmark: (Earmark) -> (String) -> Void
    let onRenameGroup: (AccountGroup) -> (String) -> Void
    let onAddAccount: () -> Void
    let onAddEarmark: () -> Void

    /// Returns the per-row `Binding<Bool>` consumed by the SwiftUI row
    /// view. Delegates to `SidebarView.renameBinding(for:editingId:)`
    /// so the one-at-a-time invariant has a single definition.
    private func renameBinding(for id: UUID) -> Binding<Bool> {
      SidebarView.renameBinding(for: id, editingId: editingRowIdBinding)
    }
    // ... existing makeCell + private cell builders below ...
  ```

- [ ] **Step 8.2: Update `accountCell(id:)` to pass edit bindings and the new menu signature**

  Replace the existing `accountCell(id:)` with:

  ```swift
  private func accountCell(id: UUID) -> NSTableCellView {
    guard let account = accountStore.accounts.by(id: id) else {
      return NSTableCellView()
    }
    let editingBinding = editingRowIdBinding
    let menu = SidebarContextMenuBuilder.accountMenu(
      accountId: id,
      accountStore: accountStore,
      selection: selectionBinding,
      accountToEdit: accountToEditBinding,
      onBeginRename: { editingBinding.wrappedValue = id })
    return NSTableCellView.hosting(
      accessibilityIdentifier: UITestIdentifiers.Sidebar.account(id),
      menu: menu
    ) {
      AccountSidebarRow(
        account: account,
        isSelected: selectionBinding.wrappedValue == .account(id),
        isMember: account.groupId != nil,
        isEditing: renameBinding(for: id),
        onRename: onRenameAccount(account)
      )
      .environment(accountStore)
    }
  }
  ```

  Capturing `editingBinding` as a local before passing it into the menu closure is intentional — the closure outlives the cell creation, and capturing the struct field directly would tie the menu's lifetime to the builder struct's lifetime (struct copying makes that fragile).

- [ ] **Step 8.3: Update `earmarkCell(id:)` to pass edit bindings and attach the new earmark menu**

  Replace the existing `earmarkCell(id:)` with:

  ```swift
  private func earmarkCell(id: UUID) -> NSTableCellView {
    guard let earmark = earmarkStore.earmarks.by(id: id) else {
      return NSTableCellView()
    }
    let isSelected = selectionBinding.wrappedValue == .earmark(id)
    let editingBinding = editingRowIdBinding
    let menu = SidebarContextMenuBuilder.earmarkMenu(
      earmarkId: id,
      onBeginRename: { editingBinding.wrappedValue = id })
    return NSTableCellView.hosting(
      accessibilityIdentifier: UITestIdentifiers.Sidebar.earmark(id),
      menu: menu
    ) {
      EarmarkRowView(
        earmark: earmark,
        isSelected: isSelected,
        isEditing: renameBinding(for: id),
        onRename: onRenameEarmark(earmark)
      )
      .environment(earmarkStore)
    }
  }
  ```

- [ ] **Step 8.4: Update `groupCell(id:)` likewise**

  Replace the existing `groupCell(id:)` with:

  ```swift
  private func groupCell(id: UUID) -> NSTableCellView {
    guard let group = accountGroupStore.by(id: id) else {
      return NSTableCellView()
    }
    let memberIds =
      accountStore.accounts.ordered
      .filter { $0.groupId == id }
      .sorted { $0.position < $1.position }
      .map(\.id)
    let isSelected = selectionBinding.wrappedValue == .group(id)
    let editingBinding = editingRowIdBinding
    let menu = SidebarContextMenuBuilder.groupMenu(
      groupId: id,
      onBeginRename: { editingBinding.wrappedValue = id })
    return NSTableCellView.hosting(
      accessibilityIdentifier: UITestIdentifiers.Sidebar.group(id),
      menu: menu
    ) {
      GroupAggregateBalanceLoader(
        memberIds: memberIds,
        targetInstrument: group.instrument
      ) { balance in
        AccountGroupSidebarRow(
          group: group,
          isSelected: isSelected,
          isExpanded: .constant(false),
          aggregateBalance: balance,
          isEditing: renameBinding(for: id),
          onRename: onRenameGroup(group),
          showChevron: false)
      }
      .environment(accountStore)
    }
  }
  ```

  Leave `sectionCell`, `totalCell`, `navigationCell` unchanged — those row types aren't renamable.

- [ ] **Step 8.5: Build (will fail until Task 9 updates `SidebarOutline` callers)**

  Run: `just build-mac 2>&1 | tee .agent-tmp/build-after-step-8.txt | tail -20`
  Expected: build fails. The cell builder now requires four new fields that callers don't yet provide. This is intentional — the next task wires them up.

- [ ] **Step 8.6: Stage but don't commit yet**

  ```bash
  git add Features/Navigation/AppKitSidebar/Cells/SidebarCellBuilder.swift
  ```

  The commit lands in Task 9 once the wiring compiles.

---

## Task 9: Pass the bindings through `SidebarOutline`

**Files:**
- Modify: `Features/Navigation/AppKitSidebar/SidebarOutline.swift`

- [ ] **Step 9.1: Add the new parameters and rewrite `makeNSViewController` / `makeCellBuilder`**

  Replace the contents of `Features/Navigation/AppKitSidebar/SidebarOutline.swift` body with:

  ```swift
  #if os(macOS)
    import SwiftUI

    /// SwiftUI bridge to `SidebarOutlineController`. Owned by the macOS
    /// body of `SidebarView`. Rebuilds the `SidebarRowTree.Snapshot` and
    /// the `SidebarCellBuilder` on every SwiftUI update; both are passed
    /// into the controller so it can apply the new state to its
    /// `NSOutlineView` and reconcile expand / selection.
    ///
    /// Selection round-trip: the controller's `selectionChanged` callback
    /// writes back into the parent's `Binding<SidebarSelection?>` via
    /// `SidebarRow.asSelection`. Expansion round-trip: the controller's
    /// `expansionChanged` callback writes back into
    /// `GroupUIStateStore.setExpanded(_:for:)` for `.group` rows only.
    /// Rename round-trip: the controller's `beginRenameRequested` callback
    /// flips `editingRowId` to the currently selected row's id, which
    /// drives the inline `TextField` swap in the hosted SwiftUI row.
    struct SidebarOutline: NSViewControllerRepresentable {
      let accountStore: AccountStore
      let accountGroupStore: AccountGroupStore
      let earmarkStore: EarmarkStore
      let importStore: ImportStore
      let groupUIStateStore: GroupUIStateStore
      @Binding var selection: SidebarSelection?
      @Binding var accountToEdit: Account?
      @Binding var editingRowId: UUID?
      let onRenameAccount: (Account) -> (String) -> Void
      let onRenameEarmark: (Earmark) -> (String) -> Void
      let onRenameGroup: (AccountGroup) -> (String) -> Void
      let onAddAccount: () -> Void
      let onAddEarmark: () -> Void
      let showHidden: Bool

      func makeNSViewController(context: Context) -> SidebarOutlineController {
        let controller = SidebarOutlineController()
        controller.delegate.selectionChanged = { row in
          selection = row?.asSelection
        }
        controller.delegate.expansionChanged = { row, isExpanded in
          guard case .group(let groupId) = row else { return }
          Task { await groupUIStateStore.setExpanded(isExpanded, for: groupId) }
        }
        controller.delegate.beginRenameRequested = { [controller] in
          let view = controller.outlineView
          guard view.selectedRow >= 0,
            let row = view.item(atRow: view.selectedRow) as? SidebarRow
          else { return }
          switch row {
          case .account(let id), .earmark(let id), .group(let id):
            editingRowId = id
          case .section, .total, .navigation:
            return
          }
        }
        return controller
      }

      func updateNSViewController(
        _ controller: SidebarOutlineController, context: Context
      ) {
        let tree = SidebarRowTree.build(from: makeSnapshot())
        controller.delegate.cellBuilder = makeCellBuilder()
        controller.apply(
          tree: tree,
          expandedGroupIds: groupUIStateStore.expandedGroupIds,
          selection: selection)
      }

      private func makeSnapshot() -> SidebarRowTree.Snapshot {
        SidebarRowTree.Snapshot(
          accounts: accountStore.accounts,
          groups: accountGroupStore.groups,
          earmarks: earmarkStore.visibleEarmarks,
          currentTotal: accountStore.convertedCurrentTotal,
          investmentTotal: accountStore.convertedInvestmentTotal,
          earmarkedTotal: earmarkStore.convertedTotalBalance,
          netWorth: accountStore.convertedNetWorth,
          showHidden: showHidden,
          unreviewedBadgeCount: importStore.unreviewedBadgeCount)
      }

      private func makeCellBuilder() -> SidebarCellBuilder {
        SidebarCellBuilder(
          accountStore: accountStore,
          accountGroupStore: accountGroupStore,
          earmarkStore: earmarkStore,
          importStore: importStore,
          availableFunds: {
            guard let current = accountStore.convertedCurrentTotal,
              let earmarked = earmarkStore.convertedTotalBalance
            else { return nil }
            return current - earmarked
          },
          selectionBinding: $selection,
          accountToEditBinding: $accountToEdit,
          editingRowIdBinding: $editingRowId,
          onRenameAccount: onRenameAccount,
          onRenameEarmark: onRenameEarmark,
          onRenameGroup: onRenameGroup,
          onAddAccount: onAddAccount,
          onAddEarmark: onAddEarmark)
      }
    }
  #endif
  ```

  The `[controller]` capture inside `beginRenameRequested` is necessary because the closure reads `controller.outlineView.selectedRow` at fire time. The controller owns the outline view, so capturing the controller (a reference type) is the cleaner shape than capturing `view` directly.

- [ ] **Step 9.2: Build (will still fail — `SidebarView.macSidebarBody` is the only remaining caller)**

  Run: `just build-mac 2>&1 | tee .agent-tmp/build-after-step-9.txt | tail -20`
  Expected: build fails with errors at the `SidebarOutline(...)` call site in `SidebarView.swift` — Task 10 wires it up.

- [ ] **Step 9.3: Stage**

  ```bash
  git add Features/Navigation/AppKitSidebar/SidebarOutline.swift
  ```

  Commit pending until Task 10.

---

## Task 10: Wire `SidebarView.macSidebarBody` to the new surface

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`

- [ ] **Step 10.1: Pass the new bindings + closures**

  Replace the macOS body in `SidebarView.swift`:

  ```swift
  #if os(macOS)
    /// macOS body: a single full-bleed `NSOutlineView` rendering every
    /// sidebar row — accounts, groups, earmarks, totals, navigation —
    /// via the `SidebarOutline` representable. Cross-platform toolbar /
    /// sheets / sync footer are still carried by `sharedBodyModifiers`.
    var macSidebarBody: some View {
      SidebarOutline(
        accountStore: accountStore,
        accountGroupStore: accountGroupStore,
        earmarkStore: earmarkStore,
        importStore: importStore,
        groupUIStateStore: groupUIStateStore,
        selection: $selection,
        accountToEdit: $accountToEdit,
        editingRowId: $editingRowId,
        onRenameAccount: renameAction(for:),
        onRenameEarmark: renameAction(for:),
        onRenameGroup: renameAction(for:),
        onAddAccount: { showCreateAccountSheet = true },
        onAddEarmark: { showCreateEarmarkSheet = true },
        showHidden: showHidden
      )
      .modifier(sharedBodyModifiers)
    }
  #endif
  ```

  Swift resolves the three `renameAction(for:)` overloads by the destination parameter's argument type (`(Account) -> ...`, `(Earmark) -> ...`, `(AccountGroup) -> ...`) — no disambiguation cast needed.

- [ ] **Step 10.2: Build the full app on both platforms**

  Run: `just build-mac`
  Expected: `** BUILD SUCCEEDED **`.

  Run: `just build-ios`
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10.3: Run the unit test suite**

  Run: `mkdir -p .agent-tmp && just test-mac 2>&1 | tee .agent-tmp/test-mac.txt`
  Expected: all tests pass. Spot-check with `grep -c "^Test .* failed" .agent-tmp/test-mac.txt` returning `0`.

- [ ] **Step 10.4: format-check**

  Run: `just format-check`
  Expected: no diff.

- [ ] **Step 10.5: Commit Tasks 8–10 together**

  ```bash
  git add Features/Navigation/SidebarView.swift
  git commit -m "$(cat <<'EOF'
  feat(sidebar): inline rename on macOS — wire editingRowId through outline

  SidebarOutline now accepts editingRowId + per-row-type rename closures
  and threads them through SidebarCellBuilder into the existing iOS row
  views (AccountSidebarRow, EarmarkRowView, AccountGroupSidebarRow).
  Cells attach the new NSMenus from SidebarContextMenuBuilder and gain
  isEditing / onRename bindings. The delegate's beginRenameRequested
  callback flips editingRowId to the currently selected row id when
  Return is pressed.

  Together with the previous commits this completes the production
  surface for #999. UI tests follow.

  For #999.
  EOF
  )"
  ```

---

## Task 11: Add earmark + group fixtures to `TradeBaseline`

**Files:**
- Modify: `UITestSupport/UITestFixtures.swift`

The UI tests need one earmark and one account group in the sidebar so XCUITest can drive Rename across all three row types. `TradeBaseline` is the seed all sidebar-affecting tests already use; existing tests reference accounts by id and don't assert on row counts, so adding the new rows is non-breaking.

- [ ] **Step 11.1: Add fixture fields**

  In the `TradeBaseline` enum inside `UITestSupport/UITestFixtures.swift`, add new fields alongside the existing `*AccountId` / `*AccountName` lines. Place them after `tradesBrokerageAccountName`:

  ```swift
  // Earmark for sidebar-rename UI coverage. Lives in the same profile;
  // no balance / target. Drive via UITestIdentifiers.Sidebar.earmark(id).
  public static let renameTargetEarmarkId =
    uuidLiteral("A1000000-0000-0000-0000-0000000000E1")
  public static let renameTargetEarmarkName = "Holiday"

  // Account group for sidebar-rename UI coverage. Bucket: investments
  // so it nests under the same source-list section as the existing
  // brokerage / tradesBrokerage accounts. Has no members — group
  // membership is out of scope for #999 and the rename test only
  // needs the row to be present and renameable.
  public static let renameTargetGroupId =
    uuidLiteral("A1000000-0000-0000-0000-0000000000F1")
  public static let renameTargetGroupName = "Investments Group"
  ```

  Update the documentation block at the top of `TradeBaseline` to mention the new fixtures alongside the existing accounts (one or two short bullets).

- [ ] **Step 11.2: Build to confirm there are no symbol clashes**

  Run: `just build-mac`
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 11.3: format-check + stage**

  Run: `just format-check`
  Expected: no diff.

  ```bash
  git add UITestSupport/UITestFixtures.swift
  ```

  Commit lands together with Task 12.

---

## Task 12: Seed the earmark + group inside `hydrateTradeBaseline`

**Files:**
- Modify: `App/UITestSeedHydrator.swift`

The hydrator already seeds accounts / snapshots / transactions for `TradeBaseline`. `UITestSeedHydrator+Upserts.swift` has no helpers for earmark / group today; this task adds them (modelled on the existing `upsertAccount`) and seeds one of each inside `hydrateTradeBaseline`.

- [ ] **Step 12.1: Add `upsertEarmark` and `upsertAccountGroup` helpers**

  `App/UITestSeedHydrator+Upserts.swift` currently has no upsert helpers for earmarks or account groups. Add them following the exact shape of `upsertAccount` (which uses `AccountRow.recordName(for:)` to derive `record_name`, then writes via `row.upsert(database)`). Both `EarmarkRow` and `AccountGroupRow` already expose static `recordName(for: UUID)` helpers (`Backends/GRDB/Records/EarmarkRow+Mapping.swift`, `Backends/GRDB/Records/AccountGroupRow+Mapping.swift`).

  Add these two specs and helpers to `App/UITestSeedHydrator+Upserts.swift`, alongside the existing `AccountSpec` / `upsertAccount`:

  ```swift
  struct EarmarkSpec {
    let id: UUID
    let name: String
    let instrumentId: String
    var position: Int = 0
  }

  static func upsertEarmark(_ spec: EarmarkSpec, in database: Database) throws {
    let row = EarmarkRow(
      id: spec.id,
      recordName: EarmarkRow.recordName(for: spec.id),
      name: spec.name,
      position: spec.position,
      isHidden: false,
      instrumentId: spec.instrumentId,
      savingsTarget: nil,
      savingsTargetInstrumentId: nil,
      savingsStartDate: nil,
      savingsEndDate: nil,
      encodedSystemFields: nil)
    try row.upsert(database)
  }

  struct AccountGroupSpec {
    let id: UUID
    let name: String
    /// `AccountBucket.rawValue` — `"current"` or `"investments"`. Stored
    /// raw to mirror the row shape (the v14 migration pinned the column
    /// with a CHECK constraint, see `AccountGroupRow`).
    let bucketRawValue: String
    let instrumentId: String
    let position: Int
  }

  static func upsertAccountGroup(
    _ spec: AccountGroupSpec, in database: Database
  ) throws {
    let row = AccountGroupRow(
      id: spec.id,
      recordName: AccountGroupRow.recordName(for: spec.id),
      name: spec.name,
      bucket: spec.bucketRawValue,
      instrumentId: spec.instrumentId,
      position: spec.position,
      encodedSystemFields: nil)
    try row.upsert(database)
  }
  ```

  These two helpers are NOT marked `@MainActor` — the rest of the file's upsert helpers are also unannotated (they're `static` on `UITestSeedHydrator`, which itself is `@MainActor`-confined at the enum level; the upserts inherit isolation through the surrounding type, not via per-method annotations).

  Note `EarmarkSpec.position` defaults to `0` (single test earmark — no ordering conflict). `AccountGroupSpec` takes `bucketRawValue: String` directly rather than an `AccountBucket` enum, mirroring the column's storage form and avoiding a dependency on the enum's case names if they ever change.

- [ ] **Step 12.2: Seed the new fixtures inside `hydrateTradeBaseline`**

  Append to the `try database.write { database in ... }` block in `hydrateTradeBaseline` (after `seedTradeBaselineTransactions`):

  ```swift
      try seedTradeBaselineRenameTargets(instrument: instrument, in: database)
  ```

  Add the new function below the existing `seedTradeBaseline*` family in `UITestSeedHydrator.swift`:

  ```swift
  /// Seeds one earmark + one investments-bucket account group used by
  /// the macOS sidebar-rename UI tests. Both are nominal fixtures with
  /// no balance / membership; the tests only need the rows present and
  /// renameable.
  private static func seedTradeBaselineRenameTargets(
    instrument: Instrument, in database: Database
  ) throws {
    let fixtures = UITestFixtures.TradeBaseline.self
    try upsertEarmark(
      EarmarkSpec(
        id: fixtures.renameTargetEarmarkId,
        name: fixtures.renameTargetEarmarkName,
        instrumentId: instrument.id),
      in: database)
    try upsertAccountGroup(
      AccountGroupSpec(
        id: fixtures.renameTargetGroupId,
        name: fixtures.renameTargetGroupName,
        bucketRawValue: AccountBucket.investments.rawValue,
        instrumentId: instrument.id,
        position: 0),
      in: database)
  }
  ```

- [ ] **Step 12.3: Build + run the existing seed tests**

  Run: `just build-mac`
  Expected: `** BUILD SUCCEEDED **`.

  Run: `just test-mac UITestSeedHydratorTests 2>&1 | tee .agent-tmp/test-seed.txt | tail -20`
  Expected: existing seed tests still pass. If any test asserts on row counts in the seed and breaks, fix the count assertion to match the new total.

- [ ] **Step 12.4: format-check + commit Tasks 11–12 together**

  Run: `just format-check`
  Expected: no diff.

  ```bash
  git add App/UITestSeedHydrator.swift App/UITestSeedHydrator+Upserts.swift
  git commit -m "$(cat <<'EOF'
  test(ui): seed earmark + group fixtures in TradeBaseline

  Adds renameTargetEarmark and renameTargetGroup to the shared
  TradeBaseline UI-test seed so the upcoming macOS sidebar-rename
  XCUITests can drive Rename across all three row types.

  For #999.
  EOF
  )"
  ```

---

## Task 13: Inline rename name-field identifier + sidebar UI driver methods

**Files:**
- Modify: `UITestSupport/UITestIdentifiers+Sidebar.swift`
- Modify: `Features/Accounts/Views/AccountSidebarRow.swift`
- Modify: `MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift`

Adds a stable accessibility identifier on the inline `TextField` so XCUITest can resolve it through `NSHostingView` deterministically, then adds driver methods so tests express intent at the row-type level. Each driver method follows the `Trace.record(...)` + `waitForExistence` + post-condition pattern already used by `switchToAccount` / `switchToNamed`.

- [ ] **Step 13.0: Add the `renameNameField` identifier and attach it to `InlineRenameField`**

  In `UITestSupport/UITestIdentifiers+Sidebar.swift`, add a new constant alongside the existing `renameContextMenuItem`:

  ```swift
  /// Accessibility identifier on the inline `TextField` rendered while
  /// a sidebar row is being renamed. Used by `SidebarScreen` driver
  /// methods to resolve the field through the `NSHostingView` boundary
  /// without relying on the accessibility label "Name".
  public static let renameNameField = "sidebar.row.renameField"
  ```

  In `Features/Accounts/Views/AccountSidebarRow.swift`, attach the identifier to the inline `TextField` inside `InlineRenameField`:

  ```swift
  var body: some View {
    TextField("Name", text: $text)
      .accessibilityLabel("Name")
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.renameNameField)
      .textFieldStyle(.plain)
      .focused($isFocused)
      .onAppear {
        text = initialText
        isFocused = true
      }
      .onSubmit {
        didCommit = true
        onCommit(text)
      }
      .onChange(of: isFocused) { _, focused in
        if !focused {
          if !didCommit { onCommit(text) }
          didCommit = false
        }
      }
      .onKeyPress(.escape) {
        onCancel()
        return .handled
      }
  }
  ```

  This change is cross-platform: iOS uses the same `InlineRenameField`. There are no iOS UI tests today, so the new identifier is currently only consumed by the macOS driver added below — but it's harmless on iOS.

- [ ] **Step 13.1: Add symbolic enums for the new fixtures and the rename driver methods**

  Append to `SidebarScreen.swift`:

  ```swift
  /// Symbolic reference to a sidebar earmark seeded by `TradeBaseline`.
  enum SidebarEarmark {
    case renameTarget

    var id: UUID {
      switch self {
      case .renameTarget: return UITestFixtures.TradeBaseline.renameTargetEarmarkId
      }
    }
  }

  /// Symbolic reference to a sidebar account group seeded by `TradeBaseline`.
  enum SidebarGroup {
    case renameTarget

    var id: UUID {
      switch self {
      case .renameTarget: return UITestFixtures.TradeBaseline.renameTargetGroupId
      }
    }
  }

  extension SidebarScreen {
    // MARK: - Inline rename

    /// Right-clicks the row, clicks the "Rename" item, and waits for the
    /// inline `TextField` to materialise inside the row.
    func beginRenameAccount(_ account: SidebarAccount) {
      Trace.record(detail: "account=\(account)")
      rightClick(rowIdentifier: UITestIdentifiers.Sidebar.account(account.id))
      clickRenameMenuItem()
      waitForRenameField(rowIdentifier: UITestIdentifiers.Sidebar.account(account.id))
    }

    func beginRenameEarmark(_ earmark: SidebarEarmark) {
      Trace.record(detail: "earmark=\(earmark)")
      rightClick(rowIdentifier: UITestIdentifiers.Sidebar.earmark(earmark.id))
      clickRenameMenuItem()
      waitForRenameField(rowIdentifier: UITestIdentifiers.Sidebar.earmark(earmark.id))
    }

    func beginRenameGroup(_ group: SidebarGroup) {
      Trace.record(detail: "group=\(group)")
      rightClick(rowIdentifier: UITestIdentifiers.Sidebar.group(group.id))
      clickRenameMenuItem()
      waitForRenameField(rowIdentifier: UITestIdentifiers.Sidebar.group(group.id))
    }

    /// Types `text` into the active inline rename field, then presses
    /// Return to commit. The currently-active field (set by
    /// `beginRename*`) keeps keyboard focus; resolving via the most
    /// recently inserted row's `textFields["Name"]` would race the
    /// `beginRename*` wait, so we use the focused-window field instead.
    func typeRenameAndCommit(text: String, inside rowIdentifier: String) {
      Trace.record(detail: "text=\(text) row=\(rowIdentifier)")
      let field = renameField(inside: rowIdentifier)
      field.typeText(text)
      app.pressKeyboardShortcut(XCUIKeyboardKey.return.rawValue)
    }

    /// Presses Esc to cancel the active inline rename.
    func cancelRename() {
      Trace.record()
      app.pressKeyboardShortcut(XCUIKeyboardKey.escape.rawValue)
    }

    /// Selects the account row by clicking it, then presses Return —
    /// the keyboard trigger for inline rename.
    func selectAndPressReturn(_ account: SidebarAccount) {
      Trace.record(detail: "account=\(account)")
      let identifier = UITestIdentifiers.Sidebar.account(account.id)
      let row = app.element(for: identifier)
      if !row.waitForExistence(timeout: 3) {
        Trace.recordFailure("sidebar row '\(identifier)' did not appear")
        XCTFail("Sidebar row for account \(account) did not appear within 3s")
        return
      }
      row.click()
      app.pressKeyboardShortcut(XCUIKeyboardKey.return.rawValue)
    }

    /// Double-clicks the account row's name to begin rename. Selects
    /// the row first (single click), which is the precondition for the
    /// `.onTapGesture(count: 2)` to attach inside `SidebarRowView`.
    func doubleClickAccountName(_ account: SidebarAccount) {
      Trace.record(detail: "account=\(account)")
      let identifier = UITestIdentifiers.Sidebar.account(account.id)
      let row = app.element(for: identifier)
      if !row.waitForExistence(timeout: 3) {
        Trace.recordFailure("sidebar row '\(identifier)' did not appear")
        XCTFail("Sidebar row for account \(account) did not appear within 3s")
        return
      }
      row.click()
      row.doubleClick()
    }

    /// Expects the row identified by `rowIdentifier` to be currently
    /// in inline-rename mode. Resolves the inline `TextField` (label
    /// "Name") inside the row's cell descendants.
    func expectRenameFieldVisible(rowIdentifier: String) {
      Trace.record(detail: "row=\(rowIdentifier)")
      let field = renameField(inside: rowIdentifier)
      if !field.waitForExistence(timeout: 3) {
        Trace.recordFailure("rename field did not appear inside '\(rowIdentifier)'")
        XCTFail("Inline rename TextField did not appear within 3s of trigger")
      }
    }

    /// Expects the row to be back in static-label mode (no rename field).
    func expectRenameFieldGone(rowIdentifier: String) {
      Trace.record(detail: "row=\(rowIdentifier)")
      let field = renameField(inside: rowIdentifier)
      let predicate = NSPredicate(format: "exists == false")
      let expectation = XCTNSPredicateExpectation(predicate: predicate, object: field)
      let result = XCTWaiter.wait(for: [expectation], timeout: 3)
      if result != .completed {
        Trace.recordFailure("rename field still present inside '\(rowIdentifier)'")
        XCTFail("Inline rename TextField did not disappear within 3s of cancel")
      }
    }

    // MARK: - Private helpers

    private func rightClick(rowIdentifier: String) {
      let row = app.element(for: rowIdentifier)
      if !row.waitForExistence(timeout: 3) {
        Trace.recordFailure("sidebar row '\(rowIdentifier)' did not appear")
        XCTFail("Sidebar row '\(rowIdentifier)' did not appear within 3s")
        return
      }
      row.rightClick()
    }

    private func clickRenameMenuItem() {
      let renameItem = app.element(
        for: UITestIdentifiers.Sidebar.renameContextMenuItem)
      if !renameItem.waitForExistence(timeout: 3) {
        Trace.recordFailure(
          "sidebar.contextMenu.rename item did not appear after right-click")
        XCTFail("'Rename' menu item did not appear within 3s of right-click")
        return
      }
      renameItem.click()
    }

    private func waitForRenameField(rowIdentifier: String) {
      let field = renameField(inside: rowIdentifier)
      if !field.waitForExistence(timeout: 3) {
        Trace.recordFailure("rename field did not appear inside '\(rowIdentifier)'")
        XCTFail("Inline rename TextField did not appear within 3s of Rename click")
      }
    }

    private func renameField(inside rowIdentifier: String) -> XCUIElement {
      // The inline TextField inside SidebarRowView is given a stable
      // identifier (`UITestIdentifiers.Sidebar.renameNameField`) so it
      // resolves deterministically through the NSHostingView boundary.
      // We scope the lookup under the row cell so unrelated text fields
      // on other screens don't shadow it during navigation.
      let row = app.element(for: rowIdentifier)
      return row.descendants(matching: .textField)
        .matching(identifier: UITestIdentifiers.Sidebar.renameNameField)
        .firstMatch
    }
  }
  ```

  All keyboard input routes through `MoolahApp.pressKeyboardShortcut(_:modifiers:)` (the screen-driver-rule seam — see `MoolahApp.swift:180-186`). Text typing routes through `field.typeText(...)` on the resolved `XCUIElement`, matching the `WelcomeScreen.typeName` / `TradeFormDriver` patterns. No driver should reach into `app.application` directly.

- [ ] **Step 13.2: Build the UI test target**

  Run: `just build-mac`
  Expected: `** BUILD SUCCEEDED **`.

  (The `MoolahUITests_macOS` target is built as part of `build-mac`. If the project surfaces a separate "build for testing" step, see `just` recipes — `just test-mac` builds + runs and is acceptable here too.)

- [ ] **Step 13.3: format-check + commit**

  Run: `just format-check`
  Expected: no diff.

  ```bash
  git add UITestSupport/UITestIdentifiers+Sidebar.swift \
    Features/Accounts/Views/AccountSidebarRow.swift \
    MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift
  git commit -m "$(cat <<'EOF'
  test(ui): identifier + driver methods for sidebar inline rename

  Attaches UITestIdentifiers.Sidebar.renameNameField to InlineRenameField
  so XCUITest can resolve the inline TextField through NSHostingView
  deterministically. Adds SidebarScreen driver methods:
  beginRename{Account,Earmark,Group}, typeRenameAndCommit, cancelRename,
  selectAndPressReturn, doubleClickAccountName, rename-field visibility
  waits — all following the existing trace + waitForExistence pattern.
  Adds SidebarEarmark / SidebarGroup symbolic enums.

  For #999.
  EOF
  )"
  ```

---

## Task 14: UI test — account inline rename via context menu

**Files:**
- Create: `MoolahUITests_macOS/Tests/Sidebar/SidebarInlineRenameMacTests.swift`

- [ ] **Step 14.1: Create the test file with the account happy path**

  Create `MoolahUITests_macOS/Tests/Sidebar/SidebarInlineRenameMacTests.swift`:

  ```swift
  import XCTest

  /// macOS-only XCUITest covering inline rename on the unified sidebar
  /// (account, earmark, account-group rows) via all three triggers
  /// (context-menu Rename, Return key, double-click). All tests use the
  /// `.tradeBaseline` seed which now ships with a rename-target earmark
  /// and group fixture in addition to the standard accounts.
  final class SidebarInlineRenameMacTests: MoolahUITestCase {
    override class var seed: UITestSeed { .tradeBaseline }

    func testContextMenuRenameAccount() {
      let renamed = "Checking Renamed"

      app.sidebar.beginRenameAccount(.checking)
      app.sidebar.typeRenameAndCommit(
        text: renamed,
        inside: UITestIdentifiers.Sidebar.account(SidebarAccount.checking.id))

      // The sidebar row's accessibility label includes the account name;
      // wait for the new label to materialise as the post-condition.
      let renamedRow = app.element(
        for: UITestIdentifiers.Sidebar.account(SidebarAccount.checking.id))
      let predicate = NSPredicate(format: "label CONTAINS %@", renamed)
      let expectation = XCTNSPredicateExpectation(
        predicate: predicate, object: renamedRow)
      XCTAssertEqual(
        XCTWaiter.wait(for: [expectation], timeout: 3), .completed,
        "Sidebar row did not reflect the renamed account label within 3s")
    }
  }
  ```

  The `seed` override matches the pattern already used by `EditAccountValuationPickerTests` (see its file for the seed-override convention).

- [ ] **Step 14.2: Run the test**

  Run: `mkdir -p .agent-tmp && just test-mac SidebarInlineRenameMacTests/testContextMenuRenameAccount 2>&1 | tee .agent-tmp/test-ui-rename-account.txt | tail -40`
  Expected: 1 test, passes.

  If the test fails, capture failure detail from the .txt file and `.agent-tmp/MoolahUITests_macOS-failures/` (see `UI_TEST_GUIDE.md` for failure-artefact locations).

- [ ] **Step 14.3: format-check + commit**

  Run: `just format-check`
  Expected: no diff.

  ```bash
  git add MoolahUITests_macOS/Tests/Sidebar/SidebarInlineRenameMacTests.swift
  git commit -m "$(cat <<'EOF'
  test(ui): macOS sidebar context-menu rename for accounts

  Right-click → Rename → type new name → Return commits → assert the
  row's accessibility label reflects the new name. Uses the
  TradeBaseline seed's checking account.

  For #999.
  EOF
  )"
  ```

---

## Task 15: UI test — earmark rename via context menu

**Files:**
- Modify: `MoolahUITests_macOS/Tests/Sidebar/SidebarInlineRenameMacTests.swift`

- [ ] **Step 15.1: Add the earmark test**

  Append below the `testContextMenuRenameAccount` method:

  ```swift
  func testContextMenuRenameEarmark() {
    let renamed = "Holiday Renamed"

    app.sidebar.beginRenameEarmark(.renameTarget)
    app.sidebar.typeRenameAndCommit(
      text: renamed,
      inside: UITestIdentifiers.Sidebar.earmark(SidebarEarmark.renameTarget.id))

    let renamedRow = app.element(
      for: UITestIdentifiers.Sidebar.earmark(SidebarEarmark.renameTarget.id))
    let predicate = NSPredicate(format: "label CONTAINS %@", renamed)
    let expectation = XCTNSPredicateExpectation(
      predicate: predicate, object: renamedRow)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: 3), .completed,
      "Sidebar row did not reflect the renamed earmark label within 3s")
  }
  ```

- [ ] **Step 15.2: Run + commit**

  Run: `just test-mac SidebarInlineRenameMacTests/testContextMenuRenameEarmark 2>&1 | tee .agent-tmp/test-ui-rename-earmark.txt | tail -40`
  Expected: passes.

  Run: `just format-check`
  Expected: no diff.

  ```bash
  git add MoolahUITests_macOS/Tests/Sidebar/SidebarInlineRenameMacTests.swift
  git commit -m "$(cat <<'EOF'
  test(ui): macOS sidebar context-menu rename for earmarks

  Mirrors the account-rename test against the seeded rename-target
  earmark.

  For #999.
  EOF
  )"
  ```

---

## Task 16: UI test — group rename via context menu

**Files:**
- Modify: `MoolahUITests_macOS/Tests/Sidebar/SidebarInlineRenameMacTests.swift`

- [ ] **Step 16.1: Add the group test**

  Append below `testContextMenuRenameEarmark`:

  ```swift
  func testContextMenuRenameGroup() {
    let renamed = "Investments Renamed"

    app.sidebar.beginRenameGroup(.renameTarget)
    app.sidebar.typeRenameAndCommit(
      text: renamed,
      inside: UITestIdentifiers.Sidebar.group(SidebarGroup.renameTarget.id))

    let renamedRow = app.element(
      for: UITestIdentifiers.Sidebar.group(SidebarGroup.renameTarget.id))
    let predicate = NSPredicate(format: "label CONTAINS %@", renamed)
    let expectation = XCTNSPredicateExpectation(
      predicate: predicate, object: renamedRow)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: 3), .completed,
      "Sidebar row did not reflect the renamed group label within 3s")
  }
  ```

- [ ] **Step 16.2: Run + commit**

  Run: `just test-mac SidebarInlineRenameMacTests/testContextMenuRenameGroup 2>&1 | tee .agent-tmp/test-ui-rename-group.txt | tail -40`
  Expected: passes.

  Run: `just format-check`
  Expected: no diff.

  ```bash
  git add MoolahUITests_macOS/Tests/Sidebar/SidebarInlineRenameMacTests.swift
  git commit -m "$(cat <<'EOF'
  test(ui): macOS sidebar context-menu rename for account groups

  Mirrors the account-rename test against the seeded rename-target
  group.

  For #999.
  EOF
  )"
  ```

---

## Task 17: UI test — Return-key trigger and Esc cancel

**Files:**
- Modify: `MoolahUITests_macOS/Tests/Sidebar/SidebarInlineRenameMacTests.swift`

- [ ] **Step 17.1: Add the Return + Esc test**

  Append below `testContextMenuRenameGroup`:

  ```swift
  func testReturnKeyEntersRenameAndEscCancels() {
    let original = SidebarAccount.checking
    let originalName = UITestFixtures.TradeBaseline.checkingAccountName

    app.sidebar.selectAndPressReturn(original)
    app.sidebar.expectRenameFieldVisible(
      rowIdentifier: UITestIdentifiers.Sidebar.account(original.id))

    app.sidebar.cancelRename()
    app.sidebar.expectRenameFieldGone(
      rowIdentifier: UITestIdentifiers.Sidebar.account(original.id))

    // After Esc the row label should be unchanged. (The seed gives
    // `checking` an immutable known name, so reading the row's label
    // and asserting CONTAINS `originalName` is the cheapest check.)
    let row = app.element(for: UITestIdentifiers.Sidebar.account(original.id))
    XCTAssertTrue(
      row.label.contains(originalName),
      "Esc on rename should leave the account name unchanged; got '\(row.label)'")
  }
  ```

- [ ] **Step 17.2: Run + commit**

  Run: `just test-mac SidebarInlineRenameMacTests/testReturnKeyEntersRenameAndEscCancels 2>&1 | tee .agent-tmp/test-ui-rename-return.txt | tail -40`
  Expected: passes.

  Run: `just format-check`
  Expected: no diff.

  ```bash
  git add MoolahUITests_macOS/Tests/Sidebar/SidebarInlineRenameMacTests.swift
  git commit -m "$(cat <<'EOF'
  test(ui): macOS sidebar Return enters rename, Esc cancels

  Drives the keyboard trigger path: select the row, press Return,
  assert the inline TextField is present, press Esc, assert it's gone
  and the original name persists.

  For #999.
  EOF
  )"
  ```

---

## Task 18: UI test — double-click trigger

**Files:**
- Modify: `MoolahUITests_macOS/Tests/Sidebar/SidebarInlineRenameMacTests.swift`

- [ ] **Step 18.1: Add the double-click test**

  Append below `testReturnKeyEntersRenameAndEscCancels`:

  ```swift
  func testDoubleClickAccountNameEntersRename() {
    let account = SidebarAccount.checking

    app.sidebar.doubleClickAccountName(account)
    app.sidebar.expectRenameFieldVisible(
      rowIdentifier: UITestIdentifiers.Sidebar.account(account.id))

    // Cancel so the test leaves the seed unchanged for any downstream
    // tests sharing the same launch session.
    app.sidebar.cancelRename()
  }
  ```

- [ ] **Step 18.2: Run + commit**

  Run: `just test-mac SidebarInlineRenameMacTests/testDoubleClickAccountNameEntersRename 2>&1 | tee .agent-tmp/test-ui-rename-doubleclick.txt | tail -40`
  Expected: passes.

  Run: `just format-check`
  Expected: no diff.

  ```bash
  git add MoolahUITests_macOS/Tests/Sidebar/SidebarInlineRenameMacTests.swift
  git commit -m "$(cat <<'EOF'
  test(ui): macOS sidebar double-click enters rename

  Drives the cell-level gesture path: select the row, double-click the
  name, assert the inline TextField appears. Cancels via Esc afterwards
  so the seeded account name is unchanged.

  For #999.
  EOF
  )"
  ```

---

## Task 19: Full-suite verification

**Files:** none.

- [ ] **Step 19.1: Run the full mac test suite**

  Run: `mkdir -p .agent-tmp && just test-mac 2>&1 | tee .agent-tmp/test-final.txt`
  Expected: all tests pass. Confirm via `grep -E "TEST EXECUTE FINISHED|with .* failures" .agent-tmp/test-final.txt | tail -5`.

  If any unrelated test fails, treat as a separate regression — DO NOT silently fix it inside this branch. Open a separate issue / PR.

- [ ] **Step 19.2: Run iOS build to confirm no iOS regression**

  Run: `just build-ios`
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 19.3: Final format-check**

  Run: `just format-check`
  Expected: no diff, no SwiftLint violations.

- [ ] **Step 19.4: Clean up agent-tmp**

  ```bash
  rm -f .agent-tmp/test-*.txt .agent-tmp/build-*.txt
  ```

- [ ] **Step 19.5: Move the design + plan docs into `plans/completed/`**

  Both the design and the implementation plan are complete; per project convention completed plans live under `plans/completed/`.

  ```bash
  git mv plans/2026-05-28-sidebar-inline-rename-macos-design.md plans/completed/
  git mv plans/2026-05-28-sidebar-inline-rename-macos-plan.md plans/completed/
  git commit -m "$(cat <<'EOF'
  docs(sidebar): mark inline-rename-macos plan complete

  For #999.
  EOF
  )"
  ```

  *(Optional — defer this step if the user prefers to move plans only after the PR merges.)*

---

## Done criteria (recap)

By the end of this plan, the branch must:

1. Build clean on `just build-mac` and `just build-ios`.
2. Pass `just test-mac` (including all new Swift Testing + XCUITest cases).
3. Pass `just format-check` with no SwiftLint suppressions and no baseline reintroductions.
4. Render the inline rename `TextField` on macOS account / earmark / group rows when triggered by Return on a selected row, double-click on the name, or "Rename" in the right-click menu.
5. Commit on Return / focus loss; cancel on Esc; route through `*Store.rename(id:to:)` for persistence.
6. Leave the iOS rename path and the existing macOS sidebar selection / context-menu / navigation behaviours unchanged.
