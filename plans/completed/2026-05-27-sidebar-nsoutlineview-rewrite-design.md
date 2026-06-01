# Sidebar rewrite over `NSOutlineView` — design

**Status:** Design, not yet planned. Driven by sidebar drag-and-drop bug [#991](https://github.com/moolah-rocks/moolah-native/issues/991).

**Tracking issue:** [#991](https://github.com/moolah-rocks/moolah-native/issues/991) — accounts can no longer be drag-reordered, dragged onto another account to create a group, or dragged into an existing group; no visual drop indicator is shown.

## Problem

The current `SidebarView` (SwiftUI `List(selection:)` with `.listStyle(.sidebar)`) cannot deliver Mail.app-style sidebar drag-and-drop:

- Reorder (drop between rows) and drop-onto-row (move into folder / group) are **mutually exclusive** in SwiftUI `List` on macOS as of macOS 26 / Tahoe.
  - With `.onMove` on the `ForEach`, every drop is interpreted as a reorder slot; per-row `.dropDestination` never fires.
  - Without `.onMove`, `.draggable` does not initiate drag in a sidebar-style `List(selection:)` — no drag preview, no drop, no visible feedback.
- This is a public SwiftUI limitation confirmed by Apple DTS in [forums thread 763013](https://developer.apple.com/forums/thread/763013) and matches the user's empirical findings reproduced across three implementation rounds (2026-05-27 session).
- Wrapping the row's `NavigationLink` in a custom `View` struct silently breaks `List` selection — `List` only recognises `NavigationLink(value:)` when it is the row's direct content (or wrapped only in built-in `ModifiedContent`).

Mail.app and Finder both implement this UX, but **not via SwiftUI** — they use AppKit's `NSOutlineView`, whose data-source contract has the two-state semantic baked in:

- `proposedChildIndex >= 0` → drop *between* children (insertion line indicator).
- `proposedChildIndex == NSOutlineViewDropOnItemIndex` (`-1`) → drop *onto* the item (full-row blue highlight).

Per the deep research run on 2026-05-27, NetNewsWire ([`Mac/MainWindow/Sidebar/SidebarOutlineDataSource.swift`](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Mac/MainWindow/Sidebar/SidebarOutlineDataSource.swift)) is a production reference for this pattern.

## Recommended approach

Wrap `NSOutlineView` via `NSViewRepresentable`, using the [Sameesunkaria/OutlineView](https://github.com/Sameesunkaria/OutlineView) MIT Swift package as the wrapper. Model the drop logic on NetNewsWire's `SidebarOutlineDataSource`.

The package exposes:

```swift
OutlineView(items, selection: $sel, children: \.children) { item in
  // Cell is an NSView — typically an NSTextField for inline rename.
}
.outlineViewStyle(.sourceList)
.dragDataSource { … }       // returns NSPasteboardItem
.onDrop(of: …, receiver: …) // a DropReceiver instance
```

The `DropReceiver.validateDrop(target:)` callback returns a `ValidationResult` that distinguishes between drop-on (when `target.childIndex == nil`) and reorder slots (when `target.childIndex != nil`) — these map directly to the two drop semantics we want.

## Scope

Migration of the **accounts** part of the sidebar (Current Accounts + Investments sections) plus group rows + member rows to `OutlineView`. The Earmarks section, totals, and navigation section can stay in SwiftUI alongside — either as separate `List`s in an `HStack` / `VStack`, or migrate them to `OutlineView` too in the same PR. Either way, the navigation and totals sections don't need drag-and-drop and can remain in SwiftUI without forcing the rewrite to be all-or-nothing.

**In scope:**

- Add `Sameesunkaria/OutlineView` as a Swift Package dependency (via `project.yml`).
- Rebuild `SidebarView`'s account / group section using `OutlineView`. Drag source = item id (per Apple Forums 741520 lesson — drag the ID, not the model). Drop target validates location-based drop mode and dispatches to `accountGroupStore` / `accountStore` reorder mutations.
- Reimplement row cell as an `NSView` (custom subclass or `NSHostingView`-wrapped SwiftUI cell). Inline rename via `NSTextField`. Icon + balance + secondary line preserved.
- Wire selection back to `SidebarSelection` (single-select binding).
- Per-row context menu via per-cell `NSMenu`. Right-click "Group ▸" submenu preserved.
- Expand / collapse state continues to bind to `GroupUIStateStore` (the local-only GRDB table is unchanged; only the read/write surface changes).
- Keyboard navigation: arrow keys, Return-to-rename, Escape-to-cancel-rename.
- VoiceOver / accessibility: NSOutlineView's native accessibility (better than the current SwiftUI baseline; cf. NetNewsWire issue [#933](https://github.com/Ranchero-Software/NetNewsWire/issues/933) where the SwiftUI sidebar experiment regressed expand/collapse VoiceOver).
- UI tests: rewrite drag-related UI tests to drive `XCUIElement.press(forDuration:thenDragTo:)` against the `NSOutlineView` rows. Selection / rename UI tests should largely keep working since the accessibility identifiers carry over to the cell views.

**Explicitly out of scope:**

- Multi-select drag (the `Sameesunkaria/OutlineView` package supports single drag; NetNewsWire's multi-feed drag is a separate concern we don't need yet).
- Cross-app drag-and-drop (drag from Finder onto an account — the existing `.dropDestination(for: URL.self)` for CSV imports needs to keep working but doesn't need new functionality).
- iOS sidebar (this rewrite is macOS-only — iOS keeps the SwiftUI `List`, which is fine on iPad since drag-and-drop conventions differ).
- The Earmarks section, sidebar totals, and navigation section — they stay in SwiftUI for this PR.

## Trade-offs and open questions

**Cell rendering:** `OutlineView` requires `NSView` cells, not SwiftUI views (this is how the package picks up the system selected-row text-colour treatment correctly). We can use `NSHostingView` to embed SwiftUI cells, but pure `NSTextField` is more idiomatic for the sidebar look and avoids the SwiftUI ↔ AppKit re-render cost on selection changes. Decision: start with `NSTextField`-based cells; revisit if cell content gets richer.

**Inline rename:** `NSTextField` configured with `isEditable = false` until double-click; on double-click → `becomeFirstResponder()`; commit on `controlTextDidEndEditing` or Return; cancel on Escape. Matches Finder.

**Section grouping:** `NSOutlineView` source-list style supports section headers natively (root items with `isGroupItem == true`). We can model "Current Accounts" and "Investments" as section headers, with standalone accounts and groups as children. Whether the totals row stays at the bottom of each section or moves elsewhere needs a UX decision.

**Earmarks section:** if Earmarks stays in a separate SwiftUI `List`, the two surfaces won't drag-and-drop into each other (no drag-from-earmark-to-account). Acceptable per the existing UX. If we want unified drag-and-drop, Earmarks also migrates — bigger scope.

**Test seeding:** existing UI tests use seeds in `UITestSeeds.swift` that set up specific account / group configurations. Those should keep working; only the test driver code that exercises drag changes.

**Dependency risk:** `Sameesunkaria/OutlineView`'s last meaningful release was Feb 2023 (v2.0.0). It's small (~1500 LOC) and MIT-licensed. If we hit a blocker we can fork it; alternatively the [orbstack/SwiftUI-AKList](https://github.com/orbstack/SwiftUI-AKList) snapshot is an even more battle-tested reference we could draw on, though its drag-drop hooks aren't first-class.

## Phasing suggestion

1. **Spike** (small worktree): drop `Sameesunkaria/OutlineView` into the project, build a hello-world `OutlineView` with two flat items + drag-to-reorder + drag-onto-row both wired to print statements. Verify the package works on macOS 26 with our targeting. ~1 day.
2. **Phase 1 — `OutlineView` skeleton + selection.** Migrate Current Accounts + Investments sections to `OutlineView` rendering with `NSTextField` cells. Selection back to `SidebarSelection`. No drag-and-drop yet. Earmarks / totals / nav stay in a sibling SwiftUI `List` or section.
3. **Phase 2 — drag-and-drop.** Add `dragDataSource` + `DropReceiver`. Wire `validateDrop` to dispatch to `accountStore.reorderAccounts` / `accountGroupStore.moveGroup` / `accountGroupStore.addAccount` / `createGroup(joining:and:)` based on `target.childIndex` and `target.intoElement`.
4. **Phase 3 — inline rename.** `NSTextField`-based rename triggered by double-click and Return.
5. **Phase 4 — context menu, keyboard nav, accessibility audit.** Per-cell `NSMenu` for "Group ▸" / "Edit Account…" etc. Arrow-key navigation. VoiceOver pass.
6. **Phase 5 — UI test refit.** Update or rewrite `MoolahUITests_macOS` drag-related tests to drive `NSOutlineView` rows.

Each phase is a separate PR — the spike and phases 1–2 land the user-visible drag fix; phases 3–5 are polish on top.

## References

- [Sameesunkaria/OutlineView README](https://github.com/Sameesunkaria/OutlineView) — package overview, `DropReceiver` / `ValidationResult` shape, cell-must-be-NSView caveat.
- [Sameesunkaria/OutlineView dragging example](https://github.com/Sameesunkaria/OutlineView/blob/main/Examples/OutlineViewDraggingExample/OutlineViewDraggingExample/ViewModel.swift) — working sample for the drop-onto-vs-between distinction.
- [Ranchero-Software/NetNewsWire `SidebarOutlineDataSource.swift`](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Mac/MainWindow/Sidebar/SidebarOutlineDataSource.swift) — production AppKit reference for `setDropItem(_:dropChildIndex:)` retargeting + copy-vs-move semantics.
- [Apple Developer Forums thread 741520 — Drag and Drop in Nested List](https://developer.apple.com/forums/thread/741520) — drag-the-ID-not-the-model lesson.
- [Apple Developer Forums thread 763013 — `.onMove` drag and drop](https://developer.apple.com/forums/thread/763013) — DTS-confirmed `List` limitation.
- [Apple Developer Forums thread 730367 — `dropDestination` does not work inside `List`](https://developer.apple.com/forums/thread/730367) — long-running confirmation that the SwiftUI behaviour hasn't been fixed.
- [`NSOutlineViewDataSource.outlineView(_:validateDrop:proposedItem:proposedChildIndex:)`](https://developer.apple.com/documentation/appkit/nsoutlineviewdatasource/1533597-outlineview?language=objc) — first-party docs on the proposed-child-index API.
