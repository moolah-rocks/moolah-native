# Insight Fallback Descriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bare-`title` deterministic insight fallback with rich, number-bearing one-sentence descriptions for all 37 `InsightKind`s, built from the existing pre-formatted `facts`.

**Architecture:** A new pure `InsightDescriptionComposer` switches on `InsightKind` and weaves pre-formatted `facts` into one readable sentence. `InsightKind` is threaded into `NarrationRequest.singleInsight` so `TemplateNarrator` can call the composer. The AI path (`NarrationPromptBuilder`, `NumericProvenanceGuard`) is untouched — `kind` is metadata for the deterministic composer only, never sent to the model.

**Tech Stack:** Swift 6, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`), `just` build/test/format targets.

## Global Constraints

- **Design doc:** `plans/2026-06-23-insight-fallback-descriptions-design.md` (read it; the per-kind sentences there are the source of truth for wording).
- **Test framework:** Swift Testing only — `@Suite` struct + `@Test` funcs + `#expect`/`#require`. Never XCTest.
- **Build/test/format via `just` only** — never raw `swift`/`swiftlint`/`swift-format`/`xcodebuild`. Capture test output to `.agent-tmp/` (gitignored); `mkdir -p .agent-tmp` first.
- **Run `just test <SuiteTypeName>`** with the EXACT suite type name (`InsightDescriptionComposerTests`, `TemplateNarratorTests`) — a non-matching name runs 0 tests yet still prints SUCCEEDED.
- **Every task ends with `just format-check`** passing (SwiftLint `--strict`, no baseline). Fix length violations by splitting into category extension files — never by collapsing blank lines or bumping thresholds.
- **No redundant file-path header comments** in new files (follow `guides/CODE_GUIDE.md`, not surrounding files).
- **Composer purity:** no model, no I/O, no `Date()`/`Calendar.current`. Numbers come only from fact values (verbatim) or, for title-as-lead kinds, from the intact `title`. Never parse fragments out of `title`.
- **Voice (per `NarrationPromptBuilder.singleInsightInstructions` + `BRAND_GUIDE`):** one sentence; numbers verbatim; warm on good news, never scolding ("overspent"/"wasted"/"should" banned); contractions; address user as "you"/"your"; no corporate words (optimise, leverage, empower, streamline, robust, seamless).
- **Test locale note:** the composer echoes fact strings verbatim, so asserting a full sentence containing `$640.00` is safe — the `$` originates from the test's own input, not from `context.formatted`. This is NOT the currency-symbol locale trap (no formatting happens in the composer).
- **Commits:** end every commit message with the standard trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Q4LphNRBYdAZSbgHNmmCg6
  ```

---

## File Structure

- **Create** `Domain/Insights/Narration/InsightDescriptionComposer.swift` — the `compose(kind:title:facts:)` switch (one line per kind, calling a private arm func), the nested/file-scoped `FactLookup`, and the per-kind arm funcs grouped in `// MARK:` sections. If SwiftLint flags `type_body_length`/`file_length`, split the arm funcs into per-category extension files (`InsightDescriptionComposer+<Category>.swift`) declaring the arm funcs as default-access (internal) static funcs so the switch in the main file can call them.
- **Modify** `Domain/Insights/Narration/NarrationRequest.swift` — add `kind` to `singleInsight`.
- **Modify** `Domain/Insights/Narration/TemplateNarrator.swift` — delegate to the composer.
- **Modify** `Domain/Insights/Narration/NarrationPromptBuilder.swift` — match the new case shape; still sends only title+facts.
- **Modify** `Features/Insights/InsightStore+Narration.swift:107` — pass `insight.kind`.
- **Create** `MoolahTests/Domain/Insights/InsightDescriptionComposerTests.swift` — cross-cutting + per-kind tests.
- **Modify** `MoolahTests/Domain/Insights/TemplateNarratorTests.swift` — assert composed sentence.
- **Modify** `MoolahTests/Domain/Insights/NarrationPromptBuilderTests.swift` — add `kind:` to its 8 `singleInsight(...)` sites.

---

## Task 1: Thread `kind` through the request + composer scaffold (behaviour-preserving)

Wires `kind` end-to-end and introduces the composer with every arm returning `title` (so behaviour is identical to today and the build stays green). Cross-cutting invariants are tested here.

**Files:**
- Modify: `Domain/Insights/Narration/NarrationRequest.swift`
- Modify: `Domain/Insights/Narration/NarrationPromptBuilder.swift:21-26`
- Modify: `Domain/Insights/Narration/TemplateNarrator.swift`
- Modify: `Features/Insights/InsightStore+Narration.swift:107`
- Create: `Domain/Insights/Narration/InsightDescriptionComposer.swift`
- Modify: `MoolahTests/Domain/Insights/TemplateNarratorTests.swift`
- Modify: `MoolahTests/Domain/Insights/NarrationPromptBuilderTests.swift`
- Create: `MoolahTests/Domain/Insights/InsightDescriptionComposerTests.swift`

