# Account Groups — Design

**Date:** 2026-05-26
**Status:** Design approved; implementation plan pending.

## Problem

A real user case: two crypto "accounts" that are each conceptually one
thing but are technically several. "Trust Fund Crypto" is the same wallet
on Ethereum + Optimism plus a Coinstash exchange account. "Personal
Crypto" is 7-10 wallet accounts across chains (largely airdrop dust) plus
several exchanges used over the years.

Both currently use the legacy manual-valuation `AccountType.crypto`
because the existing model has no way to express "these N synced things
are one account to me." The user reconciles balances against external
crypto reporting sites and then types the total in.

The mental unit is "Trust Fund Crypto" / "Personal Crypto." The
per-chain, per-exchange decomposition is plumbing.

## Goals

- Reduce sidebar clutter so the conceptual unit ("Trust Fund Crypto") is
  one row, not 3-10.
- Preserve drill-down into individual member accounts for reconciliation
  against external sources (Zerion, DeBank, exchange dashboards).
- Generalise the grouping concept to all bucket types so it can serve
  beyond crypto (e.g. "Joint Accounts" combining bank + credit card).
- Make the bucket of a group explicit, queryable from a single field,
  and bug-resistant: no derivation from member majority, no parallel
  ways to compute "is this in Investments."
- Keep sync, schema, and report queries simple — groups should not
  require special-cased code at every aggregation site.

## Non-goals (v1)

- Cross-bucket groups (e.g. mixing a bank account with a crypto
  wallet in one group).
- User-defined buckets, or per-account bucket override. The model is
  designed to accommodate them later; no UI in v1.
- Group-aware reports / forecasts / analysis cards (these stay
  account-level).
- Group-aware account pickers (e.g. transaction-creation account
  picker still selects an individual `Account`).
- A migration wizard or any automatic conversion of existing
  manual-valuation accounts. Migration is user-driven with the
  existing primitives.
- Synced sidebar expand/collapse state (intentionally local-only).
- Group hiding (`isHidden`) — to remove a group from the sidebar,
  remove its members.
- An "Ungroup" or "Delete Group" action — same reason.

## Overview

A new `AccountGroup` entity sits alongside `Account`. It carries name,
ordering, instrument (for display), and an explicit `bucket`.
Membership is stored as a back-reference on `Account` (`groupId: UUID?`)
to avoid CloudKit list-update conflicts and to keep sync-ordering
robust.

In the sidebar, a group renders as a single row inside its bucket
section, optionally expandable to reveal members. Selecting a group
shows the same single-account detail view, driven by a new
`AccountViewContext` that abstracts "selection" into a list of account
ids plus display metadata. The detail view, chart, positions table,
and transactions list don't branch on "is this a group" — they consume
the context.

`AccountType.isInvestmentLike` is replaced everywhere by `.bucket ==
.investments`. Bucket becomes a first-class concept exposed on both
`Account` (derived from `type`) and `AccountGroup` (stored).

## Model

```swift
enum AccountBucket: String, Codable, Sendable, CaseIterable {
  case current      // bank, credit card, manual asset
  case investments  // investment, crypto, exchange
  // Designed for future extension: .savings, .retirement, .liabilities, …
  // Long-term: could become a value type referencing a user-defined bucket.
}

extension AccountType {
  var bucket: AccountBucket {
    switch self {
    case .bank, .creditCard, .asset: return .current
    case .investment, .crypto, .exchange: return .investments
    }
  }
}

struct AccountGroup: Identifiable, Sendable, Codable, Hashable {
  let id: UUID
  var name: String
  var bucket: AccountBucket        // explicit, set at creation, immutable in v1
  var instrument: Instrument       // display instrument (= profile currency in v1)
  var position: Int                // ordering within bucket section
  var isExpandedInSidebar: Bool    // local-only, not synced
}

struct Account {
  // …existing fields…
  var groupId: UUID?               // NEW: nil = standalone; UUID = member
  // `position` semantics extended:
  //   - groupId == nil → ordering within bucket section
  //     (sorted alongside non-grouped accounts and groups)
  //   - groupId != nil → ordering within group
}
```

