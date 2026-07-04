# Transaction-list SQL pagination

## Problem

`GRDBTransactionRepository.fetch(filter:page:pageSize:)` materializes the
**entire** filtered transaction table on every call, then slices a page in
Swift. On a 20k-transaction profile this is a consistent ~400ms per fetch.
Because the list re-fetches through `ValueObservation` on every edit, every
transaction edit pays this ~400ms — felt as ~1s latency before the list
updates. `recomputeBalances` is 0ms; the cost is entirely the full-table
materialization in `candidateTransactionRows` (`fetchAll` with no SQL
`LIMIT`).

Goal: make `fetch` cost O(window + index walk) instead of O(table), by
pushing pagination, counting, and the after-page subtotal into SQL.

## Background / current shape

- `Backends/GRDB/Repositories/GRDBTransactionRepository.swift` — `fetch(...)`
  (~L133): resolves `instrumentMap()`, opens one `database.read` that calls
  `buildFetchSnapshot`, then `resolvePriorBalance` on the caller's actor.
- `Backends/GRDB/Repositories/GRDBTransactionRepository+Fetch.swift` —
  `buildFetchSnapshot`, `candidateTransactionRows` (the `fetchAll`),
  `applyLegFilters` (in-memory leg-filter intersect), `subtotalsAfterPage`,
  `resolveTargetInstrument`.
- `Backends/GRDB/Repositories/GRDBTransactionRepository+Observation.swift` —
  `observe(...)` (~L77) reuses `buildFetchSnapshot` inside a
  `ValueObservation.tracking` over `transaction`/`transaction_leg`/`account`
  regions. Both the imperative and observed paths share `buildFetchSnapshot`,
  so changing it fixes both.
- Runtime paging model: the store always observes `page: 0` with a growing
  window `pageSize * pageWindow`; `hasMore` derives from row count, not
  `totalCount`. True `OFFSET` (page > 0) is exercised only by repository
  contract/ordering tests.
- The single live `TransactionRepository` is `GRDBTransactionRepository`.
  `CloudKitTransactionRepository` does not exist (dead doc-comment refs only);
  there is **no parallel implementation to keep in sync**.

## Global Constraints (bind every task)

1. **Ordering is `date DESC, id ASC`** — the `id ASC` tiebreaker among equal
   dates is load-bearing (it makes `LIMIT/OFFSET` deterministic) and is pinned
   by `TransactionRepositoryOrderingTests`. Never drop it.
2. **`scheduled` quirk**: `.all` and `.nonScheduledOnly` BOTH mean
   `recur_period IS NULL`; only `.scheduledOnly` means `recur_period IS NOT
   NULL`. (Matches current `+Fetch.swift` behavior.)
3. **`dateRange` is inclusive** both ends (`date >= lower AND date <= upper`).
4. **`payee` is a case-insensitive substring**: `lower(payee) LIKE '%term%'`.
   Leading-wildcard LIKE is not index-usable — that is acceptable and
   unchanged.
5. **Leg filters intersect (AND) with each other and with txn filters**:
   - account scope = union (OR) of `accountId` and `accountIds`
     (`account_id IN (union)`), empty union → no account filter.
   - `earmarkId` → legs with that earmark.
   - `categoryIds` → legs with category in set, empty → no-op.
   Preserve the partial-index `WHERE … IS NOT NULL` coverage: do not rewrite
   a leg predicate into a form that must also match NULL.
6. **`priorBalance` / after-page subtotal semantics unchanged**: prior balance
   is the per-instrument sum of **member-account** legs of all filtered
   transactions that sort AFTER the page (older, since order is `date DESC`),
   converted to the resolved target at today's rate; returns zero when there
   is no account scope or the page is past the end; returns nil if any foreign
   leg fails conversion. (Conversion stays on the caller's actor in
   `resolvePriorBalance` — only the raw per-instrument subtotals move to SQL.)
7. **`resolveTargetInstrument` unchanged**: single-account → account's own
   instrument; group/global → profile default.
8. **No SQL injection.** Per `guides/DATABASE_CODE_GUIDE.md` only one unsafe
   SQL shape is tolerated repo-wide. Prefer the GRDB query interface; UUID
   sets and scalars must be bound parameters, never interpolated.
9. **Every behavior test listed below must stay green**, and `just build-mac`
   must pass. Run `just format-check` after each task.

## Constraining tests (must stay green unless a task says to update one)

- Ordering: `MoolahTests/Domain/TransactionRepositoryOrderingTests.swift`
  (`testScheduledTiesBreakById`, `testScheduledOrderByDateDescThenId`,
  `testPaginationStableAcrossCallsOnSameDate`).
- priorBalance: `MoolahTests/Domain/TransactionRepositoryPriorBalanceTests.swift`
  (across-pages, empty-page, account-instrument label, multi-instrument
  converts, nil-on-conversion-failure, single-instrument-no-conversion).
