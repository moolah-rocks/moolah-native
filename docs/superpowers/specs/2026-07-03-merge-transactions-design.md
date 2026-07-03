# Merge Transactions — Design

## Summary

Add a **Merge Transactions** command that combines two or more selected
transactions into one. The user Command-clicks to multi-select rows in the
transaction list, right-clicks, and chooses **Merge Transactions**. This is
additive: the existing **Merge as Transfer** command is unchanged, and the two
gates are independent.

This is a *general* combine, distinct from the transfer merge:

- **Merge as Transfer** collapses exactly two opposite-equal value legs on
  different accounts into a two-`.transfer`-leg transfer, and is reversible
  (via `MergedImportOrigin`).
- **Merge Transactions** concatenates the legs of N transactions unchanged into
  one transaction, is gated on same-day + same-payee, and is one-way.

## Behaviour

Given 2+ selected transactions that **all share the same calendar day** and the
**same payee**, and where **none is scheduled/recurring**, the merge produces one
new transaction:

- **`id`**: fresh `UUID`.
- **`date`**: the earliest timestamp among the sources (`min`).
- **`payee`**: the shared payee.
- **`notes`**: each source's notes split into lines, duplicate lines dropped,
  joined with `\n` in selection order. (Reuses the transfer-merge notes rule.)
- **`legs`**: every leg of every source, carried through **unchanged** — each
  leg keeps its own `id`, `accountId`, `instrument`, `quantity`, `externalId`,
  `counterpartyAddress`, `type`, `categoryId`, and `earmarkId`. No signing, no
  dedup, no reordering beyond source-selection order.
- **`importOrigin`**: `nil`. A denormalised CSV/merged origin has no meaning
  across N arbitrary transactions. Per-leg `externalId` is preserved, so
  wallet/exchange sync dedup — matched on `(accountId, externalId)` — stays
  correct.
- **`recurPeriod` / `recurEvery`**: `nil` (scheduled/recurring rows are excluded
  from the gate, so this is defensive).

The sources are deleted and the merged transaction created in one atomic
`TransactionRepository.replace(deletingIds:creating:)`.

### One-way

There is no "Split Back" for a general merge — unlike the transfer merge, we do
not record per-source provenance, so an exact reverse is undefined. Sync dedup
remains safe because each leg retains its own `externalId`/`accountId`.

### Same-day comparison

Uses the existing `Date.isSameDay(as:)` helper
(`Shared/Extensions/Date+SameDay.swift`, which wraps
`Calendar.current.isDate(_:inSameDayAs:)`). There is **no** day-based value type
to route through — `FinancialMonth` buckets months, and no `FinancialDate`/day
type exists. `isSameDay` is transitive within a day, so the gate checks every
selected row against the first. The comparison is local-calendar, matching the
user's perception of "same date" and the existing "due today" check. It is only
a gate; the persisted merged `date` is a real instant (`min`), so no
timezoneless carrier value is written.

### Coexistence with Merge as Transfer

The two gates are independent predicates. If exactly two selected rows satisfy
*both* (same day + same payee, and also opposite-equal legs on different
accounts), both menu items appear and the user chooses. General merge imposes no
opposite-amount / different-account / instrument constraints, so merging (say)
two same-account expenses on the same day with the same payee into one two-leg
transaction is valid.

## Components

Each mirrors its transfer-merge equivalent.

### 1. Pure builder — `Shared/TransactionMerge/TransactionMergeBuilder.swift`

`struct TransactionMergeBuilder: Sendable` with no I/O:

```swift
func merged(_ transactions: [Transaction]) throws -> Transaction
```

Validation (throws `TransactionMergeError`):

- at least two transactions,
- all payees equal (nil treated consistently — all-nil is "equal"),
- all on the same calendar day (`Date.isSameDay(as:)` against the first),
- none scheduled/recurring (`recurPeriod == nil`).

On success builds the transaction described in **Behaviour**.

Sibling `Shared/TransactionMerge/TransactionMergeError.swift` — an `Error` enum
with cases for the validation failures (e.g. `tooFewTransactions`,
`differentDays`, `differentPayees`, `containsScheduled`), each with a
user-facing message consistent with `ManualMergeError`.

### 2. Gate predicate — `Domain/Models/Transaction+Merge.swift`

```swift
static func canMerge(_ transactions: [Transaction]) -> Bool
```

The cheap menu-enable check: `count >= 2`, same calendar day, equal payee, none
scheduled. Same split of responsibility as `canManualMerge` (cheap gate) vs. the
builder (authoritative throw).

### 3. Store method — `Features/Transactions/TransactionStore+Merge.swift`