Both `Account` and `AccountGroup` expose `var bucket: AccountBucket`. On
`Account` it stays computed from `type`; on `AccountGroup` it is stored.
Same accessor name lets call sites avoid branching on "what kind of
entity is this".

`AccountType.isInvestmentLike` is **removed** in the same PR that
introduces `bucket`. No deprecated forwarder — one API only.

### Membership invariants

- Member of at most one group: enforced by `Account.groupId` being a
  single value.
- Same-bucket constraint: enforced at the *creation/move* layer (drop
  rules, "Group ▸" submenu), not the model. The DB happily stores
  cross-bucket membership; the UI doesn't permit it.
- Empty groups auto-delete: when the last member is removed, the
  `AccountGroup` row is deleted in the same transaction.
- 1-member groups are allowed.
- No nesting: groups cannot contain groups.

### Future extensibility hooks

These do not require work now; the shape is intentional:

1. **Per-account bucket override:** add `var bucketOverride: AccountBucket?`
   to `Account`; `.bucket` becomes `bucketOverride ?? type.bucket`.
   Additive migration.
2. **User-defined buckets:** replace the `AccountBucket` enum with a
   value type holding a stable key (built-in raw value or UUID for
   user-defined) and display metadata. Stored field shape unchanged.
3. **Editable group bucket:** add UI to mutate `AccountGroup.bucket`.
   Field is already mutable in code; just needs an inspector.

## Sidebar UX

### Rendering

A bucket section sorts its top-level entries — standalone accounts and
groups — together by `position`. Each group is a single row with the
aggregated balance. When `isExpandedInSidebar` is true, the group row
is followed by its members indented underneath, sorted by member
`position`. Member rows show a secondary-text identifier (chain /
address / exchange provider) below the name.

```
▾ Investments
    Vanguard ETF                  $12,400
  ▸ Trust Fund Crypto             $42,180     ← default: collapsed
  ▾ Personal Crypto               $8,920      ← user-expanded
      ETH/OP wallet · 0x7a…3f      $5,210
      Polygon wallet · 0x7a…3f       $410
      Coinstash                    $1,950
      Binance (old)                $1,350
    Vanguard Super                $98,200
```

### Drop semantics

| Drag target                                          | Operation                            | Drop indicator                     |
|------------------------------------------------------|--------------------------------------|------------------------------------|
| Middle 50% of an account row                         | Drop-on (group / add to group)       | Full-row highlight                 |
| Middle 50% of a group row (account being dragged)    | Add account to that group            | Full-row highlight                 |
| Middle 50% of a group row (group being dragged)      | Rejected (no nesting)                | None (cursor reverts)              |
| Top/bottom 25% of a row, or in a gap                 | Reorder (insert at that position)    | Horizontal accent insertion line   |
| Empty space at end of a bucket section               | Reorder to end of section            | Insertion line below last row      |
| Any cross-bucket target                              | Rejected                             | None (cursor reverts)              |

### Creating a group

Two paths only, both end with the group in inline rename mode:

1. **Drag an account onto another account (same bucket):** new group
   `"New Group"` containing both. Enters rename mode immediately with
   `"New Group"` pre-selected for overtyping.
2. **Right-click an account → "Group ▸" submenu:**
   - `[names of existing groups in this bucket]` — moves the account
     into that group
   - `─────────`
   - `New Group…` — creates a single-member group containing this
     account; enters rename mode immediately
   - When the account is already in a group, also shows
     `Remove from Group` at the bottom; the current group is omitted
     from the move list.

No global "New Group" toolbar action; no creation dialog.

### Inline rename — applied across sidebar entity types

To keep editing modes consistent, inline rename (the same row
component) is used for **all** sidebar entities:

- Account rows
- Earmark rows
- Group rows

Entering rename mode: double-click the row's label, right-click →
**Rename**, or Return while the row is selected. Commit on Return /
Tab / click-outside. Cancel on Escape. Empty name on commit reverts
silently. The existing Edit Account / Edit Earmark dialogs remain for
other field edits; rename gains a faster path.

