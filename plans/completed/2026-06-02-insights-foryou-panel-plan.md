# Insights Phase C — "For You" panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the ranked insights `InsightStore` already publishes as a "For You" card at the top of the Analysis view, with dismiss (remove-now + downrank-kind) and deep-link-to-entity.

**Architecture:** A pure presentational `ForYouCard`/`InsightRow` bound by `AnalysisView` to `session.insightStore`; navigation-target derivation extracted as a unit-tested pure `InsightNavigationTarget`; `InsightStore.dismiss` upgraded to remove the dismissed insight from the published list while keeping the per-kind fatigue signal; a UI-test seed injects fixture insights into the store (bypassing statistical detectors) so the macOS UI test asserts the surface deterministically.

**Tech Stack:** SwiftUI, Swift Testing (`@Test`/`#expect`), XCUITest (`MoolahUITests_macOS`), `just` build/test/format targets.

**Design doc:** `plans/2026-06-02-insights-foryou-panel-design.md`. Refs #1033, epic #1030. Out of scope: Phase D persistence (#1034) — dismissals stay in-memory.

---

## Conventions for every task

- Run builds/tests/format **only** via `just` (never raw `xcodebuild`/`swift test`/`swift-format`), and use `just -d <path>`/`git -C <path>` — never `cd && …`.
- Capture test output to `.agent-tmp/` (gitignored): `mkdir -p .agent-tmp && just test-mac <Filter> 2>&1 | tee .agent-tmp/out.txt`.
- After **every** task that changes Swift: `just format` then `just format-check` and **read the full output** — `… | tail` masks SwiftLint errors (memory `reference_swiftformat_swiftlint_private_extension`). Never add a SwiftLint baseline/disable; fix the code.
- Use plain `extension Foo { private func … }`, never `private extension Foo` (swift-format vs swiftlint conflict).
- One primary type per file (project convention); conform via separate `extension`, don't inline conformances.
- Commit after each task with a message referencing #1033.

---

## File Structure

New:
- `Features/Insights/InsightNavigationTarget.swift` — pure `InsightReferences → SidebarSelection?`.
- `Features/Insights/Views/ForYouCard.swift` — presentational card + `InsightRow` + `#Preview`.
- `MoolahTests/Features/Insights/InsightNavigationTargetTests.swift` — unit tests for the mapping.
- `App/UITestSeedInsightOverrides.swift` — `[ScoredInsight]` fixtures for the UI-test seed (app target).
- `UITestSupport/UITestIdentifiers+ForYou.swift` — accessibility identifiers (shared app + UI-test target).
- `UITestSupport/UITestFixtures+InsightsForYou.swift` — shared fixture **strings/ids** (no `ScoredInsight`).
- `MoolahUITests_macOS/Helpers/Screens/ForYouScreen.swift` — XCUITest screen driver.
- `MoolahUITests_macOS/Tests/ForYou/ForYouPanelUITests.swift` — UI tests.

Modified:
- `Features/Insights/InsightStore.swift` — dismiss removes + session `dismissedIds`; `fixtureInsights` init seam.
- `MoolahTests/Features/Insights/InsightStoreTests.swift` — rewrite dismiss test; add fixture + hidden-across-refresh tests.
- `Features/Analysis/Views/AnalysisView.swift` — render card + `refreshIfStale` wiring + `@FocusedValue` navigation.
- `UITestSupport/UITestSeed.swift` — add `.insightsForYouBaseline` case.
- `App/UITestSeedHydrator.swift` — dispatch the new seed to `hydrateTradeBaseline`.
- `App/UITestSeedCryptoOverrides.swift` — add the new case to the `nil` arm (keep switch exhaustive).
- `App/ProfileSession+Factories.swift` — `uiTestingInsightFixtures()` helper.
- `App/ProfileSession.swift` — pass `fixtureInsights:` into `InsightStore.init` in `finishInit`.

---

## Task 1: `InsightNavigationTarget` (pure mapping, TDD)

**Files:**
- Test: `MoolahTests/Features/Insights/InsightNavigationTargetTests.swift`
- Create: `Features/Insights/InsightNavigationTarget.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("InsightNavigationTarget")
struct InsightNavigationTargetTests {
  private let accountId = UUID()
  private let earmarkId = UUID()
  private let groupId = UUID()
  private let categoryId = UUID()

  @Test func accountReferenceMapsToAccountSelection() {
    let refs = InsightReferences(accountIds: [accountId])
    #expect(InsightNavigationTarget.sidebarSelection(for: refs) == .account(accountId))
  }

  @Test func earmarkReferenceMapsToEarmarkSelection() {
    let refs = InsightReferences(earmarkIds: [earmarkId])
    #expect(InsightNavigationTarget.sidebarSelection(for: refs) == .earmark(earmarkId))
  }

  @Test func groupReferenceMapsToGroupSelection() {
    let refs = InsightReferences(groupIds: [groupId])
    #expect(InsightNavigationTarget.sidebarSelection(for: refs) == .group(groupId))
  }

  @Test func categoryReferenceMapsToCategoriesScreen() {
    let refs = InsightReferences(categoryIds: [categoryId])
    #expect(InsightNavigationTarget.sidebarSelection(for: refs) == .categories)
  }

  @Test func priorityIsAccountThenEarmarkThenGroupThenCategories() {
    let refs = InsightReferences(
      accountIds: [accountId], categoryIds: [categoryId],
      earmarkIds: [earmarkId], groupIds: [groupId])
    #expect(InsightNavigationTarget.sidebarSelection(for: refs) == .account(accountId))
  }

  @Test func instrumentOrTransactionOnlyHasNoTarget() {
    let refs = InsightReferences(instrumentIds: ["ETH"], transactionIds: [UUID()])
    #expect(InsightNavigationTarget.sidebarSelection(for: refs) == nil)
  }

  @Test func emptyReferencesHaveNoTarget() {
    #expect(InsightNavigationTarget.sidebarSelection(for: InsightReferences()) == nil)
  }
}
```

