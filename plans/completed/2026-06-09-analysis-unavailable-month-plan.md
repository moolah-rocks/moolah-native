# Analysis "data unavailable" months — Implementation Plan (#1077)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** When crypto prices aren't yet warmed, a financial month whose expense/income rows can't all be priced must surface as **"data unavailable / still loading"** in the Analysis UI — never as a silently-absent or zero/understated month.

**Decision (user, 2026-06-09):** **Strict Rule 11** — a month is unavailable if **any** of its rows failed to price (transient), even if other rows converted. (Not just fully-unpriced months.)

**Architecture:** Add a `hasUnavailableData: Bool` flag to the two domain result types. The two GRDB aggregations track financial months that had ≥1 *transient* conversion skip, mark every emitted bucket for those months, and emit a zeroed placeholder bucket for months that had no successfully-converted rows at all (so the month still appears). `AnalysisStore` threads the flag into the over-time projection. Three Analysis cards render the unavailable state (table shows "—" + unavailable cumulative; pie + over-time show a caption).

**Background:** After #1075, an all-transient-skip month produces **no bucket** (rows skipped, `firstConversionError` stays nil for transient errors), so the month is absent from the income/expense table and dropped from the window-aggregated pie — indistinguishable from "no activity". Both assemble methods carry a comment that the proper fix "requires reshaping `ExpenseBreakdown` and every other analysis result type together". This plan is that reshape.

**Conventions:** Swift Testing only (`import Testing`). `just` targets only. `git -C`/`just -d`. Per task: `just format` → `just format-check` clean → `just build-mac` warning-free → task tests pass → commit. Worktree: `.claude/worktrees/fix-1077-analysis-unavailable` (branch `fix-1077-analysis-unavailable`, off the merged main).

---