Building inline rename for the three row types is a small prerequisite
PR that lands before the group feature, so existing rename behaviour
is unchanged during rollout.

### Member rows

Selecting a member opens the standard single-account detail view —
unchanged. This is the reconciliation path: to check a specific wallet
against an external site, the user expands the group in the sidebar
and clicks the member.

Member drag operations:
- Drag onto another account in same bucket → joins that account's
  group, or creates a new group with it. Source group auto-deletes if
  it becomes empty.
- Drag into a gap inside the same bucket section, outside the group →
  leaves the group, becomes a standalone account at that position.
- Cross-bucket drag → rejected.

### Right-click menu summary

| Entity type | Menu items                                                                 |
|-------------|----------------------------------------------------------------------------|
| Account     | Rename, Group ▸ submenu, (existing items: Edit, Hide, Delete, …)            |
| Group       | Rename, (no Hide, no Delete)                                                |
| Earmark     | Rename, (existing items)                                                    |

## Composite detail view

**Single view, single query shape.** No `GroupAccountView`. The existing
single-account detail view binds to an `AccountViewContext`:

```swift
struct AccountViewContext: Sendable {
  let displayName: String
  let displayInstrument: Instrument
  let accountIds: [UUID]                  // [account.id] OR group.members.map(\.id)
  let bucket: AccountBucket
  let syncStatus: AggregatedSyncStatus
  // …additional fields the header needs (e.g. whether to show valuation-mode toggle)
}
```

Sidebar selection → context. Single-account selection produces a
1-element `accountIds`; group selection produces N-element. Every query
already takes (or trivially refactors to) a set of accounts.

### Header

- `displayName`, rename inline (same component as sidebar).
- Aggregate balance in `displayInstrument`, monospaced.
- Conversion-status badge using existing rate-failure UX
  ([[feedback_conversion_failure_ux]]): if any member position's
  conversion fails, the whole aggregate is marked unavailable, never
  partial-summed. Clicking expands a breakdown of which member's
  position failed.
- Aggregated sync-status:
  - All synced → silent
  - In-progress → spinner + "Syncing 2 of 3"
  - Any failure → red dot + "1 member failed", clickable popover
    showing per-member state + a "Retry all" affordance
- For single-member contexts the aggregator collapses to the original
  per-account status — call sites don't branch.
- New Transaction button stays. Defaults to the first account in
  `accountIds`; transaction detail panel's account picker can change
  it.
- No valuation-mode toggle, no instrument changer, no Add Member
  button (membership is managed via sidebar drag / right-click), no
  Edit Group dialog.

### Chart

`InvestmentChartView` rebound to `accountIds`. Same conversion-failure
handling per data point.

### Positions table

Aggregated by `Instrument`, sorted by value descending — identical
rendering to the single-account case. No per-member breakdown,
disclosure column, or Source column in v1. Reconciliation is done by
selecting the individual member in the sidebar.

### Transactions list

Merged from `accountIds`, ordered by date. No per-row member chip
(the transaction detail panel already shows the account). No
member-filter dropdown (drill-down via sidebar only).

Internal transfers (between members within a group) are **shown**, not
hidden. Description rendering generalises per Section "Description
rendering & internal transfers" below.

## Description rendering & internal transfers

A single rendering function serves the single-account view, the group
view, and the all-accounts view:

```swift
func transactionDescription(
  _ tx: Transaction,
  accountContext: UUID?    // nil = no-context phrasing; UUID = perspective phrasing
) -> String
```

The view derives `accountContext` per row from the selection's
`accountIds`:

```swift
let inScope = tx.legs.map(\.accountId).filter { accountIds.contains($0) }
let accountContext: UUID? = inScope.count == 1 ? inScope.first : nil
```

- **Single-account view** — `accountIds = [a]`. Transaction is in the
  list because it touches `a`; `inScope.count == 1`. Context = `a`.
  Description reads "Transfer to *other_account*" — unchanged from
  today.
