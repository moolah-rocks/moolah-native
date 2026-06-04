# Insights — "For You" AI-headline redesign (design)

**Reworks the shipped Phase E narration layer** (E1–E4 are merged on `main`).
This is a *modify/delete* change, not a greenfield build. Refs: epic #1030;
shipped plans `plans/2026-06-03-insights-phase-e-fm-narration-plan.md` (E1–E4,
now partly superseded), `plans/2026-06-02-insights-foryou-panel-design.md`
(Phase C card), on-device AI design `plans/2026-04-18-on-device-ai-design.md`
(Privacy, Availability gating).

## Why

The shipped "For You" card has four usability problems:

1. **The "Why?" disclosure is dead weight.** Tapping it streams an AI
   explanation that only rephrases the headline. Where on-device AI is available
   it should write a genuinely useful, self-contained headline *up front* — no
   click, no title-plus-detail split.
2. **The expanded view shows noise.** "Robust z-score" is meaningless, the
   category is restated, and the cash-flow forecast prints a to-the-cent number
   wrapped in a confidence band so wide it's meaningless.
3. **The weekly review adds nothing.** Remove it and its opt-in toggle.
4. **The "✕" is mislabelled.** It reads as "close/collapse" but is really a
   "show less like this" signal that also down-weights the kind in ranking. And
   hiding a card silently promotes the next-ranked insight into the gap, so the
   action feels inert.

## Key decisions

1. **The AI line *is* the headline.** No separate title + description. When the
   model is available it generates one short, self-sufficient sentence that
   *replaces* the title.
2. **`Insight.detail` is deleted from the model.** It only held the redundant
   rephrase. Every detector / test / fixture / narrator that reads it is updated;
   each detector's `title` is verified self-sufficient.
3. **Facts are never displayed.** `InsightFact`/`facts` survive only as the
   narrator's input and the provenance-guard grounding set.
4. **Fallback = `title`, inline.** Model unavailable, master toggle off,
   generation failure, or guard rejection → the row shows `title`. The existing
   `TemplateNarrator` *is* this fallback: with `detail` gone it composes the
   `title`, and `InsightStore` already maps a `.fellBack` onto template output.
5. **Hold until the whole batch is ready.** The For You panel is absent until
   every visible insight's line has resolved (AI line, or `title` fallback).
   Then it appears at once — never half-populated, never text changing under the
   user.
6. **In-memory headline cache, keyed by stable `insight.id`.** Generated once per
   session, reused across refreshes, regenerated after relaunch. Never recomputed
   on every dashboard appearance.
7. **"Show less", not "✕".** The control is labelled so its meaning is plain: it
   removes this card *and* signals "less like this", bumping the
   Phase-D-persisted, cross-device-synced per-kind fatigue count.
8. **No backfill.** Hiding a card does not promote the next-ranked insight into
   the gap this session. The batch shrinks; the fatigue penalty reshapes ranking
   only at the next full `refresh()`.
9. **Zero-hallucination contract preserved + extended.** The model receives only
   `title` + `facts`. `NumericProvenanceGuard` is **extended** to ground numbers
   against **`title` ∪ `facts`** (today it grounds against facts only) — required
   now that the AI line restates the title's own figures (e.g. a milestone's
   "$100k" that lives in the title, not facts). Sign preserved, never `abs()`-ed.

## What we reuse vs change vs delete

**Reuse (largely unchanged):** the `ModelAvailability` seam +
`SystemLanguageModelAvailability`; the streaming `InsightNarrating` protocol;
`FoundationModelsNarrator` (streaming, greedy, provenance-checked);
`TemplateNarrator` (now the `title` fallback); `NumericProvenanceGuard`
(extended); `NarrationState`; `NarrationError`; `ScriptedNarrator` (tests).
We keep the **streaming** protocol and simply consume the stream to completion
in the store — the UI reveals only the final text, so streaming costs nothing
and avoids a protocol rewrite.

**Change:**
- `NarrationRequest` — drop the `.weeklyRecap` case and its `Item`; drop `detail`
  from `.singleInsight` → `.singleInsight(title:facts:)`. Update `allFacts`.
- `NarrationPromptBuilder` — drop the recap branch; drop `detail`; the
  single-insight instructions become "write the headline" (one self-sufficient
  sentence), not "explain". (Existing voice rules stay.)
- `NumericProvenanceGuard.isGrounded` — add the `title` to the grounded set.
- `TemplateNarrator` — drop the recap branch; compose from `title` (no `detail`).
- `InsightStore` (+`InsightStore+Narration`) — replace lazy on-tap
  `narrate(_:)`/`cancelNarration(_:)` with **eager batch generation** on refresh:
  pick top *N*, generate all headlines concurrently (consume each stream to
  completion off-main), reuse an in-memory `headlineCache[id]`, fall back to
  `title` on `.fellBack`/error, and **publish only when the whole batch is
  resolved**. Publish `[ForYouItem]` (`{scored, headline}`). Move the top-*N* cap
  into the store. Rework `dismiss(_:)` to **filter without rerank/backfill** (the
  fatigue bump + persistence stays; the in-place `rerank()` goes).
- `ForYouCard`/`InsightRow` — remove the disclosure, the "Why?" button, the facts
  list, the `detail`. Render one headline line + signed impact + "Show less" +
  optional "View". Takes `[ForYouItem]`.
