# Reports "Uncategorised" income/expense row — implementation plan

## Goal

Add an **Uncategorised** row to the Income and Expense columns of the Reports
screen, showing the total of income/expense legs that have **no category**.
Omit the row when there are none. The row is **tappable**, drilling into the
matching transactions, and is **pinned at the bottom** of each column, below all
real categories.

Including uncategorised legs also fixes a latent under-count: the report
currently filters `category_id IS NOT NULL`, so uncategorised income/expense is
missing from the column **Total** today. The new total includes it.

## Design decisions (locked)

- **Do NOT change `fetchCategoryBalances(dateRange:transactionType:filters:targetInstrument:)`.**
  Its `[UUID: InstrumentAmount]` contract *excludes* uncategorised legs and is
  relied on by earmark budgets (`EarmarkBudgetSectionView`) and a contract test
  (`AnalysisCategoryBalancesTests` "excludes transactions without category").
  Uncategorised is computed by a **separate** query, invoked only from the
  Reports-specific `fetchCategoryBalancesByType`.
- **Drill-down is type-scoped by construction.** `TransactionFilter` gains one
  optional field `uncategorizedLegType: TransactionType?`; when set, the fetch
  restricts to transactions having a leg with `category_id IS NULL AND type = X`.
  Income "Uncategorised" → uncategorised income only; expense → expense only.
- **Per-day conversion contract preserved.** The uncategorised aggregation sums
  `(day, instrument)` and converts each on its own day, exactly like the
  category aggregation (`INSTRUMENT_CONVERSION_GUIDE.md` Rule 5).
- `uncategorised == nil` (not `.zero`) means "no uncategorised legs" → row omitted.

## Steps

### Step 1 — Domain: `CategoryBalancesByType` result type + protocol

- Add `struct CategoryBalancesByType: Sendable` with `income`, `expense`
  (`[UUID: InstrumentAmount]`) and `incomeUncategorised`, `expenseUncategorised`
  (`InstrumentAmount?`).
- Change `AnalysisRepository.fetchCategoryBalancesByType(...)` return type from
  the tuple to `CategoryBalancesByType`.
- The protocol-extension **default** impl composes `income`/`expense` via
  `fetchCategoryBalances` and sets both uncategorised fields to `nil` (safe
  fallback for any non-GRDB backend — row simply never shows).
- Update the two callers to the struct:
  - `Features/Reports/ReportingStore.swift:62` (`result.income` / `result.expense`
    already field-style — keep).
  - `MoolahBenchmarks/AnalysisBenchmarks.swift:107`.
- **Verify:** `just build-mac`; existing `AnalysisCategoryBalancesTests` still green.

### Step 2 — GRDB: uncategorised aggregation + `fetchCategoryBalancesByType` override

- In `GRDBAnalysisRepository+CategoryBalances.swift` (or a new sibling
  `+UncategorisedBalances.swift`), add:
  - `makeUncategorisedBalancesRequest(args)` — mirrors
    `makeCategoryBalancesRequest` but `WHERE ... AND leg.category_id IS NULL`,
    `GROUP BY DATE(t.date), leg.instrument_id` (no category grouping). Reuses the
    same optional filter clauses (account/earmark/payee) minus `categoryIds`.
  - A lightweight row `{ day, instrumentId, qty }` + an assemble helper that
    batch-converts each `(qty, instrument, day)` and sums to a single
    `InstrumentAmount`, returning `nil` when there are no rows.
- Add a concrete `fetchCategoryBalancesByType(...)` on `GRDBAnalysisRepository`
  that runs the two category fetches **and** the two uncategorised fetches
  (income + expense) and returns a fully-populated `CategoryBalancesByType`.
  (Concrete member overrides the protocol-extension default.)
- **Tests:** extend `GRDBCategoryBalancesConversionTests` / add a suite —
  uncategorised legs sum correctly, per-day conversion holds, `nil` when none,
  and category totals are unaffected by presence of uncategorised legs.
- If the new SQL needs an index-plan assertion, add/adjust in
  `AnalysisAggregationPlanPinningTests` (only if the planner shape warrants it;
  do not disturb the existing `fetchCategoryBalancesUsesCategoryIndex` pin).
- **Verify:** `just build-mac` + the GRDB analysis test suites.

### Step 3 — `TransactionFilter.uncategorizedLegType` + fetch

- `Domain/Models/TransactionFilter.swift`: add `var uncategorizedLegType: TransactionType?`
  (default `nil` in the memberwise init — backward compatible). Include it in
  `hasActiveFilters`.
- `GRDBTransactionRepository+Fetch.swift` `filteredTransactionRequest`: when set,
  add a `legTransactionIds(where: categoryId == nil && type == rawValue)`
  subquery filter, matching the existing `categoryIds` block's shape.
- **Tests:** `TransactionFilterTests` (hasActiveFilters) + a GRDB fetch test that
  only uncategorised legs of the given type match.
- **Verify:** `just build-mac` + transaction fetch/filter tests.

### Step 4 — `ReportingStore` published uncategorised state

- Add `private(set) var incomeUncategorised: InstrumentAmount?` and
  `expenseUncategorised: InstrumentAmount?`.
- `loadCategoryBalances` populates all four from the `CategoryBalancesByType`
  result (and clears them on the cancellation/error paths consistently with the
  existing dict handling).
- **Tests:** `ReportingStoreTests` — populated when uncategorised legs exist,
  `nil` when not.
- **Verify:** `just build-mac` + reporting store tests.

### Step 5 — Views: pinned Uncategorised row + drill-down

- `CategoryBalanceTable`:
  - Add `let uncategorised: InstrumentAmount?` and `let transactionType: TransactionType`.
  - Render an "Uncategorised" row **after** all category sections (pinned bottom)
    when `uncategorised != nil`, as a `NavigationLink(value: UncategorisedDrillDown(...))`.
  - `grandTotal` includes `uncategorised` when present.
  - Accessibility label mirrors category rows.
- Add `struct UncategorisedDrillDown: Hashable { transactionType; dateRange }`.
- `ReportsView`:
  - Pass `reportingStore.incomeUncategorised` / `expenseUncategorised` and the
    correct `transactionType` into each `CategoryBalanceTable`.
  - Add `.navigationDestination(for: UncategorisedDrillDown.self)` →
    `TransactionListView` with title "Uncategorised" and
    `TransactionFilter(dateRange:, uncategorizedLegType: type)`.
- Update `CategoryBalanceTable` `#Preview` to show the row.
- **Verify:** `@ui-review`; render preview if practical.

### Step 6 — Full verification gate

- `just format-check`, `just test-mac` (full), and all relevant reviewers:
  `@code-review`, `@database-code-review`, `@concurrency-review`,
  `@instrument-conversion-review`, `@ui-review`, `@ui-test-review` (as touched).
  Fix every finding, re-review until clean.

## Out of scope

- Recategorising transactions from the report (this is read-only reporting).
- Uncategorised handling anywhere other than the Reports income/expense columns.
