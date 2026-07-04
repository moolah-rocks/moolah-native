# Companion graphs for the remaining insight kinds — execution plan

**Date:** 2026-06-05
**Status:** In progress
**Builds on:** `plans/2026-06-04-insight-companion-graphs-design.md` (framework
shipped in PR #1053).

## Goal

Extend the insight companion-graph framework to the remaining `InsightKind`s
that have a meaningful time series **already present in `InsightInput`**. Follow
the established pattern exactly:

1. A pure builder in `InsightChartBuilders` returning `InsightChart?` — returns
   `nil` when data is too sparse (reuse `minimumPoints`); values already in
   reporting currency; signs preserved (no `abs()`).
2. Attach it as the trailing `chart:` argument of the detector's `Insight(...)`,
   using only data already in `InsightInput` (no new aggregation).
3. A builder unit test (when a new builder is added) + a detector-level test
   asserting the chart attaches with the right unit/highlight (Swift Testing,
   `InsightTestSupport`).

Keep detectors pure and views thin. `just build-mac` / `test-mac` /
`format-check` green; `@code-review` + `@concurrency-review`; ship via PR, one
family per PR.

## Batches (one PR each)

### PR 1 — Liquidity (`runwayEstimate`, `idleCashAlert`)
Reuse `InsightChartBuilders.balanceForecast`. Both detectors already hold
`dailyBalances`; attach the balance + forecast-tail chart, highlighting the
latest actual balance ("you are here"). No new builder. Detector-level tests
assert the chart attaches with `.currency` unit and the latest-actual highlight.

### PR 2 — Period comparison (`monthOverMonthDelta`)
New builder `monthlySpend(monthly:reportingCurrency:highlightMonth:)` — a bar
series of total spend magnitude per complete financial month, highlighting the
latest. Attach in `PeriodComparisonInsights`.

### PR 3 — Recurring streams (`subscriptionPriceHike`, `payRateChange`,
`incomeStabilityScore`, `paycheckTimingPattern`)
Surface the per-occurrence dates the detector already computes on
`DetectedSubscription` (parallel to `amounts`). New builder
`recurringCharges(...)` — a line/bar of signed charge/income magnitude over the
occurrence dates, highlighting the latest. Attach across `SubscriptionInsights`,
`IncomeInsights`, and `IncomeExtraInsights`.

### PR 4 — Fee spend (`feeSpend`)
New builder `monthlyCategorySpend(expenseBreakdown:categoryIds:reportingCurrency:)`
— a bar series summing the fee categories' monthly spend from `expenseBreakdown`
(already in `InsightInput`), highlighting the latest month. Thread
`expenseBreakdown` into `SavingsOpportunityInsights.feeSpend`.

## Explicitly skipped (no sensible time series)

- **Investments** (`topPerformer`, `bottomPerformer`,
  `investmentConcentrationRisk`, `capitalGainsHarvest`): `InstrumentProfitLoss`
  in `InsightInput` is a point-in-time snapshot (no per-instrument value
  history); `capitalGains` is a scatter of discrete sell events. No honest
  date-keyed series without new aggregation. Decision confirmed with the user
  2026-06-05.
- `categoryMixShift`, `weekendSpendSkew`, `unusualDaySpend`,
  `largeTransactionAnomaly`, `newMerchantAlert`, `uncategorizedBacklog`,
  `unreconciledTransfers`, `groupSpendConcentration`, `unbudgetedCategory`,
  `duplicateSubscription`, `subscriptionOverspend`, `windfallIncome`,
  `missingPaycheckAlert`, `earmarkUnderspend`, `savingsGoalETA` — point events,
  share-shifts, or single-value comparisons without a meaningful trend in the
  available data.
