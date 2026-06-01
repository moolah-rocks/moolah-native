# Account Groups — Phase 6 Implementation Plan: Description rendering

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Initial-version plan.** Written before Phase 5 lands. The exact `TransactionRowView` / description-rendering call signatures may have moved during Phase 5's refactor. The rule this plan establishes is stable; the call-site wiring is the part to recheck.

**Goal:** Replace the existing `viewingAccountId: UUID?` perspective hint in transaction rendering with a per-row `accountContext: UUID?` computed from the selected view's `accountIds` set. Result: when a group is selected, transactions touching exactly one member render from that member's perspective ("Transfer from external_account"); transactions touching multiple members render in the no-context style ("Transfer from member_A to member_B"). Same code path serves single-account, group, and all-accounts views.

**Architecture:** The transaction-description function (currently keyed on `viewingAccountId`) generalises to take `accountContext: UUID?`. The view derives the context per row: `let inScope = tx.legs.map(\.accountId).filter { accountIds.contains($0) }; let accountContext = inScope.count == 1 ? inScope.first : nil`. No new types; the existing function gains the new semantics, callers thread `accountIds` instead of a single id.

**Tech Stack:** SwiftUI, Swift Testing.

**Spec:** `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-groups-design/plans/2026-05-26-account-groups-design.md` — see "Description rendering & internal transfers".

**Phase ordering:** Depends on **Phase 5** (`AccountViewContext.accountIds`). Independent of Phase 7 / 8.

---

## Worktree setup

- [ ] Base off whichever of Phase 5 has merged (or `origin/main` if it has). Worktree at `.worktrees/transaction-description-context`. Generate.

---

## Task 1: Locate the existing description-rendering path

**No files modified yet — investigation step.**

```bash
grep -rn "viewingAccountId" /Users/aj/Documents/code/moolah-project/moolah-native/Features/Transactions \
  /Users/aj/Documents/code/moolah-project/moolah-native/Domain 2>/dev/null
```

Map out:
1. The function or computed property that produces the description string (likely on `Transaction` or a free function in a `+Description.swift` file, or inline in `TransactionRowView`).
2. Every caller — `TransactionRowView` is the main one; check whether the `RecentlyAddedView`, transaction-detail panel, and exports also use it.
3. The shape of the perspective hint today (a single `UUID?` per the existing `viewingAccountId` parameter on `TransactionRowView`).

