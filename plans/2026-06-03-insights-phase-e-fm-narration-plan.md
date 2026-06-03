# Insights Phase E — Foundation Models narration polish (gated, additive)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the first Foundation Models touchpoint to the app — a narration layer *on top of* the deterministic insights that already ship. Two user-visible surfaces: (1) a per-insight **"Why?"** explanation in the For You card (#32), and (2) an opt-in **weekly recap** narrative (#33). Plus the reusable **availability-gating + narrator infrastructure** every later FM feature (Phase F assistant) will build on. Strictly additive: on devices without Apple Intelligence, **nothing changes** beyond what Phase C already renders.

**Refs:** epic #1030, design `plans/2026-04-18-on-device-ai-design.md` (Use Case 2, items 32–33; §"Availability gating"; §"Where LLM Is Load-Bearing vs Cosmetic"; §"Privacy"), integration roadmap `plans/2026-06-01-insights-integration-plan.md` (Phase E). Builds directly on Phases A–C (`Domain/Insights/`, `Features/Insights/InsightStore.swift`, `Features/Insights/Views/ForYouCard.swift`). **Out of scope:** Phase D persistence (#1034, in flight separately) and Phase F conversational assistant (#1035-to-be).

**Tech Stack:** SwiftUI, `FoundationModels` (`SystemLanguageModel`, `LanguageModelSession`), Swift Testing (`@Test`/`#expect`), XCUITest (`MoolahUITests_macOS`), `@AppStorage` over `UserDefaults.moolahShared`, `just` build/test/format targets. Deployment target is **iOS 26.0 / macOS 26.0** (`project.yml`) — the `FoundationModels` framework is available at compile time on every supported OS, so **no `if #available` / `@available` guard is needed**; gating is purely the *runtime* `SystemLanguageModel.default.availability` check.

---

## Design & key decisions

These are the decisions baked into the tasks below. Read them before implementing — several resolve apparent tensions in the source docs.

1. **Zero-hallucination seam is `insight.facts`, nothing else.** The narrator's prompt is built **only** from `insight.title` + the pre-formatted `[InsightFact]` (label/value strings the detectors already localised) — never raw transactions, never `monetaryImpact` re-derived, never `detail`. This honours the design's Privacy rule ("Foundation Models never receives raw transactions … only pre-aggregated statistics") and the architectural contract ("every number the LLM may print is in `facts`"). A **numeric-provenance guard** (Task E2.3) rejects any generated text containing a number not present verbatim in the supplied facts, falling back to the template — defence in depth against model drift.