- **Group view, transaction touches one member** — context = that
  member. Description reads "Transfer to *external_account*" or
  "Transfer from *external_account*", phrased from the member's
  perspective.
- **Group view, transaction touches multiple members** — context =
  nil. Description reads "Transfer from *member_A* to *member_B*".
  Gas-cost legs render alongside, so a cross-chain bridge shows its
  bridge transfer plus the gas leg.
- **All-accounts view** — `accountIds = all`. Most multi-leg
  transactions have multiple in-scope legs → context = nil → no-context
  phrasing. Matches today.

This is why internal transfers can be shown without looking like
double-counting: the position sum is unchanged across the bridge, and
the description makes the cross-chain motion legible.

## Reports, aggregations, callsite sweep

### `isInvestmentLike` → `.bucket == .investments`

Affected files (production + tests):

- `Domain/Models/Account.swift` — replace `isInvestmentLike`; add
  `bucket` on `AccountType`.
- `Domain/Models/Accounts+SidebarOrdering.swift` — bucket grouping;
  also the place that learns to sort standalone accounts and groups
  together within a bucket.
- `Features/Accounts/AccountStore.swift` — bucket-based filtering.
- Tests: `AccountStoreMutationsTests`, `AccountTypeTests`,
  `AccountsSidebarOrderingTests`, `ExchangeAccountModelTests`.

Single PR, mechanical edits. Lands before the group feature so the
rest builds on top of `.bucket` consistently.

### Aggregation queries

Already set-shaped (positions, transactions, balance series take
`[UUID]`) or trivially refactorable. The store layer resolves the
selection → `AccountViewContext` → ids; downstream aggregation
functions never know whether the set came from an account or a group.
Cross-currency conversion follows
[[feedback_conversion_failure_ux]] — mark unavailable, never
partial-sum.

### Sidebar bucket totals

Unchanged in formula. Bucket header sums all accounts whose `.bucket
== thisBucket`. Groups don't introduce new balance sources; they
re-render the same underlying accounts. No double-count risk.

### Reports / Analysis cards

Stay account/category-level in v1. None of the existing cards
(`NetWorthGraphCard`, `CategoriesOverTimeCard`,
`IncomeExpenseTableCard`, `ExpenseBreakdownCard`, `UpcomingTransactionsCard`,
`CapitalGainsSummary`, `ReportsView`, `CategoryBalanceTable`) does
per-account rollups that would change with groups. If a future card
does per-account breakdowns, that is the moment to add a
"by group" toggle.

### Account pickers

Stay account-level. A transaction lands on a single account; offering
a group would be misleading. Visual indentation under a group's name
is acceptable as future polish; the selectable item is always an
`Account`.

## Sync & schema

### Storage shape

Membership is a back-reference on `Account` (`groupId: UUID?`), not a
list on `AccountGroup`. Rationale:

- CloudKit: each add/remove updates the member record only; concurrent
  adds from two devices don't race on a shared list.
- GRDB: single indexed column for both directions of lookup.

### CloudKit (`CloudKit/schema.ckdb`)

New record type:

```ckdb
RECORD TYPE AccountGroup (
  "name"        STRING NOT NULL,
  "bucket"      STRING NOT NULL,   // AccountBucket raw value
  "instrument"  STRING NOT NULL,
  "position"    INT64  NOT NULL
);
```

New field on `Account`:

```ckdb
"groupId"  REFERENCE   // CKReference to AccountGroup, nullable
```

`isExpandedInSidebar` is **not** on the CloudKit record — local-only.

`just generate` regenerates `Backends/CloudKit/Sync/Generated/`; the
schema is imported to production via `cktool import-schema` per
[[reference_cloudkit_schema_tooling]] and the
`modifying-cloudkit-schema` skill.

### GRDB

```sql
CREATE TABLE account_group (
    id TEXT NOT NULL PRIMARY KEY,
    name TEXT NOT NULL,
    bucket TEXT NOT NULL,
    instrument TEXT NOT NULL,
    position INTEGER NOT NULL
) STRICT;

CREATE INDEX idx_account_group_bucket_position
    ON account_group (bucket, position);

ALTER TABLE account ADD COLUMN group_id TEXT;
CREATE INDEX idx_account_group_id ON account (group_id);
```