- Group priorBalance: `MoolahTests/Domain/TransactionGroupPriorBalanceTests.swift`.
- Running balance (store, end-to-end through fetch):
  `MoolahTests/Features/TransactionStoreRunningBalanceTests.swift`
  (after create/delete/amount-change; group ties out across pages).
- Pagination / totalCount / hasMore:
  `MoolahTests/Features/TransactionStoreLoadingTests.swift`,
  `MoolahTests/Features/TransactionStoreLoadRaceTests.swift`.
- Observation contract (totalCount):
  `MoolahTests/Domain/TransactionRepoObservationContractTests.swift`.
- Filters: `MoolahTests/Domain/TransactionRepositoryFilterTests.swift`,
  `MoolahTests/Domain/TransactionRepositoryAuxFilterTests.swift`.
- Plan-pinning (EXPLAIN): `MoolahTests/Backends/GRDB/TransactionFetchPlanPinningTests.swift`
  — `subtotalsAfterPageCompoundFilterUsesIndex` (Task 3 updates this).
- Benchmarks (re-baseline, Task 4):
  `MoolahBenchmarks/TransactionFetchBenchmarks.swift`,
  `MoolahBenchmarks/PriorBalanceBenchmarks.swift`.

All repository tests run through `makeContractCloudKitTransactionRepository`
(`MoolahTests/Support/TransactionContractTestFixtures.swift`) — despite the
name it builds a GRDB repo.

---

## Task 1 — Add composite `(date DESC, id ASC)` index

**Files:** `Backends/GRDB/ProfileSchema.swift` (register a new migration) plus
a new migration source file following the existing per-migration file pattern
(e.g. alongside `ProfileSchema+DropForeignKeys.swift`).

