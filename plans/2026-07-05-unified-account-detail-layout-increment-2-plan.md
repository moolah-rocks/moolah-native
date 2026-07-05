# Unified Account-Detail Layout — Increment 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the positions/transactions container into the unified, data-driven account-detail structure for the crypto / exchange / standard / group account paths: iOS segmented tabs `[Transactions | Chart]` (Transactions first + default), inserting a `Positions` tab (→ `[Transactions | Positions | Chart]`) only when the account has non-host-currency holdings; macOS `ResizableVSplit` with the positions table **pinned** in the top pane and a `[Transactions | Chart]` toggle (default Transactions) in the resizable bottom pane, collapsing to a single toggle pane when there are no positions. Performance tiles + the account total ride at the top of the Chart tab / companion pane. Relax the surface gate so **chart + transactions always show** and only the Positions element is gated. Investment (`.calculatedFromTrades`) and recorded-value accounts are untouched.

**Architecture:** Incremental. This plan fully specifies **Increment 2** — five independent, individually-shippable PRs. It builds on Increment 1 (denser chart, inline sync-error caption, all-instrument value/balance history), which is already implemented on this branch and is treated as present. Increment 3 (performance-tile data for non-investment accounts) and Increment 4 (fold investment in + delete redundant per-type views) get their own plans; this increment leaves the performance slot rendering only when `input.performance != nil` (which stays `nil` for these accounts until Increment 3) and keeps the legacy investment container path backward-compatible.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, Swift Testing (`@Suite`/`@Test`), XCUITest (`MoolahUITests_macOS`), GRDB (unaffected here). Design spec: `plans/2026-07-05-unified-account-detail-layout-design.md`. Increment 1 plan: `plans/2026-07-05-unified-account-detail-layout-plan.md`.

## Global Constraints

- Tests use **Swift Testing** (`@Suite`, `@Test`, `#expect`), not XCTest, except UI tests under `MoolahUITests_macOS/` (XCUITest — those import **only** `XCTest`, drive the app through screen drivers, use 10s positive waits and deterministic seeds).
- One extension per protocol conformance; thin views (logic lives in testable helpers) — `guides/AI_ARCHITECTURE_GUIDE.md`.
- Money math via `InstrumentAmount`; never `abs()` a signed leg or P&L — `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
- Timezoneless calendar values via `Calendar.utc`; chart x-tokens anchor at noon-UTC — `guides/DATE_TIME_GUIDE.md`.
- `just` test filters are **positional**, not `FILTER=` — e.g. `just test-mac AccountDetailLayoutTests`, `just test-ui AccountDetailSplitTests`.
- Run `just format-check` after every task; fix all findings. Run the relevant AI reviewer agents (`@ui-review`, `@code-review`, `@ui-test-review`) before committing and fix every finding — `guides/AI_REVIEW_GATE_GUIDE.md`.
- Each task = one PR, landed via the `landing-prs` skill. Never `git push origin main`.
- Test wait helpers default to 10s; never pass short positive timeouts — memory `feedback_test_wait_timeouts_10s`.

## File Structure

**Created:**
- `Shared/Views/Positions/AccountDetailLayout.swift` — `AccountDetailTab` enum + `AccountDetailLayout` pure decision namespace (iOS tab order, macOS pinned-positions predicate, `hasNonHostHoldings`). No view or actor state — unit-testable in isolation. (Task 1)
- `Shared/Views/Positions/PositionsChartPane.swift` — `PositionsChartPane`: the "performance/total header + chart" group extracted from `PositionsView`. Renders `AccountPerformanceTiles` (when `input.performance != nil`) else `PositionsHeader`, followed by `PositionsChart` (or its loading placeholder). The Increment-3 performance slot is this view's top element. (Task 2)
- `Shared/Views/Positions/PositionsPane.swift` — `PositionsPane`: a lightweight `PositionsHeader` (title + total) above `PositionsTable`. The macOS pinned top pane / iOS Positions tab. (Task 2)
- `Shared/Views/Positions/PositionsChartTransactionsSplit.swift` — `PositionsChartTransactionsSplit`, the three-builder successor container (transactions / positions / chart). Renders the iOS data-driven tabs and the macOS pinned-split-or-single-pane using `AccountDetailLayout`, under a fresh autosave key. (Task 3)
- `MoolahTests/Views/Positions/AccountDetailLayoutTests.swift` — unit tests for the pure helpers. (Task 1)
- `UITestSupport/UITestIdentifiers+AccountDetail.swift` — identifier namespace for the container's panes + tab picker. (Task 5)
- `App/UITestSeedHydrator+AccountDetailLayout.swift` — hydrator for the `.accountDetailLayout` seed (one multi-currency account + one fiat-only account). (Task 5)
- `MoolahUITests_macOS/Helpers/Screens/AccountDetailScreen.swift` — screen driver for the container. (Task 5)
- `MoolahUITests_macOS/Tests/AccountDetailSplitTests.swift` — macOS UI tests (pinned split for multi-instrument, single pane for fiat-only, toggle defaults to Transactions). (Task 5)

**Modified:**
- `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift` — delegate the decision helper (Task 1); rework the body to **always** wrap in `PositionsChartTransactionsSplit`, gate only the Positions pane, hoist the shared `selection`, and always run the valuator task (Task 4).
- `Shared/Views/Positions/PositionsView.swift` — recompose from `PositionsChartPane` + `PositionsTable` (behaviour-preserving refactor; keeps the investment path identical). (Task 2)
- `UITestSupport/UITestSeed.swift` — add the `.accountDetailLayout` case. (Task 5)
- `UITestSupport/UITestFixtures.swift` — add `AccountDetailLayout` fixture UUIDs. (Task 5)
- `MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift` — add `.multiCurrency` / `.everydayFiat` `SidebarAccount` cases. (Task 5)
- `MoolahUITests_macOS/Helpers/MoolahApp.swift` — add the `accountDetail` screen accessor. (Task 5)
- `MoolahTests/Features/Transactions/MultiInstrumentSplitShouldShowTests.swift` — repoint the migrated assertions at the renamed helper. (Task 4)

**NOT touched (backward-compatibility invariants):**
- `Shared/Views/Positions/PositionsTransactionsSplit.swift` — the legacy two-builder container stays as-is for `InvestmentAccountView.positionTrackedLayout` (autosave `positions-transactions-split.with-chart`). Increment 4 migrates investment onto the new container and can then delete this file.
- `Features/Investments/Views/InvestmentAccountView.swift`, and any `.recordedValue` path — out of scope.
- The four call sites (`CryptoWalletAccountView`, `ExchangeAccountView`, `StandardAccountView`, `GroupDetailView`) call `.multiInstrumentPositionsSplit(...)` with an unchanged signature, so **no call-site edits are required** — Task 4 verifies this.

## Key decisions (locked)

- **`PositionsView` decomposition:** extract the *top group* (`AccountPerformanceTiles` OR `PositionsHeader`, then `PositionsChart`/placeholder) into `PositionsChartPane`, and the header+table into `PositionsPane`. `PositionsView` is recomposed as `PositionsChartPane` + `Divider` + `PositionsTable` — **byte-for-byte the same rendered tree** as today, so the investment path (which uses `PositionsView` directly) is unchanged. The new container reuses `PositionsChartPane` for the Chart tab and `PositionsPane` for the Positions tab.
- **Fresh macOS autosave key:** `"account-detail.positions-pinned-split"` — distinct from the legacy chartless `"positions-transactions-split"` and the investment `"positions-transactions-split.with-chart"` so no user inherits a stale divider. Presets: `initialTopHeight: 260`, `minTopHeight: 120`, `minBottomHeight: 320` (the bottom pane must fit the ~280pt chart), tuned in `#Preview` during Task 3.
- **Perf-tile host:** the perf tiles + account total live at the top of `PositionsChartPane` — i.e. the top of the Chart tab (iOS) / Chart companion in the bottom toggle pane (Mac). In Increment 2 `input.performance` is `nil` for these accounts, so the tiles slot degrades to `PositionsHeader` (title + total). Increment 3 populates `performance` and the tiles appear with no further layout change.
- **Selection preserved across the tab split:** `PositionSelection` is hoisted to `@State` on `MultiInstrumentPositionsSplitModifier` and passed as a `Binding` into **both** `PositionsPane` (table taps set it) and `PositionsChartPane` (chart reads it to filter). `.onExitCommand` (macOS) and `.onChange(of: positionsInput)` clear it, matching `PositionsView`'s current behaviour.
- **Gate relaxation:** the whole-surface hide is removed. The modifier now **always** renders the container (so chart + transactions always show); the Positions tab/pinned pane is the only thing gated, on `AccountDetailLayout.hasNonHostHoldings(...)` (the repurposed old `shouldShow`). `PositionsViewInput.shouldHide` keeps its meaning (positions-list-redundant) and is still consulted **only** by the (untouched) `PositionsView.rendersNothing` for the investment path.
- **No perpetual spinner:** when there is nothing to valuate (no conversion service or empty positions), the modifier seeds an *empty* `PositionsViewInput` instead of leaving `positionsInput == nil`, so the always-present Chart tab settles to a header rather than an endless `ProgressView`.

