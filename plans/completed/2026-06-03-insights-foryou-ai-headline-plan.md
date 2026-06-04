# For You AI-headline redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the shipped "For You" insights card so the on-device AI line *is* the self-sufficient headline (replacing the title, shown inline with no "Why?" click, cached, batch-revealed only when ready), remove the weekly recap entirely, delete `Insight.detail`, trim forecast/z-score noise, and relabel dismiss as "Show less" with no backfill.

**Architecture:** Reuse the merged Phase E narrator stack (`InsightNarrating` streaming protocol, `FoundationModelsNarrator`, `TemplateNarrator`, `NumericProvenanceGuard`, `NarrationState`). `InsightStore` moves from lazy on-tap narration to eager batch generation on refresh: pick top-N, generate each headline concurrently (consume the stream to its final snapshot off-main), cache in memory keyed by `insight.id`, fall back to `title` on failure, and publish `[ForYouItem]` only when the whole batch resolves. The card renders one headline line per item; "Show less" filters without rerank/backfill and bumps the Phase-D-persisted per-kind fatigue count.

**Tech Stack:** SwiftUI, `FoundationModels`, Swift Testing (`@Test`/`#expect`), XCUITest (`MoolahUITests_macOS`), `@AppStorage` over `UserDefaults.moolahShared`, `just` build/test/format targets. Deployment target iOS 26 / macOS 26 (no `@available` guards needed).

**Design:** `plans/2026-06-03-insights-foryou-ai-headline-design.md`.

---

## Conventions for every task

- Build/test/format **only** via `just`; use `just -d <worktree>` / `git -C <worktree>` — never `cd && …` (memory `feedback_no_cd_for_any_tool`). Worktree: `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/insights-phase-d` (branch `foryou-ai-headline`).
- Capture test output to `.agent-tmp/` (gitignored): `mkdir -p .agent-tmp && just test-mac <Filter> 2>&1 | tee .agent-tmp/out.txt`. Delete temp files when done.
- After **every** task that changes Swift: `just format` then **`just format-check`** and **read the full output** — `… | tail` masks SwiftLint errors. Never add a SwiftLint baseline/disable; fix the code (memory `feedback_swiftlint_fix_not_baseline`).
- Use plain `extension Foo { private func … }`, never `private extension` (memory `reference_swiftformat_swiftlint_private_extension`). One primary type per file; conform via a separate `extension`. Project uses **Swift Testing**, not XCTest, for unit tests.
- After each task run the relevant review agent(s) and apply **all** findings (`concurrency-review` for store/async, `code-review` for logic, `ui-review` for views, `help-review` for user-facing copy, `ui-test-review` for UI tests). Commit after each task.
- macOS test-runner hang → `pkill` stale `Moolah` test-host/`xctest` first (memory `reference_macos_test_runner_hang`). If the local UI host is wedged, gate on the PR's CI "UI Test" job (memory `feedback_pr_ci_gate_when_ui_host_blocked`).

---

## Task 1: Remove the weekly recap entirely

**Files — delete:**
- `Features/Insights/WeeklyRecapStore.swift`
- `Features/Insights/Views/WeeklyRecapCard.swift`
- `Features/Insights/RecapState.swift`
- `Features/Insights/RecapLastShownStoring.swift`
- `Domain/Insights/Narration/WeeklyRecapWindow.swift`
- `App/ProfileSession+RecapFactories.swift`
- `MoolahUITests_macOS/Tests/ForYou/WeeklyRecapUITests.swift`
- `MoolahUITests_macOS/Helpers/Screens/WeeklyRecapScreen.swift`
- `UITestSupport/UITestIdentifiers+WeeklyRecap.swift`
- `MoolahTests/Features/Insights/WeeklyRecapStoreTests.swift` (if present)
- `MoolahTests/Domain/Insights/WeeklyRecapWindowTests.swift` (if present)

