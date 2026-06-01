# Personalized Insights — Integration Plan

How to take the merged deterministic insights engine (`Domain/Insights/`, see
`plans/2026-06-01-insights-core-implementation.md`) from a standalone library
to a feature users actually see and benefit from.

**Status:** the detection engine, ranker, and ~38 detectors are built, tested,
and CI-green. Nothing in the app calls them yet — there is no wiring layer, no
store, and no UI surface. This document sequences that work.

Aligns with the phasing in `plans/2026-04-18-on-device-ai-design.md`
(§"Implementation Phasing"): Phase 1 is deterministic + a single surface;
Foundation Models is strictly additive on top.

## Architectural contract (already established)

- `InsightEngine.generate(_:dismissals:interests:displayCap:)` is **pure and
  synchronous**. All async currency conversion must happen *upstream* when
  assembling `InsightInput` (`InsightTransaction` / `EarmarkSnapshot` /
  `ScheduledBill` arrive already in the reporting currency).
- Sign convention preserved end to end (income +, expense −, refunds kept;
  never `abs()`); a conversion failure drops that leg rather than guessing
  (`guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11).
- Each `Insight` carries template `title`/`detail` (works on every device) plus
  a structured `facts` array that is the zero-hallucination seam for a later
  Foundation Models narration layer.

---

## Phase A — Input-assembly layer (the async seam) — **critical path**

The one thing the engine can't do itself. New `Features/Insights/` (or
`Backends/GRDB`) code that, given the loaded stores + `BackendProvider`, builds
an `InsightInput`.

### Do **not** build the "load every transaction" version

The naive shape — `transactions ← TransactionRepository.fetchAll` → flatten every
leg → `InsightTransaction.records(...)` — is O(all history) in memory **and** runs
an FX conversion per leg on every refresh. Unacceptable for users with years of
data. It is also unnecessary: most detectors don't read raw transactions at all,
and those that do need only a bounded window or a cheap aggregate.

**Who reads raw rows:** only the merchant / anomaly / subscription / habit
detectors. Everything else already consumes pre-aggregated inputs (below) — leave
those as-is. The raw-row consumers decompose cleanly:

| Detector | True data need |
|---|---|
| Subscription detection, lapsed-merchant | per-payee cadence — ~13 months, projected columns only |
| Large-tx anomaly, new-merchant, unusual-day, windfall | recent candidates (≤30 d) **+ a baseline distribution that can be aggregated** |
| Fee-spend, unbudgeted-category, group-concentration | windowed `SUM` by category / account → pure SQL |

### Target: an SQL-backed `InsightDataSource`

Add repository queries that return **pre-aggregated summaries**, mirroring
`GRDBAnalysisRepository` (SQL `GROUP BY` + per-`(day, instrument)` conversion):

- per-day spend totals (`GROUP BY DATE(date)`) → unusual-day, weekend-skew;
- per-category windowed `SUM` → fee, unbudgeted, group-concentration;
- per-payee `(count, first_seen, last_seen, sum)` → new-merchant, lapsed-merchant,
  subscription pre-filter;
- per-category amount **samples** for the MAD baseline → large-tx anomaly;
- a **bounded recent-candidate window** of projected rows (date, payee, signed
  amount, category_id, account_id, instrument) for detectors that must cite a
  specific `transactionId`.

Memory becomes O(payees + categories + days + recent window) — independent of
total transaction count. The still-aggregate inputs stay as today:

- `monthly` / `expenseBreakdown` / `dailyBalances` ← `AnalysisStore`.
- `earmarks` ← join `EarmarkStore.earmarks` with its converted balance / saved /
  spent dictionaries into `EarmarkSnapshot`; `budgetedCategoryIds` from line items.
- `profitLoss` / `capitalGains` ← `ReportingStore`.
- `accountGroups` + `accountGroupMembership` ← `AccountGroupStore` + `AccountStore`.
- `uncategorizedTransactionCount` ← `Transaction.needsReview` (a `COUNT`, not rows);
  `pendingTransferCount` / `oldestPendingTransferDate` ← `TransferSuggestionRepository`.

### Two more cost levers

- **Conversion**: convert at the `(day, instrument)` bucket like
  `GRDBAnalysisRepository.convertedQuantity` — collapses thousands of calls to a
  handful, same-instrument short-circuits, single-currency profiles pay ~nothing.
  Never convert per leg.
- **Recompute cadence** (see Phase H): detectors are deterministic given inputs;
  compute on data-change ticks (the existing `ValueObservation` / rate-tick
  streams) and cache `[ScoredInsight]` rather than rebuilding on every open.
  Design the data source to support this.

### Implication for the detector input model

Some detectors that currently scan `[InsightTransaction]` (`SpendHabitInsights`,
`SavingsOpportunityInsights.feeSpend`, `AccountGroupInsights`,
`BudgetCoverageInsights`) will instead take pre-aggregated summary inputs. The
pure/synchronous detector contract is unchanged — only the *shape* handed in
changes. The recent-window detectors keep a small row slice so they can reference
a specific transaction.

Runs **off-main** per `guides/CONCURRENCY_GUIDE.md`; query plans pinned per
`guides/DATABASE_CODE_GUIDE.md`. Unit-tested against `TestBackend` with realistic
seeded data — this is where detector thresholds get validated beyond unit fixtures.

**Exit criteria:** `InsightDataSource` produces correct summaries + a bounded
recent window from a seeded `TestBackend`; **memory does not scale with total
transaction count** (covered by a test/benchmark on a large seed); conversion runs
per `(day, instrument)` not per leg; conversion-failure path covered (Rule 11 —
drop the leg, never guess; preserve sign).

## Phase B — `@MainActor InsightStore`

Mirrors the existing store pattern (`@Observable`, `@Environment(BackendProvider.self)`).
Publishes `[ScoredInsight]`; `refresh()` builds the input off-main then calls the
engine; `dismiss(_:)` updates state. Recompute on data-change ticks, not on every
view appearance.

**Exit criteria:** store tests assert published insights + dismissal behaviour
against `TestBackend`.

## Phase C — Dashboard "For You" panel (first surface)

The sole surface for v1 (design §"Discoverability"). Renders the top 3–5 ranked
insights: `title`, expandable `facts`, dismiss affordance, deep-link via
`references` (account / category / earmark / group ids). Thin view; all logic in
the store. `@ui-review` + `MoolahUITests_macOS` coverage (the `writing-ui-tests`
skill). Template narration only — no LLM yet.

**Exit criteria:** insights render on dashboard open, dismiss works, links
navigate; UI test green.

## Phase D — Persist dismissals + declared interests

The ranker already accepts `dismissals:` / `interests:` but nothing stores them.
New repository + CloudKit record type (the `modifying-cloudkit-schema` skill) so a
dismissal syncs across devices. This makes the anti-fatigue design real.

**Exit criteria:** dismissals survive relaunch and sync; fatigue penalty visibly
reorders insights.

## Phase E — Foundation Models polish (additive, gated)

Narration over the pre-computed `facts` (never invents numbers), behind
`SystemLanguageModel.default.availability` with template fallback already present.
Delivers the "why?" explanation and the weekly-recap narrative. Ships nothing to
ineligible devices beyond what Phase C already shows.

## Phase F — Conversational assistant (design Phase 4)

Tool-calling `LanguageModelSession` over the existing stores as read-only `Tool`
conformers, with citation chips. Apple-Intelligence devices only. Larger effort;
own design doc when reached.

## Phase G — Remaining detector ideas

From `plans/2026-06-01-insights-additional-ideas.md` (not yet built): import-balance
reconciliation (C-2), crypto gas-fee leakage / on-chain counterparty recurrence
(D-1/D-2), asset-class allocation (D-3). Most need a **parallel feed** alongside
`InsightTransaction` — transfer-typed legs and native-instrument metadata, since
`records(...)` deliberately drops transfers and folds away the instrument. Small
input-model extension, not new infrastructure.

## Phase H — Productionisation

- **Performance**: cache `InsightInput`/results; recompute on change ticks. Add a
  `MoolahBenchmarks` case (the `write-benchmark` skill) and verify on device.
- **Tuning**: ranker weights and detector thresholds are hand-set; add a debug
  surface to eyeball real output and adjust before GA.
- **Settings + help**: a disable toggle; help content (`@help-review`).
- **Privacy**: on-device only; no telemetry by default (design §Privacy).

---

## Recommended first PR

Phases **A–C** as a thin vertical slice: `InsightDataSource` → `InsightStore` →
dashboard panel with template narration and in-memory dismissals. That puts real
insights in front of a user end to end. Persistence (D), LLM polish (E), and the
assistant (F) layer on top without rework.

## Dependency order

```
A (InsightDataSource) ─┬─> B (store) ──> C (dashboard)  ← first user-visible PR
                       │                    └─> D (persist dismissals)
                       └─> G (extra detectors, parallel feed)
B ──> E (FM narration) ──> F (assistant)
H (perf / tuning / settings / help) spans C onward
```