---

## Task 1: Pure account-detail layout decision helpers

Layout/structure isn't unit-testable, but the **decisions** driving it are. Extract them into a pure `AccountDetailLayout` namespace: which iOS tabs render, whether macOS pins a positions pane, and whether the account has non-host holdings. Delegate the modifier's existing `shouldShow` to the new `hasNonHostHoldings` so there is one source of truth (and repoint it fully in Task 4).

**Files:**
- Create: `Shared/Views/Positions/AccountDetailLayout.swift`
- Create: `MoolahTests/Views/Positions/AccountDetailLayoutTests.swift`
- Modify: `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift` (make `shouldShow` a one-line delegate)

**Interfaces produced:**
- `enum AccountDetailTab: Hashable { case transactions, positions, chart }`
- `enum AccountDetailLayout` with `static func iOSTabs(hasPositions: Bool) -> [AccountDetailTab]`, `static let macBottomTabs: [AccountDetailTab]`, `static func macShowsPinnedPositions(hasPositions: Bool) -> Bool`, and `static func hasNonHostHoldings(rawPositions: [Position], hostCurrency: Instrument, positionsInput: PositionsViewInput?) -> Bool`.

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Views/Positions/AccountDetailLayoutTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountDetailLayout")
struct AccountDetailLayoutTests {
  let aud = Instrument.AUD
  let usd = Instrument.USD

  // MARK: - iOS tab presence / order

  @Test("fiat-only account shows Transactions then Chart, no Positions")
  func fiatOnlyTabs() {
    #expect(AccountDetailLayout.iOSTabs(hasPositions: false) == [.transactions, .chart])
  }

  @Test("multi-instrument account inserts Positions between Transactions and Chart")
  func multiInstrumentTabs() {
    #expect(
      AccountDetailLayout.iOSTabs(hasPositions: true) == [.transactions, .positions, .chart])
  }

  @Test("Transactions is always the first tab (the default selection)")
  func transactionsFirst() {
    #expect(AccountDetailLayout.iOSTabs(hasPositions: false).first == .transactions)
    #expect(AccountDetailLayout.iOSTabs(hasPositions: true).first == .transactions)
  }

  // MARK: - macOS layout shape

  @Test("macOS bottom pane toggle is always Transactions then Chart")
  func macBottomTabsStable() {
    #expect(AccountDetailLayout.macBottomTabs == [.transactions, .chart])
  }

  @Test("macOS pins a positions pane only when there are holdings")
  func macPinnedPositions() {
    #expect(AccountDetailLayout.macShowsPinnedPositions(hasPositions: true))
    #expect(!AccountDetailLayout.macShowsPinnedPositions(hasPositions: false))
  }

  // MARK: - hasNonHostHoldings (authoritative post-valuation)

  @Test("valuated input with a non-host row has holdings")
  func inputWithNonHostRow() {
    let input = PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 1_000, instrument: aud)),
        ValuedPosition(
          instrument: usd, quantity: 200, unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 304, instrument: aud)),
      ],
      historicalValue: nil)
    #expect(
      AccountDetailLayout.hasNonHostHoldings(
        rawPositions: [], hostCurrency: aud, positionsInput: input))
  }

  @Test("valuated host-only input has no holdings")
  func inputHostOnly() {
    let input = PositionsViewInput(
      title: "Everyday",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 1_000, instrument: aud))
      ],
      historicalValue: nil)
    #expect(
      !AccountDetailLayout.hasNonHostHoldings(
        rawPositions: [], hostCurrency: aud, positionsInput: input))
  }

  // MARK: - hasNonHostHoldings (pre-valuation raw heuristic)

  @Test("pre-valuation: multi-instrument raw positions have holdings")
  func rawMultiInstrument() {
    #expect(
      AccountDetailLayout.hasNonHostHoldings(
        rawPositions: [
          Position(instrument: aud, quantity: 1_000),
          Position(instrument: usd, quantity: 200),
        ],
        hostCurrency: aud, positionsInput: nil))
  }

  @Test("pre-valuation: host-only, empty, and zero-qty raw positions have no holdings")
  func rawNoHoldings() {
    #expect(
      !AccountDetailLayout.hasNonHostHoldings(
        rawPositions: [Position(instrument: aud, quantity: 1_000)],
        hostCurrency: aud, positionsInput: nil))
    #expect(
      !AccountDetailLayout.hasNonHostHoldings(
        rawPositions: [], hostCurrency: aud, positionsInput: nil))
    #expect(
      !AccountDetailLayout.hasNonHostHoldings(
        rawPositions: [
          Position(instrument: aud, quantity: 1_000),
          Position(instrument: usd, quantity: 0),
        ],
        hostCurrency: aud, positionsInput: nil))
  }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `just test-mac AccountDetailLayoutTests`
