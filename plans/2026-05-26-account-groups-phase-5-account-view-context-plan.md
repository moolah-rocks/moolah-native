# Account Groups — Phase 5 Implementation Plan: `AccountViewContext` + detail view

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Initial-version plan.** Written before Phase 4 lands on main. The detail-view file layout (`InvestmentAccountView`, `StandardAccountView`) is likely to evolve. Verify at execution time which view types still exist and update the file lists accordingly. The *seam* this plan introduces (`AccountViewContext`) is stable; the *which-view-binds-to-it* part is the part to recheck.

**Goal:** Single detail view, single query shape — selecting either an `Account` or an `AccountGroup` in the sidebar produces the same rendering surface. The detail view binds to an `AccountViewContext` value built by the sidebar's selection logic; everything downstream (header, chart, positions, transactions, sync status) treats the context's `accountIds: [UUID]` set as the source of truth and never knows whether it came from one account or a group.

**Architecture:** New `AccountViewContext` value type abstracts "what's selected and what does the detail view render". A new `AccountViewContextBuilder` (lives on `AccountStore` or as a free function) resolves `SidebarSelection → AccountViewContext`. Existing detail view (`InvestmentAccountView` and `StandardAccountView`) is refactored to consume the context rather than reading `Account` directly. A new `AggregatedSyncStatus` value collapses N per-member sync states into one. Group selection produces a context with `accountIds = members`; single-account selection produces a 1-element list — the same code path serves both.

**Tech Stack:** SwiftUI, Swift Testing.

**Spec:** `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-groups-design/plans/2026-05-26-account-groups-design.md` — see "Composite detail view".

**Phase ordering:** Depends on **Phase 3** (`AccountGroup`) AND **Phase 4** (`SidebarSelection.group` case + `AccountGroupStore`). Independent of Phases 6 / 7 / 8 (Phase 6 builds on top of the context shape this phase introduces — but Phase 5 ships without it; descriptions stay account-centric until Phase 6).

---

## Worktree setup

- [ ] Base off whichever of Phase 3 / Phase 4 merges later (or `origin/main` if both have merged). Worktree at `.worktrees/account-view-context`. Generate Xcode project.

---

## Task 1: Define `AccountViewContext`

**Files:**
- Create: `Features/Accounts/Models/AccountViewContext.swift`
- Create: `MoolahTests/Features/AccountViewContextTests.swift`

```swift
import Foundation

/// What the detail view renders. Built from `SidebarSelection`; the
/// detail view binds to this rather than reading `Account` directly.
/// Selecting a group produces a context with N member ids; selecting
/// a single account produces a 1-element list. Same code path either
/// way.
struct AccountViewContext: Sendable, Equatable {
  enum Kind: Sendable, Equatable { case account, group }

  let kind: Kind
  let displayName: String
  /// The instrument the detail view displays totals in. For accounts
  /// this is the account's `instrument`; for groups it's the group's
  /// `instrument` (defaults to the profile's currency in Phase 3).
  let displayInstrument: Instrument
  /// The bucket the entity lives in. Drives any UI affordances that
  /// differ across buckets (e.g. valuation-mode toggle only shows for
  /// `.investments`).
  let bucket: AccountBucket
  /// The set of accounts whose data the detail view aggregates over.
  /// Single account → `[account.id]`. Group → member ids.
  /// **Order is preserved** so the "first account in this context"
  /// (e.g. default for the New-Transaction button) is deterministic.
  let accountIds: [UUID]
  /// Aggregated sync status across `accountIds`. A 1-element input
  /// collapses to the underlying per-account status unchanged.
  let syncStatus: AggregatedSyncStatus

  /// True when this context represents a single account that is
  /// itself synced (crypto / exchange) — used to gate per-account
  /// sync-config UI (retry button, last-sync indicator) that doesn't
  /// make sense for groups.
  var supportsPerAccountSyncControls: Bool {
    if case .account = kind, accountIds.count == 1 { return true }
    return false
  }
}
```

Add an `AggregatedSyncStatus` enum (separate file or in the same):

```swift
enum AggregatedSyncStatus: Sendable, Equatable {
  case allSynced
  case syncing(done: Int, total: Int)
  case failed(memberIds: [UUID])

  /// Collapses an array of per-member statuses to a single aggregate.
  /// 1-element input returns the original (`.allSynced` if synced,
  /// `.syncing(0,1)` if in progress, etc.) — same path serves single-
  /// account headers.
  static func aggregate(_ statuses: [AccountSyncStatus]) -> AggregatedSyncStatus {
    if statuses.isEmpty { return .allSynced }
    let failed = statuses.compactMap { /* extract member ids of failed accounts */ }
    if !failed.isEmpty { return .failed(memberIds: failed) }
    let pending = statuses.filter { $0.isInProgress }.count
    if pending > 0 { return .syncing(done: statuses.count - pending, total: statuses.count) }
    return .allSynced
  }
}
```

