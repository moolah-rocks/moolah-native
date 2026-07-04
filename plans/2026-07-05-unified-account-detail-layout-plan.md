# Unified Account-Detail Layout — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the account-detail screen into one data-driven layout (denser chart, compact header, all-instrument value/balance history, per-account performance, `[Transactions | Positions | Chart]` tabs on iOS / positions-pinned split on Mac), starting with the immediately shippable foundational fixes.

**Architecture:** Incremental. This plan fully specifies **Increment 1** — three independent, individually-shippable PRs (denser chart, inline sync-error caption, all-instrument history series) that address the visible complaints and lay the data foundation. The larger structural work (Increments 2–4) is outlined at the end and gets its own detailed plan once Increment 1 lands and the denser chart is validated in preview.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, Swift Testing (`@Suite`/`@Test`), GRDB (unaffected here). Design spec: `plans/2026-07-05-unified-account-detail-layout-design.md`.

## Global Constraints

- Tests use **Swift Testing** (`@Suite`, `@Test`, `#expect`), not XCTest, except UI tests under `MoolahUITests_macOS/` (XCUITest).
- One extension per protocol conformance; thin views (logic lives in testable helpers) — `guides/AI_ARCHITECTURE_GUIDE.md`.
- Money math via `InstrumentAmount`; never `abs()` a signed leg or P&L — `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
- Timezoneless calendar values via `Calendar.utc`; chart x-tokens anchor at noon-UTC — `guides/DATE_TIME_GUIDE.md`.
- Run `just format-check` after every task; fix all findings. Run the relevant AI reviewer agents (`@ui-review`, `@code-review`, `@datetime-review`, `@instrument-conversion-review`) before committing and fix every finding — `guides/AI_REVIEW_GATE_GUIDE.md`.
- Each task = one PR, landed via the `landing-prs` skill. Never `git push origin main`.
- Test wait helpers default to 10s; never pass short positive timeouts — memory `feedback_test_wait_timeouts_10s`.

---

## Task 1: Denser chart — Y-axis hugs the data

The value chart anchors its Y-axis at `$0` while values sit in a narrow high band, wasting ~⅔ of the chart. Set an explicit `chartYScale` domain computed from the actually-plotted series (value line ∪ baseline line when shown) with small padding.

**Files:**
- Create: `Shared/Views/Positions/PositionsChartYDomain.swift`
- Modify: `Shared/Views/Positions/PositionsChart.swift` (apply `.chartYScale(domain:)` on the `Chart` at `:117`, just before `.frame(...)`)
- Test: `MoolahTests/Views/Positions/PositionsChartYDomainTests.swift`

**Interfaces:**
- Produces: `enum PositionsChartYDomain { static func domain(values: [Decimal], baselines: [Decimal], paddingFraction: Double = 0.06) -> ClosedRange<Double> }` — the padded `lo...hi` over the union of `values` and `baselines`; returns `0...1` when both are empty; when the span is zero (flat line) pads by `max(abs(v) * paddingFraction, 1)` so a flat series still renders mid-frame.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Moolah

@Suite struct PositionsChartYDomainTests {
  @Test func hugsHighBandInsteadOfAnchoringAtZero() {
    let d = PositionsChartYDomain.domain(values: [60_000, 72_000, 80_000], baselines: [])
    #expect(d.lowerBound > 50_000)          // NOT anchored at 0
    #expect(d.upperBound > 80_000)          // padded above the max
    #expect(d.lowerBound < 60_000)          // padded below the min
  }

  @Test func includesBaselineWhenPresent() {
    let d = PositionsChartYDomain.domain(values: [80_000], baselines: [10_000])
    #expect(d.lowerBound < 10_000)          // baseline pulls the floor down
    #expect(d.upperBound > 80_000)
  }

  @Test func flatSeriesStillGetsNonZeroSpan() {
    let d = PositionsChartYDomain.domain(values: [500, 500, 500], baselines: [])
    #expect(d.lowerBound < 500)
    #expect(d.upperBound > 500)
    #expect(d.upperBound - d.lowerBound >= 2)
  }

  @Test func emptyInputsAreSafe() {
    #expect(PositionsChartYDomain.domain(values: [], baselines: []) == 0.0...1.0)
  }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `just test-mac PositionsChartYDomainTests`
Expected: FAIL — `PositionsChartYDomain` is not defined.

- [ ] **Step 3: Implement `PositionsChartYDomain`**

```swift
import Foundation

