# Overspend Insight — Eliminating False Positives

**Date:** 2026-06-05
**Status:** Design (pre-implementation)
**Area:** `Domain/Insights/Detectors/CategoryAnomalyInsight.swift`, `Features/Analysis/AnalysisStore.swift`

## Problem

The "For You" overspend insight raises false positives. In the Large Test
Profile it reports *"You've overspent by 600% on superannuation this month"*
for an **annual** $80,000 payment that follows the exact same pattern as the
prior year. The card shows:

- Category: Superannuation
- This month: −$80,000.00
- Expected: −$11,428.57
- Over by: 600%

`$11,428.57 ≈ $80,000 / 7` — the detector saw a short, mostly-zero series (one
$80k spike and ~6 zero months), so its "expected" collapsed to the flat mean
and the single payment read as a 600% overspend.

A second class of false positive is a **one-off lump** — e.g. a house
purchase. Spending a lot on a house once is not an "overspend"; there is no
*usual* spend in that category to overspend against.

## Root Cause (two compounding causes)

The card is produced by `CategoryAnomalyInsight.detect`, which builds a
per-category gap-filled monthly spend series, runs a seasonal-trend
decomposition (`SeasonalDecomposition.decompose(_, period: 12)`), and flags the
latest month when its decomposition *remainder* is a robust-z outlier
(`z ≥ 3`) and `remainder / expected ≥ 0.25`.

**Cause 1 — the data window is coupled to an unrelated UI filter.** The
detector consumes `sources.analysis.expenseBreakdown` — whatever the **Analysis
screen** last loaded. That window is `AnalysisStore.historyMonths`, a
*user-facing display filter* that **defaults to 12 months** and is persisted per
profile (`UserDefaults` key `analysisHistoryMonths`). So the insight's history
is whatever the user last set the Analysis chart to. A 12-month window cannot
contain two annual occurrences with any margin, and the seasonal term needs
**≥2 full periods (24 months)** to estimate an annual cycle at all.

**Cause 2 — the algorithm can't recognise a recurring or lump spike from few
occurrences.** The robust z-score uses median + MAD, which is *resistant* to one
or two prior spikes — so even with a wider window, a single prior $80k payment
12 months ago does **not** tame the z-score. The STL `seasonal` term only
absorbs the spike once there are ~2–3 occurrences in the *same* month bucket,
and ±1-month date drift (a payment that posts in June one year and early July
the next) defeats it entirely. And nothing in the detector distinguishes a
*one-off lump* in an otherwise-empty category from a genuine overspend on a
regular habit.

## Goals

1. Stop annual / periodic recurring payments misfiring as overspend.
2. Stop one-off lumps (house, car) misfiring as overspend.
3. Keep firing for genuine overspends on categories the user spends in
   regularly (e.g. a real dining blowout).
4. Reuse the existing single analysis data load; do not introduce an
   independent insight fetch.
5. Never let the insight's wider load *cap* a larger window the Analysis UI
   asks for (5 years / All).

## Non-Goals

- Coupling the detector to scheduled / recurring transaction templates. The
  fix works purely from the monthly spend series. (Considered and explicitly
  out of scope.)
- Changing the budget-based `EarmarkBudgetInsights` overspend path.

## Design

### Part 1 — AnalysisStore loads wide, windows down for the UI

The fetch stops being driven solely by the display filter. `AnalysisStore`
becomes the single owner of a dataset sized for insights; the Analysis UI takes
a *window* into it.

- **Insight history floor:** a constant, **36 months** (3 years) — enough for
  three same-month samples so the seasonal estimate is robust and so the lag
  guard always has prior cadence to compare against.

- **Effective load window = max(user window, floor):**

  ```
  floorDate = now − 36 months
  effectiveAfter =
      nil                            if historyMonths == 0 ("All")  // load everything
      earlierOf(floorDate, userDate) otherwise                      // the larger window
  ```

  | User display filter | Loaded            | UI shows | Insights see |
  | ------------------- | ----------------- | -------- | ------------ |
  | 3 months            | 36 months (floor) | 3 months | 36 months    |
  | 5 years (60 mo)     | 60 months (user)  | 5 years  | 5 years      |
  | All                 | everything        | All      | everything   |

  The floor is a **minimum**, never a **cap**: when the user asks for more than
  the floor, the larger window is loaded and *both* the UI and insights get it.

- **AnalysisStore holds the full loaded data as the source of truth.** The
  loaded `dailyBalances` / `expenseBreakdown` / `incomeAndExpense` always span
  ≥ 36 months (or more).

- **Insights read the full loaded data** via the existing `sources.analysis.*`
  path (`InsightStore.makeSnapshot`). No new fetch, no new dependency. The
  display-filter coupling disappears because the loaded data is now always
  ≥ the floor.

