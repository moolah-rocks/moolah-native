# Unified macOS Sidebar (single `NSOutlineView`) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Per project memory (`feedback_subagent_driven.md`), do not ask whether to use it — that is the default. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the macOS sidebar's hybrid SwiftUI `List(.sidebar)` + embedded `NSOutlineView` implementation with a single top-level `NSOutlineView` that renders every sidebar row (sections, accounts, groups, earmarks, totals, navigation). Achieve visual parity with native macOS source-list sidebars (Mail, Finder, Notes) and unify chrome/scrolling/indentation across all sections.

**Architecture:** Introduce `SidebarOutline` — an `NSViewControllerRepresentable` over a single `NSOutlineView` configured with `.sourceList` style. The outline's tree contains source-list group headers ("Current Accounts", "Earmarks", "Investments", "Totals", and an untitled navigation group) as non-selectable root items; account / group / earmark / total / nav rows are children. Cell content stays SwiftUI (`NSHostingView`-wrapped `AccountSidebarRow` / `EarmarkRowView` / `AccountGroupSidebarRow` / new lightweight total + nav row views) so we keep one codepath for row visuals shared with iOS. The host `SidebarView.macSidebarBody` becomes a thin wrapper that owns the same `@Environment` stores and sheet bindings as today, and passes snapshots + bindings down to the representable.

**Tech stack:** AppKit `NSOutlineView` (direct, no vendored package), `NSViewControllerRepresentable`, `NSHostingView` for cell content, existing SwiftUI row views, existing `AccountStore` / `EarmarkStore` / `AccountGroupStore` / `GroupUIStateStore` / `ImportStore`, Swift Testing for unit tests, XCUITest for the macOS integration safety net.

