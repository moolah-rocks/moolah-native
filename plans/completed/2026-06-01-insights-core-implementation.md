# Personalized Insights — Core Detector Implementation

Implements the deterministic detection layer for Use Case 2 (Personalized
Insights) of `plans/2026-04-18-on-device-ai-design.md`. This is the
**core logic only** — pure-Swift statistical detectors operating on real
domain data. It is intentionally **not** wired into the UI; a follow-up
task picks up this branch and connects it to a surface ("For You" panel,
per-category/-account views, etc.).

## What landed

All under `Domain/Insights/` (pure domain layer — no SwiftUI, no SwiftData,
no backend imports), with a test suite under `MoolahTests/Domain/Insights/`.

### Core model
- `Insight` — the unit produced by detectors: id, kind, template `title`/
  `detail` narration, `date`, `framing` (positive/neutral/negative),
  `actionability` (act/review/informational), normalised `surprise`,
  signed `monetaryImpact`, structured `facts` (the only numbers a future
  LLM narration layer may print — zero-hallucination contract), and
  `references` (account/category/earmark/instrument/transaction ids for
  deep-linking).
- `InsightKind` — catalog enum, numbered to the design's §"Insight Catalog".
- `InsightContext` — ambient `now`, reporting currency, calendar,
  financial-month boundary (all injected for deterministic tests).
- `InsightInput` — the substrate bundle the engine consumes.
- `InsightTransaction` / `ScheduledBill` / `EarmarkSnapshot` — the
  currency-normalised inputs (see "Currency boundary" below).

### Detectors (catalog item → file)
- **Subscriptions** — `SubscriptionDetector` clusters streams;
  `SubscriptionInsights` produces new-recurring (5), price-hike (2),
  duplicate (3), cancellation-candidate (4). Overspend (23) is in
  `SavingsOpportunityInsights`.
- **Anomalies** — `LargeTransactionInsight` (7, MAD-z),
  `NewMerchantInsight` (8), `UnusualDayInsight` (9),
  `CategoryAnomalyInsight` (6, seasonal-trend decomposition).
- **Trends** — `CategoryTrendInsight` (10, Mann-Kendall + Sen's slope +
  Benjamini-Hochberg FDR), `PeriodComparisonInsights` (11, MoM),
  `CategoryMixShiftInsight` (12).
- **Cash flow** — `CashFlowForecastInsights` (13 upcoming-bill, 15
  projected month-end), `LiquidityInsights` (17 runway, 21 idle-cash),
  `SavingsRateInsight` (16).
- **Budgets** — `EarmarkBudgetInsights` (18 burndown, 19 under-spend),
  `SavingsGoalInsight` (20).
- **Income** — `IncomeInsights` (14 paycheck timing, 29 stability, 30
  missing paycheck), built on `SubscriptionDetector` over income streams.
- **Investments / net worth** — `NetWorthInsights` (24),
  `InvestmentInsights` (25 concentration, 26 top/bottom performer, 27
  conservative tax-loss-harvest prompt).
- **Fees** — `SavingsOpportunityInsights.feeSpend` (22).

### Statistics (pure, reusable)
`DescriptiveStatistics` (median/MAD/robust-z/percentile/CV),
`MannKendall` (+ Sen's slope), `BenjaminiHochberg`, `SeasonalDecomposition`
(STL-lite, documented simplification), `NormalDistribution`.

### Ranking & fatigue
`InsightRanker` implements the design's scoring model
(`surprise + actionability + log(magnitude) + recency + interest −
fatigue`), de-dupes by id, applies a display cap, and **guarantees one
positive-framed insight** per surface when one exists.

### Orchestration
`InsightEngine.detectAll(_:)` runs every detector;
`InsightEngine.generate(_:dismissals:interests:displayCap:)` returns ranked
`ScoredInsight`s.

## Currency boundary (important for wiring)

Detectors are **pure and synchronous**, but `InstrumentConversionService`
is async. The boundary is drawn at input assembly:

- The wiring layer converts every leg / earmark / bill amount to the
  reporting currency **once, up front**, and builds `InsightTransaction`,
  `EarmarkSnapshot`, and `ScheduledBill` already denominated in one
  instrument.
- `InsightTransaction.records(from:categories:convert:)` flattens
  `[Transaction]` using an injected `(InstrumentAmount, Date) -> Decimal?`
  converter; a leg whose conversion returns `nil` is dropped (Rule 11 — no
  partial/guessed totals). `sameCurrencyRecords(...)` is the single-currency
  convenience.

Sign convention is preserved throughout (income +, expense −, refunds kept;
never `abs()`). Note: the backend's `MonthlyIncomeExpense.expense` and
`ExpenseBreakdown.totalExpenses` are **negative** sums; detectors flip to a
positive spend magnitude explicitly where needed.

## How to wire it up (next task)

1. Build an `InsightInput` per surface refresh, off-main, from the existing
   stores:
   - `transactions` ← `TransactionRepository.fetchAll` → convert legs →
     `InsightTransaction.records`.
   - `monthly` ← `AnalysisStore.incomeAndExpense`;
     `expenseBreakdown` ← `AnalysisStore.expenseBreakdown`;
     `dailyBalances` ← `AnalysisStore.dailyBalances`.
   - `earmarks` ← join `EarmarkStore.earmarks` with its converted-balance /
     saved / spent dictionaries into `EarmarkSnapshot`.
   - `profitLoss` / `capitalGains` ← `ReportingStore`.
   - `scheduledBills` ← project upcoming scheduled transactions.
   - `categories` ← `CategoryStore.categories`.
2. Call `InsightEngine().generate(input, …)` and publish the
   `[ScoredInsight]` from a `@MainActor` store per
   `guides/CONCURRENCY_GUIDE.md`.
3. Persist per-kind dismissal counts to feed the ranker's fatigue term.

## Not in scope here
- UI surfaces, the `@MainActor` insights store, persistence of dismissals.
- Foundation Models narration / "why?" / conversational assistant
  (design Phases 3–4). The `facts` array is the seam for that later.
- `swift-format` / SwiftLint pass — this branch was authored without the
  Swift toolchain available; run `just format` and `just format-check`
  before merge.
