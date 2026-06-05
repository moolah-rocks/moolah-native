# Companion graphs for insights — design

**Date:** 2026-06-04
**Status:** Approved (design); pending implementation plan

## Problem

The "For You" insights on the Analysis page render as a short vertical list of
rows (framing icon + AI headline + monetary impact + controls). A detected
behaviour — "dining out is up 62% this month" — is stated but not *shown*. The
user can't see the trend that produced the insight without leaving the page.

We want each insight detector, **wherever the data supports it**, to attach a
companion graph that visualises the detected behaviour. The Analysis page then
shows each insight as a panel with the headline and a small graph, and the user
can click the graph to zoom it into a larger view with axes and detail.

## Goals

- A detector can attach a companion chart to the `Insight` it produces, computed
  as pure data (no charting logic in views), matching the existing discipline
  where detectors compute and views render.
- The Analysis "For You" section renders insights as **full-width panels**:
  headline + impact + controls on the left, a small graph on the right.
- Clicking an insight's graph opens a **centered sheet** with the enlarged chart
  (axes, highlighted anomaly), the insight's structured facts, and its deep-link
  actions.
- Ship the framework plus charts for the four highest-value insight families;
  the rest get charts incrementally later.

## Non-goals (this cut)

- Charts for the remaining ~30 insight kinds.
- Any new aggregation in `InsightInput` (e.g. earmark spend history,
  per-subscription charge history). The first cut uses only data already present
  in `InsightInput`.
- Changes to insight ranking, AI headline narration, fatigue/"show less", or
  dismissal behaviour.

## Decisions (from brainstorming)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Scope | Framework + high-value subset | Proves the pipeline end-to-end without a 43-way slog. |
| Chart representation | Generic `InsightChart` value type | Keeps detectors pure/testable, crosses actor boundaries cleanly, matches the "facts are the single source of truth" philosophy. |
| Panel layout | Full-width rows with side graph (option B) | Closest to today's list; preserves existing controls; gives the graph real estate. |
| Graph-less insights | Stay as today's compact rows | No empty panels; minimal disruption. |
| Zoom presentation | Centered sheet/dialog | Self-contained, identical on macOS and iOS, reads as a focused "zoom". |
| First-cut families | Category spending, Cash-flow forecast, Savings & income, Net worth & earmarks | Clearest charts; data already in `InsightInput`. |

## Architecture

### 1. Data model — `InsightChart`

New file `Domain/Insights/InsightChart.swift`. A `Sendable`/`Hashable` value type
the detector computes and the view renders.

```swift
struct InsightChart: Sendable, Hashable {
  enum Kind: Sendable { case line, bar, area }
  enum Unit: Sendable { case currency(Instrument), percent, count }
  enum SeriesRole: Sendable { case primary, projected, baseline }
  enum XAxisStyle: Sendable { case monthly, daily }

  let kind: Kind
  let unit: Unit
  let series: [Series]
  let highlight: Point?        // anomalous point/period to mark
  let xAxis: XAxisStyle        // drives tick formatting

  struct Series: Sendable, Hashable, Identifiable {
    let id: String             // series key (e.g. "actual", "projected", category id)
    let label: String          // legend label
    let role: SeriesRole       // .projected → dashed; .baseline → reference line
    let points: [Point]
  }

  struct Point: Sendable, Hashable {
    let date: Date
    let value: Double          // in the chart's stated `unit`; reporting-currency amount for
                               // `.currency`, a 0...1 fraction for `.percent`, a tally for `.count`.
                               // `Double` matches the Swift Charts mark y-value idiom; currency
                               // labels reconstruct `InstrumentAmount(quantity: Decimal(value), …)`
                               // exactly as `NetWorthGraphCard` does.
  }
}
```

`Insight` (`Domain/Insights/Insight.swift`) gains:

```swift
let chart: InsightChart?   // default nil; existing detectors unaffected
```

added to the struct and to the `init` (defaulted `nil`). Because it is pure data
it travels with the insight across the off-main-actor → main-actor boundary and
is unit-testable.

**Sign convention:** point values preserve their natural sign; the renderer never
`abs()`-es. Spend-over-time series carry positive magnitudes because
`ExpenseBreakdown.totalExpenses` is already a positive magnitude — the detector,
not the view, decides the values.

**Currency formatting:** `.currency(Instrument)` carries the reporting instrument
so the view can format axis ticks and the detail facts without a global currency.

### 2. Chart builders — one pure helper per family

Each builder is a pure function that turns the relevant `InsightInput` arrays
into an `InsightChart`. All required data already exists in `InsightInput`
(verified). Builders live alongside their detectors (or in a shared
`InsightChartBuilders` utility if reuse emerges).