2. **Both new affordances are FM-availability-gated.** The issue's binding constraint is *"ships nothing to ineligible devices beyond what Phase C already shows."* So the **"Why?" button** and the **weekly-recap surface** appear **only** when `availability == .available`. On ineligible devices the user sees exactly today's For You card (the template `detail` + facts already render in the expanded row). The "template fallback" referenced for the weekly recap (#33) is therefore a **resilience** path — used when the model is *available but a generation call fails mid-flight* (e.g. transient `.modelNotReady`, guardrail trip) — not a reason to render the recap on hardware that lacks the model.

3. **Per-insight narration is lazy (on tap); weekly recap is eager-but-rare (once per week, on open).** "Why?" narrates only the insight the user asked about (design #32 — "user taps why?"), cached per insight id for the session. The recap narrates the top 3–5 ranked insights once, the first time the surface opens in a given ISO week (design — "rendered on Monday open of the week after"), gated behind an opt-in toggle.

4. **Streaming for perceived latency.** A ~3B on-device model is not instant. Both surfaces stream partial output (`LanguageModelSession.streamResponse`) into a published `NarrationState` (`.idle` / `.streaming(String)` / `.done(String)` / `.fellBackToTemplate`). The store structure also supports a non-streaming first cut (`respond(to:)`) if streaming proves fiddly — see Task E3.2's note.

5. **Two narrow protocol seams, fakeable in CI.** `ModelAvailabilityProviding` and `InsightNarrating` are protocols injected into the stores (mirroring the existing optional `InstrumentChangeObserving` seam). The real `FoundationModels`-backed implementations are **not exercised in CI** (no model on CI hardware, non-deterministic output). CI tests inject fakes; the real path is covered by a prompt-builder unit test, the provenance-guard unit test, and a **manual on-device verification** task (honest about the gap — see Task E3.6 / E4.6).

6. **Settings: a new "Insights" section, two global toggles.** "Use Apple Intelligence to explain insights" (master kill-switch for FM narration; default **on**, row hidden entirely when device-ineligible) and "Show a weekly recap" (opt-in; default **off**). Stored as `@AppStorage` in `UserDefaults.moolahShared` (app-global, matching `showHiddenAccounts`). The recap's once-per-week bookkeeping is **per-profile** (keyed by profile id) since each profile has its own data.

7. **No `@Generable`.** Narration is free prose; plain `respond`/`streamResponse` returning `String` is correct. `@Generable`/`@Guide` are for Phase F's structured tool-calling, not here.

---

## ⚠️ Verify-before-code: FoundationModels API

The exact `FoundationModels` symbol names below are written from the WWDC25 API shape and **must be confirmed against the installed SDK before writing each FM-backed file.** Use `mcp__xcode__DocumentationSearch` (query `SystemLanguageModel`, `LanguageModelSession`, `streamResponse`) and/or option-click in Xcode. Treat the names as a sketch:

- `import FoundationModels`
- `SystemLanguageModel.default.availability` → an enum `.available` | `.unavailable(_:)` whose associated `UnavailableReason` has cases `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady` (confirm spelling; handle `@unknown default`).
- `LanguageModelSession(instructions:)` — create with a system-prompt string (the "only narrate the supplied numbers" instruction). Sessions are **stateful and not `Sendable`** — create one **per request**, off the main actor; do not store/share across requests in v1.
- `try await session.respond(to: prompt)` → response whose `.content` is `String`. Confirm the property name.
- `session.streamResponse(to: prompt)` → an `AsyncSequence` yielding **cumulative** snapshots; the final element is the complete content. Confirm whether elements are `String` or a wrapper with `.content`.
- `GenerationOptions(sampling:, temperature:)` — pass low/greedy sampling for determinism. Confirm initialiser.
- Generation errors live on `LanguageModelSession` (e.g. context-window-exceeded, guardrail). Catch broadly and fall back to template (decision 2).

If any name differs, adapt the call sites — the **protocol seams** (`ModelAvailabilityProviding`, `InsightNarrating`) keep the divergence contained to two implementation files.

---

## Conventions for every task

- Run builds/tests/format **only** via `just` (never raw `xcodebuild`/`swift test`/`swift-format`), and use `just -d <path>` / `git -C <path>` — never `cd && …` (memory `feedback_no_cd_for_any_tool`).
- Capture test output to `.agent-tmp/` (gitignored): `mkdir -p .agent-tmp && just test-mac <Filter> 2>&1 | tee .agent-tmp/out.txt`.
- After **every** task that changes Swift: `just format` then **`just format-check`** and **read the full output** — `… | tail` masks SwiftLint errors (memory `reference_swiftformat_swiftlint_private_extension`, `feedback_format_check_per_plan_step`). Never add a SwiftLint baseline/disable; fix the code (memory `feedback_swiftlint_fix_not_baseline`).
- Use plain `extension Foo { private func … }`, never `private extension Foo` (memory `reference_swiftformat_swiftlint_private_extension`).
- One primary type per file; conform via a separate `extension`, don't inline conformances (memory `project_instrument_registry_ui_plan_quirks`).
- Project uses **Swift Testing** (`@Test`/`#expect`/`@Suite`), not XCTest, for unit tests.
- After each task: run the relevant review agent(s) and apply **all** findings (memory `feedback_apply_all_review_findings`) — `concurrency-review` for any store/async change, `code-review` for logic, `ui-review` for views, `help-review` for any user-facing copy, `ui-test-review` for UI tests.
- Commit after each task referencing the sub-phase issue (numbers assigned when the four sub-issues are filed — see "Issue breakdown" at the end).

---

## Architecture overview

```
                       ┌──────────────────────────────────────────┐
                       │ ModelAvailabilityProviding (protocol seam) │  ── E1
                       │  └ SystemLanguageModelAvailability (FM)     │
                       │  └ FixedModelAvailability (tests/preview)   │
                       └──────────────────────────────────────────┘
                                        │ availability
                       ┌──────────────────────────────────────────┐
                       │ InsightNarrating (protocol seam)           │  ── E2
                       │  └ FoundationModelsNarrator (FM, streaming) │
                       │  └ TemplateNarrator (fallback / tests)      │
                       │  + NarrationPromptBuilder (pure, CI-tested) │
                       │  + NumericProvenanceGuard (pure, CI-tested) │
                       └──────────────────────────────────────────┘
                            │                              │
              ┌─────────────┴─────────┐        ┌───────────┴──────────────┐
              │ InsightStore           │ ── E3  │ WeeklyRecapStore          │ ── E4
              │  + narration cache      │        │  + once-per-week gate     │
              │  + narrate(_:)          │        │  + opt-in read            │
              │  publishes NarrationState│        │  publishes recap state    │
              └─────────────┬──────────┘        └───────────┬──────────────┘
                            │                                │
              ForYouCard "Why?" affordance        WeeklyRecapCard / sheet  ── E3/E4 views
                            │                                │
                        InsightsSettingsSection (two toggles) ──────────────  E1
```

Four independently-landable sub-phases / PRs: **E1** (infra, no surface) → **E2** (narrator, no surface) → **E3** ("Why?" surface) → **E4** (weekly recap surface). E3 and E4 both depend on E1+E2; E4 is independent of E3.

---

## File structure

**New (E1 — availability infra):**
- `Domain/Insights/Narration/ModelAvailability.swift` — pure domain enum + `ModelAvailabilityProviding` protocol.
- `Features/Insights/Narration/SystemLanguageModelAvailability.swift` — `FoundationModels`-backed impl (gated; the only place `SystemLanguageModel` is touched).
- `MoolahTests/Domain/Insights/ModelAvailabilityTests.swift` — maps each `availability` case → domain enum (via a fake).
- `Features/Settings/InsightsSettingsSection.swift` — the two toggles (reusable `View` embedded by both platform Settings layouts).

**New (E2 — narrator):**
- `Domain/Insights/Narration/NarrationRequest.swift` — `Sendable` value: title + `[InsightFact]` + a `kind` discriminator (per-insight vs recap), the only thing handed to a narrator.
- `Domain/Insights/Narration/InsightNarrating.swift` — protocol (`func narrate(_:) -> AsyncThrowingStream<String, Error>` or `func narrate(_:) async throws -> String`; see Task E2.2).
- `Domain/Insights/Narration/NarrationPromptBuilder.swift` — pure: `NarrationRequest → (instructions: String, prompt: String)`.
- `Domain/Insights/Narration/NumericProvenanceGuard.swift` — pure: `(generated: String, facts: [InsightFact]) -> Bool`.
- `Domain/Insights/Narration/TemplateNarrator.swift` — fallback impl (composes facts into a sentence; no model). Doubles as the CI fake.
- `Features/Insights/Narration/FoundationModelsNarrator.swift` — `FoundationModels`-backed streaming impl, applies the guard, throws `NarrationError.fellBack` on guard failure / generation error.
- `MoolahTests/Domain/Insights/NarrationPromptBuilderTests.swift`, `NumericProvenanceGuardTests.swift`, `TemplateNarratorTests.swift`.

**New (E3 — "Why?" surface):**
- `MoolahTests/Features/Insights/InsightStoreNarrationTests.swift` — narration cache + fake-narrator behaviour.
- `MoolahUITests_macOS/Tests/ForYou/ForYouNarrationUITests.swift` + a `whyButton`/`narrationText` extension to the existing `ForYouScreen` driver.

**New (E4 — weekly recap):**
- `Features/Insights/WeeklyRecapStore.swift` — `@MainActor @Observable`; once-per-week gate, opt-in read, recap narration.
- `Features/Insights/Views/WeeklyRecapCard.swift` (or sheet) — presentational recap surface + `#Preview`.
- `Domain/Insights/Narration/WeeklyRecapWindow.swift` — pure ISO-week "should show this week?" calculation (testable without a clock).
- `MoolahTests/Features/Insights/WeeklyRecapStoreTests.swift`, `MoolahTests/Domain/Insights/WeeklyRecapWindowTests.swift`.
- `MoolahUITests_macOS/Tests/ForYou/WeeklyRecapUITests.swift` + screen driver.

**Modified:**
- `Features/Insights/InsightStore.swift` — inject `availability` + `narrator`; add `narration: [String: NarrationState]`, `narrate(_:)`, `cancelNarration(_:)`; expose `availability` for the view to gate the button. (E3)
- `Features/Insights/Views/ForYouCard.swift` — "Why?" button in `expandedContent` (only when available), render `NarrationState`. (E3)
- `Features/Analysis/Views/AnalysisView.swift` — present the weekly-recap surface (gated) alongside the existing `refreshIfStale` wiring. (E4)
- `App/ProfileSession.swift` / `App/ProfileSession+Factories.swift` — construct `availability` + `narrator`, pass into `InsightStore`; construct `WeeklyRecapStore` in `finishInit`. (E1/E3/E4)
- `Features/Settings/SettingsView+macOS.swift` / `SettingsView+iOS.swift` — embed `InsightsSettingsSection`. (E1)
- `App/UITestSeedInsightOverrides.swift` + `UITestSupport/UITestIdentifiers+ForYou.swift` — fixtures/identifiers for the narration + recap UI tests; a fake-narrator + fixed-availability seam for UI determinism. (E3/E4)

---

# Sub-phase E1 — Availability-gating infrastructure + Settings

No user-visible behaviour change yet (the Settings section ships, but with no surface consuming the toggles until E3/E4). Pure foundation.

## Task E1.1: `ModelAvailability` domain enum + protocol (pure, TDD)

**Files:** create `Domain/Insights/Narration/ModelAvailability.swift`; test `MoolahTests/Domain/Insights/ModelAvailabilityTests.swift`.

- [ ] **Step 1 — failing test.** A `FixedModelAvailability` test double conforming to `ModelAvailabilityProviding` returns a fixed `ModelAvailability`; assert the four meaningful cases round-trip and `isUsable` is true only for `.available`.

```swift
import Testing
@testable import Moolah

@Suite("ModelAvailability")
struct ModelAvailabilityTests {
  @Test func onlyAvailableIsUsable() {
    #expect(ModelAvailability.available.isUsable)
    #expect(!ModelAvailability.unavailable(.deviceNotEligible).isUsable)
    #expect(!ModelAvailability.unavailable(.appleIntelligenceNotEnabled).isUsable)
    #expect(!ModelAvailability.unavailable(.modelNotReady).isUsable)
  }

  @Test func modelNotReadyIsTransient() {
    #expect(ModelAvailability.unavailable(.modelNotReady).isTransient)
    #expect(!ModelAvailability.unavailable(.deviceNotEligible).isTransient)
  }
}
```

- [ ] **Step 2 — implement.** A domain enum decoupled from `FoundationModels` (so Domain has no framework dependency and tests need no model):

```swift
import Foundation

/// Device/runtime eligibility for the on-device language model, mapped off
/// `SystemLanguageModel.default.availability` by the Features-layer adapter so
/// the Domain layer carries no `FoundationModels` dependency. Every Foundation
/// Models touchpoint gates on this (design §"Availability gating").
enum ModelAvailability: Sendable, Hashable {
  case available
  case unavailable(Reason)

  enum Reason: Sendable, Hashable {
    /// Hardware lacks Apple Intelligence — permanently hide LLM affordances.
    case deviceNotEligible
    /// Eligible but the user hasn't turned Apple Intelligence on — a one-time
    /// nudge to Settings is allowed, then hide.
    case appleIntelligenceNotEnabled
    /// Transient (model downloading / warming) — retry later, never disable.
    case modelNotReady
    /// `@unknown default` from the framework — treat as unavailable.
    case unknown
  }

  /// True only when narration may run.
  var isUsable: Bool { if case .available = self { return true } else { return false } }

  /// True when re-checking later might flip to `.available`.
  var isTransient: Bool {
    if case .unavailable(.modelNotReady) = self { return true }
    return false
  }
}

/// Narrow seam onto model eligibility, mirroring `InstrumentChangeObserving`.
/// Injected into stores so tests/previews supply a fixed value and never reach
/// for a real model.
protocol ModelAvailabilityProviding: Sendable {
  /// Current eligibility. Cheap to call; implementations may re-read each time
  /// so a transient `.modelNotReady → .available` flip is observed on refresh.
  @MainActor func current() -> ModelAvailability
}

#if DEBUG
  /// Test/preview double.
  struct FixedModelAvailability: ModelAvailabilityProviding {
    let value: ModelAvailability
    @MainActor func current() -> ModelAvailability { value }
  }
#endif
```

- [ ] **Step 3 — run** `just test-mac ModelAvailabilityTests` → green. **format-check. commit.**

## Task E1.2: `SystemLanguageModelAvailability` (FoundationModels adapter)

**Files:** create `Features/Insights/Narration/SystemLanguageModelAvailability.swift`.

> ⚠️ Confirm the `availability` enum shape first (see Verify-before-code). Not unit-tested in CI (no model); the mapping is trivial and exercised manually in E3.6.

- [ ] **Step 1 — implement the adapter.** The single file in the app that imports `FoundationModels` for availability:

```swift
import FoundationModels

/// Maps the live `SystemLanguageModel.default.availability` onto the domain
/// `ModelAvailability`. The only production reader of the framework's
/// availability API; everything downstream consumes the domain enum.
struct SystemLanguageModelAvailability: ModelAvailabilityProviding {
  @MainActor func current() -> ModelAvailability {
    switch SystemLanguageModel.default.availability {
    case .available:
      return .available
    case .unavailable(.deviceNotEligible):
      return .unavailable(.deviceNotEligible)
    case .unavailable(.appleIntelligenceNotEnabled):
      return .unavailable(.appleIntelligenceNotEnabled)
    case .unavailable(.modelNotReady):
      return .unavailable(.modelNotReady)
    @unknown default:
      return .unavailable(.unknown)
    }
  }
}
```

- [ ] **Step 2 — build** `just build-mac` → success. (No test; mapping verified on device in E3.6.) **format-check. commit.**

## Task E1.3: Insights Settings section (two toggles)

**Files:** create `Features/Settings/InsightsSettingsSection.swift`; modify `Features/Settings/SettingsView+macOS.swift` + `SettingsView+iOS.swift` to embed it.

> Copy is user-facing → run `help-review` (memory: help/brand voice). Keys are app-global `@AppStorage` over `UserDefaults.moolahShared` (matches `showHiddenAccounts` in `SidebarView`).

- [ ] **Step 1 — the section view.** Takes the current availability so it can hide the FM toggle on ineligible hardware (decision 6):

```swift
import SwiftUI

/// Settings controls for the personalized-insights narration layer. The
/// Apple-Intelligence toggle is hidden outright on ineligible devices so the
/// feature is invisible where it can never run (issue #1030 Phase E: "ships
/// nothing to ineligible devices"). The recap toggle is opt-in (default off).
struct InsightsSettingsSection: View {
  let availability: ModelAvailability

  @AppStorage("insightsNarrationEnabled") private var narrationEnabled = true
  @AppStorage("weeklyRecapEnabled") private var recapEnabled = false

  var body: some View {
    Section("Insights") {
      if availability.isUsable {
        Toggle("Explain insights with Apple Intelligence", isOn: $narrationEnabled)
        Toggle("Show a weekly recap", isOn: $recapEnabled)
          .disabled(!narrationEnabled)
      }
      // When unavailable, render nothing — the section collapses to empty and
      // the platform layouts omit it (see Step 2's `if` wrapper).
    }
  }
}
```

> Decide with `ui-review`/`help-review` whether to keep the `Section` header visible when both rows are hidden; the cleaner outcome is for the **embedding layout** (Step 2) to wrap the whole section in `if availability.isUsable`. Prefer that — move the `if` up and drop the in-body branch.

- [ ] **Step 2 — embed.** In `SettingsView+macOS.swift` and `SettingsView+iOS.swift`, add the section to the app-preferences area (these files currently host the profile-management layout; find the `Form`/`TabView`/`List` the general toggles belong in — there may be no general-preferences tab yet, in which case add one labelled "General"/"Insights" following the existing `CryptoSettingsView` precedent for a dedicated settings sub-view). Read both files first and match their structure. Pass availability from a `@State`/computed `SystemLanguageModelAvailability().current()` (recompute on `.task`).

- [ ] **Step 3 — build, `ui-review` + `help-review`,** apply findings, **format-check, commit.**

## Task E1.4: Wire availability into `ProfileSession` → `InsightStore` init

**Files:** `App/ProfileSession.swift`, `App/ProfileSession+Factories.swift`, `Features/Insights/InsightStore.swift` (init only).

- [ ] **Step 1 — add an optional `availability` parameter to `InsightStore.init`** (default `nil`, like `instrumentChanges`), stored but not yet consumed (consumed in E3). Add `narrator` in E2/E3 — keep this task availability-only to stay small.

```swift
  init(
    sources: InsightStoreSources,
    backend: any BackendProvider,
    profile: Profile,
    instrumentChanges: (any InstrumentChangeObserving)? = nil,
    availability: (any ModelAvailabilityProviding)? = nil,   // NEW
    fixtureInsights: InsightFixtures? = nil
  ) {
    …
    self.availability = availability ?? FixedModelAvailability(value: .unavailable(.deviceNotEligible))
```

> Default to **ineligible** when no provider is injected (previews/tests) so no surface lights up by accident. Production injects the real one.

- [ ] **Step 2 — in `finishInit`** pass `availability: SystemLanguageModelAvailability()` into the existing `InsightStore(...)` construction.
- [ ] **Step 3 — `concurrency-review`** on `InsightStore.swift` (init touched), apply findings, **format-check, commit.**

**E1 exit / PR:** infra compiles; Settings shows the Insights section on eligible devices only; `InsightStore` holds an availability provider it doesn't yet read. `just test` + `just format-check` green. Open PR, land via `landing-prs` (memory `feedback_prs_to_merge_queue`).

---

# Sub-phase E2 — Narrator (prompt, guard, FM impl, template fallback)

Still no surface. Delivers the narrator the E3/E4 stores call.

## Task E2.1: `NarrationRequest` + `NarrationPromptBuilder` (pure, TDD)

**Files:** create `Domain/Insights/Narration/NarrationRequest.swift`, `NarrationPromptBuilder.swift`; test `NarrationPromptBuilderTests.swift`.

- [ ] **Step 1 — failing test.** Assert the built prompt (a) contains every fact's label **and** value, (b) contains the title, (c) the instructions forbid inventing numbers, (d) **never** contains anything but the supplied facts (no raw amounts beyond them). For the recap variant, the prompt enumerates several insights and asks for a 2-sentence paragraph.

```swift
@Suite("NarrationPromptBuilder")
struct NarrationPromptBuilderTests {
  @Test func perInsightPromptContainsOnlySuppliedFacts() {
    let req = NarrationRequest.singleInsight(
      title: "Dining is up this month",
      facts: [InsightFact("This month", "$640.00"), InsightFact("6-mo median", "$410.00")])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.prompt.contains("$640.00"))
    #expect(built.prompt.contains("6-mo median"))
    #expect(built.instructions.localizedCaseInsensitiveContains("do not invent"))
  }

  @Test func recapPromptListsEachInsightAndAsksForTwoSentences() {
    let req = NarrationRequest.weeklyRecap(items: [
      .init(title: "Net worth crossed $100k", facts: [InsightFact("Now", "$101,200")]),
      .init(title: "Dining up", facts: [InsightFact("This month", "$640.00")]),
    ])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.prompt.contains("Net worth crossed $100k"))
    #expect(built.prompt.contains("$640.00"))
    #expect(built.instructions.localizedCaseInsensitiveContains("two sentences"))
  }
}
```

- [ ] **Step 2 — implement** `NarrationRequest` (a `Sendable` enum: `.singleInsight(title:facts:)` / `.weeklyRecap(items:)` where each item is `(title, facts)`) and the pure `NarrationPromptBuilder.build(_:) -> (instructions: String, prompt: String)`. Instructions encode the discipline: *"You are narrating finance insights. Use ONLY the figures provided verbatim. Do not invent, recompute, or round any number. Write plain, warm, non-judgemental prose."* (align tone with `guides/BRAND_GUIDE.md` — confirm voice). Per-insight → one or two sentences; recap → exactly two sentences over the listed items.
- [ ] **Step 3 — run, green. `code-review` + `help-review`** (the instruction string is brand-voice-adjacent), **format-check, commit.**

## Task E2.2: `InsightNarrating` protocol + `TemplateNarrator` (TDD)

**Files:** create `Domain/Insights/Narration/InsightNarrating.swift`, `TemplateNarrator.swift`; test `TemplateNarratorTests.swift`.

- [ ] **Step 1 — decide the protocol shape.** Recommended (streaming): 

```swift
protocol InsightNarrating: Sendable {
  /// Streams cumulative narration snapshots; the final element is complete.
  /// Throws `NarrationError` on guardrail/generation failure or provenance
  /// rejection — callers fall back to the template.
  func narrate(_ request: NarrationRequest) -> AsyncThrowingStream<String, any Error>
}
```

A non-streaming `func narrate(_:) async throws -> String` is an acceptable first cut; if chosen, E3/E4 publish `.done` directly. Pick streaming unless E3.2 hits friction.

- [ ] **Step 2 — `TemplateNarrator`** composes the facts into a deterministic sentence with **no model** (`"\(title). \(facts.map{ "\($0.label): \($0.value)" }.joined(separator: ", "))."` or nicer). It is the fallback **and** the CI fake. Test: emits a single snapshot equal to the composed string; recap variant composes across items.
- [ ] **Step 3 — green, `code-review`, format-check, commit.**

## Task E2.3: `NumericProvenanceGuard` (pure, TDD)

**Files:** create `Domain/Insights/Narration/NumericProvenanceGuard.swift`; test `NumericProvenanceGuardTests.swift`.

- [ ] **Step 1 — failing test.** Extract every numeric token from the generated text (regex over digit groups incl. decimal/grouping separators and a leading sign); pass iff each appears within the concatenated fact **values**. Cases: clean pass; an invented number `$700` not in facts → fail; sign-flip `+$640` when fact is `−$640` → **fail** (sign matters — memory `feedback_no_abs_on_trade_legs`, never silently re-sign); a non-monetary integer like "this month" containing no digits → pass; percentage `40%` present in facts → pass.

```swift
@Suite("NumericProvenanceGuard")
struct NumericProvenanceGuardTests {
  private let facts = [InsightFact("This month", "$640.00"), InsightFact("Median", "$410.00")]

  @Test func passesWhenEveryNumberIsSourced() {
    #expect(NumericProvenanceGuard.isGrounded("Dining hit $640.00, above your $410.00 median.", facts: facts))
  }
  @Test func failsOnInventedNumber() {
    #expect(!NumericProvenanceGuard.isGrounded("You spent $700.00 on dining.", facts: facts))
  }
  @Test func failsOnFlippedSign() {
    let signed = [InsightFact("Change", "−$640.00")]
    #expect(!NumericProvenanceGuard.isGrounded("Up +$640.00 this month.", facts: signed))
  }
}
```

> Tokenisation note: normalise away currency symbols and thousands separators consistently on **both** sides before comparing; keep the sign and decimal. Document the normalisation in the file. This is a heuristic safety net, not a parser — err toward rejecting (fall back to template) on ambiguity.

- [ ] **Step 2 — implement, Step 3 — green, `code-review`, format-check, commit.**

## Task E2.4: `FoundationModelsNarrator` (FM streaming impl)

**Files:** create `Features/Insights/Narration/FoundationModelsNarrator.swift`.

> ⚠️ Confirm `LanguageModelSession` / `streamResponse` API first. Not CI-tested.

- [ ] **Step 1 — implement.** Build the prompt via `NarrationPromptBuilder`, create a per-request `LanguageModelSession(instructions:)` **off-main**, stream snapshots, and on completion run `NumericProvenanceGuard`; if it fails (or generation throws), finish the stream with a thrown `NarrationError.fellBack` so the caller swaps in the template. Use low-temperature/greedy `GenerationOptions` for stability across runs.

```swift
import FoundationModels

/// Foundation Models narration over the structured `facts` seam. Streams
/// snapshots; rejects (throws) any completion whose numbers aren't grounded in
/// the supplied facts, so the caller can fall back to the template. The only
/// production path that runs the on-device LLM for insights.
struct FoundationModelsNarrator: InsightNarrating {
  var options: GenerationOptions = .init(sampling: .greedy)  // confirm initialiser

  func narrate(_ request: NarrationRequest) -> AsyncThrowingStream<String, any Error> {
    let built = NarrationPromptBuilder.build(request)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let session = LanguageModelSession(instructions: built.instructions)
          var latest = ""
          for try await snapshot in session.streamResponse(to: built.prompt, options: options) {
            latest = snapshot          // confirm element type (String vs wrapper)
            continuation.yield(latest)
          }
          guard NumericProvenanceGuard.isGrounded(latest, facts: request.allFacts) else {
            continuation.finish(throwing: NarrationError.fellBack); return
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

enum NarrationError: Error { case fellBack }
```

- [ ] **Step 2 — build** `just build-mac` → success. **`concurrency-review`** (off-main session, stream/cancel hygiene), apply findings. **format-check, commit.**

**E2 exit / PR:** narrator stack compiles; prompt-builder, template narrator, and provenance guard are CI-green; the FM impl builds. No surface yet. Land via `landing-prs`.

---

# Sub-phase E3 — Per-insight "Why?" narration in the For You card

First user-visible FM polish. Lazy, on-tap, gated, streaming, template fallback.

## Task E3.1: `InsightStore` narration cache + `narrate(_:)` (store change, TDD)

**Files:** modify `Features/Insights/InsightStore.swift`; test `MoolahTests/Features/Insights/InsightStoreNarrationTests.swift`.

- [ ] **Step 1 — failing tests** with a fake narrator + fixed availability:
  - When availability is `.available`, `narrate(insight)` transitions `narration[id]` `.idle → .streaming(…) → .done(text)` and caches (a second call is a no-op / returns cached).
  - When the fake narrator throws `.fellBack`, state ends `.fellBackToTemplate` and the published text equals the template narrator's output.
  - When availability is **not** usable, `narrate` is a no-op (state stays `.idle`) — the view never offers the button, but defend the store path too.
  - `cancelNarration(id)` tears down the in-flight task and resets to `.idle`.

```swift
@Suite("InsightStore narration")
struct InsightStoreNarrationTests {
  @Test func narrateStreamsThenCaches() async throws {
    let store = makeStore(
      availability: .available,
      narrator: ScriptedNarrator(snapshots: ["Din", "Dining is up."]))
    await store.refresh()                 // fixture insights present
    let insight = try #require(store.insights.first)
    await store.narrate(insight)
    #expect(store.narration[insight.id] == .done("Dining is up."))
  }

  @Test func guardFailureFallsBackToTemplate() async throws {
    let store = makeStore(availability: .available, narrator: ThrowingNarrator())
    await store.refresh()
    let insight = try #require(store.insights.first)
    await store.narrate(insight)
    if case .fellBackToTemplate(let text) = store.narration[insight.id] {
      #expect(!text.isEmpty)
    } else { Issue.record("expected template fallback") }
  }
}
```

- [ ] **Step 2 — implement.** Add `narrator: any InsightNarrating` injected via init (default `TemplateNarrator()`); add `private(set) var narration: [String: NarrationState] = [:]`; the `NarrationState` enum (`.idle`/`.streaming(String)`/`.done(String)`/`.fellBackToTemplate(String)`); a per-id `[String: Task<Void, Never>]` registry. `narrate(_:)` guards `availability.current().isUsable`, builds a `NarrationRequest.singleInsight(title:facts:)` from the insight, consumes the narrator stream on the main actor publishing snapshots, and on `.fellBack`/error composes the `TemplateNarrator` output into `.fellBackToTemplate`. Mirror the existing `nonisolated`/task hygiene patterns and the `deinit`/`stopObserving` teardown for the narration tasks.
- [ ] **Step 3 — green; `concurrency-review` + `code-review`** on `InsightStore.swift`, apply findings; **format-check, commit.**

## Task E3.2: "Why?" affordance in `ForYouCard` (view, TDD-by-preview)

**Files:** modify `Features/Insights/Views/ForYouCard.swift`.

> Iterate visuals via `RenderPreview`, not by relaunching the app (memory `feedback_iterate_via_preview`).

- [ ] **Step 1 — extend `InsightRow`.** Pass the store's `availability` and `narration[insight.id]` + an `onNarrate`/`onCancelNarrate` closure pair (keep the view thin — memory thin-view discipline; the card forwards from `InsightStore`). In `expandedContent`, **below** `detail` and **above** the facts/`View` link, when `availability.isUsable` render a "Why?" button. On tap → `onNarrate`. Render `NarrationState`:
  - `.idle` → the "Why?" button.
  - `.streaming(let partial)` → the partial text + a subtle progress indicator.
  - `.done(let text)` / `.fellBackToTemplate(let text)` → the text (the latter visually identical — the fallback is invisible to the user by design).
  Add accessibility identifiers `UITestIdentifiers.ForYou.whyButton(id)` and `…narrationText(id)`.
- [ ] **Step 2 — update `ForYouCard`** to take `availability:` + `narration:` + the two closures and thread them into each `InsightRow`. Update the `#Preview` fixtures to show one row mid-stream and one done (inject a `FixedModelAvailability(.available)` and a pre-seeded `narration` dict in the preview).
- [ ] **Step 3 — build + `RenderPreview`** (regenerate `Moolah.xcodeproj` via `just generate`, open in Xcode per the worktree-preview caveat). Confirm: button only present when available; streaming renders progressively; fallback indistinguishable from success.
- [ ] **Step 4 — `ui-review`,** apply findings; **format-check, commit.**

## Task E3.3: Wire `ForYouCard` ↔ `InsightStore` narration in `AnalysisView`

**Files:** modify `Features/Analysis/Views/AnalysisView.swift`.

- [ ] **Step 1 — pass the new params** in the existing `ForYouCard(...)` construction (line ~142): `availability: insightStore.availability.current()`, `narration: insightStore.narration`, `onNarrate: { Task { await insightStore.narrate($0) } }`, `onCancelNarrate: { insightStore.cancelNarration($0.id) }`. Keep each a one-liner (thin-view).
- [ ] **Step 2 — build, `code-review`** on `AnalysisView.swift`, apply findings; **format-check, commit.**

## Task E3.4: ProfileSession injects the real narrator

**Files:** `App/ProfileSession.swift` (+ `+Factories.swift`).

- [ ] **Step 1 —** in `finishInit`, pass `narrator:` into `InsightStore(...)`. Production narrator: choose `FoundationModelsNarrator()` **only** when the `insightsNarrationEnabled` `@AppStorage` key is true (read via `UserDefaults.moolahShared.bool(forKey:)`) **and** availability is usable; else `TemplateNarrator()` (which the store still won't surface when unavailable, but keeps the master kill-switch honest). Document the precedence. The availability provider is already wired (E1.4).
- [ ] **Step 2 — build, `concurrency-review`,** apply findings; **format-check, commit.**

## Task E3.5: Narration UI test (deterministic, fake narrator)

**Files:** `MoolahUITests_macOS/Tests/ForYou/ForYouNarrationUITests.swift`; extend `ForYouScreen` driver; extend `App/UITestSeedInsightOverrides.swift` to inject a **fixed-available** availability + a **scripted** narrator for the `.insightsForYouBaseline` seed (so the real model is never invoked in UI tests — determinism).

> **REQUIRED SUB-SKILL:** invoke `writing-ui-tests` before writing the driver/test (screen-driver rule, post-condition waits, no element caching).

- [ ] **Step 1 — extend the seam.** The UI-test seed must force `availability = .available` and a `ScriptedNarrator` that emits a known string, so the test can assert exact narration text without a model. Add a UI-testing init path on `InsightStore` (or extend `uiTestingInsightFixtures()`’s sibling to also supply a narrator + availability) — mirror the existing fixture-injection seam (`fixtureInsights`).
- [ ] **Step 2 — driver + test.** `ForYouScreen.tapWhy(id:)` taps `whyButton(id)` then waits for `narrationText(id)` to exist; `narrationText(id:)` reads it. Test: launch `.insightsForYouBaseline` → expand the large-txn row → `tapWhy` → assert the scripted narration string appears.
- [ ] **Step 3 — run** (pre-empt the runner hang: `pkill` stale `Moolah` test-host/`xctest` first — memory `reference_macos_test_runner_hang`). If the local UI host is wedged, gate on the PR's CI "UI Test" job (memory `feedback_pr_ci_gate_when_ui_host_blocked`). **`ui-test-review`,** apply findings; **format-check, commit.**

## Task E3.6: Manual on-device verification (honest gap)

- [ ] Run the app on this Mac with Apple Intelligence enabled (`run-mac-app-with-logs` skill). Open Analysis → expand an insight → tap "Why?" → confirm real streamed narration appears and contains no numbers absent from the facts (spot-check the provenance guard). Toggle the Settings switch off → confirm the button disappears. **Record the outcome in the PR description** — note explicitly that CI does **not** cover the live-model path (decision 5). If Apple Intelligence can't be enabled on the dev machine, say so and rely on the fake-narrator UI test + manual review by someone who can.

**E3 exit / PR:** "Why?" narration works end-to-end on eligible devices, hidden on ineligible ones; deterministic UI test green; manual device check recorded. Land via `landing-prs`.

---

# Sub-phase E4 — Weekly recap surface (opt-in, once per week)

## Task E4.1: `WeeklyRecapWindow` — once-per-week calculation (pure, TDD)

**Files:** create `Domain/Insights/Narration/WeeklyRecapWindow.swift`; test `WeeklyRecapWindowTests.swift`.

- [ ] **Step 1 — failing test.** `shouldShow(now:lastShown:calendar:) -> Bool`: true when `lastShown` is nil; true when `now` is in a later ISO week-of-year than `lastShown`; false within the same ISO week; respects the calendar's first-weekday (design says "Monday open" — use ISO 8601 week semantics, **not** `Date()` magic — pass `now` in, never call `Date()` inside, so it's testable and resume-safe). Cover a year boundary (week 52 → week 1).

```swift
@Suite("WeeklyRecapWindow")
struct WeeklyRecapWindowTests {
  private let cal = Calendar(identifier: .iso8601)
  @Test func showsWhenNeverShown() {
    #expect(WeeklyRecapWindow.shouldShow(now: .now /*fixed in real test*/, lastShown: nil, calendar: cal))
  }
  // … same-week false, next-week true, year-boundary true (use fixed Dates)
}
```

> Use fixed `Date(timeIntervalSince1970:)` values in the real test — no `Date()` (memory: deterministic seeds; and Workflow/journal `Date()` ban is a general discipline here too).

- [ ] **Step 2 — implement** with `Calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from:)` equality. **Step 3 — green, `code-review`, format-check, commit.**

## Task E4.2: `WeeklyRecapStore` (store, TDD)

**Files:** create `Features/Insights/WeeklyRecapStore.swift`; test `WeeklyRecapStoreTests.swift`.

- [ ] **Step 1 — failing tests** (fake narrator, fixed availability, injected `now`, in-memory "last shown" store):
  - `prepareIfDue` with opt-in **on**, availability `.available`, a fresh week, and ≥1 insight → narrates the top 3–5 into `recap = .ready(text)` and records the shown-week.
  - opt-in **off** → `recap == .hidden`, narrator never called.
  - availability not usable → `.hidden` (decision 2).
  - same week as last shown → `.hidden`.
  - narrator throws → `.ready(templateText)` (resilience fallback — decision 2).
  - `dismiss()` → `.hidden` and does **not** un-record the week (stays gone until next week).
- [ ] **Step 2 — implement.** `@MainActor @Observable final class WeeklyRecapStore`. Deps: the `InsightStore` (to read `insights`), `narrator`, `availability`, an injected `now: () -> Date` (default `Date.init`), profile id, and a `lastShownProvider` abstraction over `UserDefaults.moolahShared` keyed `"weeklyRecapLastShown.\(profileId)"` (inject a fake in tests). `recap: RecapState` (`.hidden`/`.preparing`/`.ready(String)`). `prepareIfDue()` checks opt-in `@AppStorage` value (read via the defaults), availability, `WeeklyRecapWindow.shouldShow`, then builds `NarrationRequest.weeklyRecap(items:)` from the top N insights and consumes the narrator (template fallback on throw). Reuse the off-main / task-hygiene patterns from `InsightStore`.
- [ ] **Step 3 — green; `concurrency-review` + `code-review`,** apply findings; **format-check, commit.**

## Task E4.3: `WeeklyRecapCard` presentational surface (view)

**Files:** create `Features/Insights/Views/WeeklyRecapCard.swift`.

- [ ] **Step 1 — implement** a dismissible card (a banner above the For You card, or a `.sheet` — decide with `ui-review`; a card is lower-friction and matches the existing `ForYouCard` placement). Renders the recap prose, a positive-leaning header ("Your week", per BRAND_GUIDE), and a dismiss control. Accessibility identifiers `UITestIdentifiers.WeeklyRecap.{card,dismiss}`. `#Preview` with a fixed `.ready("…")`.
- [ ] **Step 2 — `RenderPreview`, `ui-review` + `help-review`** (header/empty copy), apply findings; **format-check, commit.**

## Task E4.4: Wire recap into `AnalysisView` + ProfileSession

**Files:** `Features/Analysis/Views/AnalysisView.swift`, `App/ProfileSession.swift` (+ `+Factories.swift`).

- [ ] **Step 1 — construct `WeeklyRecapStore` in `finishInit`** (after `insightStore`, since it depends on it), with the real narrator/availability (same precedence as E3.4) and profile id. Expose it on `ProfileSession` (optional, like `insightStore`).
- [ ] **Step 2 — in `AnalysisView`**, render `WeeklyRecapCard` above `ForYouCard` when `recap` is `.ready`/`.preparing`; drive `await session.weeklyRecapStore?.prepareIfDue()` from the **same** `.task` that already calls `insightStore?.refreshIfStale` (line ~85) — **after** insights are refreshed so the recap reads fresh insights — and from the scene-active `.onChange` branch (line ~108). Keep it a one-liner.
- [ ] **Step 3 — build, `code-review`** (thin-view), apply findings; **format-check, commit.**

## Task E4.5: Recap UI test (deterministic) + E4.6 manual device check

**Files:** `MoolahUITests_macOS/Tests/ForYou/WeeklyRecapUITests.swift` + driver; extend the seed seam.

- [ ] **Step 1 — seed seam.** Add a `.weeklyRecapBaseline` seed (or extend `.insightsForYouBaseline`) that forces opt-in **on**, availability `.available`, a `ScriptedNarrator` recap string, and a `lastShown` provider reporting "never shown" so the recap is due. (`writing-ui-tests` first.)
- [ ] **Step 2 — driver + test:** launch → wait for `WeeklyRecap.card` → assert the scripted recap text → `dismiss` → assert it's gone and (relaunch in same seed week) stays gone. **Step 3 — run** (pkill stale hosts first), `ui-test-review`, apply findings; **format-check, commit.**
- [ ] **E4.6 — manual device check:** on a Mac with Apple Intelligence, toggle "Show a weekly recap" on, relaunch into a fresh week, confirm a real two-sentence recap renders and is grounded in the facts; toggle off → gone. Record in the PR (CI does not cover the live path).

**E4 exit / PR:** opt-in weekly recap renders once per week on eligible devices; deterministic UI test green; manual check recorded. Land via `landing-prs`.

---

## Cross-cutting verification (each PR)

- `just format-check 2>&1 | tee .agent-tmp/fc.txt` → zero diffs, zero SwiftLint violations (read full output, not `| tail`).
- `just test 2>&1 | tee .agent-tmp/test-all.txt` then `grep -i 'failed\|error:'` → none. (Both macOS + iOS suites.)
- Confirm the right review agents ran and findings were applied: `concurrency-review` (every store/narrator change), `code-review` (logic), `ui-review` (every view), `help-review` (every user-facing string: settings labels, recap header, prompt instructions), `ui-test-review` (UI tests), plus `instrument-conversion-review` is **N/A** here (Phase E adds no new conversion — facts arrive pre-converted from Phase A; note this in the PR so the reviewer doesn't expect it).
- PR bodies link issues as markdown (memory `feedback_pr_link_format`) and end with the Claude Code trailer.

---

## Issue breakdown (to file under epic #1030)

Phase E is "not yet broken out" in #1030. File four sub-issues (one per sub-phase / PR), then check the Phase E box on #1030 with links:

- **E1 — FM availability-gating infra + Insights Settings section.** `ModelAvailability` + provider seam, `SystemLanguageModelAvailability`, two Settings toggles, `InsightStore` holds availability.
- **E2 — Insight narrator (prompt builder, provenance guard, template fallback, FM streaming impl).** No surface.
- **E3 — Per-insight "Why?" narration in the For You card.** Lazy, gated, streaming, template fallback; deterministic UI test.
- **E4 — Opt-in weekly recap surface.** Once-per-week gate, recap narration, new card; deterministic UI test.

Each closes its sub-issue and references #1030. Recommended order E1 → E2 → E3 → E4 (E4 independent of E3 once E1+E2 land).

---

## Self-review notes (author)

- **Issue scope coverage:** "Why?" explanation (#32 → E3), weekly-recap narrative (#33 → E4), `SystemLanguageModel.default.availability` gating with template fallback (E1+E2), "ships nothing to ineligible devices" (decision 2 — both surfaces availability-gated, Settings toggle hidden when ineligible). All covered.
- **Architectural contract held:** narrator consumes **only** `insight.facts` (decision 1 + Privacy rule); no raw transactions reach the model; provenance guard + sign-preserving check (E2.3) backstops "never invents numbers" and "never `abs()`"; engine stays pure/synchronous and untouched; FM is strictly additive (no detector or arithmetic moves into the model — design §"Not LLM work").
- **Concurrency:** per-request non-`Sendable` sessions created off-main; streams cancelled on termination/teardown; stores stay `@MainActor @Observable` publishing on the main actor (mirrors `InsightStore`/`EarmarkStore`). Every store/narrator touch gets `concurrency-review`.
- **Testability honesty (decision 5):** prompt builder, provenance guard, template narrator, availability mapping, recap window, and both stores are CI-green via fakes; the live FM path is **explicitly** not in CI and is covered by manual device checks (E3.6/E4.6) recorded in PRs — stated plainly, not hidden.
- **Verify-before-code flagged inline:** FoundationModels symbol names (top callout + each FM file), Settings-layout embedding point, `BRAND_GUIDE` voice for prompt/recap/label copy, `UserDefaults.moolahShared` key precedence for the kill-switch.
- **Cross-task name consistency:** `ModelAvailability`/`ModelAvailabilityProviding`/`FixedModelAvailability`, `InsightNarrating`/`TemplateNarrator`/`FoundationModelsNarrator`, `NarrationRequest`/`NarrationPromptBuilder`/`NumericProvenanceGuard`/`NarrationError.fellBack`, `NarrationState`, `InsightStore.{narration,narrate,cancelNarration,availability}`, `WeeklyRecapStore`/`WeeklyRecapWindow`/`RecapState`, `UITestIdentifiers.ForYou.{whyButton,narrationText}` / `UITestIdentifiers.WeeklyRecap.{card,dismiss}` — used identically across tasks.
- **Out of scope, stated:** Phase D persistence (separate, in flight), Phase F assistant, push notifications, per-category/per-account insight surfaces, `@Generable` structured output.