- `AnalysisView` — remove recap wiring; render the card only when items are ready.
- `InsightsSettingsSection` — remove the "Weekly recap" toggle + key; fix footer.
- Detectors — remove `detail` (23 sites); drop "Robust z-score"
  (`CategoryAnomalyInsight`, `LargeTransactionInsight`) and "Confidence band"
  (`CashFlowForecastInsights`) facts; forecast suppression + rounding (below).
- `InsightContext`/`InstrumentAmount` — add `formattedApproximate(_:)` (≈3
  significant figures, whole-currency, sign preserved).
- UI-test seam — drop the `whyButton` identifier and the expand-then-why flow;
  rename/repurpose the dismiss identifier to a "Show less" control; keep a
  headline-text identifier; update `ForYouScreen`, fixtures, and the narration UI
  test to assert the **inline** headline and **no-backfill** on Show less.

**Delete (weekly recap, in full):**
- Files: `Features/Insights/WeeklyRecapStore.swift`,
  `Features/Insights/Views/WeeklyRecapCard.swift`,
  `Features/Insights/RecapState.swift`,
  `Features/Insights/RecapLastShownStoring.swift`,
  `Domain/Insights/Narration/WeeklyRecapWindow.swift`,
  `App/ProfileSession+RecapFactories.swift`,
  `MoolahUITests_macOS/Tests/ForYou/WeeklyRecapUITests.swift`,
  `MoolahUITests_macOS/Helpers/Screens/WeeklyRecapScreen.swift`,
  `UITestSupport/UITestIdentifiers+WeeklyRecap.swift`, and the
  `MoolahTests` recap tests (`WeeklyRecapStoreTests`, `WeeklyRecapWindowTests`).
- Wiring: `ProfileSession.weeklyRecapStore` (decl + `finishInit` construction +
  comment); the two `prepareIfDue()` calls and the `WeeklyRecapCard` render in
  `AnalysisView`; the `weeklyRecapEnabledKey` on `UserDefaults+MoolahShared`;
  the recap toggle in `InsightsSettingsSection`; the `.weeklyRecapBaseline` seed
  and its overrides (`narrator`/`availability`/`recapLastShownStore`/
  `recapOptedIn`) in `UITestSeedInsightOverrides`; `scriptedRecap` in
  `UITestFixtures+InsightsForYou`; the `weeklyRecap` accessor on the UI-test
  `XCUIApplication` helper if present.

## Architecture (after)

```
ModelAvailabilityProviding ──► InsightStore.availability (gate)
InsightNarrating (streaming) ─► InsightStore.narrator
    └ FoundationModelsNarrator (FM; provenance-guarded)
    └ TemplateNarrator (title fallback) / ScriptedNarrator (tests)

InsightStore (@MainActor @Observable)
  refresh(): select top-N → generate headlines concurrently
             (consume stream→final; cache; fallback title; guard)
             → publish [ForYouItem] only when ALL resolved
  dismiss(): filter id out (NO rerank) + bump persisted fatigue
  items: [ForYouItem]   // {scored, headline}

ForYouCard([ForYouItem]) → InsightRow: icon + headline + impact + "Show less" + View
```

## Cash-flow forecast specifics

- **Suppress** the projected-month-end insight when `band ≥ 0.5 × |projected|`
  (named constant, unit-tested). A forecast that uncertain is noise.
- When shown, **round the projected balance to ≈3 significant figures**
  ("around $225,000") via `formattedApproximate(_:)`. The rounded figure is what
  the `title` carries (self-sufficient fallback) and what the retained
  "Projected balance" fact carries (so the guard permits it).
- **Remove** the "Confidence band" fact and the "±…" clause.

## Testing

- **Pure unit:** `NarrationPromptBuilder` (single-insight only; title + every
  fact value present; no `detail`; headline framing); `NumericProvenanceGuard`
  (numbers grounded in `title` alone now pass; invented number fails; flipped
  sign fails); forecast suppression threshold; `formattedApproximate` (incl.
  negative + small values).
- **Store (`TestBackend`):** batch publishes `items` only when all resolve;
  failing/guard-tripped narration → `title` yet batch still publishes; cache hit
  on second refresh (narrator not re-invoked); availability-off / toggle-off →
  all `title`; **Show less removes the row, bumps the persisted fatigue count,
  and does NOT backfill**; rollback on persist failure.
- **`#Preview`:** AI-headline rows and `title`-fallback rows; framings ±impact
  ±nav target. Iterated via `RenderPreview`.
- **UI test (`MoolahUITests_macOS`):** scripted narrator + fixed availability;
  assert the headline renders inline (no "Why?" tap), Show less drops a row and
  the gap is **not** backfilled, and "View" navigates. Update `ForYouScreen`.
- **Manual on-device check (recorded in the PR):** real headlines render,
  grounded in facts; master toggle off → `title`. CI does not cover the live
  model path.
- Per task: `just format`, **`just format-check` (full output)**, the relevant
  review agents (`concurrency-review`, `code-review`, `ui-review`, `help-review`
  for copy, `ui-test-review`), all findings applied.

## Out of scope

Phase F assistant; `@Generable`; streaming narration UI; persisting headlines
across launches; per-category/per-account surfaces.