**Closes:** the rendering-quality issues introduced by `2026-05-27-sidebar-nsoutlineview-phase-1-plan.md`: per-section opaque background bands, per-section vertical scroll bars, left/right inset mismatch between sections, fixed-height `computedHeight(for:)` hack. Does **not** close [#991](https://github.com/moolah-rocks/moolah-native/issues/991) (drag-and-drop) — that lands in the follow-up Phase 2 plan, which now has a much simpler surface area to extend.

**iOS scope:** unchanged. iOS uses SwiftUI `List(.sidebar)` end-to-end — that *is* the native source-list on iOS, and `UIKit`'s sidebar story (`UICollectionLayoutListConfiguration.appearance = .sidebar`) offers nothing SwiftUI doesn't already give us.

---

## Non-goals

- **Drag-and-drop** (reorder, drop-into-group, cross-section earmark↔account). Follow-up plan: `2026-05-2X-sidebar-drag-wiring-plan.md`. The unified outline makes this dramatically simpler — one `NSOutlineViewDataSource` mediates all drops, including cross-section. View-agnostic foundation (pasteboard codec, dispatch, policy decision table) is landed separately by `plans/2026-05-27-sidebar-drag-foundation-cherry-pick-plan.md` — see Coordination below.
- **Inline rename on macOS**. Currently iOS-only. Follow-up plan: `2026-05-2X-sidebar-inline-rename-macos-plan.md`. With a native outline, this is `NSTextField` field-editor on double-click / Return — well-trodden AppKit territory.
- **Toolbar redesign.** The current SwiftUI toolbar in `SidebarSharedModifiers` (new-account / new-earmark / sidebar-toggle) stays untouched.
- **Sheets** (`accountToEdit`, `showCreateAccountSheet`, `showCreateEarmarkSheet`). Stay SwiftUI on the parent; the outline pokes the existing bindings to trigger them.

---

## Coordination with the drag-foundation cherry-pick

The paused `sidebar-phase-2` branch shipped four tasks locally; tasks 1–3 contain view-agnostic foundation work (pasteboard codec, `SidebarDropDispatch`, `SidebarDropPolicy` decision table, iOS `handleDrop` rewrite) that survives this rewrite unchanged. That work is landed independently by **`plans/2026-05-27-sidebar-drag-foundation-cherry-pick-plan.md`** — referred to from here as "the foundation PR."

**This plan and the foundation plan can run fully in parallel.** Their file sets are disjoint except for one small overlap (`Features/Navigation/SidebarView+Groups.swift` — the foundation PR rewrites the iOS `handleDrop` body; this plan deletes dead macOS-only blocks elsewhere in the same file). Git merges these cleanly; whichever PR rebases second resolves the trivial textual conflict.

**The foundation PR's symbols are not consumed by this plan.** `SidebarDropDispatch`, `SidebarDropPolicy`, and the pasteboard codec exist on `main` after the foundation merges but are never called from any file this plan creates or modifies. They are reserved for the **drag-wiring follow-up plan** (a separate plan, written after both this plan and the foundation PR land), which adds `NSOutlineViewDataSource`'s native drag methods to `SidebarOutlineDataSource` and calls into the foundation.

**Discarded from `sidebar-phase-2`:** task 4 (`.dragDataSource(...)` + `.onDrop(...)` wiring on `SidebarOutlineView.swift`) and the `SidebarOutlineDropReceiver` class half of task 3 (vendored-package conformance). Both target the doomed hybrid surface. The drag-wiring follow-up plan reimplements the equivalent wiring against the unified `SidebarOutlineDataSource` — fewer lines, no vendored protocol.

**Ordering summary:**
- This plan and the foundation plan → parallel; either merges first.
- Drag-wiring follow-up plan → strictly after both this plan and the foundation plan have merged.

---

## Functional acceptance criteria

By the end of this plan, the macOS sidebar must:

1. Render five logical sections — Current Accounts, Earmarks, Investments, Totals, and Navigation — as source-list group headers, with one scrollbar for the whole sidebar (or none, if the content fits). No per-section scroll view. No opaque background bands. No fixed-height hack.
2. Render the same row content as today: account rows (`AccountSidebarRow`), group rows (`AccountGroupSidebarRow` with no chevron — the outline draws its own disclosure triangle), member account rows under expanded groups, earmark rows (`EarmarkRowView`), total rows (Current Total, Investment Total, Earmarked Total, Available Funds, Net Worth — with the same visibility rules as today), and navigation rows (Analysis, Reports, Categories, Upcoming, Recently Added with unread badge, All Transactions).
3. Match the iOS row content exactly — icons, balance colours, "Not set" indicator, spinner-while-loading. Indentation, leading icon position, trailing balance position must match the iOS list (and therefore match each other across sections).
4. Map selection two-way to the parent `Binding<SidebarSelection?>` for `.account(UUID)`, `.group(UUID)`, `.earmark(UUID)`, `.recentlyAdded`, `.allTransactions`, `.upcomingTransactions`, `.categories`, `.reports`, `.analysis`. Total rows and section headers are non-selectable.
5. Persist group expand state via `GroupUIStateStore` (the existing GRDB local-only table). Reopening the profile restores the same expanded-set.
6. Account right-click menu: "Edit Account…" and "View Transactions". Identifiers preserved (`UITestIdentifiers.Sidebar.editAccountContextMenuItem`). Right-click on an unselected row selects it first (Finder behaviour).
7. Section-header `+` button on Current Accounts ↔ `showCreateAccountSheet = true`; on Earmarks ↔ `showCreateEarmarkSheet = true`. Identifiers preserved (`UITestIdentifiers.Sidebar.newAccountButton` / `newEarmarkButton`).
8. All existing `UITestIdentifiers.Sidebar.*` identifiers continue to resolve. Every existing test under `MoolahUITests_macOS` that exercises sidebar selection / context menu / navigation passes without changes.
9. `just format-check`, `just build-mac`, `just test-mac` all pass.

Anything not in this list is out of scope; flag if you find a regression and stop.

---

## File structure

The new code lives under `Features/Navigation/AppKitSidebar/`. The old `SidebarOutlineView` / `SidebarOutlineItem` / vendored `OutlineView` package are deleted at the end of the plan once the new path is live and tests are green.

**Create:**

- `Features/Navigation/AppKitSidebar/SidebarOutline.swift` — `NSViewControllerRepresentable` consumed by `SidebarView.macSidebarBody`. Takes the parent's stores + bindings + selection binding as inputs; produces `SidebarOutlineController`.
- `Features/Navigation/AppKitSidebar/SidebarOutlineController.swift` — `NSViewController` owning the `NSOutlineView` + `NSScrollView`, hosting the data source and delegate, applying tree diffs on `updateNSViewController`.
- `Features/Navigation/AppKitSidebar/SidebarOutlineDataSource.swift` — `NSOutlineViewDataSource` reading the flat `[SidebarRow]` tree.
- `Features/Navigation/AppKitSidebar/SidebarOutlineDelegate.swift` — `NSOutlineViewDelegate` producing cell views, gating selection, emitting expansion changes.
- `Features/Navigation/AppKitSidebar/SidebarRow.swift` — item model. Enum of section / account / group / earmark / total / nav. `Hashable`, `Sendable`, `Identifiable` (stable id per case).
- `Features/Navigation/AppKitSidebar/SidebarRowTree.swift` — pure builder: stores + filters in → `[SidebarRow]` (root = sections; children = entries) out. The single source of truth for sidebar ordering across the AppKit and iOS bodies.
- `Features/Navigation/AppKitSidebar/Cells/SidebarSectionHeaderCell.swift` — `NSTableCellView` with `NSHostingView`. Renders section title + optional `+` action button. Non-selectable.
- `Features/Navigation/AppKitSidebar/Cells/SidebarTotalCell.swift` — `NSHostingView`-wrapped row showing a label + value, secondary style. Non-selectable.
- `Features/Navigation/AppKitSidebar/Cells/SidebarNavigationCell.swift` — `NSHostingView`-wrapped row showing `Label("Title", systemImage:)` + optional unread badge. Selectable.
- `Features/Navigation/AppKitSidebar/Cells/SidebarRowFactory.swift` — single dispatch point from `SidebarRow` → `NSTableCellView`. Reused by the delegate. Keeps the delegate from sprawling.
- `MoolahTests/Navigation/SidebarRowTreeTests.swift` — Swift Testing suite for the tree builder. Tests every visibility rule, expansion shape, totals-row gating, hidden-account filter, etc.
- `MoolahTests/Navigation/SidebarRowIdentityTests.swift` — Swift Testing suite for `SidebarRow` identity / equality / hashability.
- `MoolahTests/Navigation/SidebarOutlineSelectionMappingTests.swift` — Swift Testing suite for the static `selection(for:)` / `row(for:)` mapping functions (no AppKit involvement, pure data).
- `MoolahTests/Navigation/SidebarOutlineExpansionMappingTests.swift` — Swift Testing suite for the expansion ↔ `GroupUIStateStore` binding shape.

**Modify:**

- `Features/Navigation/SidebarView.swift` — `macSidebarBody` collapses to a single `SidebarOutline(...)` (full-bleed), wrapping its current `@Environment` stores + sheet bindings into the representable. iOS body untouched. Toolbar / sheets / `SidebarSharedModifiers` unchanged.
- `Features/Navigation/SidebarView+Sections.swift` — delete the `#if os(macOS)` section builders (`currentAccountsSection`, `investmentsSection`, `totalsSection`, `navigationSection`, `recentlyAddedLabel`, `totalRow`, `sectionHeader`) — they are no longer reachable. Keep the iOS variants. The `addAccountAction` / `addEarmarkAction` helpers stay (the AppKit cells call them via captured closures).
- `Features/Navigation/SidebarView+Groups.swift` — `accountGroupSubmenu`, `groupRowLink`, `memberRowLink`, `standaloneAccountRowLink` stay (iOS-only paths). Drop any macOS-specific helpers that referenced the old `SidebarOutlineView`. Verify nothing is left dangling.
- `Features/Navigation/SidebarView+Previews.swift` — replace the macOS preview block with one that exercises `SidebarOutline` against `PreviewBackend`. Keep the iOS preview untouched.
- `project.yml` — remove the `Vendored/OutlineView` source group from the macOS target (only after the new path is live and all tests pass — Task 17).
- `MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift` — verify only. Identifiers are preserved; the screen driver should keep working. Update only if the resolver returns a different element type.

**Delete (Task 17, after green):**

- `Features/Navigation/SidebarOutlineView.swift` — replaced by `SidebarOutline.swift`.
- `Features/Navigation/SidebarOutlineItem.swift` — replaced by `SidebarRow.swift` (different shape — flat enum vs adapter).
- `MoolahTests/Navigation/SidebarOutlineItemTests.swift` — superseded by `SidebarRowTreeTests.swift`.
- `MoolahTests/Navigation/SidebarOutlineViewTests.swift` — superseded by the mapping/identity test suites above.
- `Vendored/OutlineView/` (entire directory) — no longer referenced.

**Untouched (referenced only):**

- `Domain/Models/Accounts+SidebarOrdering.swift` — `groupAwareSidebar(...)` still produces the bucket ordering. `SidebarRowTree` consumes it.
- `Features/Accounts/AccountStore.swift`, `Features/Accounts/AccountGroupStore.swift`, `Features/Accounts/GroupUIStateStore.swift`, `Features/Earmarks/EarmarkStore.swift`, `Features/Import/ImportStore.swift`, `Features/Transactions/TransactionStore.swift` — no API surface changes.
- `Features/Accounts/Views/AccountSidebarRow.swift`, `Features/Accounts/Views/AccountGroupSidebarRow.swift`, `Features/Accounts/Views/GroupAggregateBalanceLoader.swift`, `Features/Earmarks/Views/EarmarkRowView.swift`, `Features/Accounts/Views/SidebarRowView.swift` — embedded via `NSHostingView` unchanged. All existing `#Preview` blocks keep driving design iteration on the row cells.
- `UITestSupport/UITestIdentifiers+Sidebar.swift` — identifier strings unchanged.
- `Features/Navigation/SidebarSharedModifiers.swift` — toolbar, sheets, sync footer untouched.

---

## Branch + worktree setup

Per `CLAUDE.md`, `main` is protected. Create a worktree branched off latest `main`.

- [ ] **Step 0.1: Sync `main` and create the worktree**

  ```bash
  git -C /Users/aj/Documents/code/moolah-project/moolah-native fetch origin
  git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track .worktrees/sidebar-unified-appkit -b sidebar-unified-appkit origin/main
  ```

  All subsequent commands in this plan assume `WORKTREE=/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-unified-appkit`. Per `feedback_no_cd_for_any_tool.md`, do not `cd` into it; use `just -d "$WORKTREE" --justfile "$WORKTREE/justfile" <target>` and `git -C "$WORKTREE" ...`.

- [ ] **Step 0.2: Open the worktree's `Moolah.xcodeproj`**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  open "$WORKTREE/Moolah.xcodeproj"
  ```

  Per `CLAUDE.md` "Xcode previews and the `mcp__xcode__RenderPreview` tool from a worktree" — Xcode must be open on the worktree's project for previews / SourceKit to read worktree source.

---

## Task 1: `SidebarRow` item model

**Files:**
- Create: `Features/Navigation/AppKitSidebar/SidebarRow.swift`
- Create: `MoolahTests/Navigation/SidebarRowIdentityTests.swift`

Defines the flat enum-based item model for the outline. Each case carries a stable identifier; equality / hash key off the identifier so `NSOutlineView`'s diff and `Set<AnyHashable>` expansion sets behave.

- [ ] **Step 1.1: Write the failing identity test**

  Create `MoolahTests/Navigation/SidebarRowIdentityTests.swift`:

  ```swift
  import Testing
  import Foundation
  @testable import Moolah

  @Suite("SidebarRow identity")
  struct SidebarRowIdentityTests {
    @Test("Two rows for the same account are equal and hash equally")
    func accountIdentityRoundTrip() {
      let id = UUID()
      let a = SidebarRow.account(id)
      let b = SidebarRow.account(id)
      #expect(a == b)
      #expect(a.hashValue == b.hashValue)
      #expect(a.id == b.id)
    }

    @Test("Account and group with the same UUID are distinct rows")
    func accountAndGroupAreDistinct() {
      let id = UUID()
      #expect(SidebarRow.account(id) != SidebarRow.group(id))
      #expect(SidebarRow.account(id).id != SidebarRow.group(id).id)
    }

    @Test("Section / total / navigation cases have stable identifiers")
    func staticCaseIdentifiers() {
      #expect(SidebarRow.section(.current) == SidebarRow.section(.current))
      #expect(SidebarRow.section(.current) != SidebarRow.section(.earmarks))
      #expect(SidebarRow.total(.currentTotal) != SidebarRow.total(.netWorth))
      #expect(SidebarRow.navigation(.analysis) != SidebarRow.navigation(.reports))
    }
  }
  ```

- [ ] **Step 1.2: Run the test — confirm it fails because `SidebarRow` doesn't exist**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarRowIdentityTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-output.txt"
  ```

  Expected: compile error — `cannot find 'SidebarRow' in scope`.

- [ ] **Step 1.3: Create the type**

  Create `Features/Navigation/AppKitSidebar/SidebarRow.swift`:

  ```swift
  import Foundation

  /// One row in the unified macOS sidebar `NSOutlineView`. Every visible
  /// row — section header, account, group, member account, earmark,
  /// total, navigation link — is represented as one of these. Equality
  /// and hash key off the case identifier (`id`) so the outline view's
  /// per-item diff, the expansion `Set<SidebarRow>`, and the selection
  /// binding all behave under store mutations that produce a row with
  /// identical contents but a fresh struct value.
  enum SidebarRow: Hashable, Sendable, Identifiable {
    case section(SectionKind)
    case account(UUID)
    case group(UUID)
    case earmark(UUID)
    case total(TotalKind)
    case navigation(NavigationKind)

    enum SectionKind: Hashable, Sendable {
      case current
      case earmarks
      case investments
      case totals
      case navigation
    }

    enum TotalKind: Hashable, Sendable {
      case currentTotal
      case investmentTotal
      case earmarkedTotal
      case availableFunds
      case netWorth
    }

    enum NavigationKind: Hashable, Sendable {
      case analysis
      case reports
      case categories
      case upcoming
      case recentlyAdded
      case allTransactions
    }

    /// Stable per-case identifier — used directly as the `Identifiable.id`
    /// and as the value handed to `NSOutlineView` as the item handle.
    /// All `Hashable`-equal `SidebarRow` values share the same `id`.
    var id: String {
      switch self {
      case .section(let kind): return "section.\(kind)"
      case .account(let id): return "account.\(id.uuidString)"
      case .group(let id): return "group.\(id.uuidString)"
      case .earmark(let id): return "earmark.\(id.uuidString)"
      case .total(let kind): return "total.\(kind)"
      case .navigation(let kind): return "navigation.\(kind)"
      }
    }
  }
  ```

- [ ] **Step 1.4: Add the file to `project.yml` if not auto-discovered, regenerate, re-run the test**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarRowIdentityTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-output.txt"
  ```

  Expected: PASS, 3/3 tests green.

- [ ] **Step 1.5: Format + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarRow.swift MoolahTests/Navigation/SidebarRowIdentityTests.swift project.yml
  git -C "$WORKTREE" commit -m "feat(sidebar): SidebarRow item model for unified AppKit outline"
  ```

---

## Task 2: `SidebarRowTree` — accounts + groups for one bucket

**Files:**
- Create: `Features/Navigation/AppKitSidebar/SidebarRowTree.swift`
- Create: `MoolahTests/Navigation/SidebarRowTreeTests.swift`

The tree builder takes store snapshots and emits a flat `[SidebarRow]` plus a `children(of:) -> [SidebarRow]?` lookup. Children of section headers are the rows in that section; children of group rows are member accounts; everything else is a leaf (`children(of:) == nil`).

Start with the accounts → bucket → group-or-account ordering — this is the most complex piece and reusing `Accounts.groupAwareSidebar(...)` gives us a tested entry-ordering primitive to delegate to.

- [ ] **Step 2.1: Write the failing test for one current account**

  Create `MoolahTests/Navigation/SidebarRowTreeTests.swift`:

  ```swift
  import Testing
  import Foundation
  @testable import Moolah

  @Suite("SidebarRowTree — accounts")
  struct SidebarRowTreeAccountsTests {
    @Test("One current bank account: section header + one account leaf")
    func singleCurrentAccount() {
      let account = Account(
        name: "Checking",
        type: .bank,
        bucket: .current,
        instrument: .AUD,
        position: 0)
      let tree = SidebarRowTree.build(
        accounts: Accounts(ordered: [account]),
        groups: [],
        earmarks: [],
        currentTotal: nil,
        investmentTotal: nil,
        earmarkedTotal: nil,
        netWorth: nil,
        showHidden: false,
        unreviewedBadgeCount: 0)

      #expect(tree.roots.contains(.section(.current)))
      #expect(tree.children(of: .section(.current)) == [.account(account.id)])
      #expect(tree.children(of: .account(account.id)) == nil)
    }
  }
  ```

- [ ] **Step 2.2: Run the test — confirm compile failure**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarRowTreeAccountsTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-output.txt"
  ```

  Expected: `cannot find 'SidebarRowTree' in scope`.

- [ ] **Step 2.3: Create the minimal builder + test fixtures**

  Create `Features/Navigation/AppKitSidebar/SidebarRowTree.swift`:

  ```swift
  import Foundation

  /// Pure, side-effect-free transformation from store snapshots to the
  /// sidebar's `[SidebarRow]` tree. The single source of truth for which
  /// rows the macOS sidebar shows and in what order. Consumed by
  /// `SidebarOutlineController` to drive `NSOutlineView`'s data source.
  ///
  /// Returns a `Result` value with `roots: [SidebarRow]` (the source-list
  /// group headers) and a `children(of:) -> [SidebarRow]?` lookup. `nil`
  /// children means leaf; `[]` means expandable-but-empty (rare —
  /// expandable groups with no current members render as leaves in this
  /// codebase so the disclosure triangle does not flash).
  enum SidebarRowTree {
    struct Result: Sendable {
      let roots: [SidebarRow]
      private let childMap: [SidebarRow: [SidebarRow]]

      init(roots: [SidebarRow], childMap: [SidebarRow: [SidebarRow]]) {
        self.roots = roots
        self.childMap = childMap
      }

      func children(of row: SidebarRow) -> [SidebarRow]? {
        childMap[row]
      }
    }

    static func build(
      accounts: Accounts,
      groups: [AccountGroup],
      earmarks: [Earmark],
      currentTotal: InstrumentAmount?,
      investmentTotal: InstrumentAmount?,
      earmarkedTotal: InstrumentAmount?,
      netWorth: InstrumentAmount?,
      showHidden: Bool,
      unreviewedBadgeCount: Int
    ) -> Result {
      let visibleAccounts = showHidden ? accounts : accounts.notHidden
      let grouped = visibleAccounts.groupAwareSidebar(groups: groups)

      var childMap: [SidebarRow: [SidebarRow]] = [:]
      childMap[.section(.current)] = grouped.current.map(Self.row(from:))
      // Earmarks, Investments, Totals, Navigation sections fleshed out
      // in subsequent tasks.

      for entry in grouped.current + grouped.investments {
        if case let .group(_, members) = entry {
          // `nil` would suppress the disclosure triangle — we want it
          // visible only when the group has at least one member, so a
          // member-less group is registered with no children entry at
          // all (falls through to `children(of:) == nil`, i.e. leaf).
          if !members.isEmpty {
            childMap[Self.row(from: entry)] = members.map { .account($0.id) }
          }
        }
      }

      let roots: [SidebarRow] = [.section(.current)]
      return Result(roots: roots, childMap: childMap)
    }

    private static func row(from entry: SidebarBucketEntry) -> SidebarRow {
      switch entry {
      case .account(let account): return .account(account.id)
      case .group(let group, _): return .group(group.id)
      }
    }
  }
  ```

- [ ] **Step 2.4: Run the test — confirm PASS**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarRowTreeAccountsTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-output.txt"
  ```

  Expected: 1/1 PASS.

- [ ] **Step 2.5: Add the rest of the account-section tests (red → green together, then commit)**

  Add to `SidebarRowTreeAccountsTests`:

  ```swift
  @Test("Investment account lands under .investments section, not .current")
  func investmentAccountRouted() {
    let account = Account(
      name: "Brokerage", type: .investment, bucket: .investments,
      instrument: .AUD, position: 0)
    let tree = SidebarRowTree.build(
      accounts: Accounts(ordered: [account]),
      groups: [], earmarks: [],
      currentTotal: nil, investmentTotal: nil,
      earmarkedTotal: nil, netWorth: nil,
      showHidden: false, unreviewedBadgeCount: 0)

    #expect(tree.children(of: .section(.current)) == [])
    #expect(tree.children(of: .section(.investments)) == [.account(account.id)])
  }

  @Test("Group with two members: group row + two child account rows")
  func groupWithMembers() {
    let groupId = UUID()
    let m1 = Account(name: "Cash", type: .bank, bucket: .current,
      instrument: .AUD, position: 0, groupId: groupId)
    let m2 = Account(name: "Savings", type: .bank, bucket: .current,
      instrument: .AUD, position: 1, groupId: groupId)
    let group = AccountGroup(id: groupId, name: "Trust",
      bucket: .current, instrument: .AUD, position: 0)
    let tree = SidebarRowTree.build(
      accounts: Accounts(ordered: [m1, m2]),
      groups: [group], earmarks: [],
      currentTotal: nil, investmentTotal: nil,
      earmarkedTotal: nil, netWorth: nil,
      showHidden: false, unreviewedBadgeCount: 0)

    #expect(tree.children(of: .section(.current)) == [.group(groupId)])
    #expect(tree.children(of: .group(groupId))
      == [.account(m1.id), .account(m2.id)])
  }

  @Test("Hidden account excluded when showHidden=false; included when true")
  func hiddenAccountFilter() {
    var hidden = Account(name: "Old", type: .bank, bucket: .current,
      instrument: .AUD, position: 0)
    hidden.isHidden = true
    let visible = Account(name: "Active", type: .bank, bucket: .current,
      instrument: .AUD, position: 1)
    let accounts = Accounts(ordered: [hidden, visible])

    let hidingTree = SidebarRowTree.build(
      accounts: accounts, groups: [], earmarks: [],
      currentTotal: nil, investmentTotal: nil,
      earmarkedTotal: nil, netWorth: nil,
      showHidden: false, unreviewedBadgeCount: 0)
    #expect(hidingTree.children(of: .section(.current)) == [.account(visible.id)])

    let showingTree = SidebarRowTree.build(
      accounts: accounts, groups: [], earmarks: [],
      currentTotal: nil, investmentTotal: nil,
      earmarkedTotal: nil, netWorth: nil,
      showHidden: true, unreviewedBadgeCount: 0)
    #expect(showingTree.children(of: .section(.current))
      == [.account(hidden.id), .account(visible.id)])
  }

  @Test("Empty group has children(of:) == nil — no disclosure triangle")
  func emptyGroupHasNoChildrenEntry() {
    let groupId = UUID()
    let group = AccountGroup(id: groupId, name: "Empty",
      bucket: .current, instrument: .AUD, position: 0)
    let tree = SidebarRowTree.build(
      accounts: Accounts(ordered: []), groups: [group],
      earmarks: [],
      currentTotal: nil, investmentTotal: nil,
      earmarkedTotal: nil, netWorth: nil,
      showHidden: false, unreviewedBadgeCount: 0)

    #expect(tree.children(of: .group(groupId)) == nil)
  }
  ```

  Extend `SidebarRowTree.build` so each test passes:

  - Add `.section(.investments)` to `roots` with the investments-bucket entries as children.
  - The hidden-filter case is already handled by the `Accounts.notHidden` projection.
  - The empty-group case is already handled by the `if !members.isEmpty` guard.

  Run:

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarRowTreeAccountsTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-output.txt"
  ```

  Expected: 4/4 PASS.

- [ ] **Step 2.6: Format + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarRowTree.swift MoolahTests/Navigation/SidebarRowTreeTests.swift project.yml
  git -C "$WORKTREE" commit -m "feat(sidebar): SidebarRowTree builds Current/Investments sections"
  ```

---

## Task 3: `SidebarRowTree` — earmarks, totals, navigation

**Files:**
- Modify: `Features/Navigation/AppKitSidebar/SidebarRowTree.swift`
- Modify: `MoolahTests/Navigation/SidebarRowTreeTests.swift`

Extend the builder to emit the remaining three sections. Encode the visibility rules from today's `totalsSection`:

- `Current Total` always shown if `currentTotal != nil`.
- `Investment Total` always shown if `investmentTotal != nil`.
- `Earmarked Total` shown if any earmark exists.
- `Available Funds` shown only when both `currentTotal` and `earmarkedTotal` are non-nil **and** `earmarkedTotal.isPositive` (mirrors `SidebarView+Sections.swift:120`).
- `Net Worth` shown only when `netWorth != nil`.

Navigation rows always render in the same fixed order: `Analysis, Reports, Categories, Upcoming, RecentlyAdded, AllTransactions`.

- [ ] **Step 3.1: Write the failing earmarks-section test**

  Append to `SidebarRowTreeTests.swift`:

  ```swift
  @Suite("SidebarRowTree — earmarks")
  struct SidebarRowTreeEarmarksTests {
    @Test("Earmarks section lists earmarks in their incoming order")
    func earmarksOrder() {
      let e1 = Earmark(name: "Holiday", instrument: .AUD)
      let e2 = Earmark(name: "Tax", instrument: .AUD)
      let tree = SidebarRowTree.build(
        accounts: Accounts(ordered: []), groups: [], earmarks: [e1, e2],
        currentTotal: nil, investmentTotal: nil,
        earmarkedTotal: nil, netWorth: nil,
        showHidden: false, unreviewedBadgeCount: 0)
      #expect(tree.children(of: .section(.earmarks))
        == [.earmark(e1.id), .earmark(e2.id)])
    }
  }
  ```

- [ ] **Step 3.2: Make it pass — extend the builder to populate `.section(.earmarks)` children**

  In `SidebarRowTree.build`, add:

  ```swift
  childMap[.section(.earmarks)] = earmarks.map { .earmark($0.id) }
  ```

  And add `.section(.earmarks)` to `roots` in the correct order: `[.section(.current), .section(.earmarks), .section(.investments), .section(.totals), .section(.navigation)]`.

  Run:

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarRowTreeEarmarksTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-output.txt"
  ```

  Expected: 1/1 PASS.

- [ ] **Step 3.3: Write + pass the totals-section visibility tests**

  Append:

  ```swift
  @Suite("SidebarRowTree — totals")
  struct SidebarRowTreeTotalsTests {
    private static let amount = InstrumentAmount(quantity: 100, instrument: .AUD)
    private static let earmarked = InstrumentAmount(quantity: 50, instrument: .AUD)

    @Test("Totals are absent when all summary values are nil")
    func nothingShown() {
      let tree = SidebarRowTree.build(
        accounts: Accounts(ordered: []), groups: [], earmarks: [],
        currentTotal: nil, investmentTotal: nil,
        earmarkedTotal: nil, netWorth: nil,
        showHidden: false, unreviewedBadgeCount: 0)
      #expect(tree.children(of: .section(.totals)) == [])
    }

    @Test("Current Total + Investment Total + Net Worth render when present")
    func basicTotals() {
      let tree = SidebarRowTree.build(
        accounts: Accounts(ordered: []), groups: [], earmarks: [],
        currentTotal: Self.amount, investmentTotal: Self.amount,
        earmarkedTotal: nil, netWorth: Self.amount,
        showHidden: false, unreviewedBadgeCount: 0)
      #expect(tree.children(of: .section(.totals)) == [
        .total(.currentTotal), .total(.investmentTotal), .total(.netWorth)
      ])
    }

    @Test("Available Funds appears only when both current+earmarked present and earmarked > 0")
    func availableFundsGating() {
      let withAvailable = SidebarRowTree.build(
        accounts: Accounts(ordered: []), groups: [], earmarks: [],
        currentTotal: Self.amount, investmentTotal: nil,
        earmarkedTotal: Self.earmarked, netWorth: nil,
        showHidden: false, unreviewedBadgeCount: 0)
      #expect(withAvailable.children(of: .section(.totals))?
        .contains(.total(.availableFunds)) == true)

      let zeroEarmark = SidebarRowTree.build(
        accounts: Accounts(ordered: []), groups: [], earmarks: [],
        currentTotal: Self.amount, investmentTotal: nil,
        earmarkedTotal: .zero(instrument: .AUD), netWorth: nil,
        showHidden: false, unreviewedBadgeCount: 0)
      #expect(zeroEarmark.children(of: .section(.totals))?
        .contains(.total(.availableFunds)) == false)
    }
  }
  ```

  Extend the builder's totals-population logic:

  ```swift
  var totals: [SidebarRow] = []
  if currentTotal != nil { totals.append(.total(.currentTotal)) }
  if investmentTotal != nil { totals.append(.total(.investmentTotal)) }
  if earmarkedTotal != nil { totals.append(.total(.earmarkedTotal)) }
  if let currentTotal, let earmarkedTotal, earmarkedTotal.isPositive {
    _ = currentTotal // referenced for clarity; row uses the live store value
    totals.append(.total(.availableFunds))
  }
  if netWorth != nil { totals.append(.total(.netWorth)) }
  childMap[.section(.totals)] = totals
  ```

  Run + verify:

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarRowTreeTotalsTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-output.txt"
  ```

  Expected: 3/3 PASS.