**Interfaces:**
- Produces: `enum InsightDescriptionComposer { static func compose(kind: InsightKind, title: String, facts: [InsightFact]) -> String }`
- Produces: `NarrationRequest.singleInsight(kind: InsightKind, title: String, facts: [InsightFact])`
- Produces (file-scoped helper used by all later tasks' arm funcs): `struct FactLookup { init(_ facts: [InsightFact]); func value(_ label: String) -> String?; func value(prefix: String) -> String? }`

- [ ] **Step 1: Write the failing cross-cutting tests**

Create `MoolahTests/Domain/Insights/InsightDescriptionComposerTests.swift`:

```swift
import Testing

@testable import Moolah

@Suite("InsightDescriptionComposer")
struct InsightDescriptionComposerTests {
  /// Every kind degrades to the bare title when it has no facts — and never
  /// crashes. This invariant must hold for all kinds, now and as arms fill in.
  @Test
  func everyKindDegradesToTitleWithoutFacts() {
    for kind in InsightKind.allCases {
      let text = InsightDescriptionComposer.compose(kind: kind, title: "Headline", facts: [])
      #expect(text == "Headline")
    }
  }

  @Test
  func factLookupFindsByExactLabelAndPrefix() {
    let facts = [InsightFact("Spent (90d)", "$540.00"), InsightFact("Category", "Dining")]
    let lookup = FactLookup(facts)
    #expect(lookup.value("Category") == "Dining")
    #expect(lookup.value("Missing") == nil)
    #expect(lookup.value(prefix: "Spent") == "$540.00")
    #expect(lookup.value(prefix: "Nope") == nil)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail (do not compile)**

```bash
mkdir -p .agent-tmp
just test-mac InsightDescriptionComposerTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: FAIL — `InsightDescriptionComposer` / `FactLookup` not found.

- [ ] **Step 3: Add `kind` to `NarrationRequest.singleInsight`**

In `Domain/Insights/Narration/NarrationRequest.swift`, change the case and the two `switch` arms:

```swift
  /// A single insight to narrate in one or two sentences.
  case singleInsight(kind: InsightKind, title: String, facts: [InsightFact])

  var allFacts: [InsightFact] {
    switch self {
    case .singleInsight(_, _, let facts):
      return facts
    }
  }

  var groundingTitle: String {
    switch self {
    case .singleInsight(_, let title, _):
      return title
    }
  }
```

- [ ] **Step 4: Update `NarrationPromptBuilder` to the new case shape (still title+facts only)**

In `Domain/Insights/Narration/NarrationPromptBuilder.swift`, change the pattern at line 21 — bind `kind` to `_`, leaving the prompt unchanged:

```swift
    case let .singleInsight(_, title, facts):
      return (
        instructions: singleInsightInstructions,
        prompt: singleInsightPrompt(title: title, facts: facts)
      )
```

- [ ] **Step 5: Create the composer with all arms returning `title`**

Create `Domain/Insights/Narration/InsightDescriptionComposer.swift`:

```swift
import Foundation

/// Deterministic, model-free composer that turns an insight's structured
/// facts into one readable sentence — the non-AI fallback headline. Pure: no
/// model, no I/O, fully testable in CI without a device. Numbers come only
/// from fact values (verbatim) or the intact title; the composer never does
/// arithmetic and never invents a figure.
enum InsightDescriptionComposer {
  static func compose(kind: InsightKind, title: String, facts: [InsightFact]) -> String {
    let f = FactLookup(facts)
    switch kind {
    // A. Recurring & subscriptions
    case .newRecurringDetected: return newRecurringDetected(title: title, facts: f)
    case .subscriptionPriceHike: return subscriptionPriceHike(title: title, facts: f)
    case .duplicateSubscription: return duplicateSubscription(title: title, facts: f)
    case .subscriptionCancellationCandidate:
      return subscriptionCancellationCandidate(title: title, facts: f)
    case .subscriptionOverspend: return subscriptionOverspend(title: title, facts: f)
    // B. Anomaly / surprise spending
    case .largeTransactionAnomaly: return largeTransactionAnomaly(title: title, facts: f)
    case .newMerchantAlert: return newMerchantAlert(title: title, facts: f)
    case .unusualDaySpend: return unusualDaySpend(title: title, facts: f)
    case .categorySpendingAnomaly: return categorySpendingAnomaly(title: title, facts: f)
    // C. Trends & period comparisons
    case .categoryTrendRising: return categoryTrendRising(title: title, facts: f)
    case .categoryTrendFalling: return categoryTrendFalling(title: title, facts: f)
    case .monthOverMonthDelta: return monthOverMonthDelta(title: title, facts: f)
    case .categoryMixShift: return categoryMixShift(title: title, facts: f)
    // D. Cash flow & forecasting
    case .upcomingBillWarning: return upcomingBillWarning(title: title, facts: f)
    case .projectedMonthEndBalance: return projectedMonthEndBalance(title: title, facts: f)
    case .savingsRateTrend: return savingsRateTrend(title: title, facts: f)
    case .runwayEstimate: return runwayEstimate(title: title, facts: f)
    // E. Budget performance (earmarks)
    case .earmarkBurndownProjection: return earmarkBurndownProjection(title: title, facts: f)
    case .earmarkUnderspend: return earmarkUnderspend(title: title, facts: f)
    case .savingsGoalETA: return savingsGoalETA(title: title, facts: f)
    // F. Savings opportunities
    case .idleCashAlert: return idleCashAlert(title: title, facts: f)
    case .feeSpend: return feeSpend(title: title, facts: f)
    // G. Net worth & investments
    case .netWorthMilestone: return netWorthMilestone(title: title, facts: f)
    case .investmentConcentrationRisk:
      return investmentConcentrationRisk(title: title, facts: f)
    case .topPerformer: return topPerformer(title: title, facts: f)
    case .bottomPerformer: return bottomPerformer(title: title, facts: f)
    case .capitalGainsHarvest: return capitalGainsHarvest(title: title, facts: f)
    // H. Income analysis
    case .paycheckTimingPattern: return paycheckTimingPattern(title: title, facts: f)
    case .incomeStabilityScore: return incomeStabilityScore(title: title, facts: f)
    case .missingPaycheckAlert: return missingPaycheckAlert(title: title, facts: f)
    case .windfallIncome: return windfallIncome(title: title, facts: f)
    case .payRateChange: return payRateChange(title: title, facts: f)
    // K/L/M. Structure, data quality, coverage
    case .groupSpendConcentration: return groupSpendConcentration(title: title, facts: f)
    case .uncategorizedBacklog: return uncategorizedBacklog(title: title, facts: f)
    case .unreconciledTransfers: return unreconciledTransfers(title: title, facts: f)
    case .lapsedMerchant: return lapsedMerchant(title: title, facts: f)
    case .weekendSpendSkew: return weekendSpendSkew(title: title, facts: f)
    case .unbudgetedCategory: return unbudgetedCategory(title: title, facts: f)
    }
  }
}

extension InsightDescriptionComposer {
  /// `true` when a signed "Change" fact ("+30%", "−30%") denotes an increase.
  static func changeIsIncrease(_ change: String) -> Bool { change.hasPrefix("+") }

  /// Strips a leading sign ("+", "−" U+2212, or ASCII "-") for prose that
  /// supplies the direction word separately.
  static func unsigned(_ value: String) -> String {
    if let first = value.first, first == "+" || first == "−" || first == "-" {
      return String(value.dropFirst())
    }
    return value
  }

  // Arm funcs are filled in by later tasks; each returns `title` until then.
  static func newRecurringDetected(title: String, facts: FactLookup) -> String { title }
  static func subscriptionPriceHike(title: String, facts: FactLookup) -> String { title }
  static func duplicateSubscription(title: String, facts: FactLookup) -> String { title }
  static func subscriptionCancellationCandidate(title: String, facts: FactLookup) -> String {
    title
  }
  static func subscriptionOverspend(title: String, facts: FactLookup) -> String { title }
  static func largeTransactionAnomaly(title: String, facts: FactLookup) -> String { title }
  static func newMerchantAlert(title: String, facts: FactLookup) -> String { title }
  static func unusualDaySpend(title: String, facts: FactLookup) -> String { title }
  static func categorySpendingAnomaly(title: String, facts: FactLookup) -> String { title }
  static func categoryTrendRising(title: String, facts: FactLookup) -> String { title }
  static func categoryTrendFalling(title: String, facts: FactLookup) -> String { title }
  static func monthOverMonthDelta(title: String, facts: FactLookup) -> String { title }
  static func categoryMixShift(title: String, facts: FactLookup) -> String { title }
  static func upcomingBillWarning(title: String, facts: FactLookup) -> String { title }
  static func projectedMonthEndBalance(title: String, facts: FactLookup) -> String { title }
  static func savingsRateTrend(title: String, facts: FactLookup) -> String { title }
  static func runwayEstimate(title: String, facts: FactLookup) -> String { title }
  static func earmarkBurndownProjection(title: String, facts: FactLookup) -> String { title }
  static func earmarkUnderspend(title: String, facts: FactLookup) -> String { title }
  static func savingsGoalETA(title: String, facts: FactLookup) -> String { title }
  static func idleCashAlert(title: String, facts: FactLookup) -> String { title }
  static func feeSpend(title: String, facts: FactLookup) -> String { title }
  static func netWorthMilestone(title: String, facts: FactLookup) -> String { title }
  static func investmentConcentrationRisk(title: String, facts: FactLookup) -> String { title }
  static func topPerformer(title: String, facts: FactLookup) -> String { title }
  static func bottomPerformer(title: String, facts: FactLookup) -> String { title }
  static func capitalGainsHarvest(title: String, facts: FactLookup) -> String { title }
  static func paycheckTimingPattern(title: String, facts: FactLookup) -> String { title }
  static func incomeStabilityScore(title: String, facts: FactLookup) -> String { title }
  static func missingPaycheckAlert(title: String, facts: FactLookup) -> String { title }
  static func windfallIncome(title: String, facts: FactLookup) -> String { title }
  static func payRateChange(title: String, facts: FactLookup) -> String { title }
  static func groupSpendConcentration(title: String, facts: FactLookup) -> String { title }
  static func uncategorizedBacklog(title: String, facts: FactLookup) -> String { title }
  static func unreconciledTransfers(title: String, facts: FactLookup) -> String { title }
  static func lapsedMerchant(title: String, facts: FactLookup) -> String { title }
  static func weekendSpendSkew(title: String, facts: FactLookup) -> String { title }
  static func unbudgetedCategory(title: String, facts: FactLookup) -> String { title }
}

/// Label-keyed access over an insight's `facts`. Exact-label lookup for the
/// common case; prefix lookup for detectors that embed a dynamic value in the
/// label ("Spent (90d)", "Typical Monday", "Over 6 months").
struct FactLookup {
  private let byLabel: [String: String]
  private let facts: [InsightFact]

  init(_ facts: [InsightFact]) {
    self.facts = facts
    byLabel = Dictionary(facts.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
  }

  func value(_ label: String) -> String? { byLabel[label] }
  func value(prefix: String) -> String? { facts.first { $0.label.hasPrefix(prefix) }?.value }
}
```

- [ ] **Step 6: Delegate `TemplateNarrator` to the composer**

In `Domain/Insights/Narration/TemplateNarrator.swift`, replace the `compose` body:

```swift
extension TemplateNarrator {
  private func compose(_ request: NarrationRequest) -> String {
    switch request {
    case let .singleInsight(kind, title, facts):
      return InsightDescriptionComposer.compose(kind: kind, title: title, facts: facts)
    }
  }
}
```

- [ ] **Step 7: Pass `kind` at the store construction site**

In `Features/Insights/InsightStore+Narration.swift:107`:

```swift
    let request = NarrationRequest.singleInsight(
      kind: insight.kind, title: insight.title, facts: insight.facts)
```

- [ ] **Step 8: Update the two affected test files for the new case shape**

In `MoolahTests/Domain/Insights/TemplateNarratorTests.swift`, the fallback now composes — but `categorySpendingAnomaly` isn't implemented until Task 3, so for now pass a kind and assert it still degrades to the title (the facts here don't match any implemented arm yet). Replace the test:

```swift
  @Test
  func singleInsightComposesFromFacts() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.singleInsight(
      kind: .categorySpendingAnomaly,
      title: "Dining is up this month",
      facts: [InsightFact("This month", "$640.00"), InsightFact("6-mo median", "$410.00")])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    // Arm not yet implemented (Task 3) and the fact labels here don't match
    // its required labels, so the composer degrades to the title.
    #expect(text == "Dining is up this month")
  }
```

In `MoolahTests/Domain/Insights/NarrationPromptBuilderTests.swift`, add `kind:` to each of the 8 `NarrationRequest.singleInsight(...)` constructions (lines ~9, 26, 38, 48, 58, 69, 79, 85). The kind doesn't affect the prompt, so use `kind: .categorySpendingAnomaly` for each, e.g.:

```swift
    let req = NarrationRequest.singleInsight(
      kind: .categorySpendingAnomaly, title: "T", facts: facts)
```

- [ ] **Step 9: Build and run the full affected suites**

```bash
just test-mac InsightDescriptionComposerTests TemplateNarratorTests NarrationPromptBuilderTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt || echo "clean"
```
Expected: PASS. If any other file fails to compile due to the new associated value, fix that `singleInsight(...)` site by adding `kind:` and re-run.

- [ ] **Step 10: Format check**

```bash
just format-check 2>&1 | tee .agent-tmp/format.txt
```
Expected: no diff, no violations. If `type_body_length`/`file_length` trips on the composer, split the arm-func extension into per-category files (`InsightDescriptionComposer+Subscriptions.swift`, etc.) — keep the funcs default-access so the main switch can call them.

- [ ] **Step 11: Commit**

```bash
git add -A && git commit
```
Message: `feat(insights): thread kind through narration request + composer scaffold`

---

## Tasks 2–9: per-category arm implementations

Each task fills in the arm funcs for one category, replacing `{ title }` with real composition, and adds one `@Test` per kind (plus both directions/variants where applicable) to `InsightDescriptionComposerTests.swift`. The pattern for every step is identical:

1. **Write the failing tests** for this category's kinds (append `@Test` funcs to the suite).
2. **Run** `just test-mac InsightDescriptionComposerTests` → FAIL (arms still return title).
3. **Replace** the arm-func bodies with the code shown.
4. **Run** `just test-mac InsightDescriptionComposerTests` → PASS.
5. **`just format-check`** → clean.
6. **Commit** with the message shown.

The cross-cutting `everyKindDegradesToTitleWithoutFacts` test continues to pass after each task (every arm still returns `title` when its required facts are absent).

---

### Task 2: A. Recurring & subscriptions

**Tests to append:**