- [ ] **Step 2: Run, verify it fails to compile (`InsightNavigationTarget` undefined)**

Run: `just test-mac InsightNavigationTargetTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: build failure — "cannot find 'InsightNavigationTarget' in scope".

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Maps an insight's deep-link references onto a `SidebarSelection`, so the
/// "For You" panel can navigate to the entity an insight is about. Pure and
/// unit-tested; lives in the Features layer because `SidebarSelection` is a
/// navigation type the Domain layer (where `InsightReferences` lives) must
/// not depend on.
///
/// Priority — account → earmark → group → categories — picks the most
/// specific destination when an insight references several. Insights that
/// reference only an instrument or a transaction have no sidebar destination
/// (there is no per-instrument or per-transaction sidebar row), so they
/// return `nil` and the row shows no navigation affordance.
enum InsightNavigationTarget {
  static func sidebarSelection(for references: InsightReferences) -> SidebarSelection? {
    if let accountId = references.accountIds.first {
      return .account(accountId)
    }
    if let earmarkId = references.earmarkIds.first {
      return .earmark(earmarkId)
    }
    if let groupId = references.groupIds.first {
      return .group(groupId)
    }
    if !references.categoryIds.isEmpty {
      return .categories
    }
    return nil
  }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `just test-mac InsightNavigationTargetTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: all 7 tests PASS.

- [ ] **Step 5: format + commit**

```bash
just format && just format-check
git -C "$PWD" add Features/Insights/InsightNavigationTarget.swift MoolahTests/Features/Insights/InsightNavigationTargetTests.swift
git -C "$PWD" commit -m "Add InsightNavigationTarget reference→selection mapping (#1033)"
```

---

## Task 2: `InsightStore.dismiss` removes + downranks (store change, TDD)

Per the approved design, dismiss must remove the insight from the published list now **and** keep bumping the per-kind fatigue count (Phase D persists the latter). This replaces the downrank-only test.

**Files:**
- Modify: `Features/Insights/InsightStore.swift`
- Modify: `MoolahTests/Features/Insights/InsightStoreTests.swift`

- [ ] **Step 1: Rewrite the dismiss test + add the hidden-across-refresh test**

In `InsightStoreTests.swift`, **delete** the existing `dismissDownranksKind()` test and add:

```swift
  @Test func dismissRemovesInsightFromPublishedList() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    try await seedUncategorizedBacklog(backend, count: 12)
    let store = makeStore(backend)
    await store.refresh()

    let target = try #require(
      store.insights.first { $0.insight.kind == .uncategorizedBacklog })
    let loadedAtBeforeDismiss = store.lastLoadedAt

    store.dismiss(target)

    // The dismissed insight is gone immediately — and it was an in-place
    // re-rank, not a rebuild, so `lastLoadedAt` is untouched.
    #expect(!store.insights.contains { $0.id == target.id })
    #expect(store.lastLoadedAt == loadedAtBeforeDismiss)
  }

  @Test func dismissedInsightStaysHiddenAcrossRefresh() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    try await seedUncategorizedBacklog(backend, count: 12)
    let store = makeStore(backend)
    await store.refresh()
    let target = try #require(
      store.insights.first { $0.insight.kind == .uncategorizedBacklog })

    store.dismiss(target)
    store.overrideLastLoadedAtForTesting(nil)  // force the next refresh to rebuild
    await store.refresh()

    // A full rebuild re-detects the backlog, but the session dismissal keeps
    // it hidden until relaunch (Phase D persists this across launches).
    #expect(!store.insights.contains { $0.id == target.id })
  }
```

> Note: the per-kind fatigue **penalty math** stays covered by `InsightRankerTests`; this store suite now owns the remove-and-stay-hidden contract.

- [ ] **Step 2: Run, verify the new tests fail**

Run: `just test-mac InsightStoreTests 2>&1 | tee .agent-tmp/t2.txt`
Expected: `dismissRemovesInsightFromPublishedList` FAILS (insight still present — current dismiss only downranks); `dismissedInsightStaysHiddenAcrossRefresh` FAILS.

- [ ] **Step 3: Implement the store change**

In `InsightStore.swift`, add to the "Cached / mutable" section (after `dismissals`):

```swift
  /// Ids dismissed in this session. Filtered out of every published list so a
  /// dismissed insight stays gone until relaunch. Distinct from `dismissals`,
  /// which counts dismissals *per kind* to drive the ranker's fatigue penalty;
  /// Phase D persists both across launches.
  private var dismissedIds: Set<String> = []
```