- [ ] **Step 3.4: Write + pass the navigation-section test**

  Append:

  ```swift
  @Suite("SidebarRowTree — navigation")
  struct SidebarRowTreeNavigationTests {
    @Test("Navigation children are the fixed-order set of nav kinds")
    func fixedOrder() {
      let tree = SidebarRowTree.build(
        accounts: Accounts(ordered: []), groups: [], earmarks: [],
        currentTotal: nil, investmentTotal: nil,
        earmarkedTotal: nil, netWorth: nil,
        showHidden: false, unreviewedBadgeCount: 5)
      #expect(tree.children(of: .section(.navigation)) == [
        .navigation(.analysis), .navigation(.reports),
        .navigation(.categories), .navigation(.upcoming),
        .navigation(.recentlyAdded), .navigation(.allTransactions)
      ])
    }
  }
  ```

  Extend the builder:

  ```swift
  childMap[.section(.navigation)] = [
    .navigation(.analysis), .navigation(.reports),
    .navigation(.categories), .navigation(.upcoming),
    .navigation(.recentlyAdded), .navigation(.allTransactions)
  ]
  ```

  Run + verify:

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarRowTreeNavigationTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-output.txt"
  ```

  Expected: 1/1 PASS.

- [ ] **Step 3.5: Format + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarRowTree.swift MoolahTests/Navigation/SidebarRowTreeTests.swift
  git -C "$WORKTREE" commit -m "feat(sidebar): SidebarRowTree adds Earmarks/Totals/Navigation sections"
  ```