- **Category spending** — `categorySpendingAnomaly`, `categoryTrendRising`,
  `categoryTrendFalling`. Source: `expenseBreakdown` (per-category per-month),
  reusing the existing `CategorySpendSeries.build`. Chart: bar or line of the
  category's last ~12 financial months in reporting currency; `highlight` = the
  anomalous / latest month.
- **Cash-flow forecast** — `projectedMonthEndBalance`, `upcomingBillWarning`,
  `runwayEstimate`. Source: `dailyBalances` (`DailyBalance`). Two series:
  `.primary` = actual (`!isForecast`), `.projected` = forecast tail
  (`isForecast`, dashed); `highlight` = the dip / threshold point.
- **Savings & income** — `savingsRateTrend`, `monthOverMonthDelta`,
  `incomeStabilityScore`. Source: `monthly` (`MonthlyIncomeExpense`). Either a
  savings-rate-% line (`unit: .percent`) or income-vs-expense bars; `highlight`
  = latest month.
- **Net worth & earmarks**:
  - `netWorthMilestone` — net-worth line from `dailyBalances.netWorth`, optional
    `.baseline` series from `DailyBalance.bestFit`.
  - `earmarkBurndownProjection` — `EarmarkSnapshot` carries **point-in-time
    totals only, no history**, so this is an honest *projected* burndown: a
    `.baseline` at the full budget, a `.primary` point at the current actual
    (`budget − spent`), and a `.projected` (dashed) line to the projected final
    spend at the window end — reusing the linear extrapolation the detector
    already computes. It is never presented as real historical data.

### 3. UI — layout B

`Features/Insights/Views/`:

- **`ForYouCard`** renders each item as a full-width **panel**: headline +
  monetary impact + controls (`View` / `Show less`) on the left, a small graph
  (~200×72) on the right. An item whose `insight.chart == nil` renders as today's
  compact row. Ranking, headlines, fatigue, and dismissal are unchanged.
- **`InsightChartView`** (new) — the generic renderer over `InsightChart`, drawn
  with Swift Charts. Small/inline mode (no axes, sparkline-style) for the panel;
  full mode (axes, legend, highlighted anomaly) for the detail sheet. Tapping the
  inline graph opens the detail sheet.
- **`InsightChartDetailSheet`** (new) — a centered sheet over the dimmed Analysis
  page: headline, full `InsightChartView`, the insight's existing `facts` listed,
  and the insight's deep-link actions (`View transactions` / `Show less`). Reads
  only data already on the `Insight`; no recompute. Dismiss via close button or
  click-outside.

The inline graph and the detail chart render the **same `InsightChart` model** at
different sizes — no second data path.

### 4. Data flow

Unchanged from today except the chart rides along:

```
InsightInputBuilder.build()  (off-main)
  → InsightEngine.generate()  → detectors now also call their chart builder,
                                 attaching InsightChart to the Insight
  → ScoredInsight ranking
  → InsightStore headline resolution → ForYouItem (carries the Insight, incl. chart)
  → ForYouCard panel (inline InsightChartView)
       → tap graph → InsightChartDetailSheet (full InsightChartView + facts + actions)
```

Charts are computed eagerly inside the pure detectors during `generate()`
off-main; the arithmetic is cheap over already-aggregated arrays.

### 5. Error / edge handling

- A family whose data is too sparse to chart (e.g. < 2 points) leaves
  `chart == nil` → the insight falls back to a compact row. No empty graphs.
- The detail sheet tolerates a single-point or projection-only chart (draws the
  point + projection without a misleading historical line).
- Reporting-currency conversion failures are already handled upstream in
  `InsightInput`; the builders consume only pre-converted values.

## Testing

- **Builder unit tests** (per family): feed known `InsightInput` slices, assert
  the produced `InsightChart` — series count/roles, point values, `highlight`,
  `unit`. Pure and fast, no simulator.
- **Detector tests**: extend existing detector tests for the four families to
  assert `chart != nil` and that `highlight` matches the detected anomaly/period.
- **UI test** (`MoolahUITests_macOS`): one flow — an insight panel shows a graph,
  tapping it opens the detail sheet (gated by an `.accessibilityIdentifier` on
  the inline graph and the sheet).
- Follows `guides/TEST_GUIDE.md`, `guides/UI_TEST_GUIDE.md`, and the thin-view
  discipline (all chart-shaping logic in builders, none in views).

## Rollout

Single feature branch / PR for the framework + four families. Remaining insight
kinds get charts in follow-up PRs, reusing `InsightChart` and `InsightChartView`
with no model changes expected.