Add a `visible(_:)` helper (in the off-main `extension` or main body — put it in the main `final class` body near `dismiss`):

```swift
  /// Drops session-dismissed ids from a ranked list before publishing.
  private func visible(_ scored: [ScoredInsight]) -> [ScoredInsight] {
    scored.filter { !dismissedIds.contains($0.id) }
  }
```

In `refresh()`, change the success publish line from `insights = scored` to:

```swift
      insights = visible(scored)
```

Replace `dismiss(_:)` with:

```swift
  /// Removes the insight from the published list immediately and records a
  /// per-kind dismissal so the ranker's fatigue penalty downranks the kind for
  /// the rest of the session. Re-ranks the cached input in place (no rebuild)
  /// so any surviving insights reflect the new fatigue; falls back to filtering
  /// the current list when no input is cached (e.g. the UI-test fixture path).
  func dismiss(_ insight: ScoredInsight) {
    dismissedIds.insert(insight.id)
    dismissals[insight.insight.kind, default: 0] += 1
    if let lastInput {
      insights = visible(engine.generate(lastInput, dismissals: dismissals))
    } else {
      insights = visible(insights)
    }
  }
```

- [ ] **Step 4: Run, verify pass**

Run: `just test-mac InsightStoreTests 2>&1 | tee .agent-tmp/t2.txt`
Expected: all `InsightStoreTests` PASS (existing refresh/staleness tests unaffected — `visible(_:)` is a no-op when nothing is dismissed).

- [ ] **Step 5: format + commit**

```bash
just format && just format-check
git -C "$PWD" add Features/Insights/InsightStore.swift MoolahTests/Features/Insights/InsightStoreTests.swift
git -C "$PWD" commit -m "InsightStore.dismiss removes insight + keeps kind fatigue (#1033)"
```

---

## Task 3: `InsightStore` fixture-injection seam (store change, TDD)

A UI-testing seam so a seed can serve deterministic insights without the statistical detectors.

**Files:**
- Modify: `Features/Insights/InsightStore.swift`
- Modify: `MoolahTests/Features/Insights/InsightStoreTests.swift`

- [ ] **Step 1: Add the failing test + helpers**

In `InsightStoreTests.swift` add a fixtures-aware store factory and an insight builder to the harness:

```swift
  private func makeStore(
    _ backend: CloudKitAnalysisTestBackend, fixtures: [ScoredInsight]
  ) -> InsightStore {
    InsightStore(
      sources: makeSources(backend), backend: backend, profile: makeProfile(),
      instrumentChanges: nil, fixtureInsights: fixtures)
  }

  private func makeScoredInsight(id: String, score: Double) -> ScoredInsight {
    ScoredInsight(
      insight: Insight(
        id: id, kind: .netWorthMilestone, title: id, detail: "",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        framing: .neutral, actionability: .informational, surprise: 0),
      score: score)
  }
```

Add the test:

```swift
  @Test func fixtureInsightsArePublishedAndDismissable() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let fixtures = [
      makeScoredInsight(id: "a", score: 3),
      makeScoredInsight(id: "b", score: 2),
    ]
    let store = makeStore(backend, fixtures: fixtures)

    await store.refresh()
    #expect(store.insights.map(\.id) == ["a", "b"])

    store.dismiss(try #require(store.insights.first))
    #expect(store.insights.map(\.id) == ["b"])
  }
```

- [ ] **Step 2: Run, verify it fails to compile (`fixtureInsights:` arg unknown)**

Run: `just test-mac InsightStoreTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: build failure — extra argument `fixtureInsights` in call.

- [ ] **Step 3: Implement the seam**

In `InsightStore.swift`, add a stored property in "Dependencies":

```swift
  /// UI-testing seam: when non-nil, `refresh()` publishes these fixtures
  /// instead of building an `InsightInput` and running the engine — so a
  /// `MoolahUITests_macOS` seed can assert the surface deterministically
  /// (mirrors the `transferDetectionBaseline` "write the result directly"
  /// pattern). Nil in production and previews. `dismiss(_:)` still works via
  /// `dismissedIds` because the fixture path leaves `lastInput` nil.
  private let fixtureInsights: [ScoredInsight]?