---

## Task 4: Selection mapping (`SidebarRow` ↔ `SidebarSelection`)

**Files:**
- Modify: `Features/Navigation/AppKitSidebar/SidebarRow.swift`
- Create: `MoolahTests/Navigation/SidebarOutlineSelectionMappingTests.swift`

The outline's selection is a `SidebarRow?`; the parent's binding is `SidebarSelection?`. Build the bijection so non-selectable rows (sections, totals) map to `nil` on the parent and `nil` on the parent maps to "no row selected" on the outline.

- [ ] **Step 4.1: Write the failing test**

  Create `MoolahTests/Navigation/SidebarOutlineSelectionMappingTests.swift`:

  ```swift
  import Testing
  import Foundation
  @testable import Moolah

  @Suite("SidebarRow ↔ SidebarSelection mapping")
  struct SidebarOutlineSelectionMappingTests {
    @Test("Account row maps to .account selection and back")
    func accountRoundTrip() {
      let id = UUID()
      #expect(SidebarRow.account(id).asSelection == .account(id))
      #expect(SidebarRow(selection: .account(id)) == .account(id))
    }

    @Test("Section, total rows have no selection equivalent")
    func nonSelectableRows() {
      #expect(SidebarRow.section(.current).asSelection == nil)
      #expect(SidebarRow.total(.netWorth).asSelection == nil)
    }

    @Test("Nav selections map to nav rows")
    func navRoundTrip() {
      #expect(SidebarRow(selection: .analysis) == .navigation(.analysis))
      #expect(SidebarRow.navigation(.recentlyAdded).asSelection == .recentlyAdded)
    }
  }
  ```

- [ ] **Step 4.2: Run the test, confirm it fails**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarOutlineSelectionMappingTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-output.txt"
  ```

  Expected: `value of type 'SidebarRow' has no member 'asSelection'`.

- [ ] **Step 4.3: Add the mapping methods to `SidebarRow`**

  Append in `SidebarRow.swift`:

  ```swift
  extension SidebarRow {
    /// The parent `SidebarSelection?` value that corresponds to this
    /// row, or `nil` if the row is non-selectable (sections, totals).
    var asSelection: SidebarSelection? {
      switch self {
      case .section, .total: return nil
      case .account(let id): return .account(id)
      case .group(let id): return .group(id)
      case .earmark(let id): return .earmark(id)
      case .navigation(.analysis): return .analysis
      case .navigation(.reports): return .reports
      case .navigation(.categories): return .categories
      case .navigation(.upcoming): return .upcomingTransactions
      case .navigation(.recentlyAdded): return .recentlyAdded
      case .navigation(.allTransactions): return .allTransactions
      }
    }

    /// The `SidebarRow` that corresponds to the given selection, or
    /// `nil` if no row represents this selection (currently exhaustive
    /// — every `SidebarSelection` case has a row).
    init?(selection: SidebarSelection) {
      switch selection {
      case .account(let id): self = .account(id)
      case .group(let id): self = .group(id)
      case .earmark(let id): self = .earmark(id)
      case .analysis: self = .navigation(.analysis)
      case .reports: self = .navigation(.reports)
      case .categories: self = .navigation(.categories)
      case .upcomingTransactions: self = .navigation(.upcoming)
      case .recentlyAdded: self = .navigation(.recentlyAdded)
      case .allTransactions: self = .navigation(.allTransactions)
      }
    }
  }
  ```

  Run + verify:

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarOutlineSelectionMappingTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-output.txt"
  ```

  Expected: 3/3 PASS.

- [ ] **Step 4.4: Format + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarRow.swift MoolahTests/Navigation/SidebarOutlineSelectionMappingTests.swift
  git -C "$WORKTREE" commit -m "feat(sidebar): SidebarRow ↔ SidebarSelection mapping"
  ```

---

## Task 5: Expansion mapping (`Set<SidebarRow>` ↔ `GroupUIStateStore`)

**Files:**
- Create: `Features/Navigation/AppKitSidebar/SidebarOutlineExpansion.swift`
- Create: `MoolahTests/Navigation/SidebarOutlineExpansionMappingTests.swift`

The outline tracks expansion as a `Set<SidebarRow>`. The store tracks expansion as a `Set<UUID>` of group ids — only `.group(_)` rows persist. Section headers always render expanded by default but their expand state is local-only (no persistence — sections do not collapse).

The mapping is one-way translation `Set<UUID> → Set<SidebarRow>` plus a writeback that filters out non-group rows so toggling a section never tries to persist.

- [ ] **Step 5.1: Write the failing test**

  Create `MoolahTests/Navigation/SidebarOutlineExpansionMappingTests.swift`:

  ```swift
  import Testing
  import Foundation
  @testable import Moolah

  @Suite("Sidebar expansion mapping")
  struct SidebarOutlineExpansionMappingTests {
    @Test("expandedRows lifts a set of group UUIDs to .group rows")
    func liftToRows() {
      let g1 = UUID()
      let g2 = UUID()
      let rows = SidebarOutlineExpansion.rows(for: [g1, g2])
      #expect(rows == [.group(g1), .group(g2)])
    }

    @Test("groupIds filters non-group rows out")
    func filterRows() {
      let g = UUID()
      let mixed: Set<SidebarRow> = [
        .group(g), .section(.current), .account(UUID())
      ]
      #expect(SidebarOutlineExpansion.groupIds(in: mixed) == [g])
    }
  }
  ```

- [ ] **Step 5.2: Make it fail, create the type, re-run, verify pass**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarOutlineExpansionMappingTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-output.txt"
  ```

  Expected: compile error.

  Create `Features/Navigation/AppKitSidebar/SidebarOutlineExpansion.swift`:

  ```swift
  import Foundation

  /// Pure, side-effect-free translation between the outline view's
  /// per-row expansion `Set<SidebarRow>` and the persisted group
  /// expansion `Set<UUID>` owned by `GroupUIStateStore`. Section
  /// headers always render expanded by default and never persist their
  /// state, so the only rows that survive a round trip are `.group(_)`.
  enum SidebarOutlineExpansion {
    static func rows(for groupIds: Set<UUID>) -> Set<SidebarRow> {
      Set(groupIds.map(SidebarRow.group))
    }

    static func groupIds(in rows: Set<SidebarRow>) -> Set<UUID> {
      Set(rows.compactMap { row in
        guard case .group(let id) = row else { return nil }
        return id
      })
    }
  }
  ```

  Run + verify:

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarOutlineExpansionMappingTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-output.txt"
  ```

  Expected: 2/2 PASS.

- [ ] **Step 5.3: Format + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarOutlineExpansion.swift MoolahTests/Navigation/SidebarOutlineExpansionMappingTests.swift project.yml
  git -C "$WORKTREE" commit -m "feat(sidebar): expansion-state mapping helpers"
  ```

