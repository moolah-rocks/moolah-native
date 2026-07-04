# Group transaction filter — multi-account scope

## Problem

When viewing transactions for an account **group** and applying *any* filter, the
list stops being scoped to the group and shows transactions from **all** accounts.

Root cause: the filter dialog (`TransactionFilterView`) only edits a single
`accountId`. Its `applyFilter()` rebuilds a fresh `TransactionFilter` and **omits
the `accountIds` set entirely**, so the group scope carried in
`baseFilter.accountIds` is silently dropped. `TransactionListView+List.swift` then
replaces `activeFilter` wholesale with the un-scoped filter, and the fetch layer —
finding both `accountId == nil` and `accountIds == []` — applies no account
predicate and returns every account's transactions.

The dialog's `Accounts` control is a single-selection `Picker` and cannot represent
a group scope at all.

## Goals

- Applying a filter inside a group **never** widens beyond the group's accounts.
- The account control supports selecting **multiple** accounts.
- The account options offered are scoped to the current navigation context:
  - **Group** → only the group's member accounts, defaulting to all of them.
  - **Global transaction list** → all accounts, defaulting to all.
  - **Single account** → nothing to narrow; the account control is hidden.

## Non-goals

- No change to the `TransactionFilter` data model — it already has both
  `accountId: UUID?` and `accountIds: Set<UUID>`, and the fetch layer already ORs
  them together (`GRDBTransactionRepository+Fetch.swift`). We stop *dropping*
  `accountIds`; we do not add fields.
- No change to how groups / accounts are navigated into
  (`GroupDetailView`, `StandardAccountView`).

## Design

### The scope universe

`TransactionListView` holds `baseFilter` — the immutable navigation context
(a group passes `accountIds = Set(group members)`; a single account passes
`accountIds = [account.id]`; the global list passes an empty set). `activeFilter`
is the user-mutable copy.

Derive a stable **`scopeAccountIds`** from `baseFilter`:

```
scopeAccountIds = baseFilter.accountIds ∪ (baseFilter.accountId.map { [$0] } ?? [])
```

Pass `scopeAccountIds` (plus the full accounts list already passed) into
`TransactionFilterView`. It is derived from `baseFilter`, **not** `activeFilter`,
so the universe stays the full group even after the user narrows the selection.

The dialog's **available accounts**:

```
available = scopeAccountIds.isEmpty ? allAccounts : allAccounts.filter { scopeAccountIds.contains($0.id) }
```

### `AccountMultiSelectPicker`

New view mirroring the existing `CategoryMultiSelectPicker`
(`Features/Transactions/Views/CategoryMultiSelectPicker.swift`):

- Inputs: the available `accounts` and `@Binding var selectedIds: Set<UUID>`.
- Search field + checkbox rows + a **Clear** button.
- Convention (same as the category picker): **empty selection = all available**.
- A summary label for the trigger button: `"All accounts"` when empty,
  the account's name when exactly one, otherwise `"N accounts"`.

In `TransactionFilterView` the account control is placed where the current
single-account `Picker` lives, using the same macOS-popover / iOS-NavigationLink
treatment the category picker already uses. **The control is only shown when
`available.count > 1`** (a single-account view has nothing to narrow).

### Apply-time resolution (the fix)

A pure, unit-testable helper resolves the picker selection back into the filter's
account set:

```swift
// selection: the picker's Set (empty = "all available")
// scope: scopeAccountIds (empty = "all accounts globally")
// available: the ids offered in the picker
func resolvedAccountIds(selection: Set<UUID>, scope: Set<UUID>, available: Set<UUID>) -> Set<UUID> {
    if selection.isEmpty || selection == available {
        return scope          // preserve the group; empty scope stays empty = all accounts
    }
    return selection          // strict subset
}
```

`applyFilter()`:

- Reads the picker's `selectedAccountIds`.
- Sets `newFilter.accountIds = resolvedAccountIds(selection:scope:available:)`.
- **Stops** writing the legacy single `accountId`; passes any incoming
  `filter.accountId` through unchanged so other callers are unaffected.

This makes it impossible for applying a filter to widen beyond the scope: an empty
or "all" selection resolves to the group members (or to empty = global-all only
when the scope itself is global).

### Seeding on open

`TransactionFilterView.init` seeds `selectedAccountIds` from the incoming
`filter.accountIds`:

- `filter.accountIds == scopeAccountIds` (the default group filter) → seed **empty**
  (picker shows "All accounts").
- a strict subset → seed that subset (those rows checked).
- global scope, `filter.accountIds` empty → seed empty ("All accounts").

## Testing

- **Unit — `resolvedAccountIds`:**
  - group scope + empty selection → group members.
  - group scope + "all checked" selection → group members.
  - group scope + strict subset → that subset.
  - global scope (empty) + empty selection → empty (all accounts).
  - global scope + subset → that subset.
- **Regression — fetch layer:** a group filter combined with a date range returns
  only the group's accounts (guards the original bug).
- **XCUITest (macOS):** open a group, apply a filter (e.g. a date range), assert the
  visible rows stay within the group's accounts.

## Files

- `Features/Transactions/Views/TransactionFilterView.swift` — replace the
  single-account `Picker` section; fix `applyFilter()`; seed from `accountIds`.
- `Features/Transactions/Views/AccountMultiSelectPicker.swift` — **new**.
- `Features/Transactions/Views/TransactionListView+List.swift` — pass
  `scopeAccountIds` (from `baseFilter`) into the dialog.
- Home for `resolvedAccountIds` helper (pure; testable) + its unit tests.
- Fetch-layer regression test + macOS UI test.