- **The Analysis UI takes a smaller window when it needs one.** Cards render
  display-clipped projections honouring `historyMonths`
  (`clip = min(loaded span, historyMonths)`; All / ≥ loaded span = no-op).
  Because we always load ≥ the user's window, the clip only ever *narrows*; it
  never has to fabricate or truncate what the user actually asked for.

- **Cache invalidation keys on the effective *load* window**
  (`max(historyMonths, floor)`, All = ∞). Narrowing the display filter
  re-clips instantly from cache; only widening *beyond* the cached load
  triggers a refetch.

**Verification point during implementation:** confirm `AnalysisStore.loadAll`
is reached on the paths that feed the For You surface (insights ride
AnalysisStore's `loadAll` / `refreshIfStale`), so the floor takes effect even
if the user never opens the Analysis tab.

### Part 2 — What actually counts as an overspend (detector hardening)

A candidate spike must clear **both** gates, in this order (cheapest first):

**Gate A — regularity (primary).** An overspend is only meaningful relative to
an established habit. Require **non-trivial spend in more than half the months
of the series** — equivalently `median(monthly magnitudes) > 0`. This kills the
reported false positives:

- **House purchase** — 1 non-zero month → median 0 → suppressed. Not an
  overspend, just a purchase.
- **Annual superannuation** — ~3 non-zero months across 36 → median 0 →
  suppressed.
- **Dining** (a real habit) — spend most months → median > 0 → eligible.

This matches the insight's purpose: *"you spent more than usual on X"* only
means something where there is a *usual*.

**Gate B — recurrence / lag guard.** *Within* a regular category, suppress
spikes that recur at a fixed cadence so a known periodic bill does not nag every
cycle. For each lag `L ∈ {12, 6, 3}` months, inspect the neighbourhood
`latestIndex − L ± 1` (the ±1 absorbs date drift across month buckets); if any
point there has magnitude `≥ recurrenceTolerance × latest.magnitude`
(default **0.6**), treat the spike as recurring → suppress. Example: a quarterly
water bill on top of a monthly utilities habit — regular category (passes A),
but the lag-3 match suppresses the predictable spike.

The existing STL seasonal-absorption and robust-z / overspend-fraction gates
stay. Order: **Gate A → z-score & overspend-fraction → Gate B**.

**Dropped:** a hard "≥24 months before trusting the seasonal term" gate that an
earlier draft proposed. It would wrongly suppress a *genuine* spike in a real
but young category (e.g. 8 months of dining then a real blowout), and Gates A+B
already cover the false positives it was aimed at.

### Tunables (defaulted parameters on `detect`, pinned by tests)

| Name                  | Default | Meaning                                            |
| --------------------- | ------- | -------------------------------------------------- |
| insight history floor | 36 mo   | minimum AnalysisStore load for insights            |
| `minimumMonths`       | 6       | existing — minimum series length to evaluate       |
| `threshold` (z)       | 3       | existing — robust-z outlier bar                    |
| `minimumOverspendFraction` | 0.25 | existing — remainder/expected lower bound        |
| regularity gate       | median > 0 | > half the months have non-trivial spend        |
| lag set               | {12, 6, 3} | cadences checked for recurrence                 |
| `recurrenceTolerance` | 0.6     | prior-spike magnitude ratio that counts as recurring |

## Testing (TDD — tests before implementation)

New / updated tests in `MoolahTests/Domain/Insights/SpendAndTrendInsightTests`,
using existing `InsightTestSupport.breakdownRow` fixtures:

- **One-off lump suppressed** (house case): single large spike, empty otherwise
  → no insight.
- **Annual recurrence suppressed** (reported bug): two $80k spikes 12 months
  apart, zero otherwise → no insight (Gate A; Gate B as backstop).
- **Date-drift recurrence suppressed:** comparable spikes in June yr1 / July
  yr2 within a *regular* category → no insight.
- **Quarterly recurrence suppressed:** regular category + comparable lag-3
  spike → no insight.
- **Genuine spike still fires:** dining 100 → … → 400, all months non-zero →
  insight emitted (existing `categoryAnomalyFlagsSpike` stays green).
- **Window decoupling / floor:** AnalysisStore loads ≥ 36 months and clips for
  the Analysis UI; the insight input sees the full series regardless of
  `historyMonths`. A larger UI request (60 mo / All) is loaded in full and not
  capped to the floor.

## Risks / Trade-offs

- **Stricter regularity bar** means genuinely irregular categories never produce
  an overspend insight. This is intended: a one-off is not an overspend.
- **Wider default load** (36 mo vs prior 12 mo display default) increases the
  analysis fetch. The data is pre-aggregated per category/month with a covering
  index (`leg_analysis_by_type_category`) and daily balances are O(days); the
  net-worth graph already loads multi-year data, so the cost is low.
- **Lag guard false-negative:** a genuine overspend that happens to resemble a
  spike exactly 3/6/12 months earlier (within 0.6×) is suppressed. Acceptable
  given the user's priority is eliminating false positives, and Gate A already
  restricts this to regular categories.