---

## Task 6: Cell views — total + navigation (the only genuinely new SwiftUI)

**Files:**
- Create: `Features/Navigation/AppKitSidebar/Cells/SidebarTotalRowView.swift`
- Create: `Features/Navigation/AppKitSidebar/Cells/SidebarNavigationRowView.swift`

Two small SwiftUI views matching the existing `totalRow(label:value:)` and `navigationSection` row builders in `SidebarView+Sections.swift`. They keep the visuals identical to today; the AppKit cell layer wraps them.

- [ ] **Step 6.1: Create `SidebarTotalRowView`**

  ```swift
  import SwiftUI

  /// Sidebar total row used inside the macOS outline. Mirrors the
  /// `totalRow(label:value:)` builder used by the iOS list path so both
  /// platforms render totals identically.
  struct SidebarTotalRowView: View {
    let label: String
    let amount: InstrumentAmount?
    var emphasised: Bool = false

    var body: some View {
      LabeledContent(label) {
        if let amount {
          InstrumentAmountView(amount: amount)
        } else {
          ProgressView().controlSize(.small)
        }
      }
      .foregroundStyle(emphasised ? .primary : .secondary)
      .font(emphasised ? .headline : .callout)
    }
  }

  #Preview {
    List {
      SidebarTotalRowView(
        label: "Current Total",
        amount: InstrumentAmount(quantity: 1234.56, instrument: .AUD))
      SidebarTotalRowView(
        label: "Net Worth",
        amount: InstrumentAmount(quantity: 50000, instrument: .AUD),
        emphasised: true)
      SidebarTotalRowView(label: "Loading", amount: nil)
    }
    .listStyle(.sidebar)
    .frame(width: 260)
  }
  ```

- [ ] **Step 6.2: Create `SidebarNavigationRowView`**

  ```swift
  import SwiftUI

  /// Sidebar navigation row used inside the macOS outline. Mirrors the
  /// `NavigationLink(value:) { Label(...) }` rows in `navigationSection`
  /// in `SidebarView+Sections.swift`.
  struct SidebarNavigationRowView: View {
    let title: String
    let systemImage: String
    var badgeCount: Int = 0

    var body: some View {
      HStack {
        Label(title, systemImage: systemImage)
        Spacer()
        if badgeCount > 0 {
          Text("\(badgeCount)")
            .font(.caption)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel("\(badgeCount) recently imported need review")
        }
      }
    }
  }

  #Preview {
    List {
      SidebarNavigationRowView(title: "Analysis", systemImage: "chart.bar.xaxis")
      SidebarNavigationRowView(
        title: "Recently Added", systemImage: "tray.full", badgeCount: 3)
    }
    .listStyle(.sidebar)
    .frame(width: 260)
  }
  ```

- [ ] **Step 6.3: Format + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/Cells/SidebarTotalRowView.swift Features/Navigation/AppKitSidebar/Cells/SidebarNavigationRowView.swift project.yml
  git -C "$WORKTREE" commit -m "feat(sidebar): SwiftUI cells for total and navigation rows"
  ```

  No tests at this step — the cells are thin declarative wrappers and the previews are the design surface. Verify visually in the worktree's Xcode preview canvas before committing.

---

## Task 7: Section-header cell (with `+` action)

**Files:**
- Create: `Features/Navigation/AppKitSidebar/Cells/SidebarSectionHeaderRowView.swift`

The section-header cell renders a small-caps secondary-style title plus an optional trailing `+` button. The `+` button identifiers (`UITestIdentifiers.Sidebar.newAccountButton`, `newEarmarkButton`) move from the toolbar/inline header to here on macOS so existing tests keep resolving. Verify this is what the UI tests actually expect; if the toolbar buttons own those identifiers today, leave the section header without `+` buttons and rely on the toolbar.

- [ ] **Step 7.1: Check where the test identifiers attach today**

  ```bash
  grep -rn "newAccountButton\|newEarmarkButton" "$WORKTREE/Features" "$WORKTREE/MoolahUITests_macOS"
  ```

  If they appear on toolbar buttons (likely — `SidebarSharedModifiers.swift`), the section header keeps no `+` button on macOS. Move on.

  If they appear on inline header `+` buttons, replicate them in the new section header cell.

- [ ] **Step 7.2: Create the cell view (with `+` button conditional on bucket)**

  ```swift
  import SwiftUI

  /// Source-list section header used inside the macOS outline. Renders
  /// the section title in the standard uppercased secondary style.
  /// `onAddAction` shows a trailing "+" button when non-nil — used for
  /// Current Accounts (new account) and Earmarks (new earmark) when the
  /// section-level `+` is wanted alongside the toolbar buttons.
  struct SidebarSectionHeaderRowView: View {
    let title: String
    var onAddAction: (() -> Void)?
    var addAccessibilityIdentifier: String?

    var body: some View {
      HStack {
        Text(title)
          .font(.subheadline)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
        Spacer()
        if let onAddAction {
          Button(action: onAddAction) {
            Image(systemName: "plus").font(.caption)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(addAccessibilityIdentifier ?? "")
          .accessibilityLabel("Add \(title.lowercased())")
        }
      }
    }
  }

  #Preview {
    List {
      Section {
        Text("Row")
      } header: {
        SidebarSectionHeaderRowView(title: "Current Accounts", onAddAction: {})
      }
    }
    .listStyle(.sidebar)
    .frame(width: 260)
  }
  ```

- [ ] **Step 7.3: Format + commit**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/Cells/SidebarSectionHeaderRowView.swift project.yml
  git -C "$WORKTREE" commit -m "feat(sidebar): section header cell view for AppKit outline"
  ```

---

## Task 8: Cell factory — `SidebarRowFactory`

**Files:**
- Create: `Features/Navigation/AppKitSidebar/Cells/SidebarRowFactory.swift`

A single dispatch point from `SidebarRow → NSTableCellView`. Centralises the `NSHostingView`-wrapping and accessibility-identifier wiring. Consumed only by `SidebarOutlineDelegate`.

The factory carries dependencies (stores, bindings, action closures) so the delegate doesn't need them itself.

- [ ] **Step 8.1: Create the factory**

  ```swift
  import AppKit
  import SwiftUI

  /// Builds the `NSTableCellView` for each `SidebarRow`. Single dispatch
  /// point so `SidebarOutlineDelegate` stays focused on outline-protocol
  /// glue rather than cell construction. All cells are
  /// `NSHostingView`-wrapped SwiftUI content; the wrapping helper
  /// `NSTableCellView.hosting(...)` already handles padding, accessibility
  /// identifier attachment, and per-cell context menu.
  @MainActor
  struct SidebarRowFactory {
    let accountStore: AccountStore
    let accountGroupStore: AccountGroupStore
    let earmarkStore: EarmarkStore
    let importStore: ImportStore
    let convertedCurrentTotal: () -> InstrumentAmount?
    let convertedInvestmentTotal: () -> InstrumentAmount?
    let convertedEarmarkedTotal: () -> InstrumentAmount?
    let convertedNetWorth: () -> InstrumentAmount?
    let availableFunds: () -> InstrumentAmount?
    let selectionBinding: Binding<SidebarSelection?>
    let accountToEditBinding: Binding<Account?>
    let onAddAccount: () -> Void
    let onAddEarmark: () -> Void

    func makeCell(for row: SidebarRow) -> NSTableCellView {
      switch row {
      case .section(let kind): return sectionCell(kind: kind)
      case .account(let id): return accountCell(id: id)
      case .group(let id): return groupCell(id: id)
      case .earmark(let id): return earmarkCell(id: id)
      case .total(let kind): return totalCell(kind: kind)
      case .navigation(let kind): return navigationCell(kind: kind)
      }
    }

    private func sectionCell(kind: SidebarRow.SectionKind) -> NSTableCellView {
      let title = sectionTitle(for: kind)
      let onAdd: (() -> Void)? = {
        switch kind {
        case .current: return onAddAccount
        case .earmarks: return onAddEarmark
        case .investments, .totals, .navigation: return nil
        }
      }()
      let addId: String? = {
        switch kind {
        case .current: return UITestIdentifiers.Sidebar.newAccountButton
        case .earmarks: return UITestIdentifiers.Sidebar.newEarmarkButton
        case .investments, .totals, .navigation: return nil
        }
      }()
      return NSTableCellView.hosting {
        SidebarSectionHeaderRowView(
          title: title,
          onAddAction: onAdd,
          addAccessibilityIdentifier: addId)
      }
    }

    private func sectionTitle(for kind: SidebarRow.SectionKind) -> String {
      switch kind {
      case .current: return "Current Accounts"
      case .earmarks: return "Earmarks"
      case .investments: return "Investments"
      case .totals: return ""
      case .navigation: return ""
      }
    }

    private func accountCell(id: UUID) -> NSTableCellView {
      guard let account = accountStore.accounts.by(id: id) else {
        return NSTableCellView()
      }
      let selection = selectionBinding
      let accountToEdit = accountToEditBinding
      let menu = SidebarContextMenuBuilder.accountMenu(
        accountId: id, accountStore: accountStore,
        selection: selection, accountToEdit: accountToEdit)
      return NSTableCellView.hosting(
        accessibilityIdentifier: UITestIdentifiers.Sidebar.account(id),
        menu: menu
      ) {
        AccountSidebarRow(
          account: account,
          isSelected: selection.wrappedValue == .account(id),
          isMember: account.groupId != nil)
          .environment(accountStore)
      }
    }

    private func groupCell(id: UUID) -> NSTableCellView {
      guard let group = accountGroupStore.by(id: id) else {
        return NSTableCellView()
      }
      let memberIds = accountStore.accounts.ordered
        .filter { $0.groupId == id }
        .sorted { $0.position < $1.position }
        .map(\.id)
      let isSelected = selectionBinding.wrappedValue == .group(id)
      return NSTableCellView.hosting(
        accessibilityIdentifier: UITestIdentifiers.Sidebar.group(id)
      ) {
        GroupAggregateBalanceLoader(
          memberIds: memberIds,
          targetInstrument: group.instrument
        ) { balance in
          AccountGroupSidebarRow(
            group: group, isSelected: isSelected,
            isExpanded: .constant(false),
            aggregateBalance: balance,
            showChevron: false)
        }
        .environment(accountStore)
      }
    }

    private func earmarkCell(id: UUID) -> NSTableCellView {
      guard let earmark = earmarkStore.earmarks.by(id: id) else {
        return NSTableCellView()
      }
      let isSelected = selectionBinding.wrappedValue == .earmark(id)
      return NSTableCellView.hosting {
        EarmarkRowView(earmark: earmark, isSelected: isSelected)
          .environment(earmarkStore)
      }
    }

    private func totalCell(kind: SidebarRow.TotalKind) -> NSTableCellView {
      let label: String
      let value: InstrumentAmount?
      var emphasised = false
      switch kind {
      case .currentTotal:
        label = "Current Total"; value = convertedCurrentTotal()
      case .investmentTotal:
        label = "Investment Total"; value = convertedInvestmentTotal()
      case .earmarkedTotal:
        label = "Earmarked Total"; value = convertedEarmarkedTotal()
      case .availableFunds:
        label = "Available Funds"; value = availableFunds(); emphasised = true
      case .netWorth:
        label = "Net Worth"; value = convertedNetWorth(); emphasised = true
      }
      return NSTableCellView.hosting {
        SidebarTotalRowView(label: label, amount: value, emphasised: emphasised)
      }
    }

    private func navigationCell(kind: SidebarRow.NavigationKind) -> NSTableCellView {
      let (title, icon, badge, idSuffix): (String, String, Int, String) = {
        switch kind {
        case .analysis: return ("Analysis", "chart.bar.xaxis", 0, "analysis")
        case .reports: return ("Reports", "chart.bar.fill", 0, "reports")
        case .categories: return ("Categories", "tag", 0, "categories")
        case .upcoming: return ("Upcoming", "calendar", 0, "upcoming")
        case .recentlyAdded:
          return ("Recently Added", "tray.full",
            importStore.unreviewedBadgeCount, "recentlyAdded")
        case .allTransactions:
          return ("All Transactions", "list.bullet", 0, "allTransactions")
        }
      }()
      return NSTableCellView.hosting(
        accessibilityIdentifier: UITestIdentifiers.Sidebar.view(idSuffix)
      ) {
        SidebarNavigationRowView(title: title, systemImage: icon, badgeCount: badge)
      }
    }
  }
  ```