```swift
func mergeTransactions(_ transactions: [Transaction]) async
```

Calls `TransactionMergeBuilder().merged(_:)`, then
`repository.replace(deletingIds:creating:)`, capturing any failure via the
store's existing `setError`. It does **not** route through
`TransferDetectionCoordinator` — that type is transfer/suggestion-specific and a
general merge has no `TransferSuggestion` to delete. Matches the un-guarded style
of the store's existing `delete`/`update` mutations (`replace` is atomic).

### 4. UI wiring

Reuses the existing multi-select `Set<Transaction.ID>` (`transferMergeSelection`
on `TransactionListView`).

- **`Features/Transactions/Views/TransactionListView+List.swift`**: a
  `mergeSelection: [Transaction]?` resolver — the selected rows when
  `Transaction.canMerge` passes, else `nil` — plus a
  `Button("Merge Transactions", …)` in `rowContextMenu`, shown when the
  right-clicked row is part of `mergeSelection`, with a UI-test
  accessibility identifier.
- **`Features/Transactions/Views/TransactionListView.swift`**: publish
  `.focusedSceneValue(\.mergeTransactionsAction, …)` — the action closure when
  `mergeSelection != nil`, else `nil`.
- **`Shared/FocusedValues.swift`**: new `MergeTransactionsActionKey` + accessor,
  mirroring `MergeAsTransferActionKey`.
- **`App/MoolahDomainCommands.swift`**: `Button("Merge Transactions")` in the
  Transaction menu, next to "Merge as Transfer", disabled when the focused
  action is `nil`. No keyboard shortcut (infrequent action, UI_GUIDE §14).

No toolbar button (the requirement is right-click; keeps the toolbar
uncluttered).

### 5. AppleScript — new `combine txns` verb

The existing `merge txns … first "…" second "…"` verb (code `Moolmgtx`, class
`MergeTransactionsCommand`) is transfer-specific and takes exactly two ids, so it
cannot absorb an N-way general merge. Add a sibling:

- **sdef** (`Automation/AppleScript/Moolah.sdef`): command `combine txns`, code
  `Moolcbtx` (unused; `Moolmgtx` is taken), direct-parameter profile specifier,
  parameter `ids` of `<type type="text" list="yes"/>`, result `txn`. Both
  `merge txns` and `combine txns` get a one-line description clarifying which is
  the transfer merge and which is the general merge.
- **`Automation/AppleScript/Commands/CombineTransactionsCommand.swift`**: reads
  `args["ids"] as? [String]`, parses each to `UUID`, calls the service; mirrors
  `MergeTransactionsCommand`'s error plumbing.
- **`Automation/AutomationService+CombineTransactions.swift`**:
  `func combineTransactions(profileIdentifier:ids:) async throws -> Transaction`
  — resolves each id from the repo snapshot, runs the **same**
  `TransactionMergeBuilder`, and `replace(deletingIds: ids, creating: [merged])`.
  The builder is the single validity authority, so the AppleScript path enforces
  the identical same-day / same-payee / not-scheduled rules and throws
  `AutomationError.operationFailed` on violation.

Usage: `combine txns of profile "Real" ids {"uuid1", "uuid2", "uuid3"}`.

## Testing

- **Builder unit tests** (Swift Testing, mirroring `TransferMergeBuilderTests`):
  legs preserved field-for-field (including `externalId`, `counterpartyAddress`,
  `categoryId`, `earmarkId`, leg `id`); 3-way merge; notes dedup-join; `min`
  date; fresh transaction id; `importOrigin == nil`; throws for `<2`,
  different-day, different-payee, and scheduled inputs.
- **`canMerge` predicate tests**.
- **Store test** mirroring `TransactionStoreManualMergeTests`: sources deleted,
  merged created; error surfaced on an invalid selection.
- **AppleScript service test** mirroring
  `AutomationServiceMergeTransactionsTests`: `combineTransactions` merges N,
  deletes sources, and throws on an invalid selection.
- **One happy-path UI test**: select two rows → context menu →
  Merge Transactions → assert the combined row.

## Out of scope

- No reverse/unmerge for general merges.
- No toolbar button.
- No change to the existing `merge txns` (transfer) verb or `Merge as Transfer`.

## Review gates

Per the repo's mandatory AI review gate, run the relevant reviewers before
committing and fix every finding: `code-review` (all Swift), `concurrency-review`
(store/service async), `ui-review` (menu/context-menu), `ui-test-review` and the
`writing-ui-tests` skill (UI test), `datetime-review` (the `isSameDay` gate), and
`database-code-review` if any GRDB call site is touched (the merge uses the
existing `replace`, so likely not).
