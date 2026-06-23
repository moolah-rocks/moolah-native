# Insight fallback descriptions — design

**Date:** 2026-06-23
**Status:** Design (awaiting review)
**Scope:** Improve the deterministic, model-free insight descriptions so they read like the AI-narrated headlines — full, warm, number-bearing sentences — instead of the current bare detector title. AI stays the default headline source when on-device generation is available; this change only upgrades the fallback. Designed so a later "make templates the default" flip is trivial.

## Problem

Every `Insight` carries a terse `title` ("Dining up 56% in June") plus structured `facts` (label/value pairs, pre-formatted in the reporting currency/locale: "This month → $640", "Expected → $410", "Over by → 56%"). When the on-device Foundation Models layer is available it weaves those facts into a warm one-sentence headline. When it is unavailable, disabled, or a generation fails the numeric-provenance check, `TemplateNarrator` falls back to returning **only the bare `title`** — the facts are thrown away.

The result is a two-tier experience: rich prose with AI, terse labels without. We want the deterministic path to read clearly and usefully on its own, with the actual numbers inlined the way the AI does.

## Non-goals

- **Not** flipping the default. The AI narrator remains primary when present. (A future change can swap the order; this design keeps that cheap.)
- **Not** changing detection, ranking, charts, or the UI layout. Only the text the fallback produces changes.
- **Not** touching the AI prompt or the numeric-provenance guard.

## Approach (chosen)

**Centralized per-kind composer.** A new pure type switches on `InsightKind` and weaves the pre-formatted `facts` into one readable sentence. All 37 user-facing sentences live in one auditable, CI-testable file — the right place for brand-voice consistency (`help-review` / `BRAND_GUIDE`) and the cleanest path to a future default flip.

Rejected alternatives:

- **Detector-authored `description` field** — type-safe and co-located, but scatters prose across ~20 detector files with no single place to review voice; detectors grow; title/description duplicate.
- **Generic fact composition** (one formula: title + facts as a trailing clause) — trivial, but reads like a fact dump, not prose. Fails the "read clearly and be useful" bar.

## Architecture

### New type: `InsightDescriptionComposer`

Lives in `Domain/Insights/Narration/` alongside the existing pure `NarrationPromptBuilder`. Pure, no side effects, no model — fully testable in CI (incl. Linux) with no device.

```swift
enum InsightDescriptionComposer {
  /// One readable sentence for `kind`, weaving the pre-formatted `facts`
  /// into prose. Falls back to `title` when an expected fact is absent.
  static func compose(kind: InsightKind, title: String, facts: [InsightFact]) -> String
}
```

### Thread `kind` through the narration request

`NarrationRequest.singleInsight` gains a `kind`:

```swift
case singleInsight(kind: InsightKind, title: String, facts: [InsightFact])
```

- `InsightStore+Narration.narratedHeadline` already holds `insight.kind` at the construction site — it just passes it in.
- `NarrationPromptBuilder` (the AI path) keeps sending **only** title + facts to the model: `kind` is metadata for the deterministic composer, never for the LLM. The zero-hallucination boundary and `NumericProvenanceGuard` are unchanged.
- `allFacts` / `groundingTitle` accessors on `NarrationRequest` are unaffected.

### `TemplateNarrator` delegates to the composer

```swift
case let .singleInsight(kind, title, facts):
  return InsightDescriptionComposer.compose(kind: kind, title: title, facts: facts)
```

Streaming/fallback wiring is otherwise unchanged: the narrator still yields a single snapshot and finishes.

## Fact-access strategy & safety

The composer reads facts **by label** (the same way `NarrationPromptBuilder` already consumes them). Two small private helpers keep this honest:

- `fact(_ label:)` — exact-label lookup, returns `String?`.
- `fact(prefix:)` — prefix lookup, for the handful of detectors that embed a dynamic value in the label ("Over 6 months", "Typical Monday", "Spent (90d)").

**Degradation rule:** if a `case` cannot find a fact it needs, it returns `title` — exactly today's behaviour, never a broken half-sentence.

**Title-as-lead technique:** a few kinds carry their entity name (earmark/goal name, fee phrasing, income descriptor) only in the `title`, not in any fact. For those, the composer uses the **whole `title`** as the leading clause and appends a fact-built detail clause. It never parses fragments out of the title — the title is used intact, so it stays robust.

**Numbers only from facts.** Every monetary amount / percentage / count in a composed sentence comes from a fact value verbatim (or, for title-as-lead kinds, from the title — which is itself deterministic). Non-numeric connective time words ("this month", "this period", "over the past year") are safe to author freely because the deterministic composer cannot hallucinate, and these detectors fire on the current period.