Expected: FAIL — `AccountDetailLayout` / `AccountDetailTab` are not defined.

- [ ] **Step 3: Implement `AccountDetailLayout`**

Create `Shared/Views/Positions/AccountDetailLayout.swift`:

```swift
import Foundation

/// The three surfaces the unified account-detail screen can present. On
/// iOS these are segmented tabs; on macOS `.positions` is the pinned top
/// pane and `.transactions` / `.chart` are the resizable bottom pane's
/// toggle.
enum AccountDetailTab: Hashable {
  case transactions
  case positions
  case chart
}

/// Pure, data-driven layout decisions for `PositionsChartTransactionsSplit`.
/// Kept free of any view or actor state so the tab / pane rules are
/// unit-testable in isolation and callable from both `@MainActor` views
/// and synchronous tests.
enum AccountDetailLayout {
  /// iOS segmented-tab order. Transactions is always first (and the
  /// default selection); Chart is always last; Positions is inserted
  /// between them only when the account has non-host-currency holdings.
  static func iOSTabs(hasPositions: Bool) -> [AccountDetailTab] {
    hasPositions ? [.transactions, .positions, .chart] : [.transactions, .chart]
  }

  /// The macOS bottom-pane toggle is always `[Transactions | Chart]`,
  /// independent of holdings — the positions table, when present, is the
  /// pinned top pane rather than a bottom-pane tab.
  static let macBottomTabs: [AccountDetailTab] = [.transactions, .chart]

  /// Whether the macOS layout pins a positions table above the resizable
  /// `[Transactions | Chart]` pane. `false` → a single full-height pane
  /// carrying just the toggle.
  static func macShowsPinnedPositions(hasPositions: Bool) -> Bool { hasPositions }

  /// Whether the account has holdings worth surfacing in a positions
  /// table — at least one non-zero position in an instrument other than
  /// the host currency. Drives Positions-tab / pinned-pane presence only;
  /// the chart and transactions render unconditionally.
  ///
  /// Once the valuator has produced a `positionsInput` it is
  /// authoritative — its `shouldHide` has already dropped `.knownZero`
  /// (`.spam` / `.unpriced`) rows, so it agrees with what the positions
  /// table will actually render. Pre-valuation, fall back to a raw
  /// heuristic so the Positions tab can render with a spinner.
  static func hasNonHostHoldings(
    rawPositions: [Position],
    hostCurrency: Instrument,
    positionsInput: PositionsViewInput?
  ) -> Bool {
    if let positionsInput {
      return !positionsInput.shouldHide
    }
    guard !rawPositions.isEmpty else { return false }
    let nonZeroInstruments = Set(
      rawPositions.lazy.filter { $0.quantity != 0 }.map(\.instrument))
    return nonZeroInstruments != [hostCurrency]
  }
}
```

- [ ] **Step 4: Delegate the modifier's `shouldShow` to the new helper**

In `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`, replace the **body** of the existing `nonisolated static func shouldShow(rawPositions:hostCurrency:positionsInput:)` with a one-line delegate (keep the signature and the doc comment for now — Task 4 removes the shim):

```swift
  nonisolated static func shouldShow(
    rawPositions: [Position],
    hostCurrency: Instrument,
    positionsInput: PositionsViewInput?
  ) -> Bool {
    AccountDetailLayout.hasNonHostHoldings(
      rawPositions: rawPositions,
      hostCurrency: hostCurrency,
      positionsInput: positionsInput)
  }
```

- [ ] **Step 5: Run the tests, verify they pass**

Run: `just test-mac AccountDetailLayoutTests` (Expected: PASS) and `just test-mac MultiInstrumentSplitShouldShowTests` (Expected: PASS — the delegate is behaviour-identical).

- [ ] **Step 6: Build, format, review**

Run: `just build-mac` (Expected: succeeds, no new warnings), then `just format-check` (Expected: clean). Run `@code-review` on the created + modified files; fix every finding and re-review until clean.

- [ ] **Step 7: Commit**

```bash
git -C . add Shared/Views/Positions/AccountDetailLayout.swift MoolahTests/Views/Positions/AccountDetailLayoutTests.swift Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift
git -C . commit -m "feat(positions): pure account-detail tab/pane layout decisions"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 2: Decompose `PositionsView` into chart-pane and positions-pane

Split `PositionsView`'s single stacked surface into two reusable halves so the new container can host the chart and the positions table in different tabs/panes. This is a **behaviour-preserving refactor**: `PositionsView` recomposes to the identical rendered tree, so the investment path that renders `PositionsView` directly is unchanged.

**Files:**
- Create: `Shared/Views/Positions/PositionsChartPane.swift`
- Create: `Shared/Views/Positions/PositionsPane.swift`
- Modify: `Shared/Views/Positions/PositionsView.swift` (`body` at `:19-57`)

**Interfaces produced:**
- `struct PositionsChartPane: View { let input: PositionsViewInput; @Binding var range: PositionsTimeRange; @Binding var selection: PositionSelection? }` — renders `AccountPerformanceTiles` (when `input.performance != nil`) else `PositionsHeader`, then `PositionsChart` (gated on `input.showsChart`) or the loading placeholder (gated on `input.showsChartLoadingPlaceholder`).
- `struct PositionsPane: View { let input: PositionsViewInput; @Binding var selection: PositionSelection? }` — `PositionsHeader` + `Divider` + `PositionsTable`.

- [ ] **Step 1: Extract `PositionsChartPane`**

Create `Shared/Views/Positions/PositionsChartPane.swift`, lifting the top group from `PositionsView.body` verbatim:

```swift
import SwiftUI

/// The "performance / total header + value chart" group of the account-detail
/// surface. Renders `AccountPerformanceTiles` when the input carries
/// account-level `performance` (investments today; every account type after
/// Increment 3), otherwise the single-row `PositionsHeader` (title + total).
/// Below the header sits `PositionsChart`, or its fixed-footprint loading
/// placeholder while the historical series is still being assembled.
///
/// Hosted at the top of the Chart tab (iOS) / the Chart companion in the
/// resizable bottom pane (macOS) by `PositionsChartTransactionsSplit`, and
/// reused as the top group of `PositionsView` for the investment path.
///
/// `selection` is a binding (not local state) so a position-row tap in a
/// sibling pane filters this chart to that asset. `PositionsChart` reads it;
/// the owner clears it on Escape / input change.
struct PositionsChartPane: View {
  let input: PositionsViewInput
  @Binding var range: PositionsTimeRange
  @Binding var selection: PositionSelection?

  var body: some View {
    VStack(spacing: 0) {
      if let performance = input.performance {
        AccountPerformanceTiles(title: input.title, performance: performance)
      } else {
        PositionsHeader(input: input)
      }
      if input.showsChart {
        Divider()
        PositionsChart(input: input, range: $range, selection: $selection)
          .padding(.vertical, 8)
      } else if input.showsChartLoadingPlaceholder {
        Divider()
        // Matches PositionsChart's footprint (header + 220pt chartBody +
        // rangePicker, plus this container's own vertical padding) so
        // swapping placeholder -> chart doesn't jump the content below it.
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 280)
          .padding(.vertical, 8)
          .accessibilityLabel("Loading chart")
      }
    }
  }
}

