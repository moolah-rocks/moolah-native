# Sidebar `NSOutlineView` Phase 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Per project memory (`feedback_subagent_driven.md`), do not ask whether to use it — that is the default.

**Final plan file:** This document will be copied verbatim to `plans/2026-05-27-sidebar-nsoutlineview-phase-1-plan.md` (a project plan, checked in) once approved. The harness-allocated path is the plan-mode draft.

**Closes:** GitHub issue [#991](https://github.com/moolah-rocks/moolah-native/issues/991) — sidebar drag-and-drop broken. Phase 1 does not yet ship the drag-fix; Phase 2 does. We close #991 from Phase 2's PR.

---

## Context

`SidebarView` is a SwiftUI `List(selection:)` with `.listStyle(.sidebar)`. On macOS 26 / Tahoe, SwiftUI `List` cannot deliver the Mail.app sidebar UX we want: `.onMove` and per-row `.dropDestination(for:)` are mutually exclusive, and without `.onMove`, `.draggable` is inert in a sidebar-style list. This is a public SwiftUI limitation confirmed by Apple DTS ([forums thread 763013](https://developer.apple.com/forums/thread/763013)) and reproduced empirically across three implementation attempts (2026-05-27 session). Mail and Finder both achieve the UX by wrapping `NSOutlineView`, whose `validateDrop(proposedChildIndex:)` API natively distinguishes drop-between (insertion line) from drop-onto (full-row highlight).

The full architecture and rationale live in `plans/2026-05-27-sidebar-nsoutlineview-rewrite-design.md`. That design phases the rewrite into 5 steps preceded by a spike. **This plan covers the spike + Phase 1 only:** wrap `NSOutlineView` via the [Sameesunkaria/OutlineView](https://github.com/Sameesunkaria/OutlineView) MIT package, render the Current Accounts + Investments sections through it on macOS, and wire selection back to `SidebarSelection`. No drag-and-drop yet (Phase 2). No inline rename yet (Phase 3). iOS sidebar is untouched.

After Phase 1, the macOS sidebar is functionally regressed: drag-and-drop is still broken (same as today's bug), inline rename is unavailable on the new outline rows, and the context-menu "Rename" item is hidden on macOS until Phase 3 ships. **All other functionality — selection, group expand/collapse via chevron, balance display, "Not set" indicator, navigation to detail surfaces, accessibility identifiers, VoiceOver labels — must work end-to-end at the close of Phase 1.** Users on macOS will continue to use the right-click "Edit Account…" sheet for renames and the "Group ▸" submenu for group membership in the Phase 1 window.

---

## Architecture

Add `Sameesunkaria/OutlineView` (~1500 LOC, MIT) as a Swift Package dependency. Introduce a macOS-only `SidebarOutlineView` SwiftUI view that wraps the package's `OutlineView<Item>`. The `SidebarView` body splits on `#if os(macOS)` — macOS gets `VStack { SidebarOutlineView + List(earmarks/totals/nav) }`, iOS keeps the existing `List` with all sections inline. Cells use `NSHostingView` to wrap the existing SwiftUI `SidebarRowView` / `AccountGroupSidebarRow` — preserves all rich content (icon, balance, "Not set", spinner) without a parallel AppKit reimplementation. Expansion state is bound to the existing `GroupUIStateStore`. The existing `Accounts.groupAwareSidebar(...)` helper continues to produce the `[SidebarBucketEntry]` array; a thin `SidebarOutlineItem` adapter wraps it for the package's `Identifiable` requirement.

The spike validates three package-API unknowns before the rest of the plan commits to code: (a) does the package's `Package.swift` declare macOS 14+ in a way that compiles cleanly against our macOS 26 deployment target; (b) does `NSHostingView`-wrapped SwiftUI cells receive the correct `backgroundProminence` for the selection-colour override in `SidebarRowView`; (c) what is the package's exact mechanism for binding expansion state and marking source-list section headers.

---

## Tech stack

- Swift 6, SwiftUI on macOS 26 (deployment target).
- `Sameesunkaria/OutlineView` Swift package (latest tagged release; pinned via `exactVersion` like `GRDB`).
- AppKit `NSOutlineView` (indirectly, via the package).
- Existing `AccountStore`, `AccountGroupStore`, `GroupUIStateStore` — no new mutations introduced.
- Tests: Swift Testing for unit / store tests; XCUITest for the macOS UI smoke.

---

## File structure

**Create:**

- `Features/Navigation/SidebarOutlineItem.swift` — `Sendable, Hashable, Identifiable` adapter that wraps a `SidebarBucketEntry` (`.account` / `.group`) plus the two section headers. Exposes `children: [SidebarOutlineItem]?` for the package; section headers carry their bucket label, group items carry their members.
- `Features/Navigation/SidebarOutlineView.swift` — macOS-only `View` that owns the `OutlineView<SidebarOutlineItem>` construction, binds selection to `SidebarSelection?`, binds expansion state to `GroupUIStateStore`, and produces `NSHostingView`-wrapped cells. Lives in its own file so the macOS-only `#if` blocks don't bloat `SidebarView.swift`.
- `MoolahTests/Navigation/SidebarOutlineItemTests.swift` — Swift Testing suite for the `SidebarOutlineItem` derivation (bucket → header → entries → group members), including the dangling-groupId case (member of an unknown group renders as standalone), preserved from `Accounts+SidebarOrdering.swift`.

**Modify:**

- `project.yml` — add the `OutlineView` package under `packages:` (next to `GRDB`), and list it under each target's `dependencies` (`Moolah_iOS` excluded — the iOS target does not link the package; macOS app + macOS UI tests link it). Run `just generate` after editing.
- `Features/Navigation/SidebarView.swift` — split `body` on `#if os(macOS)` / `#if os(iOS)`. macOS body is `VStack(spacing: 0) { SidebarOutlineView(...); List { earmarksSection; totalsSection; navigationSection } }`. iOS body is the existing single `List`. Move the `currentAccountsSection` / `investmentsSection` reference out of the iOS-shared section list. The Return-key handler (`.onKeyPress(.return)`) loses its account/group case on macOS (no inline rename yet) — guard it `#if os(iOS)` so iOS rename still works. The context-menu `accountContextMenu` "Rename" item is gated `#if os(iOS)` for the same reason.
- `Features/Navigation/SidebarView+Sections.swift` — `currentAccountsSection` and `investmentsSection` stay (they're still referenced from the iOS body), but each is wrapped `#if os(iOS)`. `earmarksSection`, `totalsSection`, `navigationSection`, the row builders, `bucketEntryView` stay cross-platform — earmarks/totals/nav are shared. `bucketEntryView` becomes iOS-only since it's only called from the iOS sections; mark it `#if os(iOS)`.
- `Features/Navigation/SidebarView+Groups.swift` — drop / drag modifiers on `groupRowLink` / `memberRowLink` / `standaloneAccountRowLink` stay (iOS-only consumers) — wrap the file content (excluding the `DraggableSidebarItem` struct and the `UTType.moolahSidebarItem` extension, which remain shared for Phase 2 use) in `#if os(iOS)`. `expandBinding(for:)` is shared; lift it to the parent file or leave it shared with no `#if`.
- `Features/Navigation/SidebarView+Previews.swift` — add a third `#Preview` titled `"macOS outline (Phase 1)"` that exercises `SidebarOutlineView` directly with the existing seeded `PreviewBackend`. Existing two previews remain — they validate the iOS body via SwiftUI `List`.
- `MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift` — `switchToAccount(_:)` and the named-row helpers still use `app.element(for: UITestIdentifiers.Sidebar.account(id))` — accessibility identifiers ride along on the `NSHostingView`-wrapped SwiftUI cells, so no driver change should be needed for selection. Verify in Phase 1 acceptance and update only if the resolver returns a different element type.

**Untouched (no edits, only referenced):**

- `Domain/Models/Accounts+SidebarOrdering.swift` — `groupAwareSidebar(...)` is the source of truth for entry ordering. `SidebarOutlineItem` consumes its output; no new ordering logic.
- `Features/Accounts/AccountStore.swift`, `AccountGroupStore.swift`, `GroupUIStateStore.swift` — no API surface changes. Phase 2 will add a `move`/`reorder` API; Phase 1 doesn't need it.
- `Features/Accounts/Views/AccountSidebarRow.swift`, `AccountGroupSidebarRow.swift` — embedded via `NSHostingView` unchanged. The existing `#Preview` blocks continue to drive design iteration on the cells.
- `UITestSupport/UITestIdentifiers+Sidebar.swift` — identifier strings unchanged.

---

## Spike (~2 hours, validates the rest of the plan)

The spike is a single throw-away commit at the head of the branch. If any of its three checkpoints fail, **stop and surface to the user** before continuing — the rest of the plan may need redesign.

### Task 0: Spike — validate package, cells, expansion

**Files:**
- Modify: `project.yml`
- Modify (temporary, reverted at end of spike): `Features/Navigation/SidebarView+Previews.swift`

- [ ] **Step 1: Add the package**

  Edit `project.yml` under `packages:`:

  ```yaml
  OutlineView:
    url: https://github.com/Sameesunkaria/OutlineView
    # Pinned exactly — same convention as GRDB above.
    exactVersion: 2.0.0
  ```

  Add `- package: OutlineView` to the `dependencies:` list under `Moolah_macOS` and `MoolahUITests_macOS`. Do **not** add it to `Moolah_iOS`, `MoolahTests_iOS`, or any benchmark target.

  Then regenerate:

  ```bash
  just generate
  ```

  Expected: `xcodegen` produces `Moolah.xcodeproj` without error; `Package.resolved` (gitignored — not tracked) records `OutlineView 2.0.0`.

- [ ] **Step 2: Build macOS to confirm the package compiles**

  ```bash
  just build-mac 2>&1 | tee .agent-tmp/spike-build.txt
  ```

  Expected: clean build. If the package's `Package.swift` rejects macOS 26 (e.g. lists only `.macOS(.v10_15)`), record the actual error in `.agent-tmp/spike-build.txt`, surface it to the user, and stop. Mitigations the user may approve: vendor the package, fork it, or drop to a lower SDK floor by adjusting the wrapper.

- [ ] **Step 3: Add a hello-world preview**

  Append a `#Preview("Spike — OutlineView hello world")` block in `SidebarView+Previews.swift` that constructs the package's `OutlineView` against two hardcoded `SpikeItem` instances (one parent, one child). Use `NSHostingView` to wrap a `Text("…")` cell — the goal is to prove `NSHostingView`-cell rendering plus expansion works. Sketch (signatures to be confirmed against the package README):

  ```swift
  private struct SpikeItem: Identifiable, Hashable {
    let id: UUID = UUID()
    let title: String
    let children: [SpikeItem]?
  }

  #Preview("Spike — OutlineView hello world") {
    @Previewable @State var selection: SpikeItem? = nil
    return OutlineView(
      [
        SpikeItem(title: "Parent", children: [
          SpikeItem(title: "Child A", children: nil),
          SpikeItem(title: "Child B", children: nil),
        ])
      ],
      selection: $selection,
      children: \.children
    ) { item in
      NSHostingView(rootView: Text(item.title))
    }
    .outlineViewStyle(.sourceList)
    .frame(width: 260, height: 300)
  }
  ```

- [ ] **Step 4: Render and inspect via `RenderPreview`**

  Open `Moolah.xcodeproj` in the worktree (per CLAUDE.md's preview note), then render the spike preview via `mcp__xcode__RenderPreview`. Confirm three things, recording each in `.agent-tmp/spike-checks.md`:

  1. The two children are visible under "Parent" after clicking the disclosure chevron. Expansion via the package works.
  2. Clicking a row updates the bound `selection` (the row highlights blue). Selection-via-`@Binding` works.
  3. The cells render the text with the system selected-row foreground colour when selected (no manual override). If the text colour stays black on the blue highlight, `NSHostingView`-wrapped SwiftUI cells lose the system foreground treatment — record this finding, and bring it to the user as a fork in the road (option A: hand-build an `NSTableCellView` subclass with `NSTextField`/`NSImageView`; option B: detect selection in the SwiftUI cell via the bound `selection` and recolor manually, which `SidebarRowView` partially does already).

- [ ] **Step 5: Decide on group / section header mechanism**

  Search the package source (`.build/checkouts/OutlineView/Sources/`) for `isGroupItem` or any modifier that marks a row as a source-list group header. Record in `.agent-tmp/spike-checks.md` whether it is exposed (option A: a `.markRowGroup` modifier or analogous; option B: the package treats root-level items as group headers when they have children; option C: not exposed — we'd need a small fork to plumb `outlineView(_:isGroupItem:)` through). Surface option C to the user if that's the answer.

- [ ] **Step 6: Revert the spike**

  Remove the `SpikeItem` struct and the spike `#Preview`. Keep the `project.yml` package addition. Commit:

  ```bash
  git -C . add project.yml Moolah.xcodeproj
  git -C . commit -m "deps: add Sameesunkaria/OutlineView (spike-verified, macOS-only)"
  ```

  > **Note:** `Moolah.xcodeproj` is gitignored — do not stage it. The package addition is captured by `project.yml` alone. If `Package.resolved` lives anywhere tracked, stage that instead.

- [ ] **Step 7: format-check, then push the spike commit**

  ```bash
  just format-check 2>&1 | tee .agent-tmp/spike-format.txt
  ```

  Expected: zero violations. If anything is reported, follow `feedback_swiftlint_fix_not_baseline.md` — fix the violation in code, never bump a baseline.

  Don't push yet — the spike is a single commit at the head of the branch; the PR opens at the end of Phase 1.

---

## Phase 1 — `SidebarOutlineView` skeleton + selection

### Task 1: `SidebarOutlineItem` model

**Files:**
- Create: `Features/Navigation/SidebarOutlineItem.swift`
- Create: `MoolahTests/Navigation/SidebarOutlineItemTests.swift`

- [ ] **Step 1: Write the failing tests**

  Create `MoolahTests/Navigation/SidebarOutlineItemTests.swift`. Use Swift Testing per project convention. Cover:

  ```swift
  import Foundation
  import Testing

  @testable import Moolah

  @Suite struct SidebarOutlineItemTests {
    @Test func currentBucketHeaderEnumerationContainsStandaloneThenGroups() {
      let bankA = Account(name: "A", type: .bank, instrument: .defaultTestCurrency, position: 0)
      let bankB = Account(name: "B", type: .bank, instrument: .defaultTestCurrency, position: 2)
      let group = AccountGroup(
        name: "G", bucket: .current,
        instrument: .defaultTestCurrency, position: 1)
      let member = Account(
        name: "M", type: .bank, instrument: .defaultTestCurrency,
        position: 0, groupId: group.id)

      let items = SidebarOutlineItem.tree(
        accounts: Accounts(from: [bankA, bankB, member]),
        groups: [group]
      )

      // Two section headers at root: Current Accounts, Investments.
      #expect(items.count == 2)
      let currentHeader = try #require(items.first)
      #expect(currentHeader.kind == .currentAccountsHeader)
      // Children: bankA (pos 0), group G (pos 1), bankB (pos 2).
      let children = try #require(currentHeader.children)
      #expect(children.count == 3)
      #expect(children[0].kind == .account(bankA.id))
      #expect(children[1].kind == .group(group.id))
      #expect(children[2].kind == .account(bankB.id))
      // Group members appear under the group node.
      let groupChildren = try #require(children[1].children)
      #expect(groupChildren.count == 1)
      #expect(groupChildren[0].kind == .account(member.id))
    }

    @Test func investmentsHeaderRendersEvenWhenEmpty() {
      // Empty investments section still produces the section header
      // so the user sees "Investments" with a zero-member section.
      let bank = Account(name: "A", type: .bank, instrument: .defaultTestCurrency)
      let items = SidebarOutlineItem.tree(
        accounts: Accounts(from: [bank]), groups: []
      )
      #expect(items.count == 2)
      #expect(items[1].kind == .investmentsHeader)
      #expect(items[1].children?.isEmpty == true)
    }

    @Test func danglingGroupIdRendersMemberAsStandalone() {
      // Sync can deliver an Account ahead of its AccountGroup. The
      // ordering helper folds those into the standalone list — this
      // test asserts SidebarOutlineItem inherits that contract.
      let ghostGroupId = UUID()
      let stranded = Account(
        name: "S", type: .bank, instrument: .defaultTestCurrency,
        groupId: ghostGroupId)
      let items = SidebarOutlineItem.tree(
        accounts: Accounts(from: [stranded]), groups: []
      )
      let current = try #require(items.first?.children)
      #expect(current.count == 1)
      #expect(current[0].kind == .account(stranded.id))
    }
  }
  ```

- [ ] **Step 2: Run the tests to confirm they fail**

  ```bash
  just test SidebarOutlineItemTests 2>&1 | tee .agent-tmp/test-outline-item.txt
  ```

  Expected: compile error (`Cannot find 'SidebarOutlineItem' in scope`).

- [ ] **Step 3: Implement `SidebarOutlineItem`**

  Create `Features/Navigation/SidebarOutlineItem.swift`:

  ```swift
  import Foundation

  /// One node in the macOS sidebar outline. The two top-level entries are
  /// the bucket section headers ("Current Accounts", "Investments"); their
  /// children are bucket entries (standalone accounts + groups intermixed
  /// by `position`, exactly as produced by
  /// `Accounts.groupAwareSidebar(...)`). A group's `children` are its
  /// member accounts (sorted by member `position`); an account's
  /// `children` is always `nil`.
  ///
  /// `Identifiable` is required by the `OutlineView` package; `Hashable`
  /// is required so SwiftUI's `Binding<SidebarOutlineItem?>` selection
  /// can deduplicate. Equality is by `id` (the kind's stable identifier).
  struct SidebarOutlineItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
      case currentAccountsHeader
      case investmentsHeader
      case account(UUID)
      case group(UUID)
    }

    let kind: Kind
    let children: [SidebarOutlineItem]?

    var id: Kind { kind }

    static func == (lhs: SidebarOutlineItem, rhs: SidebarOutlineItem) -> Bool {
      lhs.kind == rhs.kind
    }

    func hash(into hasher: inout Hasher) { hasher.combine(kind) }

    /// Derives the outline tree from the same source-of-truth helper the
    /// SwiftUI sidebar uses (`Accounts.groupAwareSidebar`). Hidden /
    /// excluded handling rides along — callers don't pass `excluding`
    /// / `alwaysInclude` here; the helper is invoked with defaults
    /// because the sidebar never wants to hide its own rows.
    static func tree(
      accounts: Accounts,
      groups: [AccountGroup]
    ) -> [SidebarOutlineItem] {
      let grouped = accounts.groupAwareSidebar(groups: groups)
      return [
        section(.currentAccountsHeader, entries: grouped.current),
        section(.investmentsHeader, entries: grouped.investments),
      ]
    }

    private static func section(
      _ kind: Kind, entries: [SidebarBucketEntry]
    ) -> SidebarOutlineItem {
      SidebarOutlineItem(
        kind: kind,
        children: entries.map(item(from:))
      )
    }

    private static func item(from entry: SidebarBucketEntry) -> SidebarOutlineItem {
      switch entry {
      case .account(let account):
        return SidebarOutlineItem(kind: .account(account.id), children: nil)
      case .group(let group, let members):
        return SidebarOutlineItem(
          kind: .group(group.id),
          children: members.map { SidebarOutlineItem(kind: .account($0.id), children: nil) }
        )
      }
    }
  }
  ```

- [ ] **Step 4: Re-run the tests to confirm they pass**

  ```bash
  just test SidebarOutlineItemTests 2>&1 | tee .agent-tmp/test-outline-item.txt
  ```

  Expected: 3/3 pass.

- [ ] **Step 5: format-check + commit**

  ```bash
  just format-check
  git -C . add Features/Navigation/SidebarOutlineItem.swift MoolahTests/Navigation/SidebarOutlineItemTests.swift
  git -C . commit -m "feat(sidebar): SidebarOutlineItem tree adapter for macOS outline"
  ```

  Expected: format-check passes; commit lands.

### Task 2: `SidebarOutlineView` skeleton — sections render, no selection yet

**Files:**
- Create: `Features/Navigation/SidebarOutlineView.swift`

- [ ] **Step 1: Implement the skeleton**

  Create `Features/Navigation/SidebarOutlineView.swift` — note this file is macOS-only so wrap the whole file in `#if os(macOS)` (do not split via `#if` *inside* the file — it's simpler to read this way):

  ```swift
  #if os(macOS)
    import AppKit
    import OutlineView
    import SwiftUI

    /// macOS-only outline-rendered top section of the sidebar (Current
    /// Accounts + Investments). Wraps `NSOutlineView` via the
    /// `Sameesunkaria/OutlineView` Swift package. Selection rides through
    /// a shared `Binding<SidebarSelection?>` with the sibling SwiftUI
    /// list below (earmarks / totals / nav) — clicking in either surface
    /// updates the same binding.
    ///
    /// Phase 1 scope: render the items, support row selection, support
    /// chevron-driven group expand / collapse bound to
    /// `GroupUIStateStore`. No drag-and-drop yet (Phase 2). No inline
    /// rename (Phase 3) — rename is via the `Edit Account…` context menu
    /// item which opens the full edit sheet.
    struct SidebarOutlineView: View {
      @Environment(AccountStore.self) private var accountStore
      @Environment(AccountGroupStore.self) private var accountGroupStore
      @Environment(GroupUIStateStore.self) private var groupUIStateStore
      @Binding var selection: SidebarSelection?

      var body: some View {
        OutlineView(
          SidebarOutlineItem.tree(
            accounts: accountStore.accounts,
            groups: accountGroupStore.groups),
          selection: outlineSelectionBinding,
          children: \.children
        ) { item in
          cellView(for: item)
        }
        .outlineViewStyle(.sourceList)
      }

      // MARK: - Cell rendering

      /// Returns an `NSView` for the row. Section headers and group rows
      /// use bespoke text cells; account and group rows wrap the
      /// existing SwiftUI cells in `NSHostingView` so the rich content
      /// (icon, balance, "Not set", spinner, color overrides) carries
      /// over without reimplementation.
      private func cellView(for item: SidebarOutlineItem) -> NSView {
        switch item.kind {
        case .currentAccountsHeader: return headerCell("Current Accounts")
        case .investmentsHeader: return headerCell("Investments")
        case .account(let id): return accountCell(id: id)
        case .group(let id): return groupCell(id: id)
        }
      }

      private func headerCell(_ title: String) -> NSView {
        let field = NSTextField(labelWithString: title)
        field.font = NSFont.preferredFont(forTextStyle: .subheadline)
        field.textColor = .secondaryLabelColor
        return field
      }

      private func accountCell(id: UUID) -> NSView {
        guard let account = accountStore.accounts.by(id: id) else {
          return NSView()
        }
        let host = NSHostingView(
          rootView: AccountSidebarRow(account: account)
            .environment(accountStore)
        )
        host.setAccessibilityIdentifier(UITestIdentifiers.Sidebar.account(id))
        return host
      }

      private func groupCell(id: UUID) -> NSView {
        guard let group = accountGroupStore.by(id: id) else { return NSView() }
        let isExpanded = groupUIStateStore.expandedGroupIds.contains(id)
        let memberIds = accountStore.accounts.ordered
          .filter { $0.groupId == id }
          .sorted { $0.position < $1.position }
          .map(\.id)
        let host = NSHostingView(
          rootView: GroupAggregateBalanceLoader(
            memberIds: memberIds,
            targetInstrument: group.instrument
          ) { balance in
            AccountGroupSidebarRow(
              group: group,
              isExpanded: .constant(isExpanded),
              aggregateBalance: balance)
          }
          .environment(accountStore)
        )
        host.setAccessibilityIdentifier(UITestIdentifiers.Sidebar.group(id))
        return host
      }

      // MARK: - Selection binding

      /// Maps between the outline's `SidebarOutlineItem?` selection and
      /// the app's `SidebarSelection?`. Section-header rows are
      /// non-selectable (mapped to `nil`); account / group rows map to
      /// `.account(id)` / `.group(id)`.
      private var outlineSelectionBinding: Binding<SidebarOutlineItem?> {
        Binding(
          get: {
            switch selection {
            case .account(let id):
              return SidebarOutlineItem(kind: .account(id), children: nil)
            case .group(let id):
              return SidebarOutlineItem(kind: .group(id), children: [])
            case .none, .earmark, .recentlyAdded, .allTransactions,
              .upcomingTransactions, .categories, .reports, .analysis:
              return nil
            }
          },
          set: { newItem in
            switch newItem?.kind {
            case .account(let id): selection = .account(id)
            case .group(let id): selection = .group(id)
            case .currentAccountsHeader, .investmentsHeader, .none:
              // Header rows are not selectable; clicking one is a no-op
              // (we deliberately don't clear the existing selection
              // because the user may be re-selecting their place after
              // a header click).
              break
            }
          }
        )
      }
    }
  #endif
  ```

  **Open questions that the spike will have answered before this task runs:**

  - The `OutlineView` initialiser's exact label set may differ from `OutlineView(_, selection:, children:, content:)`. If so, adjust the call site to match. Do not invent missing parameters.
  - `outlineViewStyle(.sourceList)` may be the API for source-list styling, but the actual modifier name should be confirmed against the package source.
  - If section headers cannot be marked as group headers (Spike Step 5 reports option C), this skeleton renders them as bold first-row text without source-list section styling. That is an acceptable Phase 1 shipping state — note the gap in the PR description and open a follow-up.

- [ ] **Step 2: Build to confirm the skeleton compiles**

  ```bash
  just build-mac 2>&1 | tee .agent-tmp/build-outline-skel.txt
  ```

  Expected: clean build. Fix compile errors against the actual package API.

- [ ] **Step 3: Render preview**

  Open `Moolah.xcodeproj` in the worktree, then render the existing `"With a group"` preview through `mcp__xcode__RenderPreview` — but the preview still routes to the SwiftUI `List` body for now (we haven't wired `SidebarOutlineView` into `SidebarView` yet — that's Task 4). Add a new `#Preview("macOS outline — Phase 1 skeleton")` block in `SidebarView+Previews.swift` that hosts only `SidebarOutlineView` with the same seed:

  ```swift
  #Preview("macOS outline — Phase 1 skeleton") {
    let backend = PreviewBackend.create()
    let accountStore = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .AUD)
    let accountGroupStore = AccountGroupStore(repository: backend.accountGroups)
    let groupUIStateStore = GroupUIStateStore(repository: backend.groupUIState)
    return SidebarOutlineView(selection: .constant(nil))
      .environment(accountStore)
      .environment(accountGroupStore)
      .environment(groupUIStateStore)
      .frame(width: 260, height: 480)
      .task {
        await seedSidebarGroupPreview(
          backend: backend,
          accountStore: accountStore,
          accountGroupStore: accountGroupStore)
      }
  }
  ```

  Confirm the seeded "Trust Fund Crypto" group renders with its two member rows. Confirm the section headers render.

- [ ] **Step 4: format-check + commit**

  ```bash
  just format-check
  git -C . add Features/Navigation/SidebarOutlineView.swift Features/Navigation/SidebarView+Previews.swift
  git -C . commit -m "feat(sidebar): SidebarOutlineView skeleton (macOS, no selection wiring yet)"
  ```

### Task 3: Wire group expansion to `GroupUIStateStore`

**Files:**
- Modify: `Features/Navigation/SidebarOutlineView.swift`

- [ ] **Step 1: Inspect the OutlineView package for the expansion API**

  Read `.build/checkouts/OutlineView/Sources/OutlineView/OutlineView.swift` (path may differ — locate via `find`). The package exposes one of:

  - A `.expansion(_:)` modifier taking a `Binding<Set<Item.ID>>`.
  - An initialiser overload accepting an `expansion:` binding.
  - No bindable expansion API — the user expands/collapses, the package owns the state, no external persistence.

  Record which one it offers in `.agent-tmp/outline-expansion.md`. Branch on this:

  - **Bindable:** wire it through to `GroupUIStateStore.expandedGroupIds` (a `Set<UUID>` — but the package wants `Set<Item.ID>` where `Item.ID == SidebarOutlineItem.Kind`, so map between them).
  - **Non-bindable:** keep our existing `GroupUIStateStore` flow alive by subscribing to the package's `onItemExpansionChange` callback (if any), or accept that Phase 1 doesn't restore expand state across sessions on macOS and note it as a Phase 2 follow-up.

  **Stop and surface to the user if the package offers no expansion observation at all** — that is the kind of design-tradeoff the spike was meant to surface but only the source-read can confirm.

- [ ] **Step 2: Write the expansion test**

  Add to `SidebarOutlineItemTests.swift` if the implementation lives there, or to a new `SidebarOutlineViewTests.swift` if the binding helpers live on the view. Test sketch (adjust shape based on Step 1's branch):

  ```swift
  @Test func expansionBindingReadsAndWritesGroupUIStateStore() async {
    let store = await GroupUIStateStore.previewEmpty()
    let g = UUID()
    let binding = SidebarOutlineView.expansionBinding(
      groupStore: store,
      knownGroupIds: [g])
    #expect(binding.wrappedValue.isEmpty)
    binding.wrappedValue = [.group(g)]
    // Yield for the async write.
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await store.expandedGroupIds.contains(g))
  }
  ```

  (The exact shape depends on whether the helper is a top-level static, a method, or computed property. Pick the one that compiles cleanly with the chosen package API. If the existing test target lacks `GroupUIStateStore.previewEmpty()`, use the production initialiser against an in-memory repository as the other store tests do — search `MoolahTests` for an example, e.g. `GroupUIStateStoreTests.swift`.)

- [ ] **Step 3: Implement the binding (or, if non-bindable, the callback)**

  Wire the package's expansion API to `GroupUIStateStore.setExpanded(_:for:)`. The existing `expandBinding(for:)` helper in `SidebarView+Groups.swift` is a near-exact reference — port its logic. Note the package likely speaks in terms of `Set<Item.ID>` (here `Set<SidebarOutlineItem.Kind>`), not `Set<UUID>`, so map between them in the binding.

- [ ] **Step 4: Re-render the preview and toggle the chevron**

  Render the `"macOS outline — Phase 1 skeleton"` preview. Toggle the group's chevron. The expanded children must appear / disappear. Across a second render, the expand state should still be in memory (the in-process store survives). Cross-session persistence is exercised via the live app, not preview — schedule a manual run via `just run-mac` later in this phase.

- [ ] **Step 5: format-check + commit**

  ```bash
  just format-check
  git -C . add Features/Navigation/SidebarOutlineView.swift MoolahTests/Navigation/
  git -C . commit -m "feat(sidebar): bind outline expansion to GroupUIStateStore"
  ```

### Task 4: Wire `SidebarOutlineView` into `SidebarView` on macOS

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`
- Modify: `Features/Navigation/SidebarView+Sections.swift`
- Modify: `Features/Navigation/SidebarView+Groups.swift`

- [ ] **Step 1: Split `body` on `#if os(macOS)` / `#if os(iOS)`**

  In `SidebarView.swift`, replace the `var body` contents with:

  ```swift
  var body: some View {
    #if os(macOS)
      macSidebarBody
    #else
      iosSidebarBody
    #endif
  }
  ```

  Move the existing `List(selection:)` block into a new `iosSidebarBody: some View` computed property (gated `#if os(iOS)`). Carry over the `.onKeyPress(.return)`, `.navigationTitle`, `focusedSceneValue` modifiers, the `.onChange`, `.onAppear`, the `.sheet` and `.toolbar` modifiers, exactly as they are — they are platform-aware already.

  Add a new `macSidebarBody: some View` (gated `#if os(macOS)`):

  ```swift
  #if os(macOS)
    @ViewBuilder
    private var macSidebarBody: some View {
      VStack(spacing: 0) {
        SidebarOutlineView(selection: $selection)
        List(selection: $selection) {
          earmarksSection
          totalsSection
          navigationSection
        }
        .listStyle(.sidebar)
      }
      .navigationTitle("")
      .focusedSceneValue(\.showHiddenAccounts, $showHidden)
      .focusedSceneValue(\.showSpamTransactions, $showSpam)
      .focusedSceneValue(\.sidebarSelection, $selection)
      .focusedSceneValue(\.selectedAccount, selectedAccountBinding)
      .onChange(of: showHidden) { _, newValue in
        accountStore.showHidden = newValue
        earmarkStore.showHidden = newValue
      }
      .onChange(of: showSpam) { _, newValue in
        transactionStore.showSpam = newValue
      }
      .onAppear {
        accountStore.showHidden = showHidden
        earmarkStore.showHidden = showHidden
        transactionStore.showSpam = showSpam
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SyncProgressFooter()
      }
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button { showCreateAccountSheet = true } label: {
            Label("New Account", systemImage: "plus")
          }
          .help("Create new account")
          .accessibilityIdentifier(UITestIdentifiers.Sidebar.newAccountButton)
        }
        ToolbarItem(placement: .primaryAction) {
          Button { showCreateEarmarkSheet = true } label: {
            Label("New Earmark", systemImage: "bookmark.fill")
          }
          .help("Create new earmark")
          .accessibilityIdentifier(UITestIdentifiers.Sidebar.newEarmarkButton)
        }
      }
      .focusedSceneValue(\.newEarmarkAction) {
        showCreateEarmarkSheet = true
      }
      .focusedSceneValue(\.newAccountAction) {
        showCreateAccountSheet = true
      }
      .sheet(isPresented: $showCreateEarmarkSheet) {
        CreateEarmarkSheet(
          instrument: session.profile.instrument,
          onCreate: { newEarmark in
            Task {
              _ = await earmarkStore.create(newEarmark)
              showCreateEarmarkSheet = false
            }
          }
        )
      }
      .sheet(isPresented: $showCreateAccountSheet) {
        CreateAccountView(
          instrument: session.profile.instrument,
          accountStore: accountStore,
          cryptoSyncStore: session.cryptoSyncStore)
      }
      .sheet(item: $accountToEdit) { account in
        EditAccountView(account: account, accountStore: accountStore)
      }
      .onReceive(
        NotificationCenter.default.publisher(for: .requestAccountEdit),
        perform: handleAccountEditRequest
      )
    }
  #endif
  ```

  DRY this body against `iosSidebarBody` — the modifier set diverges only in: the body content (outline + small list vs single list), the absence of `.onKeyPress(.return)` and the iOS edit-mode environment. If `closure_body_length` or `function_body_length` SwiftLint thresholds trip, split into smaller helpers (e.g. `macSidebarSheets`, `macSidebarFocusedScenes`) — follow `feedback_swiftlint_fix_not_baseline.md` and never bump a baseline.

- [ ] **Step 2: Gate iOS-only section / group code with `#if os(iOS)`**

  In `SidebarView+Sections.swift`, wrap `currentAccountsSection`, `investmentsSection`, `bucketEntryView`, and the `handleAccountEditRequest` helper (which is only called from the iOS sheet wiring on iOS now) under `#if os(iOS)` blocks. `handleAccountEditRequest` is also called from macOS, so re-confirm by reading the call sites — if macOS uses it, lift it out of the `#if`.

  In `SidebarView+Groups.swift`, wrap the entire file's view extension body in `#if os(iOS)` **except** `DraggableSidebarItem`, `UTType.moolahSidebarItem`, and `expandBinding(for:)` — keep those shared (Phase 2 will need them on macOS too, and the iOS path still uses them now). The drop / drag handlers (`handleDrop(_:ontoAccount:)`, `handleDrop(_:ontoGroup:)`) stay shared as well because Phase 2 will reuse them from `SidebarOutlineView`'s `DropReceiver`.

- [ ] **Step 3: Gate the `.onKeyPress(.return)` rename trigger to iOS-only**

  In `SidebarView.swift`'s `iosSidebarBody`, keep `.onKeyPress(.return)` as-is. The macOS body has no Return-to-rename until Phase 3 — Return on a selected outline row falls through to system default behaviour.

- [ ] **Step 4: Build**

  ```bash
  just build-mac 2>&1 | tee .agent-tmp/build-wired.txt
  just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
  ```

  Expected: both clean. iOS must build because we did not break its code path.

- [ ] **Step 5: Render & manually run macOS**

  Render `"With a group"` and `"Empty earmarks"` previews — they should now show the outline-rendered accounts on top + the SwiftUI earmarks/totals/nav below.

  Then:

  ```bash
  just run-mac
  ```

  Click around. Verify:
  - Selecting an account opens its transaction detail (selection binding works).
  - Selecting a group opens the group detail.
  - Selecting Earmarks / Recently Added / All Transactions / Analysis / Reports / Categories / Upcoming all work (the SwiftUI `List` selection is shared with the outline's selection).
  - Toggling a group's chevron expands / collapses; quitting + relaunching restores the expand state (proves `GroupUIStateStore` round-trip).
  - The toolbar "+ Account" / "+ Earmark" buttons still open their sheets.
  - "Edit Account…" from the account row's context menu still opens the edit sheet.

  Per `feedback_iterate_via_preview.md`, iterate visual tweaks via `#Preview` rather than relaunching for every change.

- [ ] **Step 6: format-check + commit**

  ```bash
  just format-check
  git -C . add Features/Navigation/
  git -C . commit -m "feat(sidebar): macOS SidebarView body splits on #if; outline + earmarks/nav"
  ```

### Task 5: Tests — full unit suite + UI smoke

**Files:**
- Modify (already exists): `MoolahTests/Navigation/SidebarOutlineItemTests.swift` (Task 1)
- Modify (created in Task 3 or new): `MoolahTests/Navigation/SidebarOutlineViewTests.swift`

- [ ] **Step 1: Run the full macOS unit / UI test suite**

  Before running, kill any wedged test hosts per `reference_macos_test_runner_hang.md`:

  ```bash
  pkill -f Moolah 2>/dev/null || true
  ```

  Then:

  ```bash
  just test 2>&1 | tee .agent-tmp/test-full.txt
  grep -i 'failed\|error:' .agent-tmp/test-full.txt
  ```

  Expected: zero failures. If `MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift`'s `switchToAccount` or `switchToNamed` fails (because the resolver finds an `NSHostingView` instead of a SwiftUI element), update the driver per `guides/UI_TEST_GUIDE.md` — the identifier itself is unchanged.

  If the UI host is wedged after multiple retries (`feedback_pr_ci_gate_when_ui_host_blocked.md`), surface the failure to the user, push the branch, and gate Phase 1 merge on CI's UI Test job rather than on local UI tests. Confirm with the user before doing so.

- [ ] **Step 2: Code review for guide compliance**

  Run the project's review agents in parallel against the working tree:

  ```bash
  # via the Agent tool, in parallel:
  # @code-review @concurrency-review @ui-review @ui-test-review
  ```

  Address every finding per `feedback_apply_all_review_findings.md`. Critical / Important / Minor all get fixed in this PR unless deferred with the user's explicit sign-off.

- [ ] **Step 3: Commit any review-driven fixes**

  ```bash
  just format-check
  git -C . status
  # iff changes:
  git -C . add -A
  git -C . commit -m "polish(sidebar): apply code-review findings"
  ```

### Task 6: PR

**Files:** none (git only).

- [ ] **Step 1: Push the branch**

  Per CLAUDE.md's "Stacked-PR worktrees" section, use the explicit refspec form:

  ```bash
  git -C . push origin fix-sidebar-drag-drop:fix-sidebar-drag-drop
  ```

  (If the branch was created off a non-main base, also confirm with `git -C . branch -vv` that no unintended upstream tracking was set.)

- [ ] **Step 2: Open the PR**

  Title: `feat(sidebar): macOS NSOutlineView rewrite — Phase 1 (skeleton + selection)`. Body covers: link to design doc, link to issue #991, what Phase 1 ships, what's deferred to Phase 2 / 3, any spike findings worth surfacing (e.g. if option C from Spike Step 5 was taken, mention the open follow-up).

  ```bash
  gh pr create \
    --base main \
    --title "feat(sidebar): macOS NSOutlineView rewrite — Phase 1 (skeleton + selection)" \
    --body "$(cat <<'EOF'
## Summary

Phase 1 of the NSOutlineView sidebar rewrite (design: `plans/2026-05-27-sidebar-nsoutlineview-rewrite-design.md`, executed against `plans/2026-05-27-sidebar-nsoutlineview-phase-1-plan.md`). Adds the `Sameesunkaria/OutlineView` Swift package and replaces the macOS `Current Accounts` / `Investments` sections with an `NSOutlineView`-backed view. Selection is wired back to `SidebarSelection`. iOS sidebar is untouched.

This does **not** yet fix issue #991 — drag-and-drop arrives in Phase 2. Inline rename arrives in Phase 3.

## Test plan

- [ ] `just build-mac` + `just build-ios` are clean.
- [ ] `just test` passes (unit + UI).
- [ ] `just format-check` passes.
- [ ] Manual run-through on macOS: select accounts / groups / named views (Analysis, Reports, Categories, Upcoming, Recently Added, All Transactions, Earmarks); expand/collapse a group; relaunch and confirm expand state persists; right-click → Edit Account opens the sheet.
- [ ] Review agents (`@code-review`, `@concurrency-review`, `@ui-review`, `@ui-test-review`) report no Critical/Important findings.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
  ```

- [ ] **Step 3: Enable auto-merge**

  Per `feedback_prs_to_merge_queue.md` and the `landing-prs` skill:

  ```bash
  gh pr merge --auto --rebase
  ```

  Use the `monitoring-pr-status` skill in a background task to be notified on merge / CI failure / stalled automerge. Do not poll.

---

## Verification (end-to-end)

After Task 6 closes, Phase 1 is **done** if all of these hold against the working tree:

1. `just build-mac` and `just build-ios` build clean.
2. `just test` passes — including `SidebarOutlineItemTests`, any `SidebarOutlineViewTests`, and the existing `SidebarScreen`-driven UI tests.
3. `just format-check` reports zero violations and zero new `swiftlint:disable` / baseline entries.
4. Manual run-through on macOS confirms: account selection, group selection (placeholder detail surface is fine — Phase 5 wires it), navigation to all named views, group expand/collapse with persistence, toolbar add-account / add-earmark, context-menu Edit Account…, "+ Group" creation via context menu (the right-click "Group ▸" submenu is the workaround for #991 until Phase 2 ships).
5. The four review agents (`@code-review`, `@concurrency-review`, `@ui-review`, `@ui-test-review`) report no unresolved Critical or Important findings.
6. The PR description names what is intentionally deferred to Phase 2 / 3 so the reader does not expect drag-and-drop or inline rename to work.

---

## Deferred to Phase 2 / 3 / 4 / 5 (out of scope here)

- **Phase 2 — drag-and-drop.** `dragDataSource` + `DropReceiver` on `SidebarOutlineView`. Wire `validateDrop` to dispatch to existing `accountStore.reorderAccounts` / `accountGroupStore.moveGroup` / `accountGroupStore.addAccount` / `createGroup(joining:and:)`. Closes issue #991.
- **Phase 3 — inline rename.** `NSTextField`-based rename (or `NSHostingView`-wrapped `InlineRenameField` from `AccountSidebarRow.swift`) triggered by double-click and Return. Restores the iOS-side `.onKeyPress(.return)` parity on macOS.
- **Phase 4 — context menu, keyboard navigation, accessibility audit.** Per-cell `NSMenu`, arrow keys, VoiceOver pass.
- **Phase 5 — UI test refit.** Rewrite drag-related UI tests if the Phase 2 wiring needs anything beyond identifier-based row resolution.