**Omit statistical evidence.** Like the AI, the composer never surfaces p-values, z-scores, stability-score raw values, or month-window counts — those are evidence, not user-facing copy.

**Direction/variant handling.** Some kinds encode a variant that the composer must branch on:
- `monthOverMonthDelta`, `categoryMixShift`, `payRateChange` — the signed "Change" fact's leading `+` / `−` selects "up/down", "rose/dropped"; the magnitude is printed without the sign.
- `categoryTrendRising` vs `categoryTrendFalling` — distinct `InsightKind` cases, so plain `switch` arms.
- `savingsGoalETA` — three variants distinguished by which facts are present: a "Projected completion" fact → ETA wording; else a "Progress" fact → progress-only wording; else → goal-reached wording.

## Voice

Reuses the rules the AI already follows (see `NarrationPromptBuilder.singleInsightInstructions` and `BRAND_GUIDE`):

- One sentence; shown as the headline.
- Numbers written exactly as the facts supply them (digits + currency symbol); never spelled out.
- Warm on good news (one beat, not a speech); **never** scolding — no "overspent", "wasted", "should".
- Contractions where natural ("you've", "it's").
- Address the user as "you" / "your".
- No corporate vocabulary (optimise, leverage, empower, streamline, robust, seamless).

## Draft sentences (all 37 kinds)

`{Label}` = a fact value looked up by that label. `{title}` = the detector title used intact. Bracketed `[optional]` clauses appear only when that fact is present. These are the copy to review; wording can be tuned during implementation without changing the design.

### A. Recurring & subscriptions

| Kind | Draft sentence |
|---|---|
| `newRecurringDetected` | "You've started a new {Merchant} subscription — about {Monthly equivalent} a month." |
| `subscriptionPriceHike` | "{Merchant} now costs {New charge} a month — {Extra per month} more than before, a {Increase} rise." |
| `duplicateSubscription` | "You're paying for overlapping {Category} subscriptions ({Services}) — {Combined monthly} a month combined." |
| `subscriptionCancellationCandidate` | "You're still paying {Monthly cost} a month for {Merchant}, but there hasn't been a charge in {Days since last} days." |
| `subscriptionOverspend` | "Your {Active subscriptions} subscriptions add up to {Monthly subscriptions} a month — {Share of income} of your income." |

### B. Anomaly / surprise spending

| Kind | Draft sentence |
|---|---|
| `largeTransactionAnomaly` | "A {Amount} charge from {Merchant} stands out for {Category}, where you usually spend around {Typical for category}." |
| `newMerchantAlert` | "Your first charge from {Merchant} came in at {Amount}." |
| `unusualDaySpend` | "You spent {Spent} on {Day} — around {Multiple} your usual {Typical <Day>}." |
| `categorySpendingAnomaly` | "Your {Category} spending hit {This month} this month — about {Over by} above your usual {Expected}." |

### C. Trends & period comparisons

| Kind | Draft sentence |
|---|---|
| `categoryTrendRising` | "Your {Category} spending is trending up, by about {Per month} a month." |
| `categoryTrendFalling` | "Your {Category} spending is easing off — down about {Per month} a month." |
| `monthOverMonthDelta` | "You spent {This period} this period, {up/down} {Change magnitude} from {Comparison} before." |
| `categoryMixShift` | "{Category} now makes up {Current share} of your spending, {up/down} {Change magnitude}." |

### D. Cash flow & forecasting

| Kind | Draft sentence |
|---|---|
| `upcomingBillWarning` | "Your balance is set to dip to {Lowest projected} around {On}[, after {Upcoming bill}]." |
| `projectedMonthEndBalance` | "You're on track to finish the month with about {Projected balance}." |
| `savingsRateTrend` | (rising) "Your savings rate is climbing — you're now saving {Current savings rate} of your income." / (falling) "Your savings rate has slipped to {Current savings rate} of your income." |
| `runwayEstimate` | "At about {Monthly burn} a month, your {Available funds} would cover roughly {Runway}." |

### E. Budget performance (earmarks)

| Kind | Draft sentence |
|---|---|
| `earmarkBurndownProjection` | "{title} — you've spent {Spent so far} of your {Budget} budget and you're on pace for {Projected}." |
| `earmarkUnderspend` | "{title} — you've spent {Spent so far} of {Budget}, on pace for just {Projected}." |
| `savingsGoalETA` (reached) | "{title} — you've saved {Saved} toward your {Goal} target." |
| `savingsGoalETA` (ETA) | "{title} — you've saved {Saved} of {Goal} ({Progress})." |
| `savingsGoalETA` (progress) | "{title} — {Saved} saved toward {Goal}." |

### F. Savings opportunities