/// Y-axis domain for `PositionsChart`. Hugs the plotted data (value line
/// plus the invested/cost baseline when shown) instead of anchoring at 0,
/// so a portfolio worth $60–80k doesn't waste two-thirds of the chart on
/// empty space below the line. Pure and unit-tested; the view applies the
/// result via `.chartYScale(domain:)`.
enum PositionsChartYDomain {
  static func domain(
    values: [Decimal], baselines: [Decimal], paddingFraction: Double = 0.06
  ) -> ClosedRange<Double> {
    let all = (values + baselines).map { Double(truncating: $0 as NSNumber) }
    guard let lo = all.min(), let hi = all.max() else { return 0...1 }
    let span = hi - lo
    let pad = span > 0 ? span * paddingFraction : max(abs(hi) * paddingFraction, 1)
    return (lo - pad)...(hi + pad)
  }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `just test-mac PositionsChartYDomainTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Apply the domain in `PositionsChart.chartBody`**

In `Shared/Views/Positions/PositionsChart.swift`, inside `chartBody`'s non-empty branch, compute the domain from the resolved `rows` and apply it to the `Chart`. Add immediately above `.frame(height: 220)` (`:117`):

```swift
      .chartYScale(domain: PositionsChartYDomain.domain(
        values: rows.map(\.value),
        baselines: showBaseline ? rows.compactMap(\.baseline) : []))
      .frame(height: 220)
```

(`rows` is `[PositionsChartRenderRow]` already in scope from `PositionsChartBaselineResolver.resolve(...)`; `.value` is `Decimal` and `.baseline` is `Decimal?`.)

- [ ] **Step 6: Verify the chart in preview**

Use the `reviewing-ui-with-preview` skill: render `#Preview("Chart - aggregate")` and `#Preview("Chart - filtered to instrument")` in `PositionsChart.swift` via `mcp__xcode__RenderPreview`. Confirm the line now fills the vertical space and the Y-axis starts near the data floor, not `$0`. Confirm the empty-state (`#Preview("Chart - empty")`) is unaffected.

- [ ] **Step 7: Build, format, review**

Run: `just build-mac` (Expected: build succeeds, no new warnings), then `just format-check` (Expected: clean). Run `@ui-review` and `@code-review` on the two changed/created files; fix every finding and re-review until clean.

- [ ] **Step 8: Commit**

```bash
git -C . add Shared/Views/Positions/PositionsChartYDomain.swift Shared/Views/Positions/PositionsChart.swift MoolahTests/Views/Positions/PositionsChartYDomainTests.swift
git -C . commit -m "feat(positions): hug chart Y-axis to the data range"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 2: Inline sync-error caption in the header

The sync-error / missing-credential caption renders on its own row below the status row, even when there's empty horizontal space between the "open externally" link and the last-synced text. Move the caption **inline** into the status row when it fits, wrapping to its own row only when it doesn't.

**Files:**
- Modify: `Features/Sync/SyncedAccountHeaderView.swift` — `body` (`:124-152`) and `statusRow(_:)` (`:174-196`)
- Test (UI): `MoolahUITests_macOS/` — extend the existing wallet-header test suite (see `writing-ui-tests` skill; the header exposes `UITestIdentifiers.WalletAccountHeader.errorCaption`)

**Interfaces:**
- Consumes: existing `errorCaption: String?` (`:116`), `presentation.missingCredentialHint` (`:135`), `statusLeadingGroup`/`statusTrailingGroup` (`:201`, `:219`), `errorCaptionView(_:)` (`:278`), `missingCredentialHint(_:)` (`:243`).
- Produces: no new public surface — the caption keeps its `errorCaption`/`missingApiKeyHint` accessibility identifiers so existing tests and VoiceOver labels are preserved.

- [ ] **Step 1: Restructure `statusRow` to carry the caption inline, with a wrap fallback**

Replace the `ViewThatFits` body of `statusRow(_:)` so a `caption` view sits between the leading and trailing groups on the single-line branch, and drops to its own row on the stacked branch. Pass the resolved caption in:

```swift
  private func statusRow(_ presentation: SyncableAccountPresentation) -> some View {
    // The caption (missing-credential hint takes precedence over sync
    // error — same rule as `body`) rides inline in the status row's empty
    // middle when everything fits on one line; at cramped widths /
    // accessibility Dynamic Type it drops to its own row.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        statusLeadingGroup(presentation)
        inlineCaption(presentation)
        Spacer(minLength: 12)
        statusTrailingGroup(presentation)
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 12) {
          statusLeadingGroup(presentation)
          Spacer(minLength: 0)
        }
        HStack(spacing: 12) {
          statusTrailingGroup(presentation)
          Spacer(minLength: 0)
        }
        inlineCaption(presentation)
      }
    }
  }

  /// The missing-credential hint (precedence) or the sync-error caption,
  /// or `EmptyView` when neither applies. Reused in both `ViewThatFits`
  /// branches so the same element renders inline or wrapped.
  @ViewBuilder
  private func inlineCaption(_ presentation: SyncableAccountPresentation) -> some View {
    if let hint = presentation.missingCredentialHint {
      missingCredentialHint(hint)
    } else if let errorCaption {
      errorCaptionView(errorCaption)
    }
  }
