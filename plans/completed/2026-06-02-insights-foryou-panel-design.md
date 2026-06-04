# Insights Phase C — "For You" dashboard panel (design)

Issue: #1033 (epic #1030). Builds the first user-facing surface for the
insights feature shipped in Phases A+B (#1037–#1040).

## Goal

Render the ranked insights `InsightStore` already publishes on the app's
analytical landing, and let the user dismiss them and deep-link to the
referenced entity. Template narration only (no LLM). Dismissals stay
in-memory — persistence is Phase D (#1034), out of scope here.

## Surface placement

The app has no dedicated "Dashboard" screen; it is a sidebar + detail
layout where `AnalysisView` (`ContentView` → `.analysis`) is the analytical
landing — a `ScrollView` of cards (net-worth graph, upcoming, income/expense,
expense breakdown, categories-over-time). The "For You" panel is a **card at
the top of that stack**, above `NetWorthGraphCard`.

Rationale: reuses the analytical landing (no new sidebar nav), and
`InsightStore` is conceptually a sibling of `AnalysisStore`, whose loaded
state it reads to build its input.

## Components (all under `Features/Insights/`)

### 1. `ForYouCard` — pure presentational view (`Views/ForYouCard.swift`)

Inputs only — no store, no `@Environment` store reference, so it is trivially
previewable with fixtures and stays a thin view:

```
ForYouCard(
  insights: [ScoredInsight],
  maxVisible: Int = 3,
  onDismiss: (ScoredInsight) -> Void,
  onNavigate: (SidebarSelection) -> Void
)
```

Card chrome matches `ExpenseBreakdownCard`:
`VStack(alignment: .leading, spacing: 12)` with a `.title2` / `.semibold`
header "For You", `.padding()`, `.background(.background)`,
`.clipShape(.rect(cornerRadius: 12))`. Renders `insights.prefix(maxVisible)`
as a list of `InsightRow`s.

### 2. `InsightRow` — one insight (same file)

A `DisclosureGroup`:

- **Collapsed:** framing icon in a **semantic** color
  (`.green` `.positive` / `.orange` `.negative` / `.secondary` `.neutral`)
  + `title` (semibold) + optional signed `monetaryImpact` rendered with
  `.monospacedDigit()` (sign **preserved**, never `abs()`-ed) + a trailing
  **dismiss (✕)** button.
- **Expanded:** `detail` text, the `facts` list (label → value rows), and a
  **"View …"** button shown only when a navigation target exists.

### 3. `InsightNavigationTarget` — pure mapping (`InsightNavigationTarget.swift`)

The one piece of real logic, extracted from the view (thin-view discipline)
and unit-tested. Maps `InsightReferences → SidebarSelection?` by fixed
priority:

```
account → earmark → group → categories
```

Returns `nil` for instrument-only / transaction-only insights (no matching
sidebar destination — there is no per-category or per-transaction selection,
so `categoryIds` routes to the shared `.categories` screen and
`transactionIds`/`instrumentIds` alone yield no target). Lives in the
Features layer because `SidebarSelection` is a navigation type the Domain
layer must not know about.

### 4. `AnalysisView` wiring (thin)

```swift
@FocusedValue(\.sidebarSelection) private var sidebarSelection
// in contentView, above NetWorthGraphCard:
if let insightStore = session.insightStore, !insightStore.insights.isEmpty {
  ForYouCard(
    insights: insightStore.insights,
    onDismiss: { insightStore.dismiss($0) },
    onNavigate: { sidebarSelection?.wrappedValue = $0 })
}
```

`\.sidebarSelection` is the exact navigation seam `MoolahDomainCommands`
already uses (`sidebarSelection?.wrappedValue = .account(id)`), published
scene-wide via `.focusedSceneValue(\.sidebarSelection, $selection)` in
`SidebarSharedModifiers`. No new parameter is threaded through `ContentView`.

Refresh wiring in `AnalysisView`:
- In the existing `.task`, after `await store.loadAll()`, add
  `await session.insightStore?.refreshIfStale(minimumInterval: 60)` —
  insights read the sibling stores' loaded state, so they must refresh
  *after* analysis loads.
- In the existing `scenePhase` `background → active` `.onChange` branch,
  add the same `refreshIfStale(60)` call alongside `store.refreshIfStale`.

## Behaviour

- **Refresh model:** view-driven only — `refreshIfStale(60)` after analysis
  loads, plus the store's existing instrument-change tick. Never a rebuild on
  every appearance (relies on the staleness cache). This codebase has no
  transaction-data change tick; this mirrors `AnalysisStore`.
- **States:** the card is **absent** on empty / loading / error. Insights are
  supplementary — an empty box or a scary error has no place on the landing
  screen; the store already logs errors. The card appears only when
  `!insights.isEmpty`.
- **Dismiss:** `store.dismiss(_:)` bumps the kind's fatigue count and re-ranks
  the cached input in place; the next-ranked insight slides into the visible
  prefix. In-memory only (Phase D persists + syncs).
- **Deep-link:** "View …" → `onNavigate(target)` → sets `sidebarSelection` →
  `ContentView` switches the detail pane (its `.id(selection)` rebuilds it).

## Accessibility

- Each row is a combined accessibility element labelled `title` + signed
  impact + framing.
- Dismiss button: `accessibilityLabel("Dismiss \(title)")`.
- Navigate button: `accessibilityLabel("View \(entity)")`.
- `.accessibilityIdentifier`s on the card container, each row, the dismiss
  button, and the navigate button as the UI-test seam (registered in
  `UITestSupport/UITestIdentifiers*`).
- Monetary amounts use `.monospacedDigit()`; framing colors are semantic
  (dark-mode safe).

## Testing

- **Unit:** `InsightNavigationTarget` priority mapping — one case per
  reference type, the priority order when several are present, and the `nil`
  case (instrument/transaction only).
- **`#Preview`:** fixture `ScoredInsight`s covering positive / negative /
  neutral framing, with and without `monetaryImpact`, with and without a nav
  target, collapsed and expanded. Iterated via `RenderPreview`, not by
  relaunching the app.
- **UI test (`MoolahUITests_macOS`):** a `ForYouScreen` driver asserts the
  card and rows render, that dismissing drops a row, and that "View …"
  changes the detail pane.

### UI-test determinism (resolved in the plan)

Insights derive from seeded transaction data through statistical detectors,
which is fragile to assert on directly. Following the precedent of
`transferDetectionBaseline` (which writes the *result* — a `TransferSuggestion`
— directly to avoid a detection-timing dependency), the UI test will use a
new seed that installs **fixture** `ScoredInsight`s into `InsightStore`,
bypassing the detectors, so the test asserts the *surface* (render / dismiss /
navigate), not detector thresholds. The exact injection seam (a UI-testing-
gated insight source vs. a pre-populated store) is chosen in the plan after
inspecting `ProfileSession`'s `InsightStore` construction and the seed
hydrator. Detector correctness is already covered by Phase A/B unit tests.

## Out of scope

- Phase D — persistence + sync of dismissals / declared interests (#1034).
- Phase E — Foundation Models narration over `facts`.
- A dedicated sidebar "For You" destination (considered and rejected for v1 in
  favour of the Analysis card; can be added later without rework).

## Files

New:
- `Features/Insights/Views/ForYouCard.swift`
- `Features/Insights/InsightNavigationTarget.swift`
- `MoolahTests/Features/Insights/InsightNavigationTargetTests.swift`
- `MoolahUITests_macOS/Helpers/Screens/ForYouScreen.swift`
- `MoolahUITests_macOS/Tests/.../ForYouPanelUITests.swift`
- UI-test seed + identifiers (exact files determined in the plan).

Modified:
- `Features/Analysis/Views/AnalysisView.swift` (wire card + refresh).
- `UITestSupport/UITestSeed.swift` + `UITestIdentifiers*` (UI-test seam).