- [ ] **Step 8.2: Create the context-menu builder used above**

  Create `Features/Navigation/AppKitSidebar/SidebarContextMenuBuilder.swift`:

  ```swift
  import AppKit
  import SwiftUI

  /// Builds the AppKit `NSMenu` for a sidebar account row's right-click
  /// menu. Mirrors `SidebarOutlineView.makeAccountContextMenu(for:)`
  /// (the file deleted by this rewrite) — kept here so the rewrite keeps
  /// the same identifiers + action shape and the `CellMenuActions`
  /// lifetime trick stays in one place.
  enum SidebarContextMenuBuilder {
    @MainActor
    static func accountMenu(
      accountId: UUID,
      accountStore: AccountStore,
      selection: Binding<SidebarSelection?>,
      accountToEdit: Binding<Account?>
    ) -> NSMenu {
      let actions = CellMenuActions(
        onEdit: {
          guard let fresh = accountStore.accounts.by(id: accountId) else { return }
          accountToEdit.wrappedValue = fresh
        },
        onViewTransactions: {
          selection.wrappedValue = .account(accountId)
        })
      let menu = NSMenu()
      let edit = NSMenuItem(
        title: "Edit Account\u{2026}",
        action: #selector(CellMenuActions.editAction(_:)),
        keyEquivalent: "")
      edit.target = actions
      edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
      edit.setAccessibilityIdentifier(UITestIdentifiers.Sidebar.editAccountContextMenuItem)
      menu.addItem(edit)
      let view = NSMenuItem(
        title: "View Transactions",
        action: #selector(CellMenuActions.viewTransactionsAction(_:)),
        keyEquivalent: "")
      view.target = actions
      view.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
      menu.addItem(view)
      objc_setAssociatedObject(menu, &cellActionsKey, actions, .OBJC_ASSOCIATION_RETAIN)
      return menu
    }
  }

  nonisolated(unsafe) private var cellActionsKey: UInt8 = 0

  @MainActor
  private final class CellMenuActions: NSObject {
    private let onEdit: () -> Void
    private let onViewTransactions: () -> Void

    init(onEdit: @escaping () -> Void, onViewTransactions: @escaping () -> Void) {
      self.onEdit = onEdit
      self.onViewTransactions = onViewTransactions
    }

    @objc func editAction(_ sender: Any?) { onEdit() }
    @objc func viewTransactionsAction(_ sender: Any?) { onViewTransactions() }
  }
  ```