#Preview("Chart pane — with chart") {
  PositionsChartPane(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP"),
          quantity: 100, unitPrice: nil,
          costBasis: InstrumentAmount(quantity: 9_500, instrument: .AUD),
          value: InstrumentAmount(quantity: 10_200, instrument: .AUD))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: .AUD,
        total: (0..<30).map { offset in
          HistoricalValueSeries.Point(
            date: Calendar(identifier: .gregorian)
              .date(byAdding: .day, value: -29 + offset, to: Date()) ?? Date(),
            value: 9_800 + Decimal(offset) * 15, cost: 9_500, contributions: nil)
        },
        perInstrument: [:])),
    range: .constant(.oneMonth),
    selection: .constant(nil)
  )
  .frame(width: 640, height: 360)
}
```

- [ ] **Step 2: Extract `PositionsPane`**

Create `Shared/Views/Positions/PositionsPane.swift`:

```swift
import SwiftUI

/// The lightweight positions surface: a title + total header above the
/// responsive positions table. Hosted as the iOS `Positions` tab and the
/// macOS pinned top pane by `PositionsChartTransactionsSplit`.
///
/// Deliberately excludes the chart and performance tiles — those ride at
/// the top of the Chart tab / companion pane so this list stays
/// uncluttered (design §"Where performance + total live").
///
/// `selection` is a binding: tapping a row sets it, filtering the sibling
/// chart pane; the owner clears it on Escape / input change.
struct PositionsPane: View {
  let input: PositionsViewInput
  @Binding var selection: PositionSelection?

  var body: some View {
    VStack(spacing: 0) {
      PositionsHeader(input: input)
      Divider()
      PositionsTable(input: input, selection: $selection)
    }
  }
}

#Preview("Positions pane") {
  PositionsPane(
    input: PositionsViewInput(
      title: "Multi-currency",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: .USD, quantity: 250, unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 380, instrument: .AUD)),
        ValuedPosition(
          instrument: .AUD, quantity: 1_000, unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 1_000, instrument: .AUD)),
      ],
      historicalValue: nil),
    selection: .constant(nil)
  )
  .frame(width: 480, height: 320)
}
```

- [ ] **Step 3: Recompose `PositionsView` to use `PositionsChartPane` + `PositionsTable`**

In `Shared/Views/Positions/PositionsView.swift`, replace the `else` branch's `VStack` (`:23-49`) so the top group delegates to `PositionsChartPane` while the table stays inline — producing the same tree as before:

```swift
      VStack(spacing: 0) {
        PositionsChartPane(input: input, range: $range, selection: $selection)
        Divider()
        PositionsTable(input: input, selection: $selection)
      }
```

Leave the `if input.rendersNothing { EmptyView() }` guard, `.onExitCommand`, and `.onChange(of: input)` exactly as they are. (The recomposed `PositionsView` renders `PositionsChartPane` = header/tiles + chart, then `Divider`, then `PositionsTable` — identical to the pre-refactor header + chart + divider + table.)

- [ ] **Step 4: Build and verify preview parity**

Run: `just build-mac` (Expected: succeeds). Then use the `reviewing-ui-with-preview` skill to render `PositionsView.swift`'s existing `#Preview("With chart")`, `#Preview("With performance tiles")`, and `#Preview("Chart loading placeholder")` and confirm each is visually unchanged from before the refactor (same header/tiles, chart, table stack). Render the two new pane previews and confirm each half renders standalone.

- [ ] **Step 5: Run the positions regression set**

Run: `just test-mac PositionsViewInput` and `just test-mac PositionsAssembler`
Expected: PASS — the refactor changes no input logic or assembly.

- [ ] **Step 6: Format and review**

Run: `just format-check` (Expected: clean). Run `@ui-review` and `@code-review` on the three files; fix every finding and re-review until clean.

- [ ] **Step 7: Commit**

```bash
git -C . add Shared/Views/Positions/PositionsChartPane.swift Shared/Views/Positions/PositionsPane.swift Shared/Views/Positions/PositionsView.swift
git -C . commit -m "refactor(positions): split PositionsView into chart-pane and positions-pane"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 3: The three-builder `PositionsChartTransactionsSplit` container

Build the successor container that renders the unified structure from three content builders and the `AccountDetailLayout` decisions: iOS data-driven tabs; macOS pinned-positions split (or single toggle pane when fiat-only). Not yet wired to any call site — shippable as tested, previewable scaffolding.

**Files:**
- Create: `Shared/Views/Positions/PositionsChartTransactionsSplit.swift`

**Interfaces produced:**
- `struct PositionsChartTransactionsSplit<Transactions: View, Positions: View, Chart: View>: View` with `init(hasPositions: Bool, autosaveName: String = "account-detail.positions-pinned-split", initialTopHeight: CGFloat = 260, @ViewBuilder transactions:, @ViewBuilder positions:, @ViewBuilder chart:)`.
- Applies `.accessibilityIdentifier(UITestIdentifiers.AccountDetail.positionsPane)` to the positions content and `.chartPane` to the chart content; `.accessibilityIdentifier(...tabPicker)` to the segmented picker. (These identifiers land in Task 5; this task references them, so it depends on Task 5's identifier file OR introduces the identifiers here — see Step 1 note.)

> **Sequencing note:** the identifier namespace `UITestIdentifiers.AccountDetail` is created in Task 5. To keep this task self-contained and shippable, **create `UITestSupport/UITestIdentifiers+AccountDetail.swift` as part of this task** (moved out of Task 5's file list below) with the three constants, and have Task 5 only add the seed/driver/tests. The identifier file is tiny and load-bearing here.

- [ ] **Step 1: Create the identifier namespace**

Create `UITestSupport/UITestIdentifiers+AccountDetail.swift`:

```swift
import Foundation

extension UITestIdentifiers {
  /// Identifier namespace for `PositionsChartTransactionsSplit`, the
  /// unified account-detail container (crypto / exchange / standard /
  /// group accounts).
  public enum AccountDetail {
    /// The positions surface — iOS `Positions` tab / macOS pinned top
    /// pane. Absent for fiat-only accounts (no non-host holdings).
    public static let positionsPane = "accountDetail.positionsPane"

    /// The chart + performance surface — iOS `Chart` tab / macOS Chart
    /// companion in the bottom toggle pane.
    public static let chartPane = "accountDetail.chartPane"

    /// The segmented tab picker (iOS full tab set / macOS bottom-pane
    /// `[Transactions | Chart]` toggle).
    public static let tabPicker = "accountDetail.tabPicker"
  }
}
```

- [ ] **Step 2: Implement the container**

Create `Shared/Views/Positions/PositionsChartTransactionsSplit.swift`:

```swift
import SwiftUI