**What:** Add an index supporting the page query's `ORDER BY date DESC, id
ASC` + `LIMIT/OFFSET`. The existing `transaction_by_date` covers only `date`,
so the `id` tiebreaker among equal dates forces a temp B-tree sort.

- Add a NEW, separately-registered migration only. Its body does
  `CREATE INDEX IF NOT EXISTS transaction_by_date_id ON "transaction"(date
  DESC, id ASC)` (via GRDB's `db.create(index:...)` if the project uses that
  form, else raw `db.execute`). Register it after the current last migration in
  `ProfileSchema.swift`, matching the registration pattern of recent
  migrations.
- **Do NOT edit the shipped create migration** in
  `ProfileSchema+CoreFinancialGraph.swift` (editing a shipped migration leaves
  already-migrated databases inconsistent). Fresh databases get the index for
  free by replaying the full migration list including this new one — no
  fresh-create-path edit is needed or wanted.
- Verify there is no pre-existing index with the chosen name; pick a
  non-colliding name if `transaction_by_date_id` is taken.

**Verify:** `just build-mac`; the schema-review gate runs at the end. Add or
extend a migration test if the repo has a pattern for asserting an index
exists after migration (search `MoolahTests` for existing index/migration
assertions; if none exists, do not invent a framework — a fresh-DB
`EXPLAIN QUERY PLAN` assertion is added in Task 3).

**Out of scope:** any query change.

---

## Task 2 — Push pagination, filtering, and counting into SQL

**File:** `Backends/GRDB/Repositories/GRDBTransactionRepository+Fetch.swift`
(and `…Repository.swift` `fetch` if signatures shift).

Replace the "fetch all rows, filter+slice in Swift" core with SQL pushdown.

1. **Introduce one filtered-request builder** — a function that returns a GRDB
   request (NOT fetched) for the filtered transaction set, applying:
   - txn-level: `scheduled` (Constraint 2), `dateRange` (3), `payee` (4);
   - leg-level (Constraint 5): account union, `earmarkId`, `categoryIds`, each
     expressed as a subquery/EXISTS so they constrain the paginated query
     (e.g. `id IN (SELECT transaction_id FROM transaction_leg WHERE …)`),
     intersecting. Bind all UUIDs as parameters (Constraint 8).
   This replaces `candidateTransactionRows` + `applyLegFilters`.

2. **Page rows**: order the request `date DESC, id ASC`, `LIMIT pageSize OFFSET
   page*pageSize`, fetch ONLY that page, then map the page rows to domain and
   `fetchLegs` for the page (unchanged). No full-table materialization.

3. **`totalCount`**: `fetchCount` over the filtered request (replaces
   `filteredRows.count`).

4. **`isPastEnd`**: page is past end when `offset >= totalCount` (or simply
   when the page fetch returns empty AND offset > 0) — preserve the existing
   `FetchSnapshot.isPastEnd` contract and the empty-page priorBalance behavior
   (Constraint 6).

5. Keep `resolveTargetInstrument` (Constraint 7) and the
   `FetchSnapshot`/`SubtotalEntry` types. `afterPageSubtotals` is rewritten in
   Task 3; for THIS task it is acceptable to keep computing it from an
   after-page id list derived via the filtered request
   (`… LIMIT -1 OFFSET end` to fetch the after-page ids, then the existing
   `subtotalsAfterPage`), so behavior stays identical and Task 3 swaps in the
   aggregate. Do NOT reintroduce a full-row `fetchAll`.

**Verify:** all Ordering, Filter, Pagination, totalCount, priorBalance, and
running-balance suites green (run the specific files in the Constraining-tests
list); `just build-mac`; `just format-check`. The plan-pinning test must still
pass (unchanged in this task).

---

## Task 3 — Replace the after-page subtotal with a SQL aggregate; update plan-pinning test

**Files:** `…Repository+Fetch.swift` (`subtotalsAfterPage`),
`MoolahTests/Backends/GRDB/TransactionFetchPlanPinningTests.swift`.

1. Rewrite the after-page subtotal as a single SQL aggregate: per-instrument
   `SUM(quantity)` over `transaction_leg` where `account_id IN (members)` AND
   `transaction_id IN (<after-page subquery>)`, grouped by `instrument_id`,
   returning `[SubtotalEntry]`. The after-page subquery is the Task-2 filtered
   request ordered `date DESC, id ASC` with `LIMIT -1 OFFSET end`. This removes
   the need to fetch the after-page id list into Swift. Member set, conversion,
   and the zero/nil rules stay in `resolvePriorBalance` (Constraint 6).
   Preserve account-id index coverage (Constraint 5/8).

2. **Update `subtotalsAfterPageCompoundFilterUsesIndex`** to EXPLAIN the new
   aggregate query and assert it stays index-backed (`leg_by_account` or the
   `leg_analysis_*` covering index; no `SCAN transaction_leg`).

3. **Add plan-pinning tests for ALL THREE new Task-2 query shapes** (this
   closes the Important finding from the Task-2 database-code-review — the new
   shapes run on every list page load and currently have no plan guard). In
   `TransactionFetchPlanPinningTests.swift`, add EXPLAIN-QUERY-PLAN tests
   asserting **no `SCAN "transaction"`** (and, for the ordered shapes, that the
   `transaction_by_date_id` index from Task 1 is used) for:
   - the **page query**: `… WHERE recur_period IS NULL [AND id IN (leg
     subquery)] ORDER BY date DESC, id ASC LIMIT ? OFFSET ?`;
   - the **count**: `SELECT COUNT(*) … WHERE recur_period IS NULL [AND id IN
     (leg subquery)]`;
   - the **after-page id fetch**: same ordered shape with `LIMIT -1 OFFSET ?`.
   Cover BOTH the no-leg-filter case (only `recur_period IS NULL`) and the
   with-account-filter case (`id IN (SELECT transaction_id FROM
   transaction_leg WHERE account_id IN (?, ?))`), since GRDB may pick different
   plans. First run `EXPLAIN QUERY PLAN` locally to capture the exact plan
   strings, then write the positive `transaction_by_date_id` assertions to
   match the real output. Reuse the existing `PlanPinningTestHelpers`
   (`makeDatabase`, `planDetail`, `planHasFullTableScanOf`). Keep the suite's
   "follows DATABASE_CODE_GUIDE §6" intent.

   Note: the Task-2 SQL for the page/count shapes is final (Task 3 only changes
   the after-page subtotal), so pinning them here is correct and stable. If
   the local EXPLAIN reveals a shape that genuinely cannot use
   `transaction_by_date_id` (e.g. the planner prefers a leg index when a
   leg-filter subquery is present), assert only the no-full-scan invariant for
   that case and record why in the test comment — do not weaken the no-scan
   assertion.

**Verify:** plan-pinning suite green with the updated assertions; priorBalance
+ group priorBalance + running-balance suites green; `just build-mac`;
`just format-check`.

---

## Task 4 — Re-baseline benchmarks & finalize

1. Run the two benchmark suites and update their baselines per the repo's
   benchmark workflow (see `MoolahBenchmarks/TransactionFetchBenchmarks.swift`,
   `PriorBalanceBenchmarks.swift`; use the `interpret-benchmarks` /
   `write-benchmark` conventions). Record before/after fetch timings in the
   report.
2. Confirm full `just build-mac` + the complete affected test set pass.

**Verify:** benchmarks recorded; build + tests green.

## Final review gate (controller-run, after Task 4)

- `database-schema-review` (Task 1 migration/index).
- `database-code-review` (Tasks 2–3 query/repository changes).
- Broad whole-branch code review.
- Re-measure in the running app (20k profile) to confirm `repo.fetch` drops
  from ~400ms to the target O(window) range.
