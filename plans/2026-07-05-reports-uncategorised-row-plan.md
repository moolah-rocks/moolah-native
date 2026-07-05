# Reports & earmark-budget "Uncategorised" support — implementation plan

## Goal

Surface the total of income/expense legs that have **no category** everywhere
category balances are shown:

- **Reports screen** — an "Uncategorised" row in the Income and Expense columns,
  pinned at the bottom, tappable (drills into those transactions, type-scoped),
  omitted when there are none. Also fixes a latent under-count: the column
  **Total** currently excludes uncategorised legs.
- **Earmark budget breakdown** — uncategorised spend against the earmark is
  **folded into the existing "Unallocated" amount** (today it is silently
  excluded, so the budget under-counts actual spend).

## Design (revised — single combined query)

One query, one method, shared by both surfaces:

- **`fetchCategoryBalances(dateRange:transactionType:filters:targetInstrument:)`
  returns `CategoryBalances { byCategory: [UUID: InstrumentAmount]; uncategorised: InstrumentAmount? }`.**
  A single SQL query (NO `category_id IS NOT NULL` filter) selects a **nullable**
  `category_id` and groups by `(day, category_id, instrument)`. Swift assembly
  routes null-category rows into `uncategorised` and non-null rows into
  `byCategory`. `uncategorised == nil` (not `.zero`) means "no uncategorised
  legs" → the Reports row is omitted / nothing added to Unallocated.
  - `byCategory` **still excludes** uncategorised (its contract is unchanged —
    the "excludes transactions without category" guarantee now applies to the
    `byCategory` field specifically).
  - Per-day conversion contract preserved (each `(day, instrument)` converts on
    its own day; `INSTRUMENT_CONVERSION_GUIDE.md` Rule 5). Uncategorised and
    categorised share one batch conversion, so a conversion failure fails the
    whole call exactly as today — no new partial-failure surface, no best-effort
    special-casing needed.
- **`fetchCategoryBalancesByType`** (Reports) is just the protocol-extension
  default composing two `fetchCategoryBalances` calls into
  `CategoryBalancesByType { income, expense, incomeUncategorised, expenseUncategorised }`.
  **No GRDB-specific override** — the uncategorised values come from
  `fetchCategoryBalances` for any backend.
- **Index:** the combined query (no null filter) cannot use the existing
  *partial* covering index `leg_analysis_by_type_category`
  (`WHERE category_id IS NOT NULL`). Make that index **non-partial** via a
  migration (drop + recreate, same name, same columns, no `WHERE`). One full
  index then covers both the combined query and any residual `IS NOT NULL`
  usage. Re-pin the plan.
- **Drill-down** is type-scoped: `TransactionFilter.uncategorizedLegType: TransactionType?`;
  when set, the fetch restricts to transactions having a leg with
  `category_id IS NULL AND type = X`.

## Current branch state (to rework)

Task 1 landed and is kept: `CategoryBalancesByType` struct + the protocol
return-type change (commit `7e3f5593`).

Task 2's first attempt (commits `98d23910`, `ebb110c9`) took a *separate*
uncategorised query + a second partial index. **That approach is being
replaced** by the combined-query design above. The rework must DELETE:
`GRDBAnalysisRepository+UncategorisedBalances.swift`,
`ProfileSchema+UncategorisedLegAnalysisIndex.swift` (and its `v21` registration),
the GRDB `fetchCategoryBalancesByType`/`fetchUncategorisedBalances` override,
`GRDBUncategorisedBalancesTests.swift`,
`GRDBUncategorisedBalancesAssembleTests.swift`,
`UncategorisedBalancesPlanPinningTests.swift`, and revert the
`ProfileSchemaV20DropCryptoCompareTests` version bump made for the old v21.

## Steps

### Step 2 (rework) — combined query + `CategoryBalances` result

- In `GRDBAnalysisRepository+CategoryBalances.swift`: drop
  `AND leg.category_id IS NOT NULL` from the SQL; make the row's `categoryId`
  a `UUID?`; generalise `assembleCategoryBalances` to return
  `CategoryBalances` (null → `uncategorised` accumulator in the target
  instrument; non-null → `byCategory`; `uncategorised = nil` when no null rows).
- Change `fetchCategoryBalances` (in `GRDBAnalysisRepository.swift`) to return
  `CategoryBalances`. Define `struct CategoryBalances: Sendable` in Domain
  (near `AnalysisRepository`).
- Update the protocol default `fetchCategoryBalancesByType` to build
  `CategoryBalancesByType` from the two calls' `byCategory` + `uncategorised`.
- **Index migration** `v21_leg_analysis_category_include_null` (or similarly
  named): `DROP INDEX leg_analysis_by_type_category;` then recreate it WITHOUT
  the partial `WHERE`. Do not edit the base CREATE block or existing migrations.
  Update `ProfileSchema` version test(s) to the new count.