**Files — modify:**
- `App/ProfileSession.swift`: remove the `weeklyRecapStore` property (decl + doc comment) and its construction in `finishInit`.
- `Features/Analysis/Views/AnalysisView.swift`: remove the two `await session.weeklyRecapStore?.prepareIfDue()` calls and the `WeeklyRecapCard` render block.
- `Shared/.../UserDefaults+MoolahShared.swift`: remove `weeklyRecapEnabledKey`.
- `Features/Settings/InsightsSettingsSection.swift`: remove the "Weekly recap" `Toggle` + `recapEnabled` `@AppStorage`; rewrite the footer to drop recap wording (keep the privacy line for the narration toggle).
- `App/UITestSeedInsightOverrides.swift`: remove the `.weeklyRecapBaseline` cases in `fixtures`/`availability`/`narrator`, and the `recapLastShownStore`/`recapOptedIn` methods.
- `UITestSupport/UITestFixtures+InsightsForYou.swift`: remove `scriptedRecap`.
- `UITestSupport/UITestSeed.swift` (or wherever seeds are defined): remove the `.weeklyRecapBaseline` case.
- `MoolahUITests_macOS/.../XCUIApplication+Screens.swift` (or equivalent): remove the `weeklyRecap` accessor if present.
- `Domain/Insights/Narration/NarrationRequest.swift`: remove the `.weeklyRecap(items:)` case and its `Item` struct (dead once `WeeklyRecapStore` is gone). Keep `.singleInsight`.
- `Domain/Insights/Narration/NarrationPromptBuilder.swift`: remove the recap branch.
- `Domain/Insights/Narration/TemplateNarrator.swift`: remove the recap branch.

- [ ] **Step 1 — delete the files** listed above (`git rm`), then `grep -rn "WeeklyRecap\|weeklyRecap\|RecapState\|RecapLastShown\|scriptedRecap\|prepareIfDue\|\.weeklyRecapBaseline" --include="*.swift" .` (exclude `.build/`) and remove every remaining reference per the modify list. The grep must return **zero** results outside this plan/design doc when done.
- [ ] **Step 2 — `just generate`** (project.yml file membership is auto-discovered, but regenerate to drop the deleted files from the Xcode project).
- [ ] **Step 3 — `just build-mac`** → success. Fix any stragglers the compiler finds.
- [ ] **Step 4 — `just test-mac` + `just test-ios`** → green (existing non-recap insight tests still pass). Capture to `.agent-tmp/`.
- [ ] **Step 5 — `help-review`** the new Settings footer copy; `ui-review` `InsightsSettingsSection`; apply findings. **format-check. commit** ("Remove weekly recap surface").

---

## Task 2: `formattedApproximate` rounding helper (pure, TDD)

**Files:**
- Modify: `Domain/Models/InstrumentAmount.swift` (add `formattedApproximate`)
- Modify: `Domain/Insights/InsightContext.swift` (add a `formattedApproximate(_:)` delegating to it)
- Test: `MoolahTests/Domain/Models/InstrumentAmountApproximateTests.swift` (new)

Rounds a quantity to ≈3 significant figures and formats as whole currency (no cents), grouping on, **sign preserved**. Examples: `225_460.22 → "$225,000"`, `-225_460.22 → "-$225,000"`, `9_840 → "$9,840"`, `512.30 → "$512"`, `0 → "$0"`.

- [ ] **Step 1 — failing test.**

```swift
import Testing
import Foundation
@testable import Moolah

@Suite("InstrumentAmount.formattedApproximate")
struct InstrumentAmountApproximateTests {
  private let usd = Instrument.fiat(code: "USD")  // match the project's fiat constructor

  @Test func roundsHundredThousandsToThreeSigFigs() {
    #expect(InstrumentAmount(quantity: 225_460.22, instrument: usd).formattedApproximate == "$225,000")
  }
  @Test func preservesNegativeSign() {
    #expect(InstrumentAmount(quantity: -225_460.22, instrument: usd).formattedApproximate == "-$225,000")
  }
  @Test func leavesThreeSigFigValueWhole() {
    #expect(InstrumentAmount(quantity: 9_840, instrument: usd).formattedApproximate == "$9,840")
  }
  @Test func roundsSmallValueToWholeCurrency() {
    #expect(InstrumentAmount(quantity: 512.30, instrument: usd).formattedApproximate == "$512")
  }
  @Test func zeroIsZero() {
    #expect(InstrumentAmount(quantity: 0, instrument: usd).formattedApproximate == "$0")
  }
}
```

> Confirm the exact `Instrument` fiat constructor and the `InstrumentAmount` initialiser the project uses (grep `InstrumentAmount(quantity:` in existing tests, e.g. `.AUD`/`.USD` static members) and match it. Use `Currency.defaultTestCurrency` if that's the established test pattern.

- [ ] **Step 2 — run** `just test-mac InstrumentAmountApproximateTests` → FAIL (no member `formattedApproximate`).
- [ ] **Step 3 — implement** on `InstrumentAmount` (fiat path only; for stock/crypto fall through to `formatted`):

