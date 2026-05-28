# Sidebar Inline Rename on macOS — Design

**Date:** 2026-05-28
**Status:** Approved (in conversation), proceeding to implementation plan
**Closes:** [#999](https://github.com/moolah-rocks/moolah-native/issues/999)
**Scope:** Reach iOS parity for inline rename on the macOS sidebar — for
account rows (current + investments), earmark rows, and account-group
rows. Triggered by Return on a selected row, double-click, or a "Rename"
item in the row's right-click menu. Commits on Return / focus loss,
cancels on Esc.

## Motivation

The unified `NSOutlineView` macOS sidebar landed on `main` via
[#996](https://github.com/moolah-rocks/moolah-native/pull/996) but
inline rename remained iOS-only — `SidebarView.swift` even documents the
gap:

```swift
// Inline rename and the Group > submenu are iOS-only until
// Phase 3 ships AppKit-cell editing and Phase 2 wires
// drag-and-drop / group membership on the macOS outline.
```

With cells now SwiftUI views wrapped in `NSHostingView`, the existing
iOS inline-rename UI (`InlineRenameField` inside `SidebarRowView`)
already renders correctly inside outline cells. A spike on
`Large Test Profile` confirmed that SwiftUI `@FocusState` inside an
`NSHostingView`-hosted outline cell wins keyboard focus on appear,
accepts text input, commits on Return, and cancels on Esc — no AppKit
field-editor work required. The remaining work is wiring the rename
state through the existing macOS plumbing and adding three trigger
gestures.

## Scope

**In scope**

- Inline rename for account rows (`AccountSidebarRow`), earmark rows
  (`EarmarkRowView`), and account-group rows (`AccountGroupSidebarRow`)
  rendered inside the unified `SidebarOutline`.
- Three trigger gestures, mirroring macOS standard / iOS behaviour:
  - Return key on the currently selected sidebar row.
  - Double-click on the row's name text.
  - "Rename" item in the row's right-click menu.
- Commit semantics: Return key, focus loss → calls
  `store.rename(id:to:)`. Esc key → discards the in-progress text
  without calling the store. The store handles trimming, empty input
  no-op, same-name no-op, and error surfacing exactly as it does for
  iOS today.
- Unit tests for the rename-state binding helper and the new context
  menu items, plus XCUITest happy paths for each row type.

**Out of scope**

- A new editing UI. The existing SwiftUI `InlineRenameField` inside
  `SidebarRowView` is reused as-is.
- A native AppKit `NSTextField` field-editor path. Considered and
  rejected — would duplicate the editing UI with no iOS reuse and
  no benefit over the proven SwiftUI path.
- Slow-single-click-to-rename (Finder's classic "click, wait, click
  again" gesture). The three triggers above cover the common paths;
  this variant is flaky to test and iOS has never offered it.
- A new earmark `AccountGroup`-style submenu, drag-and-drop, or any
  other sidebar-context-menu items beyond the new "Rename" entries.
- Renaming any of the other sidebar row types (section headers, total
  rows, navigation rows). Those have static, non-user-editable names.
- iOS path changes. iOS keeps its existing `List(.sidebar)` rename
  flow unchanged.

## Architecture

The macOS body already passes stores + selection bindings into
`SidebarOutline` (an `NSViewControllerRepresentable`); we extend that
surface with one binding and three closures. The cell builder threads
those into the existing iOS row views, whose `isEditing` + `onRename`
parameters already drive `SidebarRowView`'s swap between
`Text(name)` and `InlineRenameField`. `editingRowId` remains a single
`@State var UUID?` on `SidebarView`, shared by both platforms; there is
no parallel macOS-only edit state.

Trigger ↔ state flow:

```
double-click on row name (existing .onTapGesture on SidebarRowView)  -+
"Rename" item in NSMenu (new for accounts/earmarks/groups)            +-> editingRowId = id
Return on selected row (new keyDown override on outline)             -+

editingRowId -> renameBinding(for:id) -> row's isEditing
             -> InlineRenameField appears with @FocusState true

InlineRenameField -> onSubmit / focus loss -> onRename(text) -> store.rename(id:to:)
                  -> .onKeyPress(.escape) -> isEditing = false (no store call)
```

The double-click trigger is already wired inside `SidebarRowView`'s
`nameLabel` (it attaches `.onTapGesture(count: 2)` only when both
`isEditing` and `onRename` are non-nil and the row is selected). Once
the bindings reach the row, double-click lights up automatically — no
new code at the cell-builder layer.

The Return-key and context-menu triggers are net-new on macOS and live
in two small AppKit additions (an `NSOutlineView` subclass and three
new `NSMenu` builders).

## Spike findings

A spike on the `Large Test Profile` build wired `editingRowId` through
`SidebarOutline` → `SidebarCellBuilder` → `AccountSidebarRow`, and
auto-set `editingRowId` to the first account 4s after the sidebar
appeared. Result: the `TextField` rendered, keyboard focus landed on
it automatically, typing was accepted, Return committed, and Esc
cancelled. No window-level `makeFirstResponder` plumbing was needed.
The spike was reverted before this design was written; the working
tree starts from clean `main`.

## File-by-file changes

### Existing files modified

**`Features/Navigation/SidebarView.swift`**
- Lift `renameBinding(for:)`, `renameAction(for: Account)`,
  `renameAction(for: Earmark)`, and `renameAction(for: AccountGroup)`
  out of the `#if os(iOS)` extension. They contain no
  platform-conditional code and become shared helpers on `SidebarView`.
- `macSidebarBody` passes `editingRowId: $editingRowId` and three rename
  closures (`onRenameAccount: renameAction(for:)`,
  `onRenameEarmark: renameAction(for:)`,
  `onRenameGroup: renameAction(for:)`) into `SidebarOutline`.

**`Features/Navigation/AppKitSidebar/SidebarOutline.swift`**
- Add `@Binding var editingRowId: UUID?`.
- Add three closure parameters:
  - `let onRenameAccount: (Account) -> (String) -> Void`
  - `let onRenameEarmark: (Earmark) -> (String) -> Void`
  - `let onRenameGroup: (AccountGroup) -> (String) -> Void`
- Pass the binding and closures into `SidebarCellBuilder` via the new
  builder fields below.
- Wire a new `delegate.beginRenameRequested: (() -> Void)?` callback in
  `makeNSViewController` to set `editingRowId` to the currently selected
  row's id. The outline subclass already gates the callback on the
  selected row being a renamable kind, so no additional filtering is
  needed here.

**`Features/Navigation/AppKitSidebar/Cells/SidebarCellBuilder.swift`**
- Accept four new fields: `editingRowIdBinding: Binding<UUID?>`,
  `onRenameAccount`, `onRenameEarmark`, `onRenameGroup` (shapes per
  `SidebarOutline`).
- Add a private `renameBinding(for id: UUID) -> Binding<Bool>` mirroring
  `SidebarView.renameBinding(for:)`.
- `accountCell(id:)` passes `isEditing: renameBinding(for: id)` and
  `onRename: onRenameAccount(account)` to `AccountSidebarRow`, and
  attaches the new account context menu (now built with an
  `onBeginRename` closure that flips `editingRowIdBinding.wrappedValue
  = id`).
- `earmarkCell(id:)` likewise on `EarmarkRowView`, attaching a new
  earmark context menu.
- `groupCell(id:)` likewise on `AccountGroupSidebarRow`, attaching a new
  group context menu. The group row's existing
  `showChevron: false` and `isExpanded: .constant(false)` are
  unchanged — the outline still owns the disclosure triangle.

**`Features/Navigation/AppKitSidebar/SidebarContextMenuBuilder.swift`**
- Add a "Rename" `NSMenuItem` as the first item in `accountMenu(...)`.
  Image `character.cursor.ibeam`, identifier
  `UITestIdentifiers.Sidebar.renameContextMenuItem` (already exists,
  shared with iOS). Target/action sink calls a new
  `onBeginRename: () -> Void` argument.
- Add two new builders following the same shape:
  - `static func earmarkMenu(earmarkId:earmarkStore:onBeginRename:)`
    — single "Rename" item.
  - `static func groupMenu(groupId:accountGroupStore:onBeginRename:)`
    — single "Rename" item. iOS already exposes a "Rename" item on
    group rows (`SidebarView+Groups.swift` `groupContextMenu(for:)`);
    macOS just reaches parity.

**`Features/Navigation/AppKitSidebar/SidebarOutlineDelegate.swift`**
- Add `var beginRenameRequested: (() -> Void)?` alongside the existing
  `selectionChanged` / `expansionChanged` callbacks.

**`Features/Navigation/AppKitSidebar/SidebarOutlineController.swift`**
- Replace the `let outlineView = NSOutlineView()` initializer with the
  new subclass `SidebarKeyHandlingOutlineView` (below).
- In `configureOutlineView`, wire the subclass's
  `onReturnKey: () -> Void` to call `delegate.beginRenameRequested?()`.

### New files

**`Features/Navigation/AppKitSidebar/SidebarKeyHandlingOutlineView.swift`**
- `@MainActor final class SidebarKeyHandlingOutlineView: NSOutlineView`.
- Holds `var onReturnKey: (() -> Void)?`.
- Overrides `keyDown(with event: NSEvent)`:
  - If `event.keyCode == 36` (Return) and a row is selected and the
    selected item is an account / earmark / group `SidebarRow`, call
    `onReturnKey?()` and return without calling super.
  - Otherwise call `super.keyDown(with: event)` so arrow-key navigation,
    expand-collapse, Esc handoff, and tab-cycling behave normally.
- A subclass (rather than a delegate-based intercept) is the standard
  AppKit pattern for adding key-equivalent behaviour to a table /
  outline. Keeping it tiny and single-purpose avoids tying unrelated
  controller logic to `NSResponder` plumbing.

### Test additions

**`MoolahTests/Navigation/SidebarRenameBindingTests.swift`** —
Swift Testing suite for `SidebarView.renameBinding(for:)`. Pure data,
no AppKit. Cases:
- `setting true for id A makes editingRowId == A`.
- `setting true for id B while A is editing replaces A`.
- `setting false on the editing binding clears editingRowId`.
- `setting false on a non-editing row leaves editingRowId unchanged`.

**`MoolahTests/Navigation/SidebarContextMenuBuilderTests.swift`** —
Swift Testing suite for the new menu builders. Cases:
- `accountMenu contains a Rename item with identifier
  renameContextMenuItem as the first entry`.
- `accountMenu rename item invokes onBeginRename when activated`.
- `earmarkMenu has a single Rename item; activating it invokes
  onBeginRename`.
- `groupMenu has a single Rename item; activating it invokes
  onBeginRename`.

**`MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift`** —
Add screen-driver methods:
- `func contextMenuRename(forAccount id: UUID)`
- `func contextMenuRename(forEarmark id: UUID)`
- `func contextMenuRename(forGroup id: UUID)`
- `func returnKeyOnSelectedRow()`
- `func nameField(forAccount id: UUID) -> XCUIElement` (and earmark,
  group variants) — resolves the inline `TextField` element via its
  parent cell identifier.

**`MoolahUITests_macOS/Sidebar/SidebarInlineRenameMacTests.swift`** —
new file. Tests:
- Account: right-click → "Rename" → type → Return → assert row label
  updated and outline still shows the row at the same selection.
- Earmark: same pattern.
- Group: same pattern.
- Return-key trigger: arrow-key to an account row → press Return →
  assert `TextField` is present → press Esc → assert `TextField` gone
  and original name preserved.
- Double-click trigger: select an account row → double-click name →
  assert `TextField` present.

## Data flow and error handling

- Store rename methods (`AccountStore.rename(id:to:)`,
  `EarmarkStore.rename(id:to:)`, `AccountGroupStore.rename(id:to:)`)
  already trim whitespace, treat empty input and same-name input as
  no-ops, and surface errors on the store's `.error` property. The row
  delegates directly to these; no new validation lives in the cell.
- Concurrent edit triggers — e.g. user double-clicks row A while row B
  is editing — settle naturally. `editingRowId` is a single `UUID?`.
  Setting it to A's id makes B's `isEditing.wrappedValue == false`,
  which removes B's `InlineRenameField`. Focus loss on B's field
  triggers its commit closure (see
  `InlineRenameField.onChange(of: isFocused)`), so the in-progress
  edit on B persists. Same behaviour as iOS today.
- Right-click on an unselected row already selects the row first
  (Finder-style behaviour preserved by the unified outline). The
  "Rename" item then sets `editingRowId` to that row's id. Same as iOS.
- Outline reload during sync activity: cells rebuild on every
  `SidebarOutlineController.apply(tree:expandedGroupIds:selection:)`.
  The `InlineRenameField`'s `@State var text` and `@FocusState` are
  scoped to the field's identity. If a reload replaces the cell while
  editing, focus loss fires the commit closure with the in-progress
  text — matching iOS, where the equivalent re-render under a sync
  tick has the same effect. This is acceptable behaviour but is
  called out in the test plan so future contributors don't try to
  "fix" it.

## Accessibility

- The `InlineRenameField` already exposes `.accessibilityLabel("Name")`.
  VoiceOver users hear "Name, text field" when focus lands, matching
  iOS.
- The Return-key trigger requires the outline to have focus; this is
  the same prerequisite as the existing arrow-key navigation. No new
  accessibility affordance is required — VoiceOver users typically
  navigate to a row and use the rotor to pick "Rename" from the
  context menu, which the new menu item exposes.
- Context-menu items get the existing
  `renameContextMenuItem` accessibility identifier; XCUITest already
  resolves it for the iOS rename tests.

## Non-goals confirmed

The following are explicitly **not** changing as part of this work:

- The earmark `AccountGroup`-style submenu wiring (iOS-only,
  separate plan).
- Drag-and-drop on the macOS sidebar (separate
  drag-wiring follow-up plan referenced by
  `plans/completed/2026-05-27-sidebar-unified-appkit-plan.md`).
- iOS rename behaviour, identifiers, helper signatures, or tests.

## Risks and mitigations

- **`@FocusState` in `NSHostingView` regression risk:** the spike on
  `Large Test Profile` proved this works on the current macOS toolchain.
  If a future OS update changes hosting-view focus behaviour, the
  fallback is a one-line `window?.makeFirstResponder(hostingView)` in
  `SidebarOutlineController.apply(...)` after the rename cell is
  inserted. No design changes required for that mitigation.
- **Sync-driven cell rebuild commits in-progress edits.** Same as
  iOS today; documented above and called out in the test plan.
- **Return-key conflict with default `NSOutlineView` behaviour.**
  `NSOutlineView` swallows Return by default (no built-in action). The
  subclass override is additive — every non-rename case still calls
  `super`, so arrow navigation, expand/collapse on left/right arrows,
  and Esc handoff remain intact.