/// The unified account-detail container for crypto / exchange / standard /
/// group accounts. Presents three data-driven surfaces from three content
/// builders:
///   - **Transactions** — always present, the default selection.
///   - **Positions** — only when `hasPositions` (non-host holdings).
///   - **Chart** — always present (perf tiles + total + value chart).
///
/// **iOS:** a segmented `Picker` over `AccountDetailLayout.iOSTabs`
/// (`[Transactions | Chart]`, inserting `Positions` between them when
/// `hasPositions`). Transactions is first and default.
///
/// **macOS:** when `hasPositions`, a `ResizableVSplit` with the positions
/// table pinned in the top pane and a `[Transactions | Chart]` toggle
/// (default Transactions) in the resizable bottom pane. When fiat-only, no
/// split — a single full-height pane carrying just the toggle. The divider
/// autosaves under a key distinct from the legacy chartless and the
/// investment split keys so no user inherits a stale divider.
struct PositionsChartTransactionsSplit<Transactions: View, Positions: View, Chart: View>: View {
  let hasPositions: Bool
  let autosaveName: String
  let initialTopHeight: CGFloat
  @ViewBuilder let transactions: () -> Transactions
  @ViewBuilder let positions: () -> Positions
  @ViewBuilder let chart: () -> Chart

  #if os(macOS)
    @State private var bottomTab: AccountDetailTab = .transactions
    @State private var scrollCollapse = TransactionScrollCollapse()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
  #else
    @State private var selectedTab: AccountDetailTab = .transactions
  #endif

  init(
    hasPositions: Bool,
    autosaveName: String = "account-detail.positions-pinned-split",
    initialTopHeight: CGFloat = 260,
    @ViewBuilder transactions: @escaping () -> Transactions,
    @ViewBuilder positions: @escaping () -> Positions,
    @ViewBuilder chart: @escaping () -> Chart
  ) {
    self.hasPositions = hasPositions
    self.autosaveName = autosaveName
    self.initialTopHeight = initialTopHeight
    self.transactions = transactions
    self.positions = positions
    self.chart = chart
  }

  var body: some View {
    #if os(macOS)
      macBody
    #else
      iOSBody
    #endif
  }

  // MARK: - iOS