```swift
  @Test
  func newRecurringDetectedReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .newRecurringDetected, title: "New monthly subscription",
      facts: [InsightFact("Merchant", "Spotify"), InsightFact("Monthly equivalent", "$11.99")])
    #expect(text == "You've started a new Spotify subscription — about $11.99 a month.")
  }

  @Test
  func subscriptionPriceHikeReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .subscriptionPriceHike, title: "Netflix went up",
      facts: [
        InsightFact("Merchant", "Netflix"), InsightFact("New charge", "$22.99"),
        InsightFact("Previous typical", "$15.99"), InsightFact("Increase", "46%"),
        InsightFact("Extra per month", "$7.00"),
      ])
    #expect(text == "Netflix now costs $22.99 a month — $7.00 more than before, a 46% rise.")
  }

  @Test
  func duplicateSubscriptionReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .duplicateSubscription, title: "Overlapping Streaming subscriptions",
      facts: [
        InsightFact("Category", "Streaming"),
        InsightFact("Services", "Netflix, Disney+"),
        InsightFact("Combined monthly", "$32.98"),
      ])
    #expect(
      text
        == "You're paying for overlapping Streaming subscriptions (Netflix, Disney+) — $32.98 a month combined."
    )
  }

  @Test
  func subscriptionCancellationCandidateReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .subscriptionCancellationCandidate, title: "Still paying for Gym",
      facts: [
        InsightFact("Merchant", "Gym"), InsightFact("Usual cadence", "every 30 days"),
        InsightFact("Days since last", "65"), InsightFact("Monthly cost", "$40.00"),
      ])
    #expect(
      text
        == "You're still paying $40.00 a month for Gym, but there hasn't been a charge in 65 days."
    )
  }

  @Test
  func subscriptionOverspendReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .subscriptionOverspend, title: "Subscriptions are 8% of income",
      facts: [
        InsightFact("Monthly subscriptions", "$120.00"),
        InsightFact("Share of income", "8%"), InsightFact("Active subscriptions", "6"),
      ])
    #expect(text == "Your 6 subscriptions add up to $120.00 a month — 8% of your income.")
  }
```

**Arm bodies:**

```swift
  static func newRecurringDetected(title: String, facts: FactLookup) -> String {
    guard let merchant = facts.value("Merchant"),
      let monthly = facts.value("Monthly equivalent")
    else { return title }
    return "You've started a new \(merchant) subscription — about \(monthly) a month."
  }

  static func subscriptionPriceHike(title: String, facts: FactLookup) -> String {
    guard let merchant = facts.value("Merchant"), let newCharge = facts.value("New charge"),
      let extra = facts.value("Extra per month"), let increase = facts.value("Increase")
    else { return title }
    return "\(merchant) now costs \(newCharge) a month — \(extra) more than before, a \(increase) rise."
  }

  static func duplicateSubscription(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let services = facts.value("Services"),
      let combined = facts.value("Combined monthly")
    else { return title }
    return "You're paying for overlapping \(category) subscriptions (\(services)) — \(combined) a month combined."
  }

  static func subscriptionCancellationCandidate(title: String, facts: FactLookup) -> String {
    guard let merchant = facts.value("Merchant"), let monthly = facts.value("Monthly cost"),
      let days = facts.value("Days since last")
    else { return title }
    return "You're still paying \(monthly) a month for \(merchant), but there hasn't been a charge in \(days) days."
  }

  static func subscriptionOverspend(title: String, facts: FactLookup) -> String {
    guard let count = facts.value("Active subscriptions"),
      let monthly = facts.value("Monthly subscriptions"),
      let share = facts.value("Share of income")
    else { return title }
    return "Your \(count) subscriptions add up to \(monthly) a month — \(share) of your income."
  }
```

**Commit:** `feat(insights): subscription fallback descriptions`

---

### Task 3: B. Anomaly / surprise spending

**Tests to append:**

```swift
  @Test
  func largeTransactionAnomalyReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .largeTransactionAnomaly, title: "Unusually large Dining charge",
      facts: [
        InsightFact("Merchant", "Steakhouse"), InsightFact("Amount", "$450.00"),
        InsightFact("Category", "Dining"), InsightFact("Typical for category", "$200.00"),
      ])
    #expect(
      text
        == "A $450.00 charge from Steakhouse stands out for Dining, where you usually spend around $200.00."
    )
  }

  @Test
  func newMerchantAlertReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .newMerchantAlert, title: "First charge from Acme",
      facts: [InsightFact("Merchant", "Acme"), InsightFact("Amount", "$80.00")])
    #expect(text == "Your first charge from Acme came in at $80.00.")
  }

  @Test
  func unusualDaySpendReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .unusualDaySpend, title: "Big spending Monday",
      facts: [
        InsightFact("Day", "Monday"), InsightFact("Spent", "$300.00"),
        InsightFact("Typical Monday", "$95.00"), InsightFact("Multiple", "3.2×"),
      ])
    #expect(text == "You spent $300.00 on Monday — around 3.2× your usual $95.00.")
  }

  @Test
  func categorySpendingAnomalyReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .categorySpendingAnomaly, title: "Dining up 56% in June",
      facts: [
        InsightFact("Category", "Dining"), InsightFact("This month", "$640.00"),
        InsightFact("Expected", "$410.00"), InsightFact("Over by", "56%"),
      ])
    #expect(
      text == "Your Dining spending hit $640.00 this month — about 56% above your usual $410.00.")
  }
```

**Arm bodies:**

```swift
  static func largeTransactionAnomaly(title: String, facts: FactLookup) -> String {
    guard let amount = facts.value("Amount"), let merchant = facts.value("Merchant"),
      let category = facts.value("Category"), let typical = facts.value("Typical for category")
    else { return title }
    return "A \(amount) charge from \(merchant) stands out for \(category), where you usually spend around \(typical)."
  }

  static func newMerchantAlert(title: String, facts: FactLookup) -> String {
    guard let merchant = facts.value("Merchant"), let amount = facts.value("Amount")
    else { return title }
    return "Your first charge from \(merchant) came in at \(amount)."
  }

  static func unusualDaySpend(title: String, facts: FactLookup) -> String {
    guard let day = facts.value("Day"), let spent = facts.value("Spent"),
      let multiple = facts.value("Multiple"), let typical = facts.value("Typical \(day)")
    else { return title }
    return "You spent \(spent) on \(day) — around \(multiple) your usual \(typical)."
  }

  static func categorySpendingAnomaly(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let thisMonth = facts.value("This month"),
      let over = facts.value("Over by"), let expected = facts.value("Expected")
    else { return title }
    return "Your \(category) spending hit \(thisMonth) this month — about \(over) above your usual \(expected)."
  }
```

**Commit:** `feat(insights): anomaly fallback descriptions`

---