```swift
/// A deliberately imprecise rendering for "ballpark" figures (e.g. a month-end
/// forecast): rounds the magnitude to ~3 significant figures and drops the
/// fractional currency unit, so a wide-confidence projection reads as
/// "$225,000", not "$225,460.22". Sign is preserved (never `abs()`-ed).
var formattedApproximate: String {
  guard case .fiatCurrency = instrument.kind else { return formatted }
  let rounded = Self.roundedToSignificantFigures(quantity, figures: 3)
  return rounded.formatted(.currency(code: instrument.id).precision(.fractionLength(0)))
}

private static func roundedToSignificantFigures(_ value: Decimal, figures: Int) -> Decimal {
  guard value != 0 else { return 0 }
  let magnitude = abs((value as NSDecimalNumber).doubleValue)
  let exponent = Int(floor(log10(magnitude))) - (figures - 1)
  var result = Decimal()
  var input = value
  NSDecimalRound(&result, &input, -exponent, .plain)
  return result
}
```

> Verify `instrument.kind`/`instrument.id`/`.fiatCurrency` names against `InstrumentAmount.formatted` (the explore confirmed this shape). `.currency(code:).precision(.fractionLength(0))` yields no decimals; the rounded value already has zeros below the sig-fig cutoff so grouping renders "$225,000".

- [ ] **Step 4 — add the `InsightContext` delegate** so detectors can call it:

```swift
func formattedApproximate(_ quantity: Decimal) -> String {
  InstrumentAmount(quantity: quantity, instrument: reportingCurrency).formattedApproximate
}
```

- [ ] **Step 5 — run** `just test-mac InstrumentAmountApproximateTests` → PASS. `code-review`, apply findings. **format-check. commit.**

---

## Task 3: Forecast — suppress wide bands, round the projection (TDD)

**Files:**
- Modify: `Domain/Insights/Detectors/CashFlowForecastInsights.swift`
- Test: `MoolahTests/Domain/Insights/CashFlowForecastInsightsTests.swift` (extend or create)

Changes: (a) suppress the projected-month-end insight when `band >= 0.5 * |projected|`; (b) the `title` carries the **rounded** projection via `context.formattedApproximate(projected)`; (c) the "Projected balance" fact also uses the rounded figure; (d) remove the "Confidence band" fact and the "±…" clause from the title/detail-free narration.