```

Extend `init` — add the parameter (after `instrumentChanges`) and assign it before the observation task:

```swift
  init(
    sources: InsightStoreSources,
    backend: any BackendProvider,
    profile: Profile,
    instrumentChanges: (any InstrumentChangeObserving)? = nil,
    fixtureInsights: [ScoredInsight]? = nil
  ) {
    self.sources = sources
    self.builder = InsightInputBuilder(backend: backend)
    self.engine = InsightEngine()
    self.reportingInstrument = profile.instrument
    self.instrumentChanges = instrumentChanges
    self.fixtureInsights = fixtureInsights
    // …existing observation-task block unchanged…
```

At the **top** of `refresh()` (before the `guard !isLoading` body work), short-circuit:

```swift
  func refresh() async {
    guard !isLoading else { return }
    if let fixtureInsights {
      insights = visible(fixtureInsights)
      lastLoadedAt = Date()
      return
    }
    // …existing snapshot/compute/publish body unchanged…
```

- [ ] **Step 4: Run, verify pass**

Run: `just test-mac InsightStoreTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: all PASS.

- [ ] **Step 5: concurrency-review + format + commit**

Run the `concurrency-review` agent on `Features/Insights/InsightStore.swift` (store touched). Apply all findings (memory `feedback_apply_all_review_findings`).

```bash
just format && just format-check
git -C "$PWD" add Features/Insights/InsightStore.swift MoolahTests/Features/Insights/InsightStoreTests.swift
git -C "$PWD" commit -m "Add InsightStore fixtureInsights UI-testing seam (#1033)"
```

---

## Task 4: `ForYouCard` + `InsightRow` presentational view + `#Preview`

Pure view; iterate visuals via `RenderPreview` (memory `feedback_iterate_via_preview`), not by relaunching the app. Identifiers come from Task 6's `UITestIdentifiers.ForYou`, so this task depends on that enum existing — **create the identifier file (Task 6 Step A) first if executing out of order**, or stub the identifiers inline and reconcile. (Recommended order: do Task 6's identifier sub-step before this task.)

**Files:**
- Create: `Features/Insights/Views/ForYouCard.swift`

- [ ] **Step 1: Implement the card + row**

```swift
import SwiftUI

/// The "For You" dashboard panel: renders the top-ranked insights with a
/// dismiss affordance and an optional deep-link. Pure presentational view —
/// all state and logic live in `InsightStore`; this binds the published
/// insights and dispatches the two closures. `AnalysisView` renders it only
/// when there are insights, so this view assumes a non-empty list.
struct ForYouCard: View {
  let insights: [ScoredInsight]
  var maxVisible: Int = 3
  let onDismiss: (ScoredInsight) -> Void
  let onNavigate: (SidebarSelection) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("For You")
        .font(.title2)
        .fontWeight(.semibold)
      VStack(spacing: 8) {
        ForEach(insights.prefix(maxVisible)) { scored in
          InsightRow(
            scored: scored,
            onDismiss: { onDismiss(scored) },
            onNavigate: onNavigate)
        }
      }
    }
    .padding()
    .background(.background)
    .clipShape(.rect(cornerRadius: 12))
    .accessibilityIdentifier(UITestIdentifiers.ForYou.card)
  }
}

private struct InsightRow: View {
  let scored: ScoredInsight
  let onDismiss: () -> Void
  let onNavigate: (SidebarSelection) -> Void

  @State private var isExpanded = false

  private var insight: Insight { scored.insight }
  private var target: SidebarSelection? {
    InsightNavigationTarget.sidebarSelection(for: insight.references)
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      expandedContent
    } label: {
      header
    }
    .accessibilityIdentifier(UITestIdentifiers.ForYou.row(insight.id))
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: framingIcon)
        .foregroundStyle(framingColor)
        .accessibilityHidden(true)
      Text(insight.title)
        .font(.subheadline)
        .fontWeight(.medium)
      Spacer(minLength: 8)
      if let impact = insight.monetaryImpact {
        Text(impact.formatted)
          .font(.subheadline)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Button(action: onDismiss) {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .accessibilityLabel("Dismiss \(insight.title)")
      .accessibilityIdentifier(UITestIdentifiers.ForYou.dismissButton(insight.id))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(headerAccessibilityLabel)
  }

  @ViewBuilder private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !insight.detail.isEmpty {
        Text(insight.detail)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      ForEach(Array(insight.facts.enumerated()), id: \.offset) { _, fact in
        HStack {
          Text(fact.label)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Text(fact.value)
            .monospacedDigit()
        }
        .font(.caption)
      }
      if let target {
        Button("View") { onNavigate(target) }
          .buttonStyle(.link)
          .accessibilityLabel("View \(insight.title)")
          .accessibilityIdentifier(UITestIdentifiers.ForYou.navigateButton(insight.id))
      }
    }
    .padding(.top, 4)
  }

  private var headerAccessibilityLabel: String {
    var parts = [framingDescription, insight.title]
    if let impact = insight.monetaryImpact {
      parts.append(impact.formatted)
    }
    return parts.joined(separator: ", ")
  }

  private var framingColor: Color {
    switch insight.framing {
    case .positive: return .green
    case .negative: return .orange
    case .neutral: return .secondary
    }
  }

  private var framingIcon: String {
    switch insight.framing {
    case .positive: return "checkmark.seal.fill"
    case .negative: return "exclamationmark.triangle.fill"
    case .neutral: return "info.circle.fill"
    }
  }

  private var framingDescription: String {
    switch insight.framing {
    case .positive: return "Good news"
    case .negative: return "Heads up"
    case .neutral: return "Note"
    }
  }
}
```

> If `Color.secondary` triggers any issue in build, substitute `Color(.secondaryLabelColor)` on macOS — but `Color.secondary` is the semantic, dark-mode-safe choice and should compile (UI_GUIDE §semantic colors).

- [ ] **Step 2: Add a `#Preview` with fixtures**

Append to `ForYouCard.swift`:

```swift
#if DEBUG
  extension ScoredInsight {
    /// Preview/iteration fixtures covering each framing, with/without impact,
    /// and with/without a navigation target.
    static var forYouPreviewFixtures: [ScoredInsight] {
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      let accountId = UUID()
      return [
        ScoredInsight(
          insight: Insight(
            id: "p-large", kind: .largeTransactionAnomaly,
            title: "Large purchase at the Apple Store",
            detail: "This is well above your usual spending here.",
            date: now, framing: .negative, actionability: .review, surprise: 0.8,
            monetaryImpact: InstrumentAmount(quantity: -2499, instrument: .AUD),
            facts: [InsightFact("Amount", "−$2,499.00"), InsightFact("Typical", "$120.00")],
            references: InsightReferences(accountIds: [accountId])),
          score: 4.2),
        ScoredInsight(
          insight: Insight(
            id: "p-netflix", kind: .subscriptionPriceHike,
            title: "Netflix raised its monthly price",
            detail: "Up $3.00 from last month.",
            date: now, framing: .negative, actionability: .act, surprise: 0.5,
            monetaryImpact: InstrumentAmount(quantity: -3, instrument: .AUD),
            facts: [InsightFact("New price", "$22.99"), InsightFact("Was", "$19.99")]),
          score: 3.1),
        ScoredInsight(
          insight: Insight(
            id: "p-milestone", kind: .netWorthMilestone,
            title: "Net worth crossed $100k",
            detail: "Nice work — a new high.",
            date: now, framing: .positive, actionability: .informational, surprise: 0.3),
          score: 2.0),
      ]
    }
  }

  #Preview {
    ForYouCard(
      insights: .forYouPreviewFixtures,
      onDismiss: { _ in },
      onNavigate: { _ in })
    .padding()
    .frame(width: 420)
  }
#endif
```

- [ ] **Step 3: Build + render preview**

Run: `just build-mac 2>&1 | tee .agent-tmp/t4-build.txt` → expect success, zero warnings in user code.
Then render the preview with `mcp__xcode__RenderPreview` (regenerate the worktree's `Moolah.xcodeproj` via `just generate` and open it in Xcode first per CLAUDE.md "Xcode previews from a worktree"). Visually confirm: three rows, semantic framing colors, impact right-aligned & monospaced, expand reveals facts + (for the first row only) a "View" link.

- [ ] **Step 4: ui-review**

Run the `ui-review` agent on `Features/Insights/Views/ForYouCard.swift`. Apply all findings.

- [ ] **Step 5: format + commit**

```bash
just format && just format-check
git -C "$PWD" add Features/Insights/Views/ForYouCard.swift
git -C "$PWD" commit -m "Add ForYouCard insights panel view + preview (#1033)"
```

---

## Task 5: Wire `ForYouCard` into `AnalysisView`

**Files:**
- Modify: `Features/Analysis/Views/AnalysisView.swift`

- [ ] **Step 1: Add the focused-value navigation reader**

Add to `AnalysisView`'s property block (near the other `@Environment`s):

```swift
  @FocusedValue(\.sidebarSelection) private var sidebarSelection
```

- [ ] **Step 2: Render the card at the top of the content stack**

In `contentView(store:)`, insert as the **first** child of the `VStack(spacing: 20)`, above `NetWorthGraphCard`:

```swift
      if let insightStore = session.insightStore, !insightStore.insights.isEmpty {
        ForYouCard(
          insights: insightStore.insights,
          onDismiss: { insightStore.dismiss($0) },
          onNavigate: { sidebarSelection?.wrappedValue = $0 })
      }
```

- [ ] **Step 3: Drive `refreshIfStale` from the existing `.task` and scene-active**

In the first `.task` (the priming one), **after** `await store.loadAll()` add:

```swift
      await session.insightStore?.refreshIfStale(minimumInterval: 60)
```

In the `scenePhase` `.onChange`, inside the `oldPhase == .background && newPhase == .active` branch, add alongside the existing call:

```swift
        Task { await session.insightStore?.refreshIfStale(minimumInterval: 60) }
```

- [ ] **Step 4: Build + verify no warnings**

Run: `just build-mac 2>&1 | tee .agent-tmp/t5.txt`
Expected: success; check `mcp__xcode__XcodeListNavigatorIssues` (severity warning) is clear for user code.

- [ ] **Step 5: code-review + format + commit**

Run the `code-review` agent on `AnalysisView.swift` (thin-view discipline: the card block + closures are one-liners, all logic in the store/`InsightNavigationTarget`). Apply findings.

```bash
just format && just format-check
git -C "$PWD" add Features/Analysis/Views/AnalysisView.swift
git -C "$PWD" commit -m "Render For You panel atop Analysis view + refresh wiring (#1033)"
```

---

## Task 6: UI-test seam (app side + shared constants)

### Step A — shared identifiers (do before Task 4 if possible)

**File:** `UITestSupport/UITestIdentifiers+ForYou.swift`

- [ ] Create:

```swift
import Foundation

extension UITestIdentifiers {
  /// Accessibility identifiers for the "For You" insights panel. Shared by the
  /// SwiftUI view (`ForYouCard`) and the `ForYouScreen` UI-test driver so they
  /// never drift. Per-insight identifiers embed the (stable) insight id.
  public enum ForYou {
    public static let card = "for-you-card"
    public static func row(_ id: String) -> String { "for-you-row-\(id)" }
    public static func dismissButton(_ id: String) -> String { "for-you-dismiss-\(id)" }
    public static func navigateButton(_ id: String) -> String { "for-you-view-\(id)" }
  }
}
```

> Confirm the existing `UITestIdentifiers` shape in `UITestSupport/UITestIdentifiers.swift` (it is the `public enum`/namespace the other `+…` files extend) and match its visibility and nesting style.

### Step B — shared fixture strings (no `ScoredInsight`)

**File:** `UITestSupport/UITestFixtures+InsightsForYou.swift`

- [ ] Create (strings/ids only — this file compiles into the UI-test target which has no `ScoredInsight`):

```swift
import Foundation

extension UITestFixtures {
  /// Deterministic constants for the `.insightsForYouBaseline` seed. The
  /// `[ScoredInsight]` values themselves live in `App/UITestSeedInsightOverrides`
  /// (app target only); these ids/titles are referenced by both that override
  /// and the `ForYouPanelUITests` so a rename can't desync them. The navigable
  /// row references `UITestFixtures.TradeBaseline.checkingAccountId`, so tapping
  /// "View" lands on that account's detail (asserted via its name).
  public enum InsightsForYou {
    public static let largeTxnId = "for-you-large-txn"
    public static let largeTxnTitle = "Large purchase at the Apple Store"
    public static let priceHikeId = "for-you-price-hike"
    public static let priceHikeTitle = "Netflix raised its monthly price"
    public static let milestoneId = "for-you-milestone"
    public static let milestoneTitle = "Net worth crossed a milestone"
  }
}
```

> Verify `UITestFixtures` is the enum the `TradeBaseline` fixtures hang off (in `UITestSupport/UITestFixtures.swift`) and that `TradeBaseline.checkingAccountId` / `checkingAccountName` exist (they are seeded by `hydrateTradeBaseline`).

### Step C — the seed case

**File:** `UITestSupport/UITestSeed.swift`

- [ ] Add the case (with a doc comment in the style of the others):

```swift
  /// Reuses the `tradeBaseline` profile (so the app boots into the sidebar +
  /// Analysis view with a real "Checking" account) and installs three fixture
  /// `ScoredInsight`s via `UITestSeedInsightOverrides`, bypassing the
  /// statistical detectors. Drives `ForYouPanelUITests`: the For You card
  /// renders the fixtures, dismiss removes one, and the navigable row deep-links
  /// to the checking account. See `UITestFixtures.InsightsForYou`.
  case insightsForYouBaseline = "insights-for-you-baseline"
```

### Step D — the fixtures (app target)

**File:** `App/UITestSeedInsightOverrides.swift`

- [ ] Create (mirrors `UITestSeedCryptoOverrides` shape — exhaustive switch over `UITestSeed`):

```swift
import Foundation

/// UI-testing-only fixture insights for the `.insightsForYouBaseline` seed.
/// Consulted from `ProfileSession.finishInit` (via
/// `ProfileSession.uiTestingInsightFixtures()`) when the process was launched
/// with `--ui-testing` and the active seed requests deterministic insights
/// instead of the live detector output. Nil for every other seed → live
/// `InsightEngine` wiring (mirrors `UITestSeedCryptoOverrides`).
@MainActor
enum UITestSeedInsightOverrides {
  static func fixtures(for seed: UITestSeed) -> [ScoredInsight]? {
    switch seed {
    case .insightsForYouBaseline:
      return insightsForYouBaselineFixtures
    case .tradeBaseline,
      .welcomeEmpty,
      .welcomeSingleCloudProfile,
      .welcomeMultipleCloudProfiles,
      .welcomeDownloading,
      .sidebarFooterUpToDate,
      .sidebarFooterReceiving,
      .sidebarFooterSending,
      .cryptoCatalogPreloaded,
      .tradeReady,
      .incompatibleProfile,
      .pendingWebImportOneChaseInbox,
      .transferDetectionBaseline:
      return nil
    }
  }

  private static var insightsForYouBaselineFixtures: [ScoredInsight] {
    let fixtures = UITestFixtures.InsightsForYou.self
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return [
      ScoredInsight(
        insight: Insight(
          id: fixtures.largeTxnId, kind: .largeTransactionAnomaly,
          title: fixtures.largeTxnTitle,
          detail: "This is well above your usual spending here.",
          date: now, framing: .negative, actionability: .review, surprise: 0.8,
          monetaryImpact: InstrumentAmount(quantity: -2499, instrument: .AUD),
          references: InsightReferences(
            accountIds: [UITestFixtures.TradeBaseline.checkingAccountId])),
        score: 4.2),
      ScoredInsight(
        insight: Insight(
          id: fixtures.priceHikeId, kind: .subscriptionPriceHike,
          title: fixtures.priceHikeTitle,
          detail: "Up $3.00 from last month.",
          date: now, framing: .negative, actionability: .act, surprise: 0.5,
          monetaryImpact: InstrumentAmount(quantity: -3, instrument: .AUD)),
        score: 3.1),
      ScoredInsight(
        insight: Insight(
          id: fixtures.milestoneId, kind: .netWorthMilestone,
          title: fixtures.milestoneTitle,
          detail: "Nice work — a new high.",
          date: now, framing: .positive, actionability: .informational, surprise: 0.3),
        score: 2.0),
    ]
  }
}
```

> If `Instrument.AUD` is not the right literal in this codebase, use the profile/test currency literal the other app fixtures use (grep `instrument: .AUD` in `App/`). The amounts feed only display; the AUD profile from `tradeBaseline` matches.

### Step E — hydrator dispatch

**File:** `App/UITestSeedHydrator.swift`

- [ ] In `hydrate(_:into:)`, add `.insightsForYouBaseline` to the `hydrateTradeBaseline` case list (it needs the same base profile + checking account):

```swift
    case .tradeBaseline,
      .sidebarFooterUpToDate,
      .sidebarFooterReceiving,
      .sidebarFooterSending,
      .cryptoCatalogPreloaded,
      .insightsForYouBaseline:
      return try hydrateTradeBaseline(into: manager)
```

### Step F — ProfileSession plumbing

**Files:** `App/ProfileSession+Factories.swift`, `App/ProfileSession.swift`

- [ ] In `ProfileSession+Factories.swift`, add next to `uiTestingCryptoOverrides()`:

```swift
  /// Returns fixture insights for the active UI-test seed, or `nil` for
  /// production launches. Mirrors `uiTestingCryptoOverrides()`.
  @MainActor
  static func uiTestingInsightFixtures() -> [ScoredInsight]? {
    guard CommandLine.arguments.contains("--ui-testing") else { return nil }
    guard let raw = ProcessInfo.processInfo.environment["UI_TESTING_SEED"],
      let seed = UITestSeed(rawValue: raw)
    else { return nil }
    return UITestSeedInsightOverrides.fixtures(for: seed)
  }
```

> Match the access level of `uiTestingCryptoOverrides` — if it is `private static`, make this `static` (not `private`) only if `finishInit` lives in a different file/extension; `finishInit` is in `ProfileSession.swift` while this helper is in `+Factories.swift`, so it must be at least `internal static`. Confirm and align.

- [ ] In `ProfileSession.swift` `finishInit`, pass the fixtures into the existing `InsightStore(...)` construction:

```swift
    self.insightStore = InsightStore(
      sources: insightSources,
      backend: backend,
      profile: profile,
      instrumentChanges: backend.instrumentChangeObserver,
      fixtureInsights: Self.uiTestingInsightFixtures())
```

- [ ] **Build + commit**

Run: `just build-mac 2>&1 | tee .agent-tmp/t6.txt` → success, no warnings.

```bash
just format && just format-check
git -C "$PWD" add UITestSupport/UITestIdentifiers+ForYou.swift UITestSupport/UITestFixtures+InsightsForYou.swift UITestSupport/UITestSeed.swift App/UITestSeedInsightOverrides.swift App/UITestSeedHydrator.swift App/ProfileSession+Factories.swift App/ProfileSession.swift
git -C "$PWD" commit -m "Add insightsForYouBaseline UI-test seed + fixture injection (#1033)"
```

---

## Task 7: macOS UI tests (`MoolahUITests_macOS`)

**REQUIRED SUB-SKILL:** invoke the `writing-ui-tests` skill before writing the driver/tests — it enforces the screen-driver rule (tests import only `XCTest`), trace logging, post-condition waits, single resolver, no element caching, and deterministic seeds. Mirror an existing simple driver (e.g. `Helpers/Screens/RecentlyAddedScreen.swift`) for structure.

**Files:**
- Create: `MoolahUITests_macOS/Helpers/Screens/ForYouScreen.swift`
- Create: `MoolahUITests_macOS/Tests/ForYou/ForYouPanelUITests.swift`

- [ ] **Step 1: Write the `ForYouScreen` driver**

A screen driver over `XCUIApplication` exposing (names indicative — follow the guide's invariants exactly):
- `waitForCard()` — waits for `UITestIdentifiers.ForYou.card` to exist.
- `row(id:)` / `rowExists(id:)` — resolves `UITestIdentifiers.ForYou.row(id)`.
- `dismiss(id:)` — taps `UITestIdentifiers.ForYou.dismissButton(id)`, then waits for the row to **not** exist (post-condition wait, not a sleep).
- `expand(id:)` — taps the row's disclosure to reveal facts/`View`.
- `tapView(id:)` — taps `UITestIdentifiers.ForYou.navigateButton(id)`.
Reference fixture ids via `UITestFixtures.InsightsForYou` and the account name via `UITestFixtures.TradeBaseline.checkingAccountName`.

- [ ] **Step 2: Write the tests**

Launch with the new seed (mirror existing launch helpers, e.g. `MoolahApp.launch(seed: .insightsForYouBaseline)`):

- `testForYouPanelRendersSeededInsights` — launch → `waitForCard()` → assert rows for `largeTxnId`, `priceHikeId`, `milestoneId` exist.
- `testDismissRemovesInsight` — launch → `dismiss(id: largeTxnId)` → assert that row no longer exists; the other two remain.
- `testNavigateOpensReferencedAccount` — launch → `expand(id: largeTxnId)` → `tapView(id: largeTxnId)` → assert the detail pane now shows `TradeBaseline.checkingAccountName` (reuse the existing account-detail screen driver / static text query used by other detail-navigation tests; see `DetailColumnNavigationSweepTests` for the pattern).

- [ ] **Step 3: Run the UI tests**

Pre-empt the known runner hang (memory `reference_macos_test_runner_hang`): `pkill` stale `Moolah` test-host/`xctest` procs first if a prior run wedged.

Run: `just test-mac ForYouPanelUITests 2>&1 | tee .agent-tmp/t7.txt`
Expected: 3 tests PASS. (If the local UI host is wedged and can't be cleared, fall back to gating on the PR's CI "UI Test" job per memory `feedback_pr_ci_gate_when_ui_host_blocked` — but attempt locally first.)

- [ ] **Step 4: ui-test-review + format + commit**

Run the `ui-test-review` agent on the new driver + test. Apply all findings.

```bash
just format && just format-check
git -C "$PWD" add MoolahUITests_macOS/Helpers/Screens/ForYouScreen.swift "MoolahUITests_macOS/Tests/ForYou/ForYouPanelUITests.swift"
git -C "$PWD" commit -m "Add For You panel UI tests (#1033)"
```

---

## Task 8: Full verification + PR

- [ ] **Step 1: Full format-check (read full output, not `| tail`)**

Run: `just format-check 2>&1 | tee .agent-tmp/fc.txt` → zero diffs, zero SwiftLint violations.

- [ ] **Step 2: Full macOS + iOS test suites**

Run: `just test 2>&1 | tee .agent-tmp/test-all.txt`
Then: `grep -i 'failed\|error:' .agent-tmp/test-all.txt` → no failures.

- [ ] **Step 3: Final review sweep**

Confirm each review agent was run and findings applied: `code-review` (ForYouCard, AnalysisView, InsightNavigationTarget), `ui-review` (ForYouCard), `concurrency-review` (InsightStore), `ui-test-review` (ForYou tests). Re-run any not yet run.

- [ ] **Step 4: Open the PR**

```bash
git -C "$PWD" push origin worktree-insights-foryou-panel:worktree-insights-foryou-panel
gh pr create --base main --title "Insights Phase C: For You dashboard panel" \
  --body "$(cat <<'EOF'
Implements the first user-facing insights surface (#1033, epic #1030): a "For You" card at the top of the Analysis view that renders the ranked insights `InsightStore` publishes, with dismiss and deep-link.

## What

- `ForYouCard` / `InsightRow` — thin presentational view (inputs + two closures), `#Preview` with fixtures.
- `InsightNavigationTarget` — pure, unit-tested `InsightReferences → SidebarSelection?` mapping (account → earmark → group → categories).
- `InsightStore.dismiss` — now removes the dismissed insight from the published list immediately (session `dismissedIds`, filtered on refresh) while keeping the per-kind fatigue signal for ranking.
- `InsightStore` fixture-injection seam + `insightsForYouBaseline` UI-test seed so the macOS UI test asserts the surface deterministically without depending on detector thresholds.
- `AnalysisView` wiring: renders the card (only when non-empty), drives `refreshIfStale(60)` on `.task` after analysis loads and on scene-active, navigates via the existing `\.sidebarSelection` focused value.

## Out of scope

- Phase D (#1034): persistence/sync of dismissals — they stay in-memory this PR.

## Testing

- Unit: `InsightNavigationTargetTests`, updated `InsightStoreTests` (remove-on-dismiss, hidden-across-refresh, fixture injection).
- UI: `ForYouPanelUITests` (render / dismiss / navigate).
- `just format-check`, `just test` green; `code-review` / `ui-review` / `concurrency-review` / `ui-test-review` run.

Closes #1033.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: Land via the merge queue**

Invoke the `landing-prs` skill (native merge queue, rebase). Do not push to `main` directly.

---

## Self-review notes (author)

- **Spec coverage:** placement (Task 5), `ForYouCard`/`InsightRow` (Task 4), `InsightNavigationTarget` (Task 1), refresh model (Task 5), absent-on-empty/error (Task 5 `if !isEmpty`; error path stays silent in the store), dismiss=remove+downrank (Task 2), deep-link (Tasks 1/4/5), accessibility (Task 4), unit/preview/UI tests (Tasks 1/4/7), UI-test determinism via fixtures (Tasks 3/6). All covered.
- **Cross-task type consistency:** `InsightNavigationTarget.sidebarSelection(for:)`, `InsightStore.init(…, fixtureInsights:)`, `visible(_:)`, `dismissedIds`, `UITestIdentifiers.ForYou.{card,row,dismissButton,navigateButton}`, `UITestFixtures.InsightsForYou.*`, `UITestSeed.insightsForYouBaseline`, `UITestSeedInsightOverrides.fixtures(for:)`, `ProfileSession.uiTestingInsightFixtures()` — names used identically across tasks.
- **Verify-before-code points flagged inline:** exact shape of `UITestIdentifiers`/`UITestFixtures` enums, `TradeBaseline.checkingAccount{Id,Name}`, `Color.secondary`, `Instrument.AUD` literal, and `uiTestingCryptoOverrides` access level — each task says to confirm against the codebase before writing.
- **Task 4↔6 ordering:** Task 4 uses `UITestIdentifiers.ForYou` (created in Task 6 Step A). Recommended execution order: 1 → 2 → 3 → 6(A) → 4 → 5 → 6(B–F) → 7 → 8. Noted at the top of Task 4.