### Task 4: C. Trends & period comparisons

**Tests to append:**

```swift
  @Test
  func categoryTrendRisingReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .categoryTrendRising, title: "Groceries spend rising",
      facts: [InsightFact("Category", "Groceries"), InsightFact("Direction", "Rising"),
        InsightFact("Per month", "$45.00")])
    #expect(text == "Your Groceries spending is trending up, by about $45.00 a month.")
  }

  @Test
  func categoryTrendFallingReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .categoryTrendFalling, title: "Transport spend is trending down",
      facts: [InsightFact("Category", "Transport"), InsightFact("Direction", "Falling"),
        InsightFact("Per month", "$30.00")])
    #expect(text == "Your Transport spending is easing off — down about $30.00 a month.")
  }

  @Test
  func monthOverMonthDeltaUpReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .monthOverMonthDelta, title: "Spending up 30% vs last month",
      facts: [InsightFact("This period", "$2,600.00"), InsightFact("Comparison", "$2,000.00"),
        InsightFact("Change", "+30%")])
    #expect(text == "You spent $2,600.00 this period, up 30% from $2,000.00 before.")
  }

  @Test
  func monthOverMonthDeltaDownReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .monthOverMonthDelta, title: "Spending down 30% vs last month",
      facts: [InsightFact("This period", "$1,400.00"), InsightFact("Comparison", "$2,000.00"),
        InsightFact("Change", "−30%")])
    #expect(text == "You spent $1,400.00 this period, down 30% from $2,000.00 before.")
  }

  @Test
  func categoryMixShiftReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .categoryMixShift, title: "Dining is now 35% of your spending",
      facts: [InsightFact("Category", "Dining"), InsightFact("Current share", "35%"),
        InsightFact("Change", "+8 pts")])
    #expect(text == "Dining now makes up 35% of your spending, up 8 pts.")
  }
```

**Arm bodies:**

```swift
  static func categoryTrendRising(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let perMonth = facts.value("Per month")
    else { return title }
    return "Your \(category) spending is trending up, by about \(perMonth) a month."
  }

  static func categoryTrendFalling(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let perMonth = facts.value("Per month")
    else { return title }
    return "Your \(category) spending is easing off — down about \(perMonth) a month."
  }

  static func monthOverMonthDelta(title: String, facts: FactLookup) -> String {
    guard let thisPeriod = facts.value("This period"), let comparison = facts.value("Comparison"),
      let change = facts.value("Change")
    else { return title }
    let dir = changeIsIncrease(change) ? "up" : "down"
    return "You spent \(thisPeriod) this period, \(dir) \(unsigned(change)) from \(comparison) before."
  }

  static func categoryMixShift(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let share = facts.value("Current share"),
      let change = facts.value("Change")
    else { return title }
    let dir = changeIsIncrease(change) ? "up" : "down"
    return "\(category) now makes up \(share) of your spending, \(dir) \(unsigned(change))."
  }
```

**Commit:** `feat(insights): trend & period-comparison fallback descriptions`

---

### Task 5: D. Cash flow & forecasting

**Tests to append:**

```swift
  @Test
  func upcomingBillWarningWithBillReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .upcomingBillWarning, title: "Low balance coming up",
      facts: [InsightFact("Lowest projected", "$120.00"), InsightFact("On", "Jun 15"),
        InsightFact("Upcoming bill", "Rent $1,500.00")])
    #expect(text == "Your balance is set to dip to $120.00 around Jun 15, after Rent $1,500.00.")
  }

  @Test
  func upcomingBillWarningWithoutBillReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .upcomingBillWarning, title: "Low balance coming up",
      facts: [InsightFact("Lowest projected", "$120.00"), InsightFact("On", "Jun 15")])
    #expect(text == "Your balance is set to dip to $120.00 around Jun 15.")
  }

  @Test
  func projectedMonthEndBalanceReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .projectedMonthEndBalance, title: "On track to end the month around $3,200",
      facts: [InsightFact("Projected balance", "$3,200")])
    #expect(text == "You're on track to finish the month with about $3,200.")
  }

  @Test
  func savingsRateTrendRisingReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .savingsRateTrend, title: "Your savings rate is climbing",
      facts: [InsightFact("Current savings rate", "18%"), InsightFact("Direction", "Rising")])
    #expect(text == "Your savings rate is climbing — you're now saving 18% of your income.")
  }

  @Test
  func savingsRateTrendFallingReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .savingsRateTrend, title: "Your savings rate is slipping",
      facts: [InsightFact("Current savings rate", "9%"), InsightFact("Direction", "Falling")])
    #expect(text == "Your savings rate has slipped to 9% of your income.")
  }

  @Test
  func runwayEstimateReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .runwayEstimate, title: "4 months of runway",
      facts: [InsightFact("Available funds", "$8,000.00"), InsightFact("Monthly burn", "$2,000.00"),
        InsightFact("Runway", "4 months")])
    #expect(text == "At about $2,000.00 a month, your $8,000.00 would cover roughly 4 months.")
  }
```

**Arm bodies:**

```swift
  static func upcomingBillWarning(title: String, facts: FactLookup) -> String {
    guard let lowest = facts.value("Lowest projected"), let on = facts.value("On")
    else { return title }
    if let bill = facts.value("Upcoming bill") {
      return "Your balance is set to dip to \(lowest) around \(on), after \(bill)."
    }
    return "Your balance is set to dip to \(lowest) around \(on)."
  }

  static func projectedMonthEndBalance(title: String, facts: FactLookup) -> String {
    guard let balance = facts.value("Projected balance") else { return title }
    return "You're on track to finish the month with about \(balance)."
  }

  static func savingsRateTrend(title: String, facts: FactLookup) -> String {
    guard let rate = facts.value("Current savings rate"), let direction = facts.value("Direction")
    else { return title }
    if direction == "Rising" {
      return "Your savings rate is climbing — you're now saving \(rate) of your income."
    }
    return "Your savings rate has slipped to \(rate) of your income."
  }

  static func runwayEstimate(title: String, facts: FactLookup) -> String {
    guard let burn = facts.value("Monthly burn"), let funds = facts.value("Available funds"),
      let runway = facts.value("Runway")
    else { return title }
    return "At about \(burn) a month, your \(funds) would cover roughly \(runway)."
  }
```

**Commit:** `feat(insights): cash-flow fallback descriptions`

---

### Task 6: E. Budget performance (earmarks) — title-as-lead + variants

**Tests to append:**