- [ ] **Step 1 — failing tests.** Build two fixtures (reuse the file's existing `DailyBalance` test helpers — grep the current test for the constructor):

```swift
@Test func suppressesForecastWhenBandIsAtLeastHalfOfProjected() {
  // history with high day-over-day variance → band >= 0.5 * |projected|
  let insights = CashFlowForecastInsights.projectedMonthEnd(dailyBalances: wideBandFixture, context: ctx)
  #expect(insights.isEmpty)
}

@Test func showsRoundedProjectionWhenBandIsNarrow() {
  let insights = CashFlowForecastInsights.projectedMonthEnd(dailyBalances: narrowBandFixture, context: ctx)
  let insight = try? #require(insights.first)
  #expect(insight?.title.contains("$225,000") == true)        // rounded, not $225,460.22
  #expect(insight?.facts.contains { $0.label == "Confidence band" } == false)
}
```

> Pin the fixtures so the narrow case projects ≈$225,460 with a small band, and the wide case has a band ≥ half the projection. Use fixed `Date(timeIntervalSince1970:)` values (memory: deterministic seeds — no `Date()`).

- [ ] **Step 2 — run** → FAIL.
- [ ] **Step 3 — implement.** In `projectedMonthEnd`, after computing `band` and `projected`:

```swift
let projectedMagnitude = abs(Double(truncating: projected as NSDecimalNumber))
let bandMagnitude = abs(Double(truncating: band as NSDecimalNumber))
// A projection whose 14-day noise band is at least half its own size carries no
// usable signal — suppress it rather than print a scary ±range.
guard projectedMagnitude == 0 || bandMagnitude < Self.maxBandFraction * projectedMagnitude else {
  return []
}
```

Add `private static let maxBandFraction = 0.5`. Change the `title` to use `context.formattedApproximate(projected)` and drop the `(±…)` clause. Replace the `InsightFact("Projected balance", context.formatted(projected))` value with `context.formattedApproximate(projected)`. **Delete** the `InsightFact("Confidence band", …)` line. (Note: `detail` is removed in Task 5 — for now leave a short `detail` that also uses the rounded figure with no band; Task 5 deletes the param.)

- [ ] **Step 4 — run** → PASS. Run the full forecast suite + `InsightRankerTests` to confirm no regressions.
- [ ] **Step 5 — `code-review`,** apply findings. **format-check. commit.**

---

## Task 4: Drop the "Robust z-score" facts (TDD-guarded)

**Files:**
- Modify: `Domain/Insights/Detectors/CategoryAnomalyInsight.swift` (remove the `InsightFact("Robust z-score", …)` line)
- Modify: `Domain/Insights/Detectors/LargeTransactionInsight.swift` (same)
- Grep `Robust z-score` across `Domain/Insights/Detectors` to catch any sibling; remove all.
- Tests: any test asserting that fact must be updated.

> The z-score still drives `surprise` (`NormalDistribution.surprise(fromZScore:)`); we only remove the user-facing/narrator-facing fact.

- [ ] **Step 1 — remove the fact lines.** `grep -rn "Robust z-score" --include="*.swift" .` → fix every production + test site.
- [ ] **Step 2 — `just test-mac CategoryAnomalyInsightTests LargeTransactionInsightTests`** (and any others referencing the fact) → green.
- [ ] **Step 3 — `code-review`,** apply findings. **format-check. commit.**

---

## Task 5: Delete `Insight.detail` (atomic, large)

**Files — modify (model + every `detail:` site):**
- `Domain/Insights/Insight.swift`: remove the `detail` stored property, the doc-comment bullet, and the `detail` init param.
- All 23 detectors under `Domain/Insights/Detectors/` that pass `detail:` — remove the argument. **For each, confirm the `title` is self-sufficient**; if `detail` carried essential context (a number, a comparison) absent from the title, fold it into the title. List of detectors (from grep): `CategoryMixShiftInsight`, `SavingsGoalInsight`, `CategoryAnomalyInsight`, `UnusualDayInsight`, `BudgetCoverageInsights`, `PeriodComparisonInsights`, `SpendHabitInsights`, `NewMerchantInsight`, `CashFlowForecastInsights`, `LargeTransactionInsight`, `InvestmentInsights`, `NetWorthInsights`, `EarmarkBudgetInsights`, `SubscriptionInsights`, `LiquidityInsights`, `CategoryTrendInsight`, `SavingsOpportunityInsights`, `IncomeInsights`, `AccountGroupInsights`, `SavingsRateInsight`, `IncomeExtraInsights`, `DataQualityInsights`.
- `Domain/Insights/Narration/NarrationRequest.swift`: change `.singleInsight(title:detail:facts:)` → `.singleInsight(title:facts:)`; update `allFacts`.
- `Domain/Insights/Narration/NarrationPromptBuilder.swift`: drop the `detail` reference from the single-insight prompt body.
- `Domain/Insights/Narration/TemplateNarrator.swift`: compose from `title` only (drop the `detail`-fallback).
- `Features/Insights/InsightStore+Narration.swift`: drop `detail:` from the `NarrationRequest.singleInsight(...)` it builds.
- `Features/Insights/Views/ForYouCard.swift`: remove the `detail` `Text` from `expandedContent` (this whole view is rewritten in Task 8, but it must compile after Task 5 — remove the `detail` usage now).
- Tests / fixtures: `MoolahTests/Features/Insights/InsightStoreTests.swift`, `MoolahTests/Domain/Insights/InsightRankerTests.swift`, `MoolahTests/Backends/GRDB/PlanPinningTestHelpers.swift`, the `ForYouCard` `#Preview` fixtures, and `App/UITestSeedInsightOverrides.swift` `insightsForYouBaselineInsights` — remove every `detail:`.

- [ ] **Step 1 — remove the property + init param** in `Insight.swift`.
- [ ] **Step 2 — fix every construction site.** `grep -rln "detail:" --include="*.swift" Domain/Insights Features/Insights MoolahTests App UITestSupport | grep -v .build` and remove the argument at each. For each detector, read its `title` and confirm it stands alone; reword the title where `detail` held the substance (e.g. fold a comparison figure into the title). Keep titles in brand voice.
- [ ] **Step 3 — `just build-mac`** → success (compiler enumerates any missed site).
- [ ] **Step 4 — `just test-mac` + `just test-ios`** → green. Update any test asserting `detail`.
- [ ] **Step 5 — `grep -rn "\.detail\b\|detail:" --include="*.swift" Domain/Insights Features/Insights | grep -v .build`** → only unrelated matches remain (e.g. SwiftUI `detail` panes elsewhere are out of this scope; confirm none are insight-related).
- [ ] **Step 6 — `code-review`** (logic + naming), `help-review` (any reworded titles are user-facing). Apply findings. **format-check. commit** ("Delete Insight.detail; titles are now self-sufficient").

---

## Task 6: Ground the provenance guard against `title` ∪ `facts` (TDD)

**Files:**
- Modify: `Domain/Insights/Narration/NumericProvenanceGuard.swift` — add a `title` parameter: `isGrounded(_ generated: String, title: String, facts: [InsightFact]) -> Bool`. The grounded number pool becomes the normalised numeric tokens of `title` plus every fact value.
- Modify: `Features/Insights/Narration/FoundationModelsNarrator.swift` — pass the request's title (add `title` to `NarrationRequest`'s public surface if not already reachable; `allFacts` exists, add an analogous `title`/`groundingText`).
- Modify: `Domain/Insights/Narration/NarrationRequest.swift` — expose the title for grounding (e.g. a `groundingTitle: String` computed from the `.singleInsight` case).
- Test: `MoolahTests/Domain/Insights/NumericProvenanceGuardTests.swift` — update call sites; add cases.