No `REFERENCES account_group(id)` on `account.group_id`. Sync delivery
order can place an `Account` with a `group_id` ahead of its
`AccountGroup`; FK enforcement would reject the insert. The lookup
layer handles the unknown-id case gracefully, mirroring how Category
resolution already works:

```swift
extension Accounts {
  func group(for account: Account, in groups: AccountGroups) -> AccountGroup? {
    guard let id = account.groupId else { return nil }
    return groups.by(id: id)         // nil for unknown id
  }
}
```

A dangling `group_id` renders the account as standalone in its bucket
until the group arrives via sync. Group deletion via sync just removes
the group; orphaned `group_id`s naturally resolve to nil. Order-
independent in all directions.

### Local-only state

`isExpandedInSidebar` lives in a local-only GRDB table on the profile
DB, not `UserDefaults`. Reasons: scoped per profile (multi-profile is
on the project list — [[project_multi_profile]]); clear cleanup when
the group is deleted (cascade-delete on `group_id`); no
`UserDefaults`-key namespacing across profiles.

Suggested shape:

```sql
CREATE TABLE local_account_group_ui (
    group_id TEXT NOT NULL PRIMARY KEY,
    is_expanded INTEGER NOT NULL DEFAULT 0
) STRICT;
```

If the project does not yet have a "local-only" table pattern in GRDB,
this table introduces one. The implementation plan should confirm or
adapt to an existing pattern.

### Sync-status surface

Aggregated from per-member sync states at read time. No persisted
field. A small pure function over `[AccountSyncStatus]` returns
`AggregatedSyncStatus` (`.allSynced`, `.syncing(done:total:)`,
`.failed(memberIds:)`). A 1-member input returns the original status
unchanged, so the same path serves single-account headers.

### Sync conflict resolution

`Account.position` and `AccountGroup.position` follow the existing
last-write-wins-per-record convention. Two devices concurrently
reordering members of the same group, or reordering groups within a
bucket, may produce a transient ordering that the next save resolves.
Same behaviour as today's per-account reorder; no new conflict surface.

Concurrent membership change (one device moves account A from group X
to group Y while another device deletes group Y) resolves cleanly
because membership is a single field on the member: A's `groupId`
takes the winning device's value; the group-deletion delivery may
leave A pointing at a non-existent group temporarily, which the lookup
gracefully treats as "standalone in bucket".

### DataFormatVersion

Adding `AccountGroup` and `Account.groupId` is a `SyncBoundary` change
per the comment on `AccountType` in `Account.swift`. Bump
`DataFormatVersion.current`. An older build encountering a profile
that uses groups refuses to open it (existing forward-compat gate),
preventing the older build from silently dropping `groupId` on write
or misclassifying records.

## Migration from existing manual-valuation accounts

No automatic migration, no in-app wizard, no help article. Users with
existing manual-valuation accounts that conceptually map to groups
work the migration themselves using the primitives already in scope
(create account, group via drag, rename, hide, delete). The unscripted
path is shorter than a scripted one would be.

## Suggested implementation order

For the writing-plans skill to refine. Each step lands as its own PR
and ships independently:

1. `AccountBucket` enum + `AccountType.bucket` + remove
   `isInvestmentLike` (mechanical sweep).
2. Inline-rename row component + apply to Account, Earmark, Group
   rows.
3. `AccountGroup` model, CKDB record, GRDB table + migration,
   DataFormatVersion bump.
4. Sidebar rendering with collapsed/expanded groups; drop semantics;
   creation flows.
5. `AccountViewContext` + thread through detail view header, chart,
   positions, transactions.
6. Description-rendering generalisation + transaction list under group
   view.
7. Sync wiring (record convertibles, change tracker, conflict
   handling, retry surface for aggregated status).
8. Local-only `account_group_ui` table for `isExpandedInSidebar`.