The exact shape of `AccountSyncStatus` already exists in the codebase (search `AccountSyncStatus` to find its declaration); the aggregator is a pure function over it.

Tests:
- `accountIds.count == 1, kind == .account` collapses correctly.
- `accountIds.count > 1, kind == .group` produces the expected shape.
- `supportsPerAccountSyncControls` is true only for single-account.
- `AggregatedSyncStatus.aggregate(_:)` for: all-synced, one failed, all in-progress, mix.

---

## Task 2: Selection → context builder

**Files:**
- Modify: `Features/Accounts/AccountStore.swift` (add `func viewContext(for: SidebarSelection) -> AccountViewContext?`), or
- Create: `Features/Accounts/AccountViewContextBuilder.swift` (free function / namespace)
- Tests: `MoolahTests/Features/AccountViewContextBuilderTests.swift`

The builder is a pure function over `(SidebarSelection, Accounts, [AccountGroup], per-account sync states)` → `AccountViewContext?` (nil for selections that don't render a detail view: `.allTransactions`, `.reports`, etc.).

```swift
enum AccountViewContextBuilder {
  static func build(
    for selection: SidebarSelection,
    accounts: Accounts,
    groups: [AccountGroup],
    syncStatuses: [UUID: AccountSyncStatus]
  ) -> AccountViewContext? {
    switch selection {
    case .account(let id):
      guard let account = accounts.by(id: id) else { return nil }
      return AccountViewContext(
        kind: .account,
        displayName: account.name,
        displayInstrument: account.instrument,
        bucket: account.bucket,
        accountIds: [account.id],
        syncStatus: AggregatedSyncStatus.aggregate([syncStatuses[account.id]].compactMap { $0 })
      )
    case .group(let id):
      guard let group = groups.first(where: { $0.id == id }) else { return nil }
      let members = accounts.ordered
        .filter { $0.groupId == group.id }
        .sorted(by: { $0.position < $1.position })
      let memberStatuses = members.compactMap { syncStatuses[$0.id] }
      return AccountViewContext(
        kind: .group,
        displayName: group.name,
        displayInstrument: group.instrument,
        bucket: group.bucket,
        accountIds: members.map(\.id),
        syncStatus: AggregatedSyncStatus.aggregate(memberStatuses)
      )
    case .earmark, .recentlyAdded, .allTransactions, .upcomingTransactions,
         .categories, .reports, .analysis:
      return nil
    }
  }
}
```

Tests cover:
- Account selection → 1-element `accountIds`, kind `.account`.
- Group selection → N-element `accountIds` ordered by member position.
- Group selection with 0 members (transient state during creation) → context with empty `accountIds` (the view renders a "no members" state — Phase 4's "1-member groups allowed" rule prevents this in normal use).
- Unknown id returns nil.
- Earmark selection returns nil (earmarks have their own detail view; out of scope here).

---

## Task 3: Refactor the detail view to bind to `AccountViewContext`

**Files:**
- Modify: `Features/Investments/Views/InvestmentAccountView.swift` (and any sibling files for current accounts)
- Modify: `Features/Accounts/Views/StandardAccountView.swift`
- Modify: the parent view that selects detail view by type (search for where these are constructed)
- Tests: existing detail-view tests (if any) — verify still pass; add coverage if not present

Strategy: introduce the context binding at the parent view (the one that picks `InvestmentAccountView` vs `StandardAccountView` by `Account.bucket`). For the group case, route to the same view that currently handles `investmentAccounts` (since both real user groups are investment-bucket; current-bucket groups are supported by the model but rare in practice).

The detail view's `var body` currently reads `account.name`, `account.instrument`, etc. Replace with `viewContext.displayName`, `viewContext.displayInstrument`, etc. The header, chart, and positions table become context-driven.

For the positions table and transactions list, the query shape already takes a set (or trivially converts):

```swift
// Old:
let positions = accountStore.positions(for: account.id)
// New:
let positions = accountStore.positions(for: viewContext.accountIds)
```

Verify each downstream query supports the set shape. If a query is hard-coded for a single id, refactor it to take `Set<UUID>` (or `[UUID]`).

**No Add Transaction button changes in this PR — Phase 6 covers the "defaults to first account in context" behaviour. For this PR, the New Transaction button defaults to `accountIds.first` (so it works for groups; for single-account it's still the account).**

**No description-rendering changes** — TransactionRowView still receives `viewingAccountId: UUID?` from the detail view; for a group context, pass `nil` (the rows render with the no-context description style). Phase 6 generalises this with a per-row computation.

---

## Task 4: Wire `SidebarView` to construct the context on selection

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`
- Modify: the parent / NavigationStack / split-view container that holds the detail view

Currently `SidebarView` binds `selection: Binding<SidebarSelection?>` to the parent. Add a sibling derived value:

```swift
var detailContext: AccountViewContext? {
  guard let selection else { return nil }
  return AccountViewContextBuilder.build(
    for: selection,
    accounts: accountStore.accounts,
    groups: groupStore.groups,
    syncStatuses: accountStore.syncStatuses)
}
```

…and pass `detailContext` into the detail view. If the parent constructs the detail view via a `NavigationDestination` modifier, the destination closure becomes:

```swift
.navigationDestination(for: SidebarSelection.self) { selection in
  if let context = AccountViewContextBuilder.build(for: selection, ...) {
    AccountDetailView(context: context)   // unified entry point
  } else {
    // Earmark / Reports / etc. — existing routes
  }
}
```

Introduce a new umbrella `AccountDetailView` if neither `InvestmentAccountView` nor `StandardAccountView` reads from the context naturally — its only job is to switch on `context.bucket` and route to the right sub-view. Bucket = `.investments` → InvestmentAccountView; bucket = `.current` → StandardAccountView.

---

## Task 5: Aggregated balance + conversion-failure UX in the header

**Files:**
- Modify: detail-view header (wherever the balance card lives — search for `convertedCurrentTotal` / `convertedInvestmentTotal` usage near the header)
- Modify: `AccountStore` to expose a per-context balance: `func aggregateBalance(for accountIds: [UUID]) -> InstrumentAmount?`

Per `[[feedback_conversion_failure_ux]]`: if any member's conversion failed, the aggregate is marked **unavailable** (nil), never partial-summed. The header renders an "unavailable" badge in that case. Clicking the badge opens a popover listing which members failed (Phase 4-style affordance; can be a simple alert in this PR if popovers feel heavy).

Tests:
- 3 members all converted → sum.
- 3 members, 1 conversion failed → nil (badge).
- 1-member context, account converted → its converted balance.
- 1-member context, account's conversion failed → nil.

---

## Task 6: Wire `aggregateBalance` into `AccountGroupSidebarRow`

**Files:**
- Modify: `Features/Navigation/SidebarView.swift` (the `groupRow` builder added by Phase 4)
- Modify: `Features/Accounts/Views/AccountGroupSidebarRow.swift` (the row created in Phase 4 — wire its `aggregateBalance` parameter)

Phase 4 left `aggregateBalance: nil` (placeholder ProgressView). Replace with:

```swift
let memberIds = members.map(\.id)
let balance = accountStore.aggregateBalance(for: memberIds)
AccountGroupSidebarRow(group: group, ..., aggregateBalance: balance, ...)
```

Conversion-failure UX in the sidebar: if `aggregateBalance` is nil, the row shows a small badge / dimmed amount slot — same treatment used by single-account rows when their conversion fails.

---

## Task 7: Final verify + open PR

- [ ] `just test` (existing detail-view tests + new context / aggregation tests).
- [ ] Manual verification: select an account → unchanged rendering; select a group → composite rendering with summed positions, merged transactions, group name in header.
- [ ] `just format-check`; push; PR; auto-merge.

---

## Acceptance criteria for Phase 5

- `AccountViewContext` value type exists with `accountIds: [UUID]`, `displayName`, `displayInstrument`, `bucket`, `syncStatus`.
- `AggregatedSyncStatus` aggregates per-member statuses; 1-element input collapses to original.
- `AccountViewContextBuilder.build(for:...)` resolves `SidebarSelection → AccountViewContext?`.
- Detail view binds to context (header, chart, positions, transactions all read from context).
- Group selection renders composite detail view via the same view code as a single-account selection.
- Aggregate balance respects conversion-failure UX (unavailable, never partial-sum).
- `AccountGroupSidebarRow` shows the aggregate balance via the same store path.
- Per-account sync controls (retry, last-sync) are gated to single-account contexts.
- New Transaction button on a group context defaults to first member in `accountIds`.
- Full `just test`; `just format-check`.

---

## What's NOT in this phase

- **Phase 6** — `accountContext`-based transaction description rendering (in this phase, group view passes `viewingAccountId: nil` and uses today's no-context style).
- **Phase 8** — `isExpandedInSidebar` persistence (still in-memory).
- Per-account sync-status surfacing on the composite header (an inline list of failed members in the badge popover) — basic "1 member failed" + alert is the v1 surface; the rich popover can be a follow-up if user testing shows the alert isn't enough.