```swift
  @Test
  func earmarkBurndownProjectionReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .earmarkBurndownProjection, title: "Holiday fund heading over budget",
      facts: [InsightFact("Budget", "$800.00"), InsightFact("Spent so far", "$600.00"),
        InsightFact("Projected", "$950.00"), InsightFact("Window elapsed", "50%")])
    #expect(
      text
        == "Holiday fund heading over budget — you've spent $600.00 of your $800.00 budget and you're on pace for $950.00."
    )
  }

  @Test
  func earmarkUnderspendReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .earmarkUnderspend, title: "Room to spare in Groceries",
      facts: [InsightFact("Budget", "$500.00"), InsightFact("Spent so far", "$200.00"),
        InsightFact("Projected", "$300.00"), InsightFact("Window elapsed", "60%")])
    #expect(
      text == "Room to spare in Groceries — you've spent $200.00 of $500.00, on pace for just $300.00."
    )
  }

  @Test
  func savingsGoalReachedReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .savingsGoalETA, title: "Car fund goal reached",
      facts: [InsightFact("Goal", "$5,000.00"), InsightFact("Saved", "$5,000.00")])
    #expect(text == "Car fund goal reached — you've saved $5,000.00 toward your $5,000.00 target.")
  }

  @Test
  func savingsGoalETAReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .savingsGoalETA, title: "Car fund: on track for Jun 2026",
      facts: [InsightFact("Goal", "$5,000.00"), InsightFact("Saved", "$3,000.00"),
        InsightFact("Progress", "60%"), InsightFact("Projected completion", "Jun 2026")])
    #expect(text == "Car fund: on track for Jun 2026 — you've saved $3,000.00 of $5,000.00 (60%).")
  }

  @Test
  func savingsGoalProgressReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .savingsGoalETA, title: "Car fund is 60% of the way there",
      facts: [InsightFact("Goal", "$5,000.00"), InsightFact("Saved", "$3,000.00"),
        InsightFact("Progress", "60%")])
    #expect(text == "Car fund is 60% of the way there — $3,000.00 saved toward $5,000.00.")
  }
```

**Arm bodies:**

```swift
  static func earmarkBurndownProjection(title: String, facts: FactLookup) -> String {
    guard let spent = facts.value("Spent so far"), let budget = facts.value("Budget"),
      let projected = facts.value("Projected")
    else { return title }
    return "\(title) — you've spent \(spent) of your \(budget) budget and you're on pace for \(projected)."
  }

  static func earmarkUnderspend(title: String, facts: FactLookup) -> String {
    guard let spent = facts.value("Spent so far"), let budget = facts.value("Budget"),
      let projected = facts.value("Projected")
    else { return title }
    return "\(title) — you've spent \(spent) of \(budget), on pace for just \(projected)."
  }

  static func savingsGoalETA(title: String, facts: FactLookup) -> String {
    guard let goal = facts.value("Goal"), let saved = facts.value("Saved") else { return title }
    guard let progress = facts.value("Progress") else {
      return "\(title) — you've saved \(saved) toward your \(goal) target."
    }
    if facts.value("Projected completion") != nil {
      return "\(title) — you've saved \(saved) of \(goal) (\(progress))."
    }
    return "\(title) — \(saved) saved toward \(goal)."
  }
```

**Commit:** `feat(insights): earmark & savings-goal fallback descriptions`

---

### Task 7: F. Savings + G. Net worth & investments

**Tests to append:**

```swift
  @Test
  func idleCashAlertReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .idleCashAlert, title: "More cash than usual in liquid accounts",
      facts: [InsightFact("Available funds", "$20,000.00"),
        InsightFact("Average monthly spend", "$4,000.00"),
        InsightFact("Suggested buffer (3 months' spending)", "$12,000.00"),
        InsightFact("Idle excess", "$8,000.00")])
    #expect(
      text
        == "You've got $20,000.00 sitting in cash — about $8,000.00 more than you'd typically need on hand."
    )
  }

  @Test
  func feeSpendReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .feeSpend, title: "You paid $120.00 in fees",
      facts: [InsightFact("Annual fees", "-$120.00"), InsightFact("Transactions", "47")])
    #expect(text == "You paid $120.00 in fees over the past year, across 47 charges.")
  }

  @Test
  func netWorthMilestoneReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .netWorthMilestone, title: "Net worth passed $100,000",
      facts: [InsightFact("Net worth", "$104,200"), InsightFact("Milestone", "$100,000"),
        InsightFact("Was", "$92,000")])
    #expect(text == "Your net worth just passed $100,000 and now sits at $104,200.")
  }

  @Test
  func investmentConcentrationRiskReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .investmentConcentrationRisk, title: "AAPL is 42% of your investments",
      facts: [InsightFact("Holding", "AAPL"), InsightFact("Value", "$21,000.00"),
        InsightFact("Share of portfolio", "42%")])
    #expect(text == "AAPL now makes up 42% of your investments, worth $21,000.00.")
  }

  @Test
  func topPerformerReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .topPerformer, title: "AAPL is your top performer",
      facts: [InsightFact("Holding", "AAPL"), InsightFact("Return", "34%"),
        InsightFact("Gain/loss", "$3,400.00"), InsightFact("Invested", "$10,000.00")])
    #expect(
      text == "AAPL is your strongest holding, up 34% for a $3,400.00 gain on $10,000.00 invested.")
  }

  @Test
  func bottomPerformerReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .bottomPerformer, title: "TSLA is lagging",
      facts: [InsightFact("Holding", "TSLA"), InsightFact("Return", "−12%"),
        InsightFact("Gain/loss", "−$1,200.00"), InsightFact("Invested", "$10,000.00")])
    #expect(text == "TSLA is lagging — −12% on $10,000.00 invested, a −$1,200.00 change.")
  }

  @Test
  func capitalGainsHarvestReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .capitalGainsHarvest, title: "Possible tax-loss offset",
      facts: [InsightFact("Realised gains", "$3,000.00"),
        InsightFact("Unrealised losses", "−$2,500.00"),
        InsightFact("Potential offset", "$2,000.00"), InsightFact("Loss positions", "TSLA, NVDA")])
    #expect(
      text
        == "You could offset $2,000.00 of realised gains against unrealised losses in TSLA, NVDA.")
  }
```

**Arm bodies:**