- [ ] **Step 1 — failing tests.**

```swift
@Test func passesWhenNumberIsGroundedInTitleOnly() {
  // milestone: the figure lives in the title, not the facts
  #expect(NumericProvenanceGuard.isGrounded(
    "Your net worth just passed $100k — a new high.",
    title: "Net worth crossed $100k",
    facts: []))
}

@Test func stillFailsOnInventedNumber() {
  #expect(!NumericProvenanceGuard.isGrounded(
    "You spent $700 on dining.",
    title: "Dining is up this month",
    facts: [InsightFact("This month", "$640.00")]))
}

@Test func stillFailsOnFlippedSign() {
  #expect(!NumericProvenanceGuard.isGrounded(
    "Up +$640.00 this month.",
    title: "Dining change",
    facts: [InsightFact("Change", "−$640.00")]))
}
```

- [ ] **Step 2 — run** → FAIL (signature mismatch / title number rejected).
- [ ] **Step 3 — implement.** Extend the grounded-token pool: tokenise `title` with the same normalisation already applied to fact values, union the two sets, and check every generated token against the union. Keep the existing normalisation helpers.
- [ ] **Step 4 — update `FoundationModelsNarrator`** to call `isGrounded(latest, title: request.groundingTitle, facts: request.allFacts)`.
- [ ] **Step 5 — run** the guard suite → PASS; `just build-mac` → success.
- [ ] **Step 6 — `code-review`,** apply findings. **format-check. commit.**

---

## Task 7: Reframe the single-insight prompt to write a headline (TDD)

**Files:**
- Modify: `Domain/Insights/Narration/NarrationPromptBuilder.swift`
- Test: `MoolahTests/Domain/Insights/NarrationPromptBuilderTests.swift`

The instructions must now ask for a **self-sufficient headline that replaces the title**, not an explanation of a shown title. Keep all existing voice rules (no corporate words, no scolding, contractions ok, omit statistical terms, use only supplied figures verbatim).

- [ ] **Step 1 — failing test.**

```swift
@Test func headlinePromptAsksForSelfSufficientSentence() {
  let req = NarrationRequest.singleInsight(
    title: "Net worth crossed $100k",
    facts: [InsightFact("Now", "$101,200")])
  let built = NarrationPromptBuilder.build(req)
  #expect(built.prompt.contains("Net worth crossed $100k"))
  #expect(built.prompt.contains("$101,200"))
  #expect(built.instructions.localizedCaseInsensitiveContains("do not invent"))
  #expect(built.instructions.localizedStandardContains("on its own"))  // self-sufficient framing
}
```

- [ ] **Step 2 — run** → FAIL.
- [ ] **Step 3 — implement.** Reword the single-insight instructions: "Write a single sentence that states this insight on its own — it will be shown as the headline, with no other text. Begin with the substance, not a label. …" plus the retained voice rules. The prompt body still lists the title (as context/grounding) and the facts.
- [ ] **Step 4 — run** → PASS. `help-review` the instruction copy (brand voice). Apply findings.
- [ ] **Step 5 — `code-review`. format-check. commit.**

---

## Task 8: `InsightStore` — eager batch generation, `ForYouItem`, no-backfill (store, TDD)

**Files:**
- Create: `Features/Insights/ForYouItem.swift`
- Modify: `Features/Insights/InsightStore.swift`, `Features/Insights/InsightStore+Narration.swift`
- Test: `MoolahTests/Features/Insights/InsightStoreNarrationTests.swift` (rework), `MoolahTests/Features/Insights/InsightStoreTests.swift` (dismiss/no-backfill)

`ForYouItem`:

```swift
/// One ready-to-render For You entry: the ranked insight plus its resolved
/// display headline (the on-device AI line, or the detector `title` fallback).
struct ForYouItem: Identifiable, Sendable, Hashable {
  let scored: ScoredInsight
  let headline: String
  var id: String { scored.id }
}
```

Store changes:
- Add `private var headlineCache: [String: String] = [:]` (keyed by `insight.id`).
- Add a published `private(set) var items: [ForYouItem] = []`.
- Add `var maxVisible = 3` (the top-N cap, moved out of the view).
- **Replace** lazy `narrate(_:)`/`cancelNarration(_:)`/`narration`/`narrationTasks` with batch generation invoked from `refresh()`:
  - After ranking, take `visible(scored).prefix(maxVisible)` as the batch.
  - For each batch member without a `headlineCache` hit: if `currentAvailability.isUsable`, consume `narrator.narrate(.singleInsight(title:facts:))` to its **final** snapshot off-main; on the stream throwing `.fellBack`/any error, use the insight's `title`. If availability is not usable, use `title` immediately. Run all members **concurrently** in a `withTaskGroup`.
  - Cache each resolved headline. Build `[ForYouItem]` for the batch and **assign `items` only after all resolve** (atomic publish on the main actor).
  - Guard with a generation token (an incrementing `Int` captured per refresh) so a superseding `refresh()` discards a stale batch.
- `dismiss(_:)`: keep the optimistic `dismissedIds` insert, the `dismissals[kind] += 1` fatigue bump, the persistence call, and the rollback — but **remove the `rerank()` call**. Instead filter the dismissed id out of `items` directly. The fatigue penalty reshapes ranking on the next `refresh()` only (no backfill this session).
- `refreshIfStale`/the instrument-change tick still drive `refresh()`.

- [ ] **Step 1 — failing store tests** (fake narrator + `FixedModelAvailability`; use `TestBackend`):
  - `itemsPublishedOnlyWhenWholeBatchResolves`: with `.available` and a `ScriptedNarrator` returning known lines, after `refresh()` `store.items` has the batch and each `headline` equals the scripted line.
  - `guardFailureFallsBackToTitle`: a throwing narrator → every `headline` equals its `insight.title`, and `items` is still published.
  - `availabilityOffUsesTitle`: `.unavailable(.deviceNotEligible)` → headlines equal titles, no narrator call.
  - `cacheHitSkipsRegeneration`: a counting narrator is invoked once per id across two `refresh()` calls.
  - `showLessRemovesRowWithoutBackfill`: with 4 ranked insights and `maxVisible = 3`, dismissing one of the visible 3 leaves **2** items (the 4th is **not** promoted), and the persisted fatigue count for that kind incremented.
  - `showLessRollsBackOnPersistFailure`: a failing dismissal repo restores the row.

```swift
@Test func showLessRemovesRowWithoutBackfill() async throws {
  let store = makeStore(rankedCount: 4, maxVisible: 3, availability: .unavailable(.deviceNotEligible))
  await store.refresh()
  #expect(store.items.count == 3)
  let removed = try #require(store.items.first)
  await store.dismiss(removed.scored)
  #expect(store.items.count == 2)                          // NOT 3 — no backfill
  #expect(!store.items.contains { $0.id == removed.id })
}
```

- [ ] **Step 2 — run** → FAIL.
- [ ] **Step 3 — implement** the batch generation + `dismiss` rework. Consume the stream:

```swift
private func resolveHeadline(for scored: ScoredInsight) async -> String {
  let insight = scored.insight
  if let cached = headlineCache[insight.id] { return cached }
  guard currentAvailability.isUsable else { return insight.title }
  let request = NarrationRequest.singleInsight(title: insight.title, facts: insight.facts)
  do {
    var latest = insight.title
    for try await snapshot in narrator.narrate(request) { latest = snapshot }
    return latest
  } catch {
    return insight.title   // .fellBack or any generation error
  }
}
```

Run resolution concurrently in `refresh()` (task group keyed by id), then publish.

- [ ] **Step 4 — run** all store tests → PASS.
- [ ] **Step 5 — `concurrency-review` + `code-review`** on `InsightStore*.swift` (off-main streams, task-group cancellation, generation-token race, main-actor publish). Apply findings. **format-check. commit.**

---

## Task 9: `ForYouCard` redesign + `AnalysisView` wiring (view)

**Files:**
- Modify: `Features/Insights/Views/ForYouCard.swift`
- Modify: `Features/Analysis/Views/AnalysisView.swift`
- Modify: `UITestSupport/UITestIdentifiers+ForYou.swift`

