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

The one thing the engine can't do itself. New `Features/Insights/` code that,
given the loaded stores + `BackendProvider`, builds an `InsightInput`:

- `transactions` ← `TransactionRepository.fetchAll` → flatten each leg through
  `InstrumentConversionService` → `InsightTransaction.records(from:categories:convert:)`.
  Track the dropped-leg count for a future "data incomplete" signal.
- `monthly` / `expenseBreakdown` / `dailyBalances` ← `AnalysisStore`.
- `earmarks` ← join `EarmarkStore.earmarks` with its converted balance / saved /
  spent dictionaries into `EarmarkSnapshot`; `budgetedCategoryIds` from line items.
- `profitLoss` / `capitalGains` ← `ReportingStore`.
- `accountGroups` + `accountGroupMembership` ← `AccountGroupStore` + `AccountStore`.
- `uncategorizedTransactionCount` ← `Transaction.needsReview` count;
  `pendingTransferCount` / `oldestPendingTransferDate` ← `TransferSuggestionRepository`.

Runs **off-main** per `guides/CONCURRENCY_GUIDE.md`. Unit-tested against
`TestBackend` with realistic seeded data — this is where detector thresholds get
validated beyond the unit fixtures.

**Exit criteria:** `InsightInputBuilder` produces a correct `InsightInput` from a
seeded `TestBackend`; conversion-failure path covered.

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

Phases **A–C** as a thin vertical slice: builder → `InsightStore` → dashboard
panel with template narration and in-memory dismissals. That puts real insights in
front of a user end to end. Persistence (D), LLM polish (E), and the assistant (F)
layer on top without rework.

## Dependency order

```
A (input builder) ─┬─> B (store) ──> C (dashboard)  ← first user-visible PR
                   │                    └─> D (persist dismissals)
                   └─> G (extra detectors, parallel feed)
B ──> E (FM narration) ──> F (assistant)
H (perf / tuning / settings / help) spans C onward
```