  #if !os(macOS)
    private var iOSBody: some View {
      let tabs = AccountDetailLayout.iOSTabs(hasPositions: hasPositions)
      return VStack(spacing: 0) {
        Picker("Show", selection: $selectedTab) {
          ForEach(tabs, id: \.self) { tab in
            Text(label(for: tab)).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(UITestIdentifiers.AccountDetail.tabPicker)
        .padding(.horizontal)
        .padding(.vertical, 8)

        Divider()

        selectedContent
      }
      // If holdings disappear (e.g. the last non-host position is sold or
      // flagged spam) while the Positions tab is selected, fall back to
      // Transactions so the picker never points at a removed tab.
      .onChange(of: hasPositions) { _, nowHasPositions in
        if !nowHasPositions, selectedTab == .positions {
          selectedTab = .transactions
        }
      }
    }

    @ViewBuilder private var selectedContent: some View {
      switch selectedTab {
      case .transactions: transactions()
      case .positions: positionsPane
      case .chart: chartPane
      }
    }
  #endif

  // MARK: - macOS

  #if os(macOS)
    @ViewBuilder private var macBody: some View {
      if AccountDetailLayout.macShowsPinnedPositions(hasPositions: hasPositions) {
        ResizableVSplit(
          autosaveName: autosaveName,
          initialTopHeight: initialTopHeight,
          minTopHeight: 120,
          minBottomHeight: 320,
          collapsed: scrollCollapse.isCollapsed,
          reduceMotion: reduceMotion
        ) {
          positionsPane
        } bottom: {
          bottomToggle
        }
      } else {
        bottomToggle
      }
    }

    private var bottomToggle: some View {
      VStack(spacing: 0) {
        Picker("Show", selection: $bottomTab) {
          ForEach(AccountDetailLayout.macBottomTabs, id: \.self) { tab in
            Text(label(for: tab)).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(UITestIdentifiers.AccountDetail.tabPicker)
        .padding(.horizontal)
        .padding(.vertical, 8)

        Divider()

        switch bottomTab {
        case .transactions:
          transactions()
            .environment(\.transactionScrollCollapse, scrollCollapse)
        case .chart:
          chartPane
        case .positions:
          // Not reachable — the bottom toggle only offers Transactions /
          // Chart; positions is the pinned top pane.
          EmptyView()
        }
      }
    }
  #endif

  // MARK: - Shared pane wrappers

  private var positionsPane: some View {
    positions()
      .accessibilityIdentifier(UITestIdentifiers.AccountDetail.positionsPane)
  }

  private var chartPane: some View {
    chart()
      .accessibilityIdentifier(UITestIdentifiers.AccountDetail.chartPane)
  }

  private func label(for tab: AccountDetailTab) -> String {
    switch tab {
    case .transactions: return "Transactions"
    case .positions: return "Positions"
    case .chart: return "Chart"
    }
  }
}

#Preview("Multi-instrument — pinned split / 3 tabs") {
  PositionsChartTransactionsSplit(hasPositions: true) {
    Color.green.opacity(0.15).overlay(Text("Transactions"))
  } positions: {
    Color.blue.opacity(0.15).overlay(Text("Positions"))
  } chart: {
    Color.orange.opacity(0.15).overlay(Text("Chart + performance"))
  }
  .frame(width: 520, height: 620)
}

#Preview("Fiat-only — single pane / 2 tabs") {
  PositionsChartTransactionsSplit(hasPositions: false) {
    Color.green.opacity(0.15).overlay(Text("Transactions"))
  } positions: {
    Color.blue.opacity(0.15).overlay(Text("Positions"))
  } chart: {
    Color.orange.opacity(0.15).overlay(Text("Chart + performance"))
  }
  .frame(width: 520, height: 620)
}
```

- [ ] **Step 3: Build and tune presets in preview**

Run: `just build-mac` (Expected: succeeds). Use `reviewing-ui-with-preview` on both `#Preview`s. Confirm: the multi-instrument preview shows the pinned "Positions" pane on top and a `[Transactions | Chart]` toggle beneath defaulting to "Transactions"; toggling to "Chart" shows the chart placeholder without the ~280pt content clipping (adjust `initialTopHeight` / `minBottomHeight` here if it does). Confirm the fiat-only preview shows a single pane with just the toggle. Confirm iOS previews (switch canvas device) show 3 vs 2 segments with Transactions selected.

- [ ] **Step 4: Format and review**

Run: `just format-check` (Expected: clean). Run `@ui-review` and `@code-review` on the two created files; fix every finding and re-review until clean.

- [ ] **Step 5: Commit**

```bash
git -C . add Shared/Views/Positions/PositionsChartTransactionsSplit.swift UITestSupport/UITestIdentifiers+AccountDetail.swift
git -C . commit -m "feat(positions): unified account-detail tabs/pinned-split container"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 4: Wire the container in — always show chart+transactions, gate only Positions

Rework `MultiInstrumentPositionsSplitModifier` to **always** wrap its content in `PositionsChartTransactionsSplit` (removing the whole-surface hide), gate only the Positions pane on `hasNonHostHoldings`, hoist the shared `PositionSelection`, and always run the valuator so the chart series builds for every account. All four call sites keep their unchanged `.multiInstrumentPositionsSplit(...)` calls — verify, don't edit them.

**Files:**
- Modify: `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`
- Modify: `MoolahTests/Features/Transactions/MultiInstrumentSplitShouldShowTests.swift` (repoint at the renamed helper)

**Interfaces changed:**
- Remove the `nonisolated static func shouldShow(...)` shim and the private `shouldShow` computed property; replace with a private `hasPositions` computed property delegating to `AccountDetailLayout.hasNonHostHoldings`.
- Add `@State private var selection: PositionSelection?`.
- `valuatePositions()`'s empty-return path seeds an empty `PositionsViewInput` instead of `nil` (no perpetual chart spinner).

- [ ] **Step 1: Migrate the decision-helper test suite**

In `MoolahTests/Features/Transactions/MultiInstrumentSplitShouldShowTests.swift`, replace every `MultiInstrumentPositionsSplitModifier.shouldShow(` call with `AccountDetailLayout.hasNonHostHoldings(` (five call sites), and update the `@Suite`/doc string to name the new API (e.g. `@Suite("AccountDetailLayout.hasNonHostHoldings")`). The assertions and fixtures are otherwise unchanged — this proves the behaviour is preserved through the rename.

Run: `just test-mac AccountDetailLayout` (Expected: FAIL to compile — `shouldShow` still exists AND the suite now references only `hasNonHostHoldings`; this is expected until Step 2 removes the shim, but the reference itself resolves. If it compiles, run it: Expected PASS). Proceed to Step 2.

- [ ] **Step 2: Rework the modifier body**

In `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`:

1. Delete the `nonisolated static func shouldShow(...)` method and the private `shouldShow` computed property.
2. Add the shared selection state and a `hasPositions` predicate:

```swift
  @State private var positionsInput: PositionsViewInput?
  @State private var positionsRange: PositionsTimeRange = .threeMonths
  @State private var selection: PositionSelection?

  private var hasPositions: Bool {
    AccountDetailLayout.hasNonHostHoldings(
      rawPositions: positions,
      hostCurrency: hostCurrency,
      positionsInput: positionsInput)
  }
```

3. Replace `func body(content:)` with the always-wrapping form:

```swift
  func body(content: Content) -> some View {
    PositionsChartTransactionsSplit(hasPositions: hasPositions) {
      content
    } positions: {
      if let positionsInput {
        PositionsPane(input: positionsInput, selection: $selection)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding()
          .accessibilityLabel("Loading positions")
      }
    } chart: {
      if let positionsInput {
        PositionsChartPane(
          input: positionsInput, range: $positionsRange, selection: $selection)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding()
          .accessibilityLabel("Loading chart")
      }
    }
    .task(
      id: PositionsTaskKey(
        positions: positions, registrationsVersion: registrationsVersion,
        range: positionsRange)
    ) {
      await valuatePositions()
    }
    #if os(macOS)
      .onExitCommand { selection = nil }
    #endif
    .onChange(of: positionsInput) { _, _ in selection = nil }
  }
```

4. In `valuatePositions()`, change the early-return guard so it seeds an empty input rather than `nil`, so the always-present Chart tab settles to a header instead of an endless spinner:

```swift
    guard let conversionService, !positions.isEmpty else {
      // Nothing to value (no conversion service, or an account with no
      // positions). Settle to an empty input so the always-present Chart
      // tab renders a header rather than a perpetual loading spinner.
      positionsInput = PositionsViewInput(
        title: title, hostCurrency: hostCurrency, positions: [], historicalValue: nil)
      return
    }
```

(The rest of `valuatePositions()`, `loadingBaseInput`, and `buildHistoryInput` are unchanged — they already build `historicalValue` for host-currency legs via the Increment-1 all-instrument series, so a fiat-only account now gets a balance chart.)

- [ ] **Step 3: Update the modifier doc comment**

Update the type doc comment (`:1-22`) so it describes the new contract: the modifier now **always** wraps its content in `PositionsChartTransactionsSplit` (chart + transactions always present); `hasPositions` gates only the Positions tab / pinned pane; the valuator runs for every account to build the chart series. Remove the stale "No-op otherwise" wording from `multiInstrumentPositionsSplit(...)`'s doc (`:232-236`).

- [ ] **Step 4: Build, verify all four call sites, run tests**

Run: `just build-mac` — Expected: succeeds. The four call sites (`Features/Crypto/CryptoWalletAccountView.swift:45`, `Features/Exchange/ExchangeAccountView.swift:37`, `Features/Accounts/Views/StandardAccountView.swift:38`, `Features/Accounts/Views/GroupDetailView.swift:61`) use the unchanged `.multiInstrumentPositionsSplit(...)` signature, so they compile without edits — confirm the build touches none of them.

Run: `just test-mac AccountDetailLayout` and `just test-mac PositionsAssembler`
Expected: PASS.

- [ ] **Step 5: Preview each account shape**

Use `reviewing-ui-with-preview` on `MultiInstrumentPositionsSplitModifier.swift`'s existing previews (`"Split shown — multi-instrument"`, `"Split hidden — host-currency only"`). Confirm: the multi-instrument preview now shows the pinned Positions pane + `[Transactions | Chart]` toggle; the (renamed intent) host-currency-only preview now shows a single pane with `[Transactions | Chart]` (no positions pane) — the chart tab renders the balance line rather than the old bare transaction list. Rename that second preview to reflect "chart + transactions, no positions".

- [ ] **Step 6: Format and review**

Run: `just format-check` (Expected: clean). Run `@ui-review`, `@code-review`, and `@concurrency-review` (the `.task`/valuator lifecycle changed) on the modifier; fix every finding and re-review until clean.

- [ ] **Step 7: Commit**

```bash
git -C . add Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift MoolahTests/Features/Transactions/MultiInstrumentSplitShouldShowTests.swift
git -C . commit -m "feat(positions): unify account detail — chart+transactions always, positions gated"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 5: macOS UI tests — pinned split, fiat-only single pane, default Transactions

Lock the container's macOS structure through a screen driver: a multi-instrument account renders the pinned Positions pane plus the `[Transactions | Chart]` toggle defaulting to Transactions; a fiat-only account renders a single toggle pane with no Positions surface; toggling shows the chart. (iOS tab-set presence is covered by `AccountDetailLayoutTests` in Task 1 and by preview, since the UI-test target is macOS-only.)

**Files:**
- Modify: `UITestSupport/UITestSeed.swift` (add `.accountDetailLayout`)
- Modify: `UITestSupport/UITestFixtures.swift` (add `AccountDetailLayout` fixture UUIDs)
- Create: `App/UITestSeedHydrator+AccountDetailLayout.swift`
- Modify: `MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift` (add `.multiCurrency` / `.everydayFiat`)
- Modify: `MoolahUITests_macOS/Helpers/MoolahApp.swift` (add `accountDetail` accessor)
- Create: `MoolahUITests_macOS/Helpers/Screens/AccountDetailScreen.swift`
- Create: `MoolahUITests_macOS/Tests/AccountDetailSplitTests.swift`

**Interfaces produced:**
- `UITestSeed.accountDetailLayout` ("account-detail-layout") — an AUD CloudKit profile seeding: a **Multi-Currency** bank account holding AUD + USD positions (non-host holdings → Positions pane), and an **Everyday** fiat-only checking (AUD only → no Positions pane). Each with a couple of deterministic transactions so the transaction list and the balance chart have data.
- `AccountDetailScreen` driver with `expectPositionsPanePinned()`, `expectNoPositionsPane()`, `expectTransactionsDefault()`, `toggleToChart()`, `toggleToTransactions()`.

- [ ] **Step 1: Add the seed, fixtures, and hydrator**

Follow the `writing-ui-tests` skill and the `.walletHeaderSyncError` seed as the pattern (`UITestSeed` case + `UITestFixtures.<Name>` UUIDs + `UITestSeedHydrator+<Name>.swift` + a `SidebarAccount` mapping).

- In `UITestSupport/UITestSeed.swift`, append: `case accountDetailLayout = "account-detail-layout"` with a doc comment describing the two seeded accounts.
- In `UITestSupport/UITestFixtures.swift`, add an `AccountDetailLayout` enum exposing `multiCurrencyAccountId` and `everydayAccountId` as fixed UUID literals.
- Create `App/UITestSeedHydrator+AccountDetailLayout.swift` hydrating a CloudKit-backed AUD profile with the two accounts, their positions (Multi-Currency: an AUD balance + a USD holding; Everyday: an AUD balance only), and 2–3 deterministic transactions each. Wire it into `UITestSeedHydrator`'s dispatch on `UITestSeed.accountDetailLayout` (mirror how `.walletHeaderSyncError` is dispatched).

- [ ] **Step 2: Extend the sidebar driver**

In `MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift`, add to `SidebarAccount`:

```swift
  /// The multi-currency bank account from `.accountDetailLayout` (AUD host
  /// holding a USD position) — drives the pinned-positions macOS layout.
  case multiCurrency
  /// The fiat-only checking account from `.accountDetailLayout` (AUD only)
  /// — drives the single-pane macOS layout.
  case everydayFiat
```

and the corresponding `id` cases returning `UITestFixtures.AccountDetailLayout.multiCurrencyAccountId` / `.everydayAccountId`.

- [ ] **Step 3: Add the `accountDetail` accessor and the screen driver**

In `MoolahUITests_macOS/Helpers/MoolahApp.swift`, add `var accountDetail: AccountDetailScreen { AccountDetailScreen(app: self) }` (mirror the existing `syncedAccountHeader` accessor).

Create `MoolahUITests_macOS/Helpers/Screens/AccountDetailScreen.swift` (imports only `XCTest`; every lookup via `app.element(for:)`; 10s positive waits; trace breadcrumbs; segments clicked by their button label):

```swift
import XCTest

/// Driver for `PositionsChartTransactionsSplit`, the unified account-detail
/// container. Returned from `MoolahApp.accountDetail`.
@MainActor
struct AccountDetailScreen {
  let app: MoolahApp

  /// Asserts the pinned Positions pane is present (macOS multi-instrument
  /// layout) within `timeout` seconds.
  func expectPositionsPanePinned(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let pane = app.element(for: UITestIdentifiers.AccountDetail.positionsPane)
    if !pane.waitForExistence(timeout: timeout) {
      Trace.recordFailure("positions pane did not appear")
      XCTFail(
        "Pinned positions pane did not appear within \(timeout)s for a multi-instrument "
          + "account. Check PositionsChartTransactionsSplit renders the pinned top pane "
          + "when hasPositions is true.")
    }
  }

  /// Asserts NO Positions pane exists (macOS fiat-only single-pane layout).
  /// The tab picker (the `[Transactions | Chart]` toggle) must exist first,
  /// so the container has rendered before we assert the pane's absence.
  func expectNoPositionsPane(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let picker = app.element(for: UITestIdentifiers.AccountDetail.tabPicker)
    if !picker.waitForExistence(timeout: timeout) {
      Trace.recordFailure("tab picker did not appear")
      XCTFail("Account-detail toggle did not appear within \(timeout)s")
      return
    }
    let pane = app.element(for: UITestIdentifiers.AccountDetail.positionsPane)
    XCTAssertFalse(
      pane.exists,
      "Positions pane should be absent for a fiat-only account (no non-host holdings).")
  }

  /// Asserts the transactions surface is showing by default (the toggle
  /// defaults to Transactions, so the transaction-list container is present
  /// and the chart pane is not).
  func expectTransactionsDefault(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let list = app.element(for: UITestIdentifiers.TransactionList.container)
    if !list.waitForExistence(timeout: timeout) {
      Trace.recordFailure("transaction list not shown by default")
      XCTFail("Transactions is not the default bottom-pane tab within \(timeout)s")
      return
    }
    XCTAssertFalse(
      app.element(for: UITestIdentifiers.AccountDetail.chartPane).exists,
      "Chart pane should not be visible while Transactions is the selected tab.")
  }

  /// Clicks the "Chart" segment and waits for the chart pane.
  func toggleToChart(timeout: TimeInterval = 10) {
    Trace.record(#function)
    app.buttons["Chart"].click()
    let chart = app.element(for: UITestIdentifiers.AccountDetail.chartPane)
    if !chart.waitForExistence(timeout: timeout) {
      Trace.recordFailure("chart pane did not appear after toggling")
      XCTFail("Chart pane did not appear within \(timeout)s of clicking the Chart segment")
    }
  }

  /// Clicks the "Transactions" segment and waits for the transaction list.
  func toggleToTransactions(timeout: TimeInterval = 10) {
    Trace.record(#function)
    app.buttons["Transactions"].click()
    let list = app.element(for: UITestIdentifiers.TransactionList.container)
    if !list.waitForExistence(timeout: timeout) {
      Trace.recordFailure("transaction list did not reappear after toggling")
      XCTFail("Transaction list did not reappear within \(timeout)s")
    }
  }
}
```

(If `app.buttons["Chart"]` is ambiguous or unreachable via the raw query, add a stable identifier to each segment in Task 3's picker and click via `app.element(for:)` instead — resolve during implementation per the `writing-ui-tests` skill.)

- [ ] **Step 4: Write the failing UI tests**

Create `MoolahUITests_macOS/Tests/AccountDetailSplitTests.swift`:

```swift
import XCTest

/// macOS UI tests for `PositionsChartTransactionsSplit`, the unified
/// account-detail container. Seeded via `.accountDetailLayout`:
/// a multi-currency bank account (pinned positions) and a fiat-only
/// checking (single toggle pane).
@MainActor
final class AccountDetailSplitTests: MoolahUITestCase {
  /// A multi-instrument account pins the Positions pane and defaults the
  /// bottom toggle to Transactions.
  func testMultiInstrumentAccountPinsPositionsAndDefaultsToTransactions() throws {
    let app = launch(seed: .accountDetailLayout)
    app.sidebar.switchToAccount(.multiCurrency)
    app.accountDetail.expectPositionsPanePinned()
    app.accountDetail.expectTransactionsDefault()
  }

  /// Toggling the bottom pane to Chart shows the chart pane; toggling back
  /// restores the transaction list.
  func testToggleBetweenTransactionsAndChart() throws {
    let app = launch(seed: .accountDetailLayout)
    app.sidebar.switchToAccount(.multiCurrency)
    app.accountDetail.expectTransactionsDefault()
    app.accountDetail.toggleToChart()
    app.accountDetail.toggleToTransactions()
  }

  /// A fiat-only account renders a single toggle pane with no Positions
  /// surface, still defaulting to Transactions.
  func testFiatOnlyAccountHasNoPositionsPane() throws {
    let app = launch(seed: .accountDetailLayout)
    app.sidebar.switchToAccount(.everydayFiat)
    app.accountDetail.expectNoPositionsPane()
    app.accountDetail.expectTransactionsDefault()
  }
}
```

- [ ] **Step 5: Run the UI tests, verify they pass**

Run: `just test-ui AccountDetailSplitTests`
Expected: PASS (3 tests). If the transaction-list `TransactionList.container` is present in BOTH the pinned-pane case and the single-pane case, that is correct — the difference the tests assert is the presence/absence of `AccountDetail.positionsPane`. If a test flakes on element resolution, follow `feedback_pr_ci_gate_when_ui_host_blocked` and the `writing-ui-tests` driver invariants; do not shorten the 10s waits.

- [ ] **Step 6: Format and review**

Run: `just format-check` (Expected: clean). Run `@ui-test-review` on the driver + tests + seed, and `@code-review` on the hydrator; fix every finding and re-review until clean.

- [ ] **Step 7: Commit**

```bash
git -C . add UITestSupport/UITestSeed.swift UITestSupport/UITestFixtures.swift App/UITestSeedHydrator+AccountDetailLayout.swift MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift MoolahUITests_macOS/Helpers/MoolahApp.swift MoolahUITests_macOS/Helpers/Screens/AccountDetailScreen.swift MoolahUITests_macOS/Tests/AccountDetailSplitTests.swift
git -C . commit -m "test(positions): UI coverage for unified account-detail split"
```

Then open a PR and land via the `landing-prs` skill.

---

## Self-Review

- **Spec coverage (vs Increment 2 scope):**
  - iOS data-driven tabs, Transactions first + default, Positions inserted only for non-host holdings → `AccountDetailLayout.iOSTabs` (Task 1) + container (Task 3) + wiring (Task 4). ✓
  - macOS `ResizableVSplit` with positions pinned top + `[Transactions | Chart]` bottom toggle (default Transactions); single pane when fiat-only → container `macBody` (Task 3). ✓
  - Fresh autosave key (`"account-detail.positions-pinned-split"`), distinct from both legacy keys, + right-sized presets (`260`/`120`/`320`) → Task 3, decisions block. ✓
  - Perf tiles + total at top of Chart tab / companion pane; slot designed for Increment 3 (`input.performance != nil`) → `PositionsChartPane` (Task 2). ✓
  - Relax the gate: chart + transactions always show; only Positions gated → Task 4 (always-wrap, `hasPositions` gate); `PositionsViewInput.shouldHide` semantics preserved for the untouched investment `PositionsView.rendersNothing`. ✓
  - Preserve `PositionSelection` chart filtering across the split → hoisted `@State selection` bindings into both panes (Tasks 2 & 4). ✓
  - Applies to crypto / exchange / standard / group via `MultiInstrumentPositionsSplitModifier`; four call sites unchanged → Task 4 Step 4. ✓
  - Investment untouched + backward-compatible container → legacy `PositionsTransactionsSplit` retained; migration deferred to Increment 4, noted in File Structure. ✓
  - Recorded-value out of scope → noted. ✓
- **Placeholder scan:** every code step carries complete, compiling code — no `TBD`/`...`-as-content. The only ellipses are inside doc-comment prose and the standard `.dynamicTypeSize(...)` range operator. Task 5's seed hydrator is described (not fully coded) because it must mirror the repo's existing hydrator plumbing (`UITestSeedHydrator` dispatch, `UITestFixtures` literals), which the implementer reads at execution time — same convention as Increment 1's fixture-backed test stubs. ✓
- **Type / name consistency across tasks:** `AccountDetailTab` (`.transactions`/`.positions`/`.chart`) and `AccountDetailLayout.{iOSTabs, macBottomTabs, macShowsPinnedPositions, hasNonHostHoldings}` defined in Task 1 and used verbatim in Tasks 3–4. `PositionsChartPane(input:range:selection:)` and `PositionsPane(input:selection:)` defined in Task 2, consumed in Tasks 3–4. `PositionsChartTransactionsSplit(hasPositions:autosaveName:initialTopHeight:transactions:positions:chart:)` defined in Task 3, consumed in Task 4. `UITestIdentifiers.AccountDetail.{positionsPane, chartPane, tabPicker}` created in Task 3, consumed in Task 5. `PositionsTable(input:selection:)`, `PositionsHeader(input:)`, `AccountPerformanceTiles(title:performance:)`, `PositionsChart(input:range:selection:)`, `ResizableVSplit(autosaveName:initialTopHeight:minTopHeight:minBottomHeight:collapsed:reduceMotion:top:bottom:)`, and `PositionsViewInput(title:hostCurrency:positions:historicalValue:)` match the current source signatures. ✓
- **Ambiguities resolved:** (a) *iOS tab-set UI verification* — the macOS-only UI-test target can't assert iOS tabs, so iOS presence is covered by the `AccountDetailLayoutTests` pure helper + preview, and the macOS UI tests assert the pinned-split / single-pane shapes. (b) *Both panes carry a total header* — the pinned Positions pane (`PositionsHeader`) and the Chart pane (`PositionsChartPane`) each show the total; on macOS both are visible when the bottom toggle is on Chart. Accepted per the design's self-contained-tab intent. (c) *Empty/no-conversion accounts* — **decided (user):** the Chart tab is ALWAYS present; a brand-new zero-activity account shows a total header + "No chart data yet" empty state (never a perpetual spinner, never a suppressed tab). The modifier seeds an empty `PositionsViewInput` rather than `nil` to realize this.