`ForYouCard` now takes `items: [ForYouItem]`, `onDismiss: (ForYouItem) -> Void`, `onNavigate: (SidebarSelection) -> Void`. Remove `availability`, `narration`, `onNarrate`, `onCancelNarrate`, `maxVisible`. `InsightRow` renders:

```swift
VStack(alignment: .leading, spacing: 6) {
  HStack(alignment: .top, spacing: 8) {
    Image(systemName: framingIcon).foregroundStyle(framingColor).accessibilityHidden(true)
    Text(item.headline).font(.subheadline).fontWeight(.medium)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier(UITestIdentifiers.ForYou.headline(item.id))
    Spacer(minLength: 8)
    showLessButton
  }
  HStack(spacing: 12) {
    if let impact = item.scored.insight.monetaryImpact {
      Text(impact.formatted).font(.subheadline).monospacedDigit().foregroundStyle(impactColor(impact))
    }
    Spacer(minLength: 0)
    if let target { Button("View") { onNavigate(target) }.buttonStyle(.borderless)
      .accessibilityIdentifier(UITestIdentifiers.ForYou.viewButton(item.id)) }
  }
}
```

`showLessButton`: a clearly-labelled control replacing `xmark.circle.fill`:

```swift
private var showLessButton: some View {
  Button(action: onDismiss) {
    Label("Show less", systemImage: "hand.thumbsdown")
      .labelStyle(.iconOnly)        // finalise icon-only vs text via ui-review
      .contentShape(Rectangle())
  }
  .buttonStyle(.borderless)
  .foregroundStyle(.secondary)
  #if os(iOS)
    .frame(minWidth: 44, minHeight: 44)
  #endif
  .help("Show fewer insights like this")
  .accessibilityLabel("Show fewer insights like this: \(item.headline)")
  .accessibilityIdentifier(UITestIdentifiers.ForYou.showLess(item.id))
}
```

Remove the disclosure/`expandToggle`, `isExpanded`, the "Why?" affordance, the facts loop, and `detail`.

`UITestIdentifiers+ForYou.swift`: remove `whyButton` and `narrationText`; add `headline(_ id:)` and `showLess(_ id:)`; keep `card`, `row`, `viewButton`. (Drop `dismissButton` or alias it to `showLess` — prefer renaming to `showLess` and updating all callers.)

`AnalysisView`: replace the `ForYouCard(...)` construction — render when `!insightStore.items.isEmpty`:

```swift
if let insightStore = session.insightStore, !insightStore.items.isEmpty {
  ForYouCard(
    items: insightStore.items,
    onDismiss: { item in Task { await insightStore.dismiss(item.scored) } },
    onNavigate: { sidebarSelection?.wrappedValue = $0 })
}
```