| Kind | Draft sentence |
|---|---|
| `idleCashAlert` | "You've got {Available funds} sitting in cash — about {Idle excess} more than you'd typically need on hand." |
| `feeSpend` | "{title} over the past year, across {Transactions} charges." |

### G. Net worth & investments

| Kind | Draft sentence |
|---|---|
| `netWorthMilestone` | "Your net worth just passed {Milestone} and now sits at {Net worth}." |
| `investmentConcentrationRisk` | "{Holding} now makes up {Share of portfolio} of your investments, worth {Value}." |
| `topPerformer` | "{Holding} is your strongest holding, up {Return} for a {Gain/loss} gain on {Invested} invested." |
| `bottomPerformer` | "{Holding} is lagging — {Return} on {Invested} invested, a {Gain/loss} change." |
| `capitalGainsHarvest` | "You could offset {Potential offset} of realised gains against unrealised losses in {Loss positions}." |

### H. Income analysis

| Kind | Draft sentence |
|---|---|
| `paycheckTimingPattern` | "Your next {Source} paycheck of about {Typical amount} should land around {Next expected}." |
| `incomeStabilityScore` | "{title} — it varies by about {Variation} month to month." |
| `missingPaycheckAlert` | "Your {Source} paycheck of around {Typical amount} was expected {Expected} and is {Days overdue} days late." |
| `windfallIncome` | "You received {Amount} from {Source} — well above your typical {Typical income}." |
| `payRateChange` | (up) "Your {Source} pay rose to {New amount} from {Previous}." / (down) "Your {Source} pay dropped to {New amount} from {Previous}." |

### K. Account structure

| Kind | Draft sentence |
|---|---|
| `groupSpendConcentration` | "{Share of spend} of your spending — {Spent} — runs through {Group}." |

### L. Data quality

| Kind | Draft sentence |
|---|---|
| `uncategorizedBacklog` | "You've got {Uncategorized} transactions waiting for a category." |
| `unreconciledTransfers` | "There are {Pending transfers} possible transfers to review and merge." |

### M. Merchant & budget coverage

| Kind | Draft sentence |
|---|---|
| `lapsedMerchant` | "You haven't paid {Merchant} in {Days since last} days." |
| `weekendSpendSkew` | "You spend more on weekends — about {Avg weekend day} a weekend day versus {Avg weekday} on weekdays." |
| `unbudgetedCategory` | "{Category} has no budget yet — you've spent {Spent (<window>)} there recently." |

## Testing

- **`InsightDescriptionComposerTests`** (new, pure — runs iOS/macOS and Linux, no device):
  - One test per kind asserting the composed sentence from representative facts (incl. each `savingsGoalETA` variant and both directions of the signed kinds). These pin the wording and are the safety net: if a detector renames a fact label, the affected `case` silently misses its lookup and the test fails loudly.
  - A degradation test: a request missing an expected fact returns the `title` unchanged.
  - A coverage test over `InsightKind.allCases`: every kind produces non-empty output that is **not** equal to the bare title for kinds with facts (guards against a newly added kind slipping through unhandled), and the `switch` is exhaustive (no `default`).
- **`TemplateNarratorTests`** — update the existing expectation (currently asserts the bare title round-trips) to assert the composed sentence, and pass `kind` in the request.
- **`NarrationRequest` ripple** — every `singleInsight(...)` construction site (app + tests) gains `kind:`. The compiler enumerates them.
- **No new AI/device tests** — the AI path is untouched.

## Risks & mitigations

- **Fact-label drift** → per-kind composer tests fail loudly; degradation rule prevents broken output in production.
- **Repetitive feel** (fixed text reads samer than AI across the feed) → accepted for the fallback tier; the variant branching and per-kind phrasing keep it varied enough; tuning is cheap and centralized.
- **Locale fragility in tests** → assert on digits/sign and structure, not on a literal currency symbol (per project test guidance on currency-symbol locale traps).

## Files touched

- `Domain/Insights/Narration/InsightDescriptionComposer.swift` (new)
- `Domain/Insights/Narration/NarrationRequest.swift` (add `kind` to `singleInsight`)
- `Domain/Insights/Narration/TemplateNarrator.swift` (delegate to composer)
- `Domain/Insights/Narration/NarrationPromptBuilder.swift` (accept new case shape; still sends only title+facts)
- `Features/Insights/InsightStore+Narration.swift` (pass `insight.kind`)
- `MoolahTests/Domain/Insights/InsightDescriptionComposerTests.swift` (new)
- `MoolahTests/Domain/Insights/TemplateNarratorTests.swift` (update)
- any other `singleInsight(...)` call sites surfaced by the compiler