```swift
  static func idleCashAlert(title: String, facts: FactLookup) -> String {
    guard let funds = facts.value("Available funds"), let excess = facts.value("Idle excess")
    else { return title }
    return "You've got \(funds) sitting in cash — about \(excess) more than you'd typically need on hand."
  }

  static func feeSpend(title: String, facts: FactLookup) -> String {
    guard let transactions = facts.value("Transactions") else { return title }
    return "\(title) over the past year, across \(transactions) charges."
  }

  static func netWorthMilestone(title: String, facts: FactLookup) -> String {
    guard let milestone = facts.value("Milestone"), let current = facts.value("Net worth")
    else { return title }
    return "Your net worth just passed \(milestone) and now sits at \(current)."
  }

  static func investmentConcentrationRisk(title: String, facts: FactLookup) -> String {
    guard let holding = facts.value("Holding"), let share = facts.value("Share of portfolio"),
      let value = facts.value("Value")
    else { return title }
    return "\(holding) now makes up \(share) of your investments, worth \(value)."
  }

  static func topPerformer(title: String, facts: FactLookup) -> String {
    guard let holding = facts.value("Holding"), let ret = facts.value("Return"),
      let gain = facts.value("Gain/loss"), let invested = facts.value("Invested")
    else { return title }
    return "\(holding) is your strongest holding, up \(ret) for a \(gain) gain on \(invested) invested."
  }

  static func bottomPerformer(title: String, facts: FactLookup) -> String {
    guard let holding = facts.value("Holding"), let ret = facts.value("Return"),
      let gain = facts.value("Gain/loss"), let invested = facts.value("Invested")
    else { return title }
    return "\(holding) is lagging — \(ret) on \(invested) invested, a \(gain) change."
  }

  static func capitalGainsHarvest(title: String, facts: FactLookup) -> String {
    guard let offset = facts.value("Potential offset"), let positions = facts.value("Loss positions")
    else { return title }
    return "You could offset \(offset) of realised gains against unrealised losses in \(positions)."
  }
```

**Commit:** `feat(insights): savings & investment fallback descriptions`

---

### Task 8: H. Income analysis

**Tests to append:**

```swift
  @Test
  func paycheckTimingPatternReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .paycheckTimingPattern, title: "Next pay around Jun 30",
      facts: [InsightFact("Source", "Acme Corp"), InsightFact("Typical amount", "$3,500.00"),
        InsightFact("Cadence", "fortnightly"), InsightFact("Next expected", "Jun 30")])
    #expect(text == "Your next Acme Corp paycheck of about $3,500.00 should land around Jun 30.")
  }

  @Test
  func incomeStabilityScoreReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .incomeStabilityScore, title: "Your income is very steady",
      facts: [InsightFact("Source", "Acme Corp"), InsightFact("Stability", "94 /100"),
        InsightFact("Variation", "6%")])
    #expect(text == "Your income is very steady — it varies by about 6% month to month.")
  }

  @Test
  func missingPaycheckAlertReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .missingPaycheckAlert, title: "Expected pay hasn't arrived",
      facts: [InsightFact("Source", "Acme Corp"), InsightFact("Expected", "Jun 15"),
        InsightFact("Days overdue", "5"), InsightFact("Typical amount", "$3,500.00")])
    #expect(
      text == "Your Acme Corp paycheck of around $3,500.00 was expected Jun 15 and is 5 days late.")
  }

  @Test
  func windfallIncomeReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .windfallIncome, title: "Larger-than-usual deposit",
      facts: [InsightFact("Source", "Acme Corp"), InsightFact("Amount", "$5,000.00"),
        InsightFact("Typical income", "$3,500.00")])
    #expect(text == "You received $5,000.00 from Acme Corp — well above your typical $3,500.00.")
  }

  @Test
  func payRateChangeUpReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .payRateChange, title: "Your pay went up",
      facts: [InsightFact("Source", "Acme Corp"), InsightFact("New amount", "$4,000.00"),
        InsightFact("Previous", "$3,500.00"), InsightFact("Change", "+14%")])
    #expect(text == "Your Acme Corp pay rose to $4,000.00 from $3,500.00.")
  }

  @Test
  func payRateChangeDownReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .payRateChange, title: "Your pay dropped",
      facts: [InsightFact("Source", "Acme Corp"), InsightFact("New amount", "$3,000.00"),
        InsightFact("Previous", "$3,500.00"), InsightFact("Change", "−14%")])
    #expect(text == "Your Acme Corp pay dropped to $3,000.00 from $3,500.00.")
  }
```

**Arm bodies:**

```swift
  static func paycheckTimingPattern(title: String, facts: FactLookup) -> String {
    guard let source = facts.value("Source"), let amount = facts.value("Typical amount"),
      let next = facts.value("Next expected")
    else { return title }
    return "Your next \(source) paycheck of about \(amount) should land around \(next)."
  }

  static func incomeStabilityScore(title: String, facts: FactLookup) -> String {
    guard let variation = facts.value("Variation") else { return title }
    return "\(title) — it varies by about \(variation) month to month."
  }

  static func missingPaycheckAlert(title: String, facts: FactLookup) -> String {
    guard let source = facts.value("Source"), let amount = facts.value("Typical amount"),
      let expected = facts.value("Expected"), let overdue = facts.value("Days overdue")
    else { return title }
    return "Your \(source) paycheck of around \(amount) was expected \(expected) and is \(overdue) days late."
  }

  static func windfallIncome(title: String, facts: FactLookup) -> String {
    guard let amount = facts.value("Amount"), let source = facts.value("Source"),
      let typical = facts.value("Typical income")
    else { return title }
    return "You received \(amount) from \(source) — well above your typical \(typical)."
  }

  static func payRateChange(title: String, facts: FactLookup) -> String {
    guard let source = facts.value("Source"), let newAmount = facts.value("New amount"),
      let previous = facts.value("Previous"), let change = facts.value("Change")
    else { return title }
    let verb = changeIsIncrease(change) ? "rose" : "dropped"
    return "Your \(source) pay \(verb) to \(newAmount) from \(previous)."
  }
```

**Commit:** `feat(insights): income fallback descriptions`

---

### Task 9: K. Structure + L. Data quality + M. Coverage

**Tests to append:**

```swift
  @Test
  func groupSpendConcentrationReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .groupSpendConcentration, title: "Most spending runs through Daily Spending",
      facts: [InsightFact("Group", "Daily Spending"), InsightFact("Share of spend", "65%"),
        InsightFact("Spent", "$3,250.00")])
    #expect(text == "65% of your spending — $3,250.00 — runs through Daily Spending.")
  }

  @Test
  func uncategorizedBacklogReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .uncategorizedBacklog, title: "23 transactions need a category",
      facts: [InsightFact("Uncategorized", "23")])
    #expect(text == "You've got 23 transactions waiting for a category.")
  }

  @Test
  func unreconciledTransfersReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .unreconciledTransfers, title: "4 transfers to review and merge",
      facts: [InsightFact("Pending transfers", "4")])
    #expect(text == "There are 4 possible transfers to review and merge.")
  }

  @Test
  func lapsedMerchantReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .lapsedMerchant, title: "No recent payments to Corner Cafe",
      facts: [InsightFact("Merchant", "Corner Cafe"), InsightFact("Days since last", "90")])
    #expect(text == "You haven't paid Corner Cafe in 90 days.")
  }

  @Test
  func weekendSpendSkewReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .weekendSpendSkew, title: "Weekends are your big spend days",
      facts: [InsightFact("Avg weekend day", "$150.00"), InsightFact("Avg weekday", "$60.00"),
        InsightFact("Ratio", "2.5×")])
    #expect(
      text == "You spend more on weekends — about $150.00 a weekend day versus $60.00 on weekdays.")
  }

  @Test
  func unbudgetedCategoryReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .unbudgetedCategory, title: "Dining has no budget",
      facts: [InsightFact("Category", "Dining"), InsightFact("Spent (90d)", "$540.00")])
    #expect(text == "Dining has no budget yet — you've spent $540.00 there recently.")
  }
```