- [ ] **Step 1 — rewrite `ForYouCard`** + update identifiers + `#Preview` (fixtures with AI-style headlines and plain-title headlines; ±impact; ±nav target). Build.
- [ ] **Step 2 — wire `AnalysisView`** (thin; one-liner closures).
- [ ] **Step 3 — `just build-mac`** → success.
- [ ] **Step 4 — `RenderPreview`** (per the worktree-preview caveat: `just generate` then open the worktree's `Moolah.xcodeproj`). Confirm: single headline line, wraps cleanly; "Show less" reads as intent, not "close"; impact + View placement. Iterate via preview (memory `feedback_iterate_via_preview`).
- [ ] **Step 5 — `ui-review`** (HIG, accessibility, the "Show less" affordance label/icon), apply findings. **format-check. commit.**

---

## Task 10: Deterministic For You UI test (inline headline + no backfill)

**Files:**
- Modify: `MoolahUITests_macOS/Helpers/Screens/ForYouScreen.swift`
- Modify: `MoolahUITests_macOS/Tests/ForYou/ForYouNarrationUITests.swift` (rework) and `ForYouPanelUITests.swift`
- Modify: `App/UITestSeedInsightOverrides.swift` (the `.insightsForYouBaseline` seed already forces `FixedModelAvailability(.available)` + a `ScriptedNarrator`; ensure ≥4 fixture insights so no-backfill is testable, and `maxVisible` exposes 3)
- Modify: `UITestSupport/UITestFixtures+InsightsForYou.swift` (the scripted headline string)

> **REQUIRED SUB-SKILL:** invoke `writing-ui-tests` before editing the driver/test (screen-driver rule, post-condition waits, no element caching, deterministic seeds).

`ForYouScreen` changes: remove `tapWhy`, the `expand`-for-why flow, and `narrationText`/`expectNarrationText` keyed on the why-button. Add:
- `expectHeadline(_ id:, equals:)` — predicate-wait on the `headline(id)` element's value (SwiftUI prose surfaces in `.value`, not `.label` — memory `reference_xcuitest_text_value_not_label`).
- `showLess(_ id:)` — taps `showLess(id)`, waits for that row to be removed.
- Keep `expectRowVisible`/`expectRowRemoved`/`tapView`.

- [ ] **Step 1 — update the seed/fixtures** so `.insightsForYouBaseline` yields ≥4 deterministic insights with known titles and a `ScriptedNarrator` whose output is asserted as the **inline headline** (no tap). Build.
- [ ] **Step 2 — driver + tests:**
  - `testHeadlineRendersInlineWithoutWhyTap`: launch `.insightsForYouBaseline` → `expectCardVisible` → `expectHeadline(largeTxnId, equals: scriptedNarration)` with **no** "Why?" tap.
  - `testShowLessRemovesRowWithoutBackfill`: with 4 fixtures and 3 visible, `showLess(firstVisibleId)` → assert that row removed AND the previously-hidden 4th row did **not** appear (`expectRowRemoved` on its id).
  - `testViewNavigates`: `tapView` → `expectTransactionListVisible`.
- [ ] **Step 3 — run** (`pkill` stale hosts first). If the local UI host is wedged, gate on the PR's CI "UI Test" job. `ui-test-review`, apply findings. **format-check. commit.**

---

## Task 11: Final integration, manual device check, PR

- [ ] **Step 1 — full suite.** `just test 2>&1 | tee .agent-tmp/test-all.txt`; `grep -i 'failed\|error:'` → none (mind the known pre-existing date-flaky tests — memory `reference_pre_existing_date_flaky_tests`; do not count those as regressions). `just format-check 2>&1 | tee .agent-tmp/fc.txt` → zero diffs/violations (read full output).
- [ ] **Step 2 — grep sweeps:** `grep -rn "WeeklyRecap\|weeklyRecap\|\.detail\b\|Robust z-score\|Confidence band\|whyButton\|narrate(" --include="*.swift" . | grep -v .build` → only intended remnants (none for recap/detail/why/z-score/band).
- [ ] **Step 3 — manual on-device check** (`run-mac-app-with-logs`): with Apple Intelligence enabled, open Analysis → confirm the For You card appears only once populated, headlines read as self-sufficient sentences with no numbers absent from title/facts, "Show less" removes a card without a replacement sliding in, and toggling "Explain insights with on-device AI" off falls back to plain titles. If Apple Intelligence can't be enabled here, say so and rely on the scripted UI test + record the gap in the PR.
- [ ] **Step 4 — open the PR.** Push `foryou-ai-headline` with the explicit `<src>:<dst>` form; `gh pr create` with a body that links the design doc, summarises the four UX fixes, notes the `Insight.detail` removal and weekly-recap deletion, and states CI does not cover the live FM path (manual check recorded). Link issues as markdown (memory `feedback_pr_link_format`); end with the Claude Code trailer.
- [ ] **Step 5 — land** via the `landing-prs` skill (`gh pr merge --auto --rebase`), then monitor to merge.

---

## Self-review notes (author)

- **Spec coverage:** AI headline replaces title (T7/T8/T9); inline, no click, hold-until-ready (T8/T9); in-memory cache (T8); fallback to title (T6/T8); facts not displayed (T9); `detail` deleted (T5); z-score/band/category noise gone (T3/T4, category auto-resolved by T9 dropping facts); forecast suppression + rounding (T2/T3); weekly recap removed (T1); "Show less" relabel + no backfill (T8/T9); provenance grounds title∪facts (T6). All covered.
- **Type consistency:** `ForYouItem{scored,headline,id}`, `InsightStore.items`/`maxVisible`/`headlineCache`/`resolveHeadline`/`dismiss`, `NarrationRequest.singleInsight(title:facts:)`, `NumericProvenanceGuard.isGrounded(_:title:facts:)`, `formattedApproximate`, `UITestIdentifiers.ForYou.{headline,showLess,viewButton,row,card}` — used identically across tasks.
- **Ordering keeps the build green:** recap removal (T1) is self-contained; T2–T4 are additive/local; T5 is atomic across all `detail:` sites; T6/T7 are narrator-internal; T8/T9 are the behavioural core; T10 the UI test; T11 integration.
- **FoundationModels live path** is not in CI (decision honoured) — covered by scripted UI test + manual device check recorded in the PR.