```

- [ ] **Step 2: Remove the now-duplicated caption block from `body`**

In `body` (`:130-139`), delete the `if let hint = … missingCredentialHint … else if let errorCaption …` block — the caption now lives inside `statusRow`. `body`'s `VStack` becomes: `addressSection` (crypto only) then `statusRow(presentation)`.

- [ ] **Step 3: Guard `missingCredentialHint`'s trailing `Spacer`**

`missingCredentialHint(_:)` ends with `Spacer()` (`:271`) which will fight the inline `HStack` layout. Change that trailing `Spacer()` to `Spacer(minLength: 0)` so the hint hugs its content inline but still expands when it's on its own wrapped row. (`errorCaptionView` has no `Spacer`, so it's already inline-safe.)

- [ ] **Step 4: Build and verify in preview**

Run: `just build-mac` (Expected: succeeds). Then use `reviewing-ui-with-preview`: add/inspect a `#Preview` of `SyncedAccountHeaderView` with a wallet account whose `syncState.lastError` is set (mirrors the "Alchemy rate-limited" screenshot) at a wide window, and confirm the caption sits between the explorer link and "Synced …". Narrow the preview width and confirm it wraps to its own row without clipping. Iterate padding/spacing with the user in the canvas.

- [ ] **Step 5: UI test — caption is present and identified on a synced account with an error**

Using the `writing-ui-tests` skill, extend the wallet-header UI suite: seed a synced crypto account with a sync error, open its detail, and assert `UITestIdentifiers.WalletAccountHeader.errorCaption` exists (10s positive wait). This locks the caption's presence/identifier through the layout change. Run: `just test-ui <suite>` — Expected: PASS.

- [ ] **Step 6: Format and review**

Run: `just format-check` (Expected: clean). Run `@ui-review`, `@ui-test-review`, and `@code-review` on the changed files; fix every finding and re-review until clean.

- [ ] **Step 7: Commit**