- Update ALL `fetchCategoryBalances` callers to `.byCategory`
  (`AnalysisBenchmarks`, the `AnalysisCategoryBalancesTests` suite,
  `GRDBCategoryBalancesConversionTests`, `AnalysisMultiCurrencyConversionTests`,
  `AnlRepoSharedInstrumentResolutionTests`, and any others `grep` finds).
- **Tests:** repurpose the deleted uncategorised tests into
  `AnalysisCategoryBalancesTests` (or a sibling): uncategorised legs land in
  `.uncategorised` and NOT in `.byCategory`; `.uncategorised == nil` when none;
  category totals unaffected; per-day conversion for a multi-currency
  uncategorised leg. Update/extend the plan-pinning test for the combined query
  (`USING COVERING INDEX leg_analysis_by_type_category`).
- **Verify:** `just build-mac`; controller runs the analysis + pinning suites.

### Step 3 — `TransactionFilter.uncategorizedLegType` + fetch (unchanged)

- Add `var uncategorizedLegType: TransactionType?` (default `nil`); include in
  `hasActiveFilters`.
- `GRDBTransactionRepository+Fetch.swift`: when set, filter to
  `legTransactionIds(where: categoryId == nil && type == rawValue)`.
- Tests: `TransactionFilterTests` + a GRDB fetch test.

### Step 2b — Rule 11 partial availability (fold into the assembly)

`assembleCategoryBalances` must match the `#1077` sibling pattern
(`+ExpenseBreakdown.swift` / `+IncomeAndExpense.swift`): on a **transient**
conversion failure (`ConversionFailureClassifier.isTransient`) skip that row's
contribution and set a `hasUnavailableData` flag; keep the loud rethrow only for
**structural** failures. Add `hasUnavailableData: Bool` (default false) to
`CategoryBalances`, and propagate per-column onto `CategoryBalancesByType`
(`incomeHasUnavailableData` / `expenseHasUnavailableData`). Tests mirror the
expense-breakdown transient-skip coverage.

### Step 4 — `ReportingStore` published uncategorised + unavailable state

- Add `incomeUncategorised` / `expenseUncategorised: InstrumentAmount?` and
  `incomeHasUnavailableData` / `expenseHasUnavailableData: Bool`, populated from
  `CategoryBalancesByType` in `loadCategoryBalances`.
- Store tests.

### Step 5 — Reports views: pinned row + drill-down

- `CategoryBalanceTable` gains `uncategorised: InstrumentAmount?` and
  `transactionType: TransactionType`; renders an "Uncategorised" row pinned
  after all category sections when non-nil; `grandTotal` includes it; row is a
  `NavigationLink(value: UncategorisedDrillDown(transactionType:dateRange:))`.
- `ReportsView` passes the fields + type and adds
  `.navigationDestination(for: UncategorisedDrillDown.self)` →
  `TransactionListView` (title "Uncategorised",
  `TransactionFilter(dateRange:, uncategorizedLegType: type)`).
- `CategoryBalanceTable` shows a "some amounts unavailable" indicator when its
  column's `hasUnavailableData` is set (mirror `ExpenseBreakdownCard`'s
  treatment).
- Update `CategoryBalanceTable` `#Preview`. UI review.
- Also fix the Rule 11 gap in `EarmarkBudgetSectionView.loadCategoryBalances`
  (Step 6): its `catch` currently swallows errors to an empty dict silently —
  log via `os.Logger` and surface an error/retry state instead.

### Step 6 — Earmark budget shows uncategorised spend as a line item

NOTE: "Unallocated" is `savingsGoal − sum(budget allocations)` — a budget-side
figure, unrelated to spend. Uncategorised spend must NOT go there. Instead it is
an actual-spend row, exactly like the existing "categories with spending but no
budget" rows `buildLineItems` already appends (budgeted = 0, actual = spend).

- `EarmarkBudgetSectionView.loadCategoryBalances` keeps the whole
  `CategoryBalances` (both `.byCategory` and `.uncategorised`).
- `BudgetLineItem.buildLineItems(...)` gains an `uncategorised: InstrumentAmount?`
  parameter; when non-nil it appends one row labelled "Uncategorised"
  (`budgeted = 0`, `actual = uncategorised`), coerced to the earmark instrument,
  sorted alongside the others (or pinned last — match the Reports pinned-bottom
  treatment). Omit when nil. `unallocatedAmount` is UNCHANGED.
- Tests: `buildLineItems` includes an "Uncategorised" row when a total is passed
  and omits it when nil; totals (`totalActual`) include it; earmark-budget load
  test.
- UI review for the new row.

### Step 7 — Full verification gate

- `just format-check`, `just test-mac` (full), and reviewers:
  `@code-review`, `@database-code-review`, `@database-schema-review`
  (index migration), `@concurrency-review`, `@instrument-conversion-review`,
  `@ui-review`. Fix every finding, re-review until clean.

## Out of scope

- Recategorising transactions from either screen (read-only).
- Uncategorised anywhere other than Reports income/expense + earmark budgets.