## Key facts (from recon)
- `Domain/Models/MonthlyIncomeExpense.swift` — `struct ... : Sendable, Codable, Identifiable, Hashable`; fields month/start/end/income/expense/profit/earmarked*. Memberwise init synthesized.
- `Domain/Models/ExpenseBreakdown.swift` — `struct ... : Sendable, Codable, Identifiable, Hashable`; fields categoryId/month/totalExpenses.
- Producers (only real ones): `GRDBAnalysisRepository+IncomeAndExpense.swift` (`assembleIncomeAndExpense`, `MonthBucket`, `flattenIncomeAndExpenseBuckets`) and `+ExpenseBreakdown.swift` (`assembleExpenseBreakdown`, `flattenExpenseBreakdownBuckets`). In both, the per-row `catch` currently does `handlers.handleConversionFailure(...)` then `if firstConversionError == nil, !ConversionFailureClassifier.isTransient(error) { firstConversionError = error }; continue`. The financial-month key is `Self.financialMonth(for: day, monthEnd:)` and `day = Self.parseDayString(row.day)` is parsed **before** conversion, so it is available in the catch branch.
- `~40 construction sites` of these structs (tests/previews) — a NEW field must be **defaulted** so they compile unchanged. Both types are `Codable`; verify nothing decodes them from storage (they're in-memory) — to be safe, add `decodeIfPresent(... ) ?? false` for the new key.
- `AnalysisStore`: `expenseBreakdown`/`incomeAndExpense` state; `displayedExpenseBreakdown`/`displayedIncomeAndExpense` (clip by month, structural — preserve any flag); `buildCategoriesOverTime` → `CategoryOverTimePoint`(month/monthDate/actualAmount/percentage); `buildExpenseBreakdown` → `ExpenseBreakdownWithPercentage`.
- Cards: `IncomeExpenseTableCard.swift` (per-month rows + `cumulativeSavings` running reduce), `ExpenseBreakdownCard.swift` (window pie), `CategoriesOverTimeCard.swift` (per-month stacked area).
- `financialMonth(for:monthEnd:)` → `YYYYMM` (UTC-anchored).

---

## Task 1: Add `hasUnavailableData` to the two domain types

**Files:** `Domain/Models/MonthlyIncomeExpense.swift`, `Domain/Models/ExpenseBreakdown.swift`; Test: `MoolahTests/Domain/AnalysisUnavailableFlagTests.swift`

- [ ] **Step 1 — failing test.** New suite asserting: (a) the memberwise init defaults `hasUnavailableData` to `false` when omitted (so existing call sites are unaffected); (b) it can be set true; (c) Codable round-trips it; (d) decoding a JSON object **missing** the key yields `false` (the `decodeIfPresent` guarantee). Use `JSONEncoder`/`JSONDecoder`.
- [ ] **Step 2 — run, expect fail** (`just ... test-mac AnalysisUnavailableFlag`).
- [ ] **Step 3 — implement.** Add `var hasUnavailableData: Bool = false` to both structs (a stored property with a default, so the synthesized memberwise init keeps it optional). Add explicit `CodingKeys` including the new key and a custom `init(from:)` that decodes every existing field as today and `self.hasUnavailableData = try container.decodeIfPresent(Bool.self, forKey: .hasUnavailableData) ?? false` (encode stays synthesized or add `encode(to:)` symmetric — keep it simple and correct). Keep `Identifiable.id`/`Hashable` as-is (the flag participates in `Hashable`/`Equatable` synthesis — fine).
- [ ] **Step 4 — run, expect pass.** Also `just ... test-mac DomainModels` to confirm existing model tests unaffected.
- [ ] **Step 5 — format-check, build-mac, commit** `feat(analysis): add hasUnavailableData to income/expense + breakdown models (#1077)`.

## Task 2: Income/expense aggregation marks & emits unavailable months

**Files:** `Backends/GRDB/Repositories/GRDBAnalysisRepository+IncomeAndExpense.swift`; Test: `MoolahTests/Backends/GRDB/GRDBIncomeAndExpenseUnavailableTests.swift`

- [ ] **Step 1 — failing tests.** Using the existing assemble-test harness (`ThrowingCountingConversionService`, the aggregation fixtures): 
  - A month with ONE transient-skipped row and one good row → returned `MonthlyIncomeExpense` for that month has `hasUnavailableData == true` (and still includes the good row's contribution).
  - A month where ALL rows are transient-skipped → a `MonthlyIncomeExpense` IS returned for that month (not absent), zeroed amounts, `hasUnavailableData == true`, with `start`/`end` spanning the month's rows.
  - A clean month (no skips) → `hasUnavailableData == false`.
  - A structural error still throws (unchanged).
- [ ] **Step 2 — run, expect fail.**
- [ ] **Step 3 — implement.** In `assembleIncomeAndExpense`: maintain `var incompleteMonths: Set<String> = []` and `var unavailableDayRange: [String: (start: Date, end: Date)] = [:]`. In the per-row `catch`, when `ConversionFailureClassifier.isTransient(error)`, compute `let month = Self.financialMonth(for: day, monthEnd: monthEnd)`, insert into `incompleteMonths`, and widen `unavailableDayRange[month]` with `day`. After the walk (before `flatten`), for each `m in incompleteMonths` with no existing `buckets[m]`, insert a zeroed `MonthBucket` (start/end from `unavailableDayRange[m]`). Then change `flattenIncomeAndExpenseBuckets` to take `incompleteMonths` and set `hasUnavailableData: incompleteMonths.contains(month)` on each emitted `MonthlyIncomeExpense`. (Structural-error rethrow path unchanged.)
- [ ] **Step 4 — run, expect pass.** Plus existing `GRDBIncomeAndExpenseAssemble` suite green.
- [ ] **Step 5 — format-check, build-mac, commit** `feat(analysis): income/expense marks unavailable months (#1077)`.

## Task 3: Expense breakdown aggregation marks & emits unavailable months

**Files:** `Backends/GRDB/Repositories/GRDBAnalysisRepository+ExpenseBreakdown.swift`; Test: `MoolahTests/Backends/GRDB/GRDBExpenseBreakdownUnavailableTests.swift`

- [ ] **Step 1 — failing tests.** Mirror Task 2: a (month) with a transient-skipped row → emitted `ExpenseBreakdown`(s) for that month have `hasUnavailableData == true`; a fully-skipped month → a placeholder `ExpenseBreakdown(categoryId: nil, month: m, totalExpenses: .zero(instrument: profileInstrument), hasUnavailableData: true)` is emitted; clean months → false; structural still throws.
- [ ] **Step 2 — run, expect fail.**
- [ ] **Step 3 — implement.** Same `incompleteMonths` tracking in `assembleExpenseBreakdown`'s transient catch (`month = Self.financialMonth(for: day, monthEnd:)`). Change `flattenExpenseBreakdownBuckets` to take `incompleteMonths` + `profileInstrument`: set `hasUnavailableData: incompleteMonths.contains(month)` on every emitted row, and for each incomplete month with NO emitted (month,*) row, append the `categoryId: nil` placeholder above. Keep the descending-month sort.
- [ ] **Step 4 — run, expect pass.** Plus existing `GRDBExpenseBreakdownAssemble` suite green.
- [ ] **Step 5 — format-check, build-mac, commit** `feat(analysis): expense breakdown marks unavailable months (#1077)`.

## Task 4: Thread the flag through AnalysisStore projections

**Files:** `Features/Analysis/AnalysisStore.swift` (+ `CategoryOverTimePoint.swift`, `+DisplayWindow.swift` as needed); Test: `MoolahTests/Features/AnalysisStoreUnavailableProjectionTests.swift`

- [ ] **Step 1 — failing tests.** `buildCategoriesOverTime(from:categories:)`: given breakdown rows where some months are `hasUnavailableData`, the produced `CategoryOverTimePoint`s for those months carry `isUnavailable == true`; available months `false`. And a store-level helper, e.g. `displayedExpenseBreakdownHasUnavailableData` / a computed `Bool`, is true iff the displayed breakdown contains an unavailable row. (Keep `displayedIncomeAndExpense` passing the per-row flag through unchanged — clip is structural.)
- [ ] **Step 2 — run, expect fail.**
- [ ] **Step 3 — implement.** Add `let isUnavailable: Bool` to `CategoryOverTimePoint` (default `false` in its init for existing test sites, OR update sites — prefer a defaulted memberwise via an explicit init). In `buildCategoriesOverTime`, a `(category, month)` point is `isUnavailable` if any source breakdown row for that month has `hasUnavailableData`. Add a small computed `var displayedExpenseHasUnavailableData: Bool { displayedExpenseBreakdown.contains(\.hasUnavailableData) }` (and equivalent for over-time if the card needs it). Don't change clip logic.
- [ ] **Step 4 — run, expect pass.** Plus existing `AnalysisStoreCategoriesOverTime` / `AnalysisStoreBuildExpenseBreakdown` suites green (update those fixtures only if the `CategoryOverTimePoint` init changed — prefer a default so they don't).
- [ ] **Step 5 — format-check, build-mac, commit** `feat(analysis): thread unavailable flag into over-time projection (#1077)`.

## Task 5: IncomeExpenseTableCard renders unavailable months

**Files:** `Features/Analysis/Views/IncomeExpenseTableCard.swift`; Test: extend `MoolahTests/Features/IncomeExpenseCumulativeSavingsTests.swift` (+ accessibility test).

- [ ] **Step 1 — failing tests.** A `cumulativeSavings`-style pure-logic test: once a month has `hasUnavailableData == true`, that month's displayed income/expense/profit AND the cumulative-savings value from that month onward are "unavailable" (model the cumulative helper to return an optional / sentinel for unavailable rows). Extract any rendering decision into a testable pure helper (thin-view rule) rather than asserting on SwiftUI.
- [ ] **Step 2 — run, expect fail.**
- [ ] **Step 3 — implement.** In the card: for a row with `item.hasUnavailableData`, render the four amount columns as an unavailable treatment — a secondary "—" with `.accessibilityLabel("\(month): data unavailable, prices still loading")`. Make `cumulativeSavings` propagate unavailability: once an unavailable month is hit, the running cumulative is unavailable for that and all later months (return `nil`/sentinel; render "—"). Keep the logic in a testable static/free helper; the view binds it. Don't blank the whole card.
- [ ] **Step 4 — run, expect pass.**
- [ ] **Step 5 — format-check, build-mac (no warnings), commit** `feat(analysis): income/expense table shows unavailable months (#1077)`.

## Task 6: Pie + over-time cards show an "incomplete" caption

**Files:** `Features/Analysis/Views/ExpenseBreakdownCard.swift`, `Features/Analysis/Views/CategoriesOverTimeCard.swift`, `Features/Analysis/Views/AnalysisView.swift` (pass the flag). Verify via `#Preview` / RenderPreview + `@ui-review`.

- [ ] **Step 1 — implement.** When the card's data includes unavailable months (`ExpenseBreakdownCard`: a new `hasUnavailableData: Bool` param the view passes from `store.displayedExpenseHasUnavailableData`; `CategoriesOverTimeCard`: an `isUnavailable` point in any entry), show a subtle caption beneath the title: `Text("Some prices are still loading — totals may be incomplete").font(.caption).foregroundStyle(.secondary)` with an appropriate `.accessibilityLabel`. Don't blank the card. Wire `AnalysisView.contentView` to pass the flag(s).
- [ ] **Step 2 — build-mac (no warnings); RenderPreview a state with unavailable data to confirm the caption is unobtrusive; run `@ui-review`.**
- [ ] **Step 3 — format-check, commit** `feat(analysis): caption when breakdown/over-time data is incomplete (#1077)`.

## Task 7: Integration, reviews, PR, merge

- [ ] `just format` → `just format-check` clean → `just build-mac` + `just build-ios` (no warnings).
- [ ] Full `just test-mac` (0 failures) → `.agent-tmp/full.txt`.
- [ ] Review agents: `@code-review`, `@instrument-conversion-review` (Rule 11 partial-failure now surfaced as unavailable), `@ui-review`. Apply all findings.
- [ ] Push `fix-1077-analysis-unavailable:fix-1077-analysis-unavailable`; `gh pr create` (Fixes #1077, reference #1075). Land via `landing-prs` (`land-pr.sh <N>`); monitor queue to merge (re-enqueue on unrelated flake).

## Self-review
- Coverage: domain flag (T1) ↔ both aggregations (T2/T3) ↔ store projection (T4) ↔ three cards (T5/T6). Strict Rule 11 (any-skip) honored in T2/T3. Defaulted fields keep ~40 sites compiling. Structural-error rethrow preserved. Daily-balances/forecast untouched (already per-day scoped).
- Consistency: `hasUnavailableData` name used on both domain types and the store helper; `CategoryOverTimePoint.isUnavailable` for the projection.