**Arm bodies:**

```swift
  static func groupSpendConcentration(title: String, facts: FactLookup) -> String {
    guard let share = facts.value("Share of spend"), let spent = facts.value("Spent"),
      let group = facts.value("Group")
    else { return title }
    return "\(share) of your spending — \(spent) — runs through \(group)."
  }

  static func uncategorizedBacklog(title: String, facts: FactLookup) -> String {
    guard let count = facts.value("Uncategorized") else { return title }
    return "You've got \(count) transactions waiting for a category."
  }

  static func unreconciledTransfers(title: String, facts: FactLookup) -> String {
    guard let count = facts.value("Pending transfers") else { return title }
    return "There are \(count) possible transfers to review and merge."
  }

  static func lapsedMerchant(title: String, facts: FactLookup) -> String {
    guard let merchant = facts.value("Merchant"), let days = facts.value("Days since last")
    else { return title }
    return "You haven't paid \(merchant) in \(days) days."
  }

  static func weekendSpendSkew(title: String, facts: FactLookup) -> String {
    guard let weekend = facts.value("Avg weekend day"), let weekday = facts.value("Avg weekday")
    else { return title }
    return "You spend more on weekends — about \(weekend) a weekend day versus \(weekday) on weekdays."
  }

  static func unbudgetedCategory(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let spent = facts.value(prefix: "Spent")
    else { return title }
    return "\(category) has no budget yet — you've spent \(spent) there recently."
  }
```

**Commit:** `feat(insights): structure, data-quality & coverage fallback descriptions`

---

## Task 10: Strengthen the TemplateNarrator end-to-end test + full suite

Now that arms are implemented, prove the narrator path composes (not just the composer in isolation), and run the whole insight test surface on both platforms.

**Files:**
- Modify: `MoolahTests/Domain/Insights/TemplateNarratorTests.swift`

- [ ] **Step 1: Update the narrator test to expect a composed sentence**

Replace the Task-1 placeholder test with one whose facts match the implemented `categorySpendingAnomaly` arm:

```swift
  @Test
  func singleInsightComposesFromFacts() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.singleInsight(
      kind: .categorySpendingAnomaly,
      title: "Dining up 56% in June",
      facts: [
        InsightFact("Category", "Dining"), InsightFact("This month", "$640.00"),
        InsightFact("Expected", "$410.00"), InsightFact("Over by", "56%"),
      ])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    #expect(
      text == "Your Dining spending hit $640.00 this month — about 56% above your usual $410.00.")
  }
```

- [ ] **Step 2: Run the narrator + composer suites**

```bash
just test-mac TemplateNarratorTests InsightDescriptionComposerTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt || echo "clean"
```
Expected: PASS.

- [ ] **Step 3: Run the full suite on both platforms**

```bash
just test 2>&1 | tee .agent-tmp/test-full.txt
grep -i 'failed\|error:' .agent-tmp/test-full.txt || echo "clean"
```
Expected: PASS on `MoolahTests_iOS` and `MoolahTests_macOS`. (No behaviour changed for the AI path or any other feature, so only the insight narration tests are affected.)

- [ ] **Step 4: Format check**

```bash
just format-check 2>&1 | tee .agent-tmp/format.txt
```
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit
```
Message: `test(insights): narrator composes fallback sentence end-to-end`

- [ ] **Step 6: Clean up temp files**

```bash
rm -f .agent-tmp/test-output.txt .agent-tmp/test-full.txt .agent-tmp/format.txt
```

---

## Task 11: Review & ship

- [ ] **Step 1: Code review** — run `@agent-code-review` (and `@agent-help-review` for the user-facing copy / brand voice) over the new composer and tests; apply all findings (Critical/Important/Minor) per project policy.
- [ ] **Step 2: Open the PR** — push the `insight-fallback-descriptions` branch and `gh pr create`. PR body should note: this upgrades only the deterministic fallback (AI remains default when available); the AI prompt and provenance guard are untouched; 37 kinds covered.
- [ ] **Step 3: Land via the `landing-prs` skill** (auto-merge), per project workflow.

---

## Self-Review

**Spec coverage:**
- Centralized composer switching on kind → Tasks 1–9. ✓
- `kind` threaded into `NarrationRequest`, AI path unchanged → Task 1 (steps 3–4). ✓
- `TemplateNarrator` delegates → Task 1 (step 6) + Task 10. ✓
- Fact-access helpers (exact + prefix), degradation to title → Task 1 (`FactLookup`, `everyKindDegradesToTitleWithoutFacts`); used by `unusualDaySpend` (dynamic `Typical <Day>`) and `unbudgetedCategory` (prefix `Spent`). ✓
- Title-as-lead → `earmarkBurndownProjection`, `earmarkUnderspend`, `savingsGoalETA`, `feeSpend`, `incomeStabilityScore`. ✓
- Variant/direction branching → `monthOverMonthDelta`, `categoryMixShift`, `payRateChange` (signed Change); `savingsRateTrend` (Direction); `savingsGoalETA` (fact-presence); `categoryTrendRising`/`Falling` (distinct cases). ✓
- All 37 kinds have a draft sentence in the design and an arm + test here. ✓
- Statistical facts omitted (p-value, Stability /100, occurrence/months counts) — none referenced by any arm. ✓
- Testing: per-kind tests, degradation test, coverage-over-`allCases`, narrator end-to-end, full suite → Tasks 1–10. ✓

**Placeholder scan:** No TBD/TODO; every step has concrete code or an exact command. ✓

**Type consistency:** `compose(kind:title:facts:)`, `FactLookup.value(_:)`/`value(prefix:)`, `changeIsIncrease(_:)`, `unsigned(_:)`, and `NarrationRequest.singleInsight(kind:title:facts:)` are used identically across all tasks. Arm-func names in the Task-1 switch match the bodies filled in Tasks 2–9. ✓