Write a one-page note (in the agent's scratch) of the mapping. The next tasks edit each site.

---

## Task 2: Lock in current behaviour with tests

**Files:**
- Create or modify: `MoolahTests/Domain/TransactionDescriptionTests.swift` (or sibling) — pin the existing renderings before refactoring

For each existing perspective behaviour, write a regression test using a small synthetic transaction. The goal: the refactor must not change description text for any case other than the new "group view with multi-member transaction" case.

Cases to cover:
- Single-leg expense, account = X, perspective = X → existing description text.
- Two-leg transfer between X and Y, perspective = X → "Transfer to Y".
- Two-leg transfer between X and Y, perspective = Y → "Transfer from X".
- Two-leg transfer between X and Y, no perspective → "Transfer from X to Y" (no-context style).
- Three-leg trade — verify both perspective-set and no-perspective renderings.

These tests will continue to pass through the refactor — Phase 6 doesn't change semantics for single-account / all-accounts views, only adds the new group-view behaviour.

```bash
just test TransactionDescriptionTests
```

Expected: all green against existing implementation.

---

## Task 3: Generalise the description function signature

**Files:**
- Modify: wherever the description function lives (Task 1's investigation).

Rename / add an overload. The new signature:

```swift
/// Per-row description string. `accountContext` is the perspective
/// from which the description is phrased — typically the single
/// in-scope account for the current view, or nil when the view spans
/// multiple in-scope accounts (e.g. the all-accounts list, or a group
/// view where this row touches more than one member).
func transactionDescription(
  _ tx: Transaction,
  accountContext: UUID?,
  accounts: Accounts,
  categories: Categories,
  // …whatever other dependencies the current function takes
) -> String
```

The semantics:
- `accountContext == nil` → use the no-context style ("Transfer from X to Y").
- `accountContext == some` → use the perspective style ("Transfer to Y" / "Transfer from X").

The body of the function shouldn't change much — it already had a `viewingAccountId: UUID?` path. Rename internally; preserve existing branches.

If the existing function is named `transactionDescription` and has a `viewingAccountId` parameter, just rename the parameter to `accountContext` and update all callers.

---

## Task 4: Replace `viewingAccountId` callers with per-row context derivation

**Files:**
- Modify: `Features/Transactions/Views/TransactionRowView.swift` (and `+Preview.swift` if it constructs sample data with the old name)
- Modify: the transaction list view in the detail view (search for `TransactionRowView(`)

`TransactionRowView` today takes `viewingAccountId: UUID?` as a property. Update the property name:

```swift
struct TransactionRowView: View {
  // …
  /// The perspective from which this row's description is rendered.
  /// Derived per-row by the parent from the view's `accountIds`:
  /// nil when the transaction touches multiple in-scope accounts
  /// (no-context style), or the single in-scope account id otherwise.
  var accountContext: UUID?
  // …
}
```

In the parent (transaction list within the detail view), derive the per-row context from `AccountViewContext.accountIds`:

```swift
let inScopeIds: Set<UUID> = Set(viewContext.accountIds)
ForEach(transactions) { tx in
  let inScope = tx.legs.lazy.map(\.accountId).filter { inScopeIds.contains($0) }
  let context: UUID? = (inScope.count == 1) ? inScope.first : nil
  TransactionRowView(
    transaction: tx,
    accountContext: context,
    // …other params
  )
}
```

For the all-accounts list (no detail-view context), `accountIds` is effectively "all" — multi-leg transactions will have `count > 1` → context = nil → same no-context rendering as today.

For the single-account detail view, `accountIds = [account.id]` → inScope = `[account.id]` (assuming the row is shown because it touches the account) → context = the account → same perspective rendering as today.

For the group detail view, the new behaviour kicks in: rows touching exactly one member render from that member's perspective; rows touching multiple members render no-context.

---

## Task 5: Verify against the regression tests + add group-context cases

**Files:**
- Modify: `MoolahTests/Domain/TransactionDescriptionTests.swift`

Existing regression tests should still pass (no semantic change for single-account / all-accounts). Add new cases:

```swift
@Test
func groupViewSingleInScopeLegRendersFromMemberPerspective() {
  let memberA = Account(...)
  let external = Account(...)
  let tx = makeTransfer(from: memberA, to: external, amount: ...)

  // Group context contains memberA + memberB; transaction touches only memberA.
  let memberIds: Set<UUID> = [memberA.id, memberB.id]
  let inScope = tx.legs.map(\.accountId).filter { memberIds.contains($0) }
  let context: UUID? = inScope.count == 1 ? inScope.first : nil

  #expect(context == memberA.id)
  let desc = transactionDescription(tx, accountContext: context, accounts: ..., categories: ...)
  #expect(desc == "Transfer to external_account_name")
}

@Test
func groupViewMultipleInScopeLegsRendersNoContext() {
  let memberA = Account(...)
  let memberB = Account(...)
  let tx = makeTransfer(from: memberA, to: memberB, amount: ...)   // intra-group bridge

  let memberIds: Set<UUID> = [memberA.id, memberB.id]
  let inScope = tx.legs.map(\.accountId).filter { memberIds.contains($0) }
  let context: UUID? = inScope.count == 1 ? inScope.first : nil

  #expect(context == nil)
  let desc = transactionDescription(tx, accountContext: context, accounts: ..., categories: ...)
  #expect(desc == "Transfer from memberA_name to memberB_name")
}

@Test
func allAccountsViewMultiLegTransactionAlwaysNoContext() {
  let a = Account(...)
  let b = Account(...)
  let tx = makeTransfer(from: a, to: b, amount: ...)

  // All-accounts view: inScopeIds = all accounts (effectively unconstrained).
  let inScope = tx.legs.map(\.accountId)   // both legs in scope
  let context: UUID? = inScope.count == 1 ? inScope.first : nil

  #expect(context == nil)
  // Matches today's all-accounts list rendering — pinning here.
  let desc = transactionDescription(tx, accountContext: context, accounts: ..., categories: ...)
  #expect(desc == "Transfer from a_name to b_name")
}
```

Run:

```bash
just test TransactionDescriptionTests
```

---

## Task 6: Internal-transfer visibility (no filter)

**No new code** — just confirm the spec's "internal transfers are shown" rule (no filter UI, no toggle):

- Select a group in the sidebar.
- Verify that bridge transactions between two members appear in the list.
- Verify they render in the no-context style ("Transfer from memberA to memberB").
- Verify their gas-cost legs also render (no filtering).

If the existing transaction-list view filters by `viewingAccountId` (only showing transactions that touch the selected account), update it for group contexts: a transaction qualifies if it touches *any* `accountId` in `viewContext.accountIds`. This is a query change — likely a small change to the existing transaction-fetch logic in the detail view's transaction list.

---

## Task 7: Manual exercise + open PR

Verify in the running app:
1. Select an account → unchanged description text for every transaction.
2. Select a group → transactions touching one member read from that member's perspective; cross-member bridges show "Transfer from … to …".
3. Select "All Transactions" → unchanged.

`just test`; `just format-check`; push; PR; auto-merge.

---

## Acceptance criteria for Phase 6

- Description rendering function takes `accountContext: UUID?`.
- `TransactionRowView` exposes `accountContext: UUID?` (renamed from `viewingAccountId`).
- Parent views derive `accountContext` per row from `AccountViewContext.accountIds` (single in-scope leg → that account; multiple → nil).
- Regression tests cover single-account, all-accounts, and group views.
- Group-view bridge transactions render in no-context style + show gas-cost legs.
- Transaction-list query filters by membership in `accountIds` set rather than equality with a single account id.
- Full `just test` passes; `just format-check` clean.

---

## What's NOT in this phase

- An "Internal Transfers" filter toggle — user explicitly chose to show them always.
- Inline summary chips ("3 internal transfers" headers) — out of scope.
- Cross-currency description nuances beyond what already exists — Phase 6 only changes perspective, not formatting.