```bash
git -C . add Features/Sync/SyncedAccountHeaderView.swift MoolahUITests_macOS
git -C . commit -m "feat(sync): fit sync-status caption inline in the header row"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 3: History series includes all instruments (total value / balance)

`PositionsHistoryBuilder.apply` excludes host-currency legs from `quantities` (`:243`), so a pure-fiat account produces an empty value series and a mixed fiat+crypto account under-reports its value by its cash balance. Include every instrument so the value line is a correct **total account value / balance-over-time** series. Cost-basis and contributions folding are unchanged (they already handle host-currency flows), so this must not alter existing investment cost/contribution lines.

**Files:**
- Modify: `Shared/PositionsHistoryBuilder.swift` — the leg loop at `:243` and its doc comment (`:226-229`)
- Test: `MoolahTests/Shared/PositionsHistoryBuilderAllInstrumentsTests.swift` (new suite; peers with the existing `PositionsHistoryBuilder*Tests.swift`)

**Interfaces:**
- Consumes: `PositionsHistoryBuilder.build(transactions:accountId:hostCurrency:range:now:)` (`:127`), `HistoricalValueSeries` (`total: [Point]`, each `Point(date:value:cost:contributions:)`). Test conversion via the existing test conversion-service fixture used by the sibling suites (see `PositionsHistoryBuilderTests.swift` for the established fixture/setup pattern — reuse it, don't invent a new one).
- Produces: unchanged public signature; behaviour change is additive (host-currency now contributes to `total.value` and gets a `perInstrument[hostCurrency.id]` series).

- [ ] **Step 1: Confirm host→host identity conversion**

Read `convertResultBatch` (search: `func convertResultBatch`) and confirm a request whose `amount.instrument == target` resolves to `.value(identity)` (not `.failure`). If it does NOT short-circuit identity, add that short-circuit as the first sub-step of Step 3 (a host→host request must yield the same amount, or the aggregate day would be dropped by `aggOK == false`). Note the finding in the commit body.

- [ ] **Step 2: Write the failing test — pure fiat account gets a balance line**

Model a single account denominated in host currency (e.g. AUD) with a couple of cash-in transactions; build a series and assert the `total` value line equals the running balance. Use the sibling suites' fixture/builder helpers.

```swift
import Testing
import Foundation
@testable import Moolah

@Suite struct PositionsHistoryBuilderAllInstrumentsTests {
  @Test func pureFiatAccountProducesRunningBalanceLine() async {
    // Arrange: one AUD account, +$1,000 then +$500 on consecutive days,
    // host currency AUD, identity conversion. (Reuse the fixture pattern
    // from PositionsHistoryBuilderTests.swift.)
    // Act: let series = await builder.build(transactions:accountId:hostCurrency: .AUD, range: .oneMonth, now:)
    // Assert: the last total point's value == 1_500; an earlier day == 1_000.
    #expect(Bool(true)) // replace with the fixture-backed assertions above
  }

  @Test func mixedFiatAndCryptoIncludesCashInTotal() async {
    // Arrange: AUD account holding both 8 ETH (priced) and $2,000 cash.
    // Assert: the terminal total == valueOf(8 ETH) + 2_000 (cash no longer dropped).
    #expect(Bool(true)) // replace with fixture-backed assertions
  }
}
```

Flesh both `#expect(Bool(true))` placeholders into real fixture-backed assertions using the sibling suite's helpers before running.

- [ ] **Step 3: Run the tests, verify they fail**

Run: `just test-mac PositionsHistoryBuilderAllInstrumentsTests`
Expected: FAIL — pure-fiat `total` is currently empty; mixed total omits the $2,000 cash.

- [ ] **Step 4: Include all instruments in the quantity fold**

In `Shared/PositionsHistoryBuilder.swift` change the leg loop (`:243`):

```swift
    for leg in accountLegs {
      state.quantities[leg.instrument, default: 0] += leg.quantity
    }
```

Update the doc comment (`:226-229`) to state that host-currency (cash) legs are now folded into `quantities` so the value line is total account value (cash + non-cash holdings), with cost basis still derived via `TradeEventClassifier`.