- [ ] **Step 8.3: Build to verify it compiles**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  ```

  Expected: builds cleanly. No tests run yet — the factory is exercised end-to-end through the outline in Task 10.

- [ ] **Step 8.4: Commit**

  ```bash
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/Cells/SidebarRowFactory.swift Features/Navigation/AppKitSidebar/SidebarContextMenuBuilder.swift project.yml
  git -C "$WORKTREE" commit -m "feat(sidebar): cell factory + context-menu builder for AppKit outline"
  ```

---

## Task 9: `SidebarOutlineDataSource` + `SidebarOutlineDelegate`

**Files:**
- Create: `Features/Navigation/AppKitSidebar/SidebarOutlineDataSource.swift`
- Create: `Features/Navigation/AppKitSidebar/SidebarOutlineDelegate.swift`

These hold the `NSOutlineViewDataSource` and `NSOutlineViewDelegate` conformances. The data source reads from a `SidebarRowTree.Result` snapshot; the delegate hosts a `SidebarRowFactory` and an `onExpansionChanged` callback.

- [ ] **Step 9.1: Create the data source**

  ```swift
  import AppKit

  /// `NSOutlineViewDataSource` for the unified sidebar. Reads a
  /// `SidebarRowTree.Result` snapshot — child counts and child items
  /// come from `children(of:)`; root items come from `roots`.
  ///
  /// `NSOutlineView` hands its data-source / delegate `item: Any?` values
  /// that originated from one of our `child(_:ofItem:)` returns. We use
  /// `SidebarRow` directly as that `Any` payload — `Hashable` + value
  /// equality is enough; the outline does not need a class identity.
  @MainActor
  final class SidebarOutlineDataSource: NSObject, NSOutlineViewDataSource {
    var tree: SidebarRowTree.Result = .empty

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
      guard let row = item as? SidebarRow else { return tree.roots.count }
      return tree.children(of: row)?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
      guard let row = item as? SidebarRow else { return tree.roots[index] }
      return (tree.children(of: row) ?? [])[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
      guard let row = item as? SidebarRow else { return false }
      return tree.children(of: row) != nil
    }
  }

  extension SidebarRowTree.Result {
    static var empty: SidebarRowTree.Result {
      SidebarRowTree.Result(roots: [], childMap: [:])
    }
  }
  ```

  The `init(roots:childMap:)` on `Result` was made `internal` in Task 2 — confirm visibility allows `extension SidebarRowTree.Result` to see it. If not, expose a static `empty` directly from `SidebarRowTree.swift`.

- [ ] **Step 9.2: Create the delegate**

  ```swift
  import AppKit

  /// `NSOutlineViewDelegate` for the unified sidebar. Produces cell
  /// views via `SidebarRowFactory`, gates selection (sections and
  /// totals are non-selectable), emits expand/collapse events to the
  /// caller via `expansionChanged`, and emits selection-changed events
  /// via `selectionChanged`.
  @MainActor
  final class SidebarOutlineDelegate: NSObject, NSOutlineViewDelegate {
    var factory: SidebarRowFactory?
    var selectionChanged: ((SidebarRow?) -> Void)?
    var expansionChanged: ((SidebarRow, Bool) -> Void)?
    var suppressExpansionCallbacks = false

    func outlineView(
      _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
      guard let row = item as? SidebarRow else { return nil }
      return factory?.makeCell(for: row)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
      guard let row = item as? SidebarRow else { return false }
      if case .section = row { return true }
      return false
    }

    func outlineView(
      _ outlineView: NSOutlineView, shouldSelectItem item: Any
    ) -> Bool {
      guard let row = item as? SidebarRow else { return false }
      switch row {
      case .section, .total: return false
      case .account, .group, .earmark, .navigation: return true
      }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
      guard let outlineView = notification.object as? NSOutlineView else { return }
      let row = outlineView.item(atRow: outlineView.selectedRow) as? SidebarRow
      selectionChanged?(row)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
      guard !suppressExpansionCallbacks,
            let row = notification.userInfo?["NSObject"] as? SidebarRow else { return }
      expansionChanged?(row, true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
      guard !suppressExpansionCallbacks,
            let row = notification.userInfo?["NSObject"] as? SidebarRow else { return }
      expansionChanged?(row, false)
    }
  }
  ```

- [ ] **Step 9.3: Build to verify**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  ```

  Expected: builds cleanly. If `SidebarRowTree.Result.empty` extension fails for access reasons, hoist `empty` into `SidebarRowTree.swift` as `extension SidebarRowTree.Result { static let empty = ... }` and delete the extension in the data source.

- [ ] **Step 9.4: Commit**

  ```bash
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarOutlineDataSource.swift Features/Navigation/AppKitSidebar/SidebarOutlineDelegate.swift project.yml
  git -C "$WORKTREE" commit -m "feat(sidebar): NSOutlineView data source + delegate"
  ```

---

## Task 10: `SidebarOutlineController` — owns `NSOutlineView` + `NSScrollView`

**Files:**
- Create: `Features/Navigation/AppKitSidebar/SidebarOutlineController.swift`

The controller owns the outline view's lifecycle, configures it with source-list style + transparent backgrounds, holds a reference to the delegate / data source, and exposes `apply(tree:expanded:)` for the representable's `updateNSViewController` to invoke.

- [ ] **Step 10.1: Create the controller**

  ```swift
  import AppKit

  /// `NSViewController` owning the single `NSOutlineView` that drives
  /// the entire macOS sidebar. The outline lives inside an
  /// `NSScrollView`; the scroll view fills the controller's view via
  /// auto-layout so the sidebar gets a single, full-bleed scrollbar
  /// (replacing the per-section scrollbars from the earlier
  /// `SidebarOutlineView` design).
  @MainActor
  final class SidebarOutlineController: NSViewController {
    let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    let dataSource = SidebarOutlineDataSource()
    let delegate = SidebarOutlineDelegate()

    override func loadView() {
      view = NSView()
      configureOutlineView()
      configureScrollView()
      installScrollView()
    }

    private func configureOutlineView() {
      outlineView.style = .sourceList
      outlineView.selectionHighlightStyle = .sourceList
      outlineView.headerView = nil
      outlineView.autoresizesOutlineColumn = false
      outlineView.usesAutomaticRowHeights = true
      outlineView.floatsGroupRows = true
      outlineView.allowsMultipleSelection = false
      outlineView.allowsEmptySelection = true
      outlineView.intercellSpacing = NSSize(width: 0, height: 0)
      let column = NSTableColumn()
      column.resizingMask = .autoresizingMask
      outlineView.addTableColumn(column)
      outlineView.outlineTableColumn = column
      outlineView.dataSource = dataSource
      outlineView.delegate = delegate
    }

    private func configureScrollView() {
      scrollView.documentView = outlineView
      scrollView.hasVerticalScroller = true
      scrollView.hasHorizontalScroller = false
      scrollView.drawsBackground = false
      scrollView.backgroundColor = .clear
      scrollView.contentView.drawsBackground = false
      if let clip = scrollView.contentView as NSClipView? {
        clip.backgroundColor = .clear
      }
      scrollView.scrollerStyle = .overlay
    }

    private func installScrollView() {
      scrollView.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(scrollView)
      NSLayoutConstraint.activate([
        scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        scrollView.topAnchor.constraint(equalTo: view.topAnchor),
        scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
    }

    /// Replaces the current tree, reloads, and reconciles expansion +
    /// selection. Called by `SidebarOutline.updateNSViewController` on
    /// every SwiftUI update — the snapshot includes the freshly built
    /// `SidebarRowTree.Result`, the set of expanded group ids, and the
    /// current selection.
    func apply(
      tree: SidebarRowTree.Result,
      expandedGroupIds: Set<UUID>,
      selection: SidebarSelection?
    ) {
      dataSource.tree = tree
      outlineView.reloadData()

      // Sections always render expanded — they are never collapsible
      // by the user (we don't mark them as expandable), but we expand
      // them once after a reload so children show.
      for root in tree.roots {
        outlineView.expandItem(root)
      }

      // Reconcile group expansion.
      delegate.suppressExpansionCallbacks = true
      defer { delegate.suppressExpansionCallbacks = false }
      for root in tree.roots {
        guard let children = tree.children(of: root) else { continue }
        for child in children {
          guard case .group(let id) = child else { continue }
          if expandedGroupIds.contains(id) {
            outlineView.expandItem(child)
          } else {
            outlineView.collapseItem(child)
          }
        }
      }

      // Reconcile selection.
      if let selection, let row = SidebarRow(selection: selection) {
        let index = outlineView.row(forItem: row)
        if index >= 0 {
          outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
          outlineView.deselectAll(nil)
        }
      } else {
        outlineView.deselectAll(nil)
      }
    }
  }
  ```

- [ ] **Step 10.2: Build to verify**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  ```

  Expected: builds cleanly.

- [ ] **Step 10.3: Commit**

  ```bash
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarOutlineController.swift project.yml
  git -C "$WORKTREE" commit -m "feat(sidebar): NSOutlineView controller — source-list style, full-bleed"
  ```

---

## Task 11: `SidebarOutline` — the `NSViewControllerRepresentable`

**Files:**
- Create: `Features/Navigation/AppKitSidebar/SidebarOutline.swift`

The bridge from SwiftUI to the controller. Takes all the inputs (stores, bindings, totals, selection) and produces / updates a `SidebarOutlineController`. Builds the `SidebarRowTree.Result` and the `SidebarRowFactory` on each SwiftUI update.

- [ ] **Step 11.1: Create the representable**

  ```swift
  import SwiftUI

  /// SwiftUI bridge to `SidebarOutlineController`. Owned by the macOS
  /// body of `SidebarView`. Rebuilds the row tree + cell factory on
  /// every SwiftUI update; passes both into the controller for diffing
  /// against `NSOutlineView`.
  struct SidebarOutline: NSViewControllerRepresentable {
    @ObservedObject private var observers = Observers()
    let accountStore: AccountStore
    let accountGroupStore: AccountGroupStore
    let earmarkStore: EarmarkStore
    let importStore: ImportStore
    let groupUIStateStore: GroupUIStateStore
    @Binding var selection: SidebarSelection?
    @Binding var accountToEdit: Account?
    let onAddAccount: () -> Void
    let onAddEarmark: () -> Void
    let showHidden: Bool

    func makeNSViewController(context: Context) -> SidebarOutlineController {
      let controller = SidebarOutlineController()
      controller.delegate.selectionChanged = { row in
        selection = row?.asSelection
      }
      controller.delegate.expansionChanged = { row, isExpanded in
        guard case .group(let id) = row else { return }
        Task { await groupUIStateStore.setExpanded(isExpanded, for: id) }
      }
      return controller
    }

    func updateNSViewController(
      _ controller: SidebarOutlineController, context: Context
    ) {
      let tree = SidebarRowTree.build(
        accounts: accountStore.accounts,
        groups: accountGroupStore.groups,
        earmarks: earmarkStore.visibleEarmarks,
        currentTotal: accountStore.convertedCurrentTotal,
        investmentTotal: accountStore.convertedInvestmentTotal,
        earmarkedTotal: earmarkStore.convertedTotalBalance,
        netWorth: accountStore.convertedNetWorth,
        showHidden: showHidden,
        unreviewedBadgeCount: importStore.unreviewedBadgeCount)

      let factory = SidebarRowFactory(
        accountStore: accountStore,
        accountGroupStore: accountGroupStore,
        earmarkStore: earmarkStore,
        importStore: importStore,
        convertedCurrentTotal: { accountStore.convertedCurrentTotal },
        convertedInvestmentTotal: { accountStore.convertedInvestmentTotal },
        convertedEarmarkedTotal: { earmarkStore.convertedTotalBalance },
        convertedNetWorth: { accountStore.convertedNetWorth },
        availableFunds: {
          guard let current = accountStore.convertedCurrentTotal,
                let earmarked = earmarkStore.convertedTotalBalance else { return nil }
          return current - earmarked
        },
        selectionBinding: $selection,
        accountToEditBinding: $accountToEdit,
        onAddAccount: onAddAccount,
        onAddEarmark: onAddEarmark)
      controller.delegate.factory = factory

      controller.apply(
        tree: tree,
        expandedGroupIds: groupUIStateStore.expandedGroupIds,
        selection: selection)
    }

    /// `ObservableObject` purely to give the representable a place to
    /// hang any future per-instance subscriptions. Empty today.
    @MainActor
    final class Observers: ObservableObject {}
  }
  ```

- [ ] **Step 11.2: Build to verify the bridge compiles**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  ```

  Expected: builds cleanly. If `@ObservedObject private var observers = Observers()` triggers a warning about never being read, replace with an underscored ignore in `body` of the representable or delete the observer (it's a placeholder for Phase 2 drag-drop subscriptions).

- [ ] **Step 11.3: Commit**

  ```bash
  git -C "$WORKTREE" add Features/Navigation/AppKitSidebar/SidebarOutline.swift project.yml
  git -C "$WORKTREE" commit -m "feat(sidebar): SidebarOutline NSViewControllerRepresentable bridge"
  ```

---

## Task 12: Swap `SidebarView.macSidebarBody` to use `SidebarOutline`

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`

Collapse the macOS body. The iOS body and all `@Environment` plumbing stay; only the macOS branch of `body` changes.

- [ ] **Step 12.1: Replace `macSidebarBody`**

  In `SidebarView.swift`, replace the existing `macSidebarBody` with:

  ```swift
  #if os(macOS)
    var macSidebarBody: some View {
      SidebarOutline(
        accountStore: accountStore,
        accountGroupStore: accountGroupStore,
        earmarkStore: earmarkStore,
        importStore: importStore,
        groupUIStateStore: groupUIStateStore,
        selection: $selection,
        accountToEdit: $accountToEdit,
        onAddAccount: { showCreateAccountSheet = true },
        onAddEarmark: { showCreateEarmarkSheet = true },
        showHidden: showHidden)
        .modifier(sharedBodyModifiers)
    }
  #endif
  ```

- [ ] **Step 12.2: Build the app and launch it**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" run-mac
  ```

  Visually verify (no automated test catches this) every acceptance criterion in the "Functional acceptance criteria" section near the top of this plan. In particular:
  - One scrollbar for the whole sidebar (or none, if it fits).
  - No opaque background bands behind the account list.
  - Icon column and balance column align between Earmarks, Current Accounts, Investments.
  - Clicking an account selects it; clicking the disclosure triangle on a group expands it; reopening the app preserves expansion.
  - Right-click an account → "Edit Account…" opens the edit sheet.
  - Selecting Analysis / Reports / Categories / Upcoming / Recently Added / All Transactions all navigate.

  If any of the above fails, stop and report — do not proceed to Task 13 until the rendering matches iOS.

- [ ] **Step 12.3: Commit**

  ```bash
  git -C "$WORKTREE" add Features/Navigation/SidebarView.swift
  git -C "$WORKTREE" commit -m "feat(sidebar): macOS body uses unified SidebarOutline"
  ```

---

## Task 13: Run the macOS test suite — fix regressions

**Files:**
- Modify: as needed.

- [ ] **Step 13.1: Run the macOS unit + UI test suite**

  ```bash
  mkdir -p "$WORKTREE/.agent-tmp"
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac 2>&1 | tee "$WORKTREE/.agent-tmp/test-mac.txt"
  ```

  Per `reference_macos_test_runner_hang.md`, if the runner hangs "before establishing connection", `pkill -f Moolah` to clear stale test-host / xctest processes from other worktrees and re-run.

  Look for failures with:

  ```bash
  grep -i 'failed\|error:' "$WORKTREE/.agent-tmp/test-mac.txt"
  ```

- [ ] **Step 13.2: Triage each failure**

  Expected failure classes:
  - `SidebarOutlineViewTests` / `SidebarOutlineItemTests` — these test types that are about to be deleted; skip them with a `@available` gate or comment-out the suite, then delete in Task 14.
  - Tests that resolve sidebar rows via accessibility identifiers — these should pass unchanged. If one fails, the cell isn't applying the identifier correctly; trace through `SidebarRowFactory` and confirm `NSTableCellView.hosting(accessibilityIdentifier:)` is called with the right id.
  - Tests that drive the context menu — same identifier rule. The context menu's `editAccountContextMenuItem` identifier must be set on the `NSMenuItem`.

  Fix until the suite goes green. Commit each fix as a small commit.

- [ ] **Step 13.3: Run `just format-check`**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  ```

  Expected: PASS. Per `feedback_swiftlint_fix_not_baseline.md`, do not bump SwiftLint thresholds; if a violation appears, fix it (split a type, shorten a function, etc.).

- [ ] **Step 13.4: Commit any test or format fixes**

  ```bash
  git -C "$WORKTREE" status
  # commit each logical fix separately
  ```

---

## Task 14: Delete the old sidebar outline + vendored package

**Files:**
- Delete: `Features/Navigation/SidebarOutlineView.swift`
- Delete: `Features/Navigation/SidebarOutlineItem.swift`
- Delete: `MoolahTests/Navigation/SidebarOutlineViewTests.swift`
- Delete: `MoolahTests/Navigation/SidebarOutlineItemTests.swift`
- Delete: `Vendored/OutlineView/` (entire directory)
- Possibly already gone (if the foundation PR merged before this one): `Features/Navigation/SidebarOutlineDropReceiver.swift` and its conformance tests. See Step 14.0.
- Modify: `project.yml` — remove the `Vendored/OutlineView` source group and the `OutlineView` package dependency if listed.
- Modify: `Features/Navigation/SidebarView+Sections.swift` — drop dead macOS-only section builders.
- Modify: `Features/Navigation/SidebarView+Groups.swift` — drop dead macOS-only group helpers.
- Modify: `Features/Navigation/SidebarView+Previews.swift` — replace the macOS preview with one that exercises `SidebarOutline`.

- [ ] **Step 14.0: Check which deletion targets still exist (rebase-defensive)**

  Per the Coordination section, the foundation PR may merge before this one. If it did, it already removed `SidebarOutlineDropReceiver.swift` and its conformance tests; this plan's deletion sweep should skip them rather than trying to `git rm` files that no longer exist.

  ```bash
  for path in \
    Features/Navigation/SidebarOutlineView.swift \
    Features/Navigation/SidebarOutlineItem.swift \
    MoolahTests/Navigation/SidebarOutlineViewTests.swift \
    MoolahTests/Navigation/SidebarOutlineItemTests.swift \
    Vendored/OutlineView; do
    if [ -e "$WORKTREE/$path" ]; then
      echo "TO DELETE: $path"
    else
      echo "ALREADY GONE: $path"
    fi
  done
  ```

  Use the resulting list to build the actual `git rm` commands in Step 14.1. If `Vendored/OutlineView/` is already gone (foundation PR also removed it — unlikely; the foundation plan does not delete the vendored package, only the receiver class), skip that line. The vendored package directory is this plan's responsibility regardless.

- [ ] **Step 14.1: Delete the obsolete files (per Step 14.0's list)**

  ```bash
  # Only include lines for paths that Step 14.0 reported as "TO DELETE".
  git -C "$WORKTREE" rm Features/Navigation/SidebarOutlineView.swift Features/Navigation/SidebarOutlineItem.swift
  git -C "$WORKTREE" rm MoolahTests/Navigation/SidebarOutlineViewTests.swift MoolahTests/Navigation/SidebarOutlineItemTests.swift
  git -C "$WORKTREE" rm -r Vendored/OutlineView
  ```

- [ ] **Step 14.2: Edit `project.yml`**

  Remove the `Vendored/OutlineView` source group / file references. If an `OutlineView` package dependency was added in the earlier Phase 1 plan, remove it from `packages:` and any target `dependencies:` block. Regenerate:

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  ```

- [ ] **Step 14.3: Strip dead macOS-only branches from `SidebarView+Sections.swift` and `SidebarView+Groups.swift`**

  Open `SidebarView+Sections.swift` and remove the `#if os(macOS)` blocks for `currentAccountsSection`, `investmentsSection`, `totalsSection`, `navigationSection`, plus any helper builders that were only called from those branches. Keep the iOS variants and shared `addAccountAction` / `addEarmarkAction` helpers.

  Open `SidebarView+Groups.swift` and remove any macOS-only branches. The iOS-only `groupRowLink`, `memberRowLink`, `standaloneAccountRowLink`, `accountGroupSubmenu`, `expandBinding(for:)` remain.

- [ ] **Step 14.4: Replace the macOS preview in `SidebarView+Previews.swift`**

  Drop the previews that constructed the old `SidebarOutlineView`. Add:

  ```swift
  #if os(macOS)
  #Preview("macOS sidebar — unified outline") {
    let backend = PreviewBackend.create()
    // … instantiate the same store stack the existing iOS preview uses,
    // then render NavigationSplitView { SidebarView(selection: ...) }.
  }
  #endif
  ```

  (Pattern the preview after the iOS one already in the file; reuse the same backend + store wiring.)

- [ ] **Step 14.5: Build, test, format-check**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac 2>&1 | tee "$WORKTREE/.agent-tmp/test-mac.txt"
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  ```

  Expected: all green.

- [ ] **Step 14.6: Commit**

  ```bash
  git -C "$WORKTREE" add -A
  git -C "$WORKTREE" commit -m "chore(sidebar): delete obsolete outline path and vendored OutlineView"
  ```

---

## Task 15: Sub-agent review pass

- [ ] **Step 15.1: Run `@ui-review` on the new files**

  ```bash
  # In the worktree, invoke the ui-review agent against the new directory.
  ```

  Apply every Critical and Important finding. Per `feedback_apply_all_review_findings.md`, do not defer Minor findings without asking the user.

- [ ] **Step 15.2: Run `@concurrency-review` on the new files**

  Particularly check: `SidebarOutlineController`'s `apply(...)` is `@MainActor` (it is — the class is annotated); the `Task { await groupUIStateStore.setExpanded(...) }` fire-and-forget is acceptable because `setExpanded` is `async`-not-throwing and the store owns its own error handling; the `selectionChanged` and `expansionChanged` callbacks fire on the main thread (AppKit's standard contract).

- [ ] **Step 15.3: Run `@code-review` on the new files**

  Address any naming / extension organisation / thin-view findings.

- [ ] **Step 15.4: Commit fixes (one per logical change)**

---

## Task 16: Open the PR

- [ ] **Step 16.1: Push the branch with the explicit `<src>:<dst>` form**

  Per `CLAUDE.md` "Stacked-PR worktrees" — even though this branch is off `main` not a stacked PR, the explicit src:dst form keeps it unambiguous:

  ```bash
  git -C "$WORKTREE" push origin sidebar-unified-appkit:sidebar-unified-appkit
  ```

- [ ] **Step 16.2: Open the PR**

  ```bash
  gh pr create --title "Unified macOS sidebar over single NSOutlineView" --body "$(cat <<'EOF'
  ## Summary

  - Replaces the hybrid SwiftUI `List(.sidebar)` + embedded NSOutlineView macOS sidebar with a single full-bleed `NSOutlineView`.
  - Fixes the rendering regressions from the earlier Phase 1 work: per-section opaque background bands, per-section vertical scrollbars, left/right inset mismatch between sections, fixed-height `computedHeight(for:)` hack.
  - iOS body unchanged.

  ## Non-goals (follow-up plans)

  - Drag-and-drop (Phase 2; closes #991).
  - Inline rename on macOS (Phase 3).

  ## Test plan

  - [ ] `just test-mac` passes
  - [ ] `just format-check` passes
  - [ ] App launches; sidebar renders with one scrollbar, consistent insets, no background bands
  - [ ] Right-click account → "Edit Account…" opens edit sheet
  - [ ] Group expand state persists across relaunch
  - [ ] All `MoolahUITests_macOS` sidebar drivers (selection, navigation, context menu) green
  EOF
  )"
  ```

- [ ] **Step 16.3: Enable automerge**

  Per `feedback_prs_to_merge_queue.md`, invoke the landing-prs skill:

  ```
  # via /landing-prs or `gh pr merge --auto --rebase`
  ```

  Per `feedback_pr_ci_gate_when_ui_host_blocked.md`, if the local UI host is wedged, gate on the PR's CI (UI Test job) before merging — overrides the straight-to-queue default for that case.

---

## Self-review checklist

Before invoking `superpowers:subagent-driven-development` on this plan, run through:

**Spec coverage:** Does every acceptance criterion in the "Functional acceptance criteria" section map to a task?
- Single scrollbar / no background bands / consistent insets → Tasks 10–12 (controller + representable + visual verification in 12.2).
- All five sections render with correct order / content → Tasks 2–3 (tree builder) + Task 8 (cell factory).
- Selection round-trip for all `SidebarSelection` cases → Task 4 (mapping) + Task 9 (delegate) + Task 11 (binding wiring).
- Group expand persistence → Task 5 (mapping) + Task 11 (wiring to `GroupUIStateStore`).
- Account context menu → Task 8 (`SidebarContextMenuBuilder`).
- Section-header `+` buttons → Task 7 + Task 8 (factory) — gated on Step 7.1 confirming where identifiers currently attach.
- All test identifiers preserved → Task 8 (factory wires identifiers from `UITestIdentifiers.Sidebar.*`).
- `just format-check` / `just build-mac` / `just test-mac` green → Tasks 13–14 explicitly verify, and per `feedback_format_check_per_plan_step.md` every commit step includes `format-check`.

**Type consistency:** `SidebarRow`, `SidebarRowTree.Result`, `SidebarRowFactory`, `SidebarOutlineDataSource`, `SidebarOutlineDelegate`, `SidebarOutlineController`, `SidebarOutline` — same names referenced across tasks.

**Placeholder scan:** No "TBD" / "implement later" — every step has either runnable code or an explicit verification check.

**Branch protection:** Plan creates a worktree before touching code (Step 0.1). All commits go onto `sidebar-unified-appkit`, not `main`.

---

## Plan complete

Saved to `plans/2026-05-27-sidebar-unified-appkit-plan.md`.

Two execution options:

1. **Subagent-Driven (recommended, per project default)** — fresh subagent per task; review between tasks; fast iteration.
2. **Inline Execution** — execute in this session with checkpoints.

Per project memory `feedback_subagent_driven.md`, the default is option 1 — do not ask, just dispatch.