- [ ] **Step 5: Run the new tests, verify they pass**

Run: `just test-mac PositionsHistoryBuilderAllInstrumentsTests`
Expected: PASS.

- [ ] **Step 6: Run the full history-builder regression set**

Run: `just test-mac PositionsHistoryBuilder` and `just test-mac PositionsContributions`
Expected: PASS — existing investment cost/contribution behaviour is unchanged. If any sibling test now asserts the *old* "cash excluded" value, update it to the correct total-value expectation and note the intentional behaviour change in the commit body. Investigate (don't blanket-update) any contribution-line change — contributions must be unaffected.

- [ ] **Step 7: Format and review**

Run: `just format-check` (Expected: clean). Run `@instrument-conversion-review`, `@code-review`, and `@datetime-review` on the changed file; fix every finding and re-review until clean.

- [ ] **Step 8: Commit**

```bash
git -C . add Shared/PositionsHistoryBuilder.swift MoolahTests/Shared/PositionsHistoryBuilderAllInstrumentsTests.swift
git -C . commit -m "feat(positions): value history includes cash for a correct total-value line"
```

Then open a PR and land via the `landing-prs` skill.

---

## Increment 2–4 (outline — detailed plan authored after Increment 1 lands)

These depend on the denser chart and the all-instrument series being validated in a real build, so they are outlined here and turned into their own bite-sized plan next:

- **Increment 2 — Unified tab/split container + relaxed gate.** Rework `PositionsTransactionsSplit` (or a successor) to take three content builders (transactions, positions, chart+performance). iOS: data-driven segmented tabs `[Transactions | Positions | Chart]` (Positions present only when there are non-host holdings; default Transactions). Mac: `ResizableVSplit` with positions pinned on top and a `[Transactions | Chart]` toggle (default Transactions) in the bottom pane, under a **fresh autosave key** and right-sized presets. Relax `PositionsViewInput.shouldHide` so it gates only the Positions element, not the whole surface — chart + transactions always show. Apply to crypto / exchange / standard / group via `MultiInstrumentPositionsSplitModifier`. (`ui-review`, `ui-test-review`.)
- **Increment 3 — Performance tiles for every account type.** Drive `AccountPerformanceCalculator.compute(...)` in the unified path (thread the result into `PositionsAssemblyContext.performance`, as `InvestmentStore` already does); tiles hide per-field when data (e.g. cost basis) is absent. (`instrument-conversion-review`, `concurrency-review`.)
- **Increment 4 — Fold in investment + delete redundant views.** Route `.calculatedFromTrades` investment accounts through the shared container; then delete `CryptoWalletAccountView`, `ExchangeAccountView`, `StandardAccountView`, `GroupDetailView`, and the folded investment branch. `.recordedValue` accounts are out of scope (deprecated).

---

## Self-Review

- **Spec coverage:** Chart density → Task 1. Header inline → Task 2. All-instrument history → Task 3. Structure / tabs / Mac split / relaxed gate → Increment 2 (outlined). Perf tiles for all → Increment 3 (outlined). Dedup/delete → Increment 4 (outlined). Recorded-value out of scope → noted. ✓
- **Placeholder scan:** Task 3's test bodies are intentionally fixture-backed stubs with an explicit "flesh out before running" instruction (the sibling-suite fixture is the source of truth for the exact helper API, which the implementer reads at execution time) — every other step carries complete code. ✓
- **Type consistency:** `PositionsChartYDomain.domain(values:baselines:paddingFraction:)` defined in Task 1 and used with `rows.map(\.value)` / `rows.compactMap(\.baseline)` matching `PositionsChartRenderRow` (`value: Decimal`, `baseline: Decimal?`). `inlineCaption(_:)` reuses existing `errorCaptionView`/`missingCredentialHint`. Task 3 keeps `build(...)` signature. ✓
