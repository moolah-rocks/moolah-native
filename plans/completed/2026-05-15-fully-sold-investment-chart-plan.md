# Fully-Sold Investment Chart — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the value-over-time chart at the top of a position-tracked investment account view even when all positions have been sold (current value = 0).

**Architecture:** Two surgical changes — relax `PositionsViewInput.showsChart` to allow rendering when current positions is empty but the historical aggregate series has points, plus add a `hasHistoricalSeries` helper; wire `InvestmentAccountView.positionTrackedLayout` to render `PositionsChart` (no header/tiles/table) in a new chart-only branch when `shouldHide` is true but `hasHistoricalSeries` is true.

**Tech Stack:** Swift 6, SwiftUI (iOS 26 / macOS 26), Swift Testing (`@Suite` / `@Test`), GRDB-backed `TestBackend`, xcodegen project generation, `just` build targets.

**Working directory:** All paths in this plan are relative to the worktree root `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold`. Run every `just` and `git` command via `just -d <root>` or `git -C <root>` — never `cd`.

**Pre-task setup (run once before Task 1):**

```bash
mkdir -p /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp
```

The `.agent-tmp/` directory is gitignored and is where test output gets captured per project rules.

---

## File map

- Modify: `Domain/Models/PositionsViewInput.swift` — add `hasHistoricalSeries`; relax `showsChart`.
- Modify: `MoolahTests/Domain/PositionsViewInputTests.swift` — add new cases; update the two existing cases that exercised the old "non-empty positions + empty `total`" path.
- Create: `MoolahTests/Features/Investments/InvestmentStoreFullySoldChartTests.swift` — store-level integration coverage.
- Modify: `Features/Investments/Views/InvestmentAccountView.swift` — split `positionTrackedLayout` into a `chartOnlySplit` / `standardPositionsSplit` pair, gated on `hasHistoricalSeries`.
- Modify: `Features/Investments/Views/InvestmentAccountView+Previews.swift` — add a "Position-tracked (fully sold)" preview that seeds matched buy + sell pairs.

`PositionsView`, `PositionsChart`, `PositionsTransactionsSplit`, `PositionsHistoryBuilder`, and the legacy `recordedValue` layout are **not** touched.

---

## Task 1: Add `hasHistoricalSeries` to `PositionsViewInput`

**Files:**

- Modify: `Domain/Models/PositionsViewInput.swift`
- Modify: `MoolahTests/Domain/PositionsViewInputTests.swift`

- [ ] **Step 1: Add three failing tests for `hasHistoricalSeries`**

Append to `MoolahTests/Domain/PositionsViewInputTests.swift` immediately after the final closing `}` of the `subtotalsRequireMultipleKinds` test (around line 209), before the suite's closing `}`:

```swift
  @Test("hasHistoricalSeries is false when historicalValue is nil")
  func historicalSeriesAbsentWhenNoSeries() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [], historicalValue: nil)
    #expect(!input.hasHistoricalSeries)
  }

  @Test("hasHistoricalSeries is false when total is empty")
  func historicalSeriesAbsentWhenTotalEmpty() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:]))
    #expect(!input.hasHistoricalSeries)
  }

  @Test("hasHistoricalSeries is true when total has at least one point")
  func historicalSeriesPresentWhenTotalHasPoints() {
    let point = HistoricalValueSeries.Point(
      date: Date(), value: 100, cost: 80, contributions: 80)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:]))
    #expect(input.hasHistoricalSeries)
  }
```

- [ ] **Step 2: Run the new tests to verify they fail to compile**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold test PositionsViewInputTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build fails with three errors of the form `value of type 'PositionsViewInput' has no member 'hasHistoricalSeries'`. Confirm by grepping:

```bash
grep -F "has no member 'hasHistoricalSeries'" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
```

Expected: three matches.

- [ ] **Step 3: Implement `hasHistoricalSeries`**

In `Domain/Models/PositionsViewInput.swift`, immediately after `showsAggregateChart` (around line 63) and before `showsGroupSubtotals`, insert:

```swift
  /// `true` iff `historicalValue` exists and its aggregate `total` series
  /// has at least one point. The view layer reads this to decide whether
  /// a chart-only surface is worth rendering when `shouldHide` is true —
  /// e.g. a position-tracked investment account where every holding has
  /// been sold but the historical performance is still meaningful.
  var hasHistoricalSeries: Bool {
    guard let series = historicalValue else { return false }
    return !series.total.isEmpty
  }
```

- [ ] **Step 4: Run the new tests to verify they pass**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold test PositionsViewInputTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build succeeds, all `PositionsViewInputTests` cases pass. Confirm:

```bash
grep -E "Test run with [0-9]+ tests passed" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
grep -i "failed" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
```

Expected: first grep matches at least once; second grep returns no lines.

- [ ] **Step 5: Format and commit**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold add Domain/Models/PositionsViewInput.swift MoolahTests/Domain/PositionsViewInputTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold commit -m "$(cat <<'EOF'
feat(positions): add PositionsViewInput.hasHistoricalSeries

True iff `historicalValue` exists and its `total` series has at least one
point. Lets the view layer decide whether to render a chart-only surface
when `shouldHide` is true — used in the next step for fully-sold
position-tracked investment accounts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

```bash
rm /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
```

---

## Task 2: Relax `PositionsViewInput.showsChart`

**Files:**

- Modify: `Domain/Models/PositionsViewInput.swift`
- Modify: `MoolahTests/Domain/PositionsViewInputTests.swift`

This task changes the contract of `showsChart`. New rule:

- The chart renders when `historicalValue` exists **and** its `total` series has at least one point.
- When `positions` is non-empty, at least one row must carry cost basis (preserves "this is an investment account" check).
- When `positions` is empty, the historical series alone is sufficient (the new behaviour).

Two existing tests in `PositionsViewInputTests.swift` rely on the old looser definition of `historicalValue != nil` regardless of `total`. They must be updated to provide a non-empty `total` so their original intent ("show chart when conditions are met") still holds.

- [ ] **Step 1: Add new failing tests for the relaxed contract**

Append three new tests inside the `@Suite("PositionsViewInput")` body (after the `hasHistoricalSeries` tests added in Task 1):

```swift
  @Test("showsChart is true when positions is empty but historical total has points")
  func chartVisibleForEmptyPositionsWithHistory() {
    let point = HistoricalValueSeries.Point(
      date: Date(), value: 100, cost: 80, contributions: 80)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:]))
    #expect(input.showsChart)
  }

  @Test("showsChart is false when positions is empty and historical total is empty")
  func chartHiddenForEmptyPositionsWithoutHistory() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:]))
    #expect(!input.showsChart)
  }

  @Test("showsChart is false when positions has cost basis but historical total is empty")
  func chartHiddenWhenCostBasisButNoHistoricalPoints() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:]))
    #expect(!input.showsChart)
  }
```

- [ ] **Step 2: Update the two existing tests that used empty `total` with non-empty positions**

In `MoolahTests/Domain/PositionsViewInputTests.swift`, locate the `chartVisibleWithSeriesAndCostBasis` test (around line 168). Its body currently constructs `HistoricalValueSeries(hostCurrency: aud, total: [], perInstrument: [:])`. Replace the body so it supplies a non-empty `total`:

```swift
  @Test("showsChart is true when historicalValue has points and at least one row carries cost basis")
  func chartVisibleWithSeriesAndCostBasis() {
    let point = HistoricalValueSeries.Point(
      date: Date(), value: 60, cost: 50, contributions: 50)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:])
    )
    #expect(input.showsChart)
  }
```

Then locate `aggregateChartHiddenOnFailure` (around line 125). Its body also uses empty `total` and asserts `input.showsChart == true`; replace it with a non-empty `total` so the intent (aggregate hidden but chart container still shown) survives:

```swift
  @Test("showsAggregateChart is false when any row's value is nil")
  func aggregateChartHiddenOnFailure() {
    let point = HistoricalValueSeries.Point(
      date: Date(), value: 60, cost: 50, contributions: 50)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60)),
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(40), value: nil),
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:])
    )
    #expect(!input.showsAggregateChart)
    #expect(input.showsChart)  // chart can still render for working instruments
  }
```

The two existing tests that already used `historicalValue: nil` (`chartHiddenWithoutSeries`) or already pass through the new logic (`chartHiddenWithoutAnyCostBasis`) are left untouched.

- [ ] **Step 3: Run the suite to verify the failures**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold test PositionsViewInputTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: at least `chartVisibleForEmptyPositionsWithHistory` fails (it expects `showsChart == true` for empty positions but the old code returns false). Confirm:

```bash
grep "chartVisibleForEmptyPositionsWithHistory" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
```

Expected: at least one line containing "failed" near the test name.

- [ ] **Step 4: Implement the relaxed `showsChart`**

In `Domain/Models/PositionsViewInput.swift`, locate `showsChart` (currently around lines 55-58):

```swift
  var showsChart: Bool {
    guard historicalValue != nil else { return false }
    return positions.contains(where: { $0.hasCostBasis })
  }
```

Replace with:

```swift
  /// `true` iff the chart container is rendered at all. Requires a
  /// non-empty aggregate historical series, and — when current positions
  /// exist — at least one of them carrying cost basis. An empty `positions`
  /// array is allowed (the historic series alone is sufficient): supports
  /// position-tracked investment accounts where every holding has been
  /// sold but the user still wants to inspect prior performance.
  var showsChart: Bool {
    guard let series = historicalValue, !series.total.isEmpty else { return false }
    return positions.isEmpty || positions.contains(where: { $0.hasCostBasis })
  }
```

- [ ] **Step 5: Run the suite to verify all tests pass**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold test PositionsViewInputTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i "failed" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
```

Expected: second grep returns no lines.

- [ ] **Step 6: Run the wider domain suite to catch any indirect regressions**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold test PositionsViewInputShouldHideTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i "failed" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
```

Expected: no failures. `shouldHide` was not changed, so this should be a no-op safety check.

- [ ] **Step 7: Format and commit**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold add Domain/Models/PositionsViewInput.swift MoolahTests/Domain/PositionsViewInputTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold commit -m "$(cat <<'EOF'
feat(positions): allow showsChart with empty positions and non-empty history

`showsChart` previously required a current position with cost basis. For a
position-tracked investment account where every holding has been sold the
positions array is empty, even though the historic value series still
carries meaningful points. Relaxing the rule — non-empty `historicalValue.total`
plus either an empty positions array OR a cost-basis row — lets the view
layer expose that history. Empty `total` now also fails the chart gate, so
two existing tests that constructed an empty total are tightened.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

```bash
rm /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
```

---

## Task 3: Integration test — fully-sold account end-to-end

**Files:**

- Create: `MoolahTests/Features/Investments/InvestmentStoreFullySoldChartTests.swift`
- Modify: `project.yml` (only if `MoolahTests/Features/Investments/` is not already wildcarded as a sources entry — verify in Step 0)

After Tasks 1-2 the underlying contract is in place. This task adds a store-level test that exercises the real path `InvestmentStore.loadAndBuildPositionsInput` takes for a fully-sold account, against `TestBackend` (GRDB-backed in-memory store).

- [ ] **Step 0: Confirm `project.yml` already includes `MoolahTests/Features/Investments/`**

```bash
grep -n "Features/Investments" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/project.yml
```

Expected: at least one match showing `MoolahTests/Features/Investments` (or a parent wildcard like `MoolahTests`). The peer file `MoolahTests/Features/Investments/InvestmentStoreSyncRefreshTests.swift` already exists, so the directory is already in sources and no `project.yml` edit is needed. If the grep returns nothing, stop and add `MoolahTests/Features/Investments` under the test target's `sources:` block and re-run `just generate`.

- [ ] **Step 1: Write the new test file**

Create `MoolahTests/Features/Investments/InvestmentStoreFullySoldChartTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("InvestmentStore fully-sold account chart")
struct InvestmentStoreFullySoldChartTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  @Test("fully-sold account yields shouldHide + hasHistoricalSeries + showsChart")
  func fullySoldAccountSurfacesChart() async throws {
    let (backend, _) = try TestBackend.create()
    let conversionService = FixedConversionService(rates: [bhp.id: Decimal(50)])
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversionService
    )
    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))

    // Buy 100 BHP @ 40 AUD on day -30.
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceNow: -86_400 * 30),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: -4_000, type: .trade),
        ]))
    // Sell all 100 BHP @ 50 AUD on day -10.
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceNow: -86_400 * 10),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: -100, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: 5_000, type: .trade),
        ]))

    let input = try await store.loadAndBuildPositionsInput(
      account: account, profileCurrency: aud, range: .threeMonths)

    #expect(input.positions.isEmpty)
    #expect(input.shouldHide)
    #expect(input.hasHistoricalSeries)
    #expect(input.showsChart)
    #expect(input.showsAggregateChart)
  }

  @Test("brand-new account with no transactions still falls back to bare transactions path")
  func emptyAccountStillHidesChart() async throws {
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService
    )
    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))

    let input = try await store.loadAndBuildPositionsInput(
      account: account, profileCurrency: aud, range: .threeMonths)

    #expect(input.positions.isEmpty)
    #expect(input.shouldHide)
    #expect(!input.hasHistoricalSeries)
    #expect(!input.showsChart)
  }
}
```

- [ ] **Step 2: Regenerate the Xcode project so the new file is picked up**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold generate
```

Expected: `xcodegen` reports success; `Moolah.xcodeproj` is rewritten.

- [ ] **Step 3: Run the new suite**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold test InvestmentStoreFullySoldChartTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i "failed\|error:" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
```

Expected: grep returns no lines. Both cases should pass on the first run — the relaxations from Tasks 1-2 already enable this behaviour at the model level.

- [ ] **Step 4: Format and commit**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold add MoolahTests/Features/Investments/InvestmentStoreFullySoldChartTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold commit -m "$(cat <<'EOF'
test(investments): integration coverage for fully-sold chart-only path

Pins the contract the view layer relies on: a position-tracked account
whose holdings have all been sold reports `shouldHide` (no positions) AND
`hasHistoricalSeries` AND `showsChart`, while a brand-new account with no
transactions still reports `shouldHide` without `hasHistoricalSeries`.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

```bash
rm /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
```

---

## Task 4: View wiring — chart-only branch in `InvestmentAccountView`

**Files:**

- Modify: `Features/Investments/Views/InvestmentAccountView.swift`

The current `positionTrackedLayout` (lines 91-117) collapses to the bare transaction list when `shouldHide && !isLoadingPositions`. Split it so a non-empty historical series instead routes to a chart-only `PositionsTransactionsSplit`.

- [ ] **Step 1: Replace `positionTrackedLayout` and add the two sibling layouts**

In `Features/Investments/Views/InvestmentAccountView.swift`, locate the existing `positionTrackedLayout` declaration (around line 91). It currently reads:

```swift
  @ViewBuilder private var positionTrackedLayout: some View {
    if positionsInput.shouldHide && !isLoadingPositions {
      makeAccountTransactionList()
    } else {
      PositionsTransactionsSplit(
        defaultTab: .positions,
        // Distinct autosave key from the chartless multi-currency split so
        // the saved divider position from each layout doesn't bleed into
        // the other; the chart pushes the table off-screen at the
        // chartless 180pt default.
        autosaveName: "positions-transactions-split.with-chart",
        // Header (~50pt) + chart (~250pt with padding) + a few table rows
        // need ~530pt to render comfortably without the user dragging.
        initialTopHeight: 540
      ) {
        if isLoadingPositions && positionsInput.positions.isEmpty {
          ProgressView()
            .frame(maxWidth: .infinity)
            .padding()
        } else {
          PositionsView(input: positionsInput, range: $positionsRange)
        }
      } transactions: {
        makeAccountTransactionList()
      }
    }
  }
```

Replace this single declaration with the following three:

```swift
  /// The positions/transactions composition for non-legacy accounts.
  /// Three branches:
  ///   - Positions exist (or are still loading): show the full
  ///     `PositionsView` with header, optional chart, and table.
  ///   - Positions empty but historic series has points: show a chart-only
  ///     surface so the user can review prior performance.
  ///   - Positions empty and no history: collapse to the bare transaction
  ///     list, the same as today.
  @ViewBuilder private var positionTrackedLayout: some View {
    if positionsInput.shouldHide && !isLoadingPositions {
      if positionsInput.hasHistoricalSeries {
        chartOnlySplit
      } else {
        makeAccountTransactionList()
      }
    } else {
      standardPositionsSplit
    }
  }

  /// Full positions surface — header (or performance tiles), optional
  /// chart, and the responsive table. Used when current positions exist.
  @ViewBuilder private var standardPositionsSplit: some View {
    PositionsTransactionsSplit(
      defaultTab: .positions,
      // Distinct autosave key from the chartless multi-currency split so
      // the saved divider position from each layout doesn't bleed into
      // the other; the chart pushes the table off-screen at the
      // chartless 180pt default.
      autosaveName: "positions-transactions-split.with-chart",
      // Header (~50pt) + chart (~250pt with padding) + a few table rows
      // need ~530pt to render comfortably without the user dragging.
      initialTopHeight: 540
    ) {
      if isLoadingPositions && positionsInput.positions.isEmpty {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding()
      } else {
        PositionsView(input: positionsInput, range: $positionsRange)
      }
    } transactions: {
      makeAccountTransactionList()
    }
  }

  /// Chart-only top pane for a position-tracked account that currently
  /// holds nothing but has historical activity. Reuses the same
  /// `autosaveName` as `standardPositionsSplit` so the divider position
  /// the user has chosen for this account shape persists across the two
  /// branches. `selectedInstrument` is pinned to `.constant(nil)` —
  /// there are no positions to filter to, so the per-instrument selection
  /// chip would never appear.
  @ViewBuilder private var chartOnlySplit: some View {
    PositionsTransactionsSplit(
      defaultTab: .positions,
      autosaveName: "positions-transactions-split.with-chart",
      initialTopHeight: 540
    ) {
      PositionsChart(
        input: positionsInput,
        range: $positionsRange,
        selectedInstrument: .constant(nil))
    } transactions: {
      makeAccountTransactionList()
    }
  }
```

No other part of the file changes. In particular, `body`, `legacyValuationsLayout`, `legacySummary`, `legacyChartAndValuations`, the `valuationsList`/`valuationsHeader`/`valuationsBody` group, and the `timePeriodPicker` are unchanged.

- [ ] **Step 2: Build for macOS to confirm the changes compile**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold build-mac 2>&1 | tee .agent-tmp/build.txt
grep -E "error:|warning:" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/build.txt
```

Expected: no `error:` lines; no new `warning:` lines (preview-macro warnings emitted from `#Preview` blocks are fine and can be ignored per CLAUDE.md).

- [ ] **Step 3: Re-run the investment-related test suites**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold test InvestmentStoreFullySoldChartTests PositionsViewInputTests PositionsViewInputShouldHideTests InvestmentStorePositionsInputTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i "failed\|error:" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
```

Expected: grep returns no lines. The view change is data-driven via `hasHistoricalSeries` / `shouldHide` — the existing suites still cover the model semantics.

- [ ] **Step 4: Format and commit**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold add Features/Investments/Views/InvestmentAccountView.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold commit -m "$(cat <<'EOF'
feat(investments): show value-over-time chart when positions all sold

`positionTrackedLayout` now routes through a third branch: when
`positionsInput.shouldHide` (no current positions) but
`hasHistoricalSeries` is true, the top pane renders just `PositionsChart`
— no performance tiles, no positions table — so the user can still review
prior performance after closing out every holding. Truly empty accounts
(no historic data) keep today's bare transaction list. Reuses the existing
`positions-transactions-split.with-chart` autosave key so the divider
position persists across the two branches.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

```bash
rm /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/build.txt /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
```

---

## Task 5: Preview for fully-sold state

**Files:**

- Modify: `Features/Investments/Views/InvestmentAccountView+Previews.swift`

Adds a third `#Preview` so the chart-only path is visible in Xcode's canvas. Useful both for review and for future UI work.

- [ ] **Step 1: Add a `seedFullySoldPositions` helper and a `#Preview` entry**

At the bottom of `Features/Investments/Views/InvestmentAccountView+Previews.swift`, after the existing `seedPositionValuations` helper and `#Preview("Position-tracked")` block, append:

```swift
@MainActor
private func seedFullySoldPositions(backend: any BackendProvider, account: Account) async {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  _ = try? await backend.accounts.create(
    account, openingBalance: InstrumentAmount(quantity: 0, instrument: .AUD))
  // Buy 100 BHP @ 40 AUD on day -45.
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-86_400 * 45),
      legs: [
        TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
        TransactionLeg(accountId: account.id, instrument: .AUD, quantity: -4_000, type: .trade),
      ]))
  // Sell all 100 BHP @ 50 AUD on day -15.
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-86_400 * 15),
      legs: [
        TransactionLeg(accountId: account.id, instrument: bhp, quantity: -100, type: .trade),
        TransactionLeg(accountId: account.id, instrument: .AUD, quantity: 5_000, type: .trade),
      ]))
}

#Preview("Position-tracked (fully sold)") {
  let backend = PreviewBackend.create()
  let investmentStore = InvestmentStore(
    repository: backend.investments,
    transactionRepository: backend.transactions,
    conversionService: backend.conversionService)
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  let account = Account(
    name: "Brokerage",
    type: .investment,
    instrument: .AUD,
    valuationMode: .calculatedFromTrades)
  return NavigationStack {
    InvestmentAccountView(
      account: account,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      investmentStore: investmentStore,
      transactionStore: transactionStore
    )
  }
  .previewProfileEnvironment(session: session)
  .frame(width: 720, height: 600)
  .task { await seedFullySoldPositions(backend: backend, account: account) }
}
```

- [ ] **Step 2: Build to confirm the preview compiles**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold build-mac 2>&1 | tee .agent-tmp/build.txt
grep -E "error:" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/build.txt
```

Expected: no `error:` lines.

- [ ] **Step 3: Format and commit**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold add Features/Investments/Views/InvestmentAccountView+Previews.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold commit -m "$(cat <<'EOF'
chore(investments): preview for fully-sold position-tracked account

Seeds a matched buy + sell pair so positions return to zero, demonstrating
the chart-only branch added to `positionTrackedLayout`.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

```bash
rm /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/build.txt
```

---

## Task 6: Full pre-PR verification

- [ ] **Step 1: Full format-check**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold format-check
```

Expected: exit code 0, no diff suggestions.

- [ ] **Step 2: Full test suite (iOS + macOS)**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold test 2>&1 | tee .agent-tmp/test-output.txt
grep -i "failed\|error:" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp/test-output.txt
```

Expected: grep returns no lines. If anything fails, do NOT amend earlier commits — debug, fix, and add a new commit.

- [ ] **Step 3: Manual macOS verification**

Open the project in Xcode (`open /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/Moolah.xcodeproj`) and render each preview in `InvestmentAccountView+Previews.swift`:

- **Default** (legacy recorded-value): existing behaviour, no change expected.
- **Position-tracked**: existing behaviour — tiles + chart + positions table + transactions.
- **Position-tracked (fully sold)** (new): chart at the top with a populated curve, transactions below; no tiles, no positions table.

If `mcp__xcode__RenderPreview` is being used, point it at the worktree's `Moolah.xcodeproj` per the project's worktree preview rules (CLAUDE.md §Xcode previews and the RenderPreview tool from a worktree).

- [ ] **Step 4: Clean up `.agent-tmp/`**

```bash
rm -rf /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold/.agent-tmp
```

- [ ] **Step 5: Push the branch and open the PR**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/investment-chart-fully-sold push origin fix/investment-chart-fully-sold:fix/investment-chart-fully-sold
gh pr create --repo ajsutton/moolah-native --base main --head fix/investment-chart-fully-sold \
  --title "Show value-over-time chart for fully-sold position-tracked accounts" \
  --body "$(cat <<'EOF'
## Summary
- Adds `PositionsViewInput.hasHistoricalSeries` and relaxes `showsChart` so the chart container renders when current positions are empty but the historic aggregate series has points.
- `InvestmentAccountView.positionTrackedLayout` gains a chart-only branch: when every holding has been sold, the top pane renders just `PositionsChart` — no performance tiles, no positions table — so prior performance is still visible. Truly empty accounts (no history) keep today's bare transaction list.
- Adds an `InvestmentStoreFullySoldChartTests` suite + a `#Preview("Position-tracked (fully sold)")` for canvas review.

Design spec: `plans/2026-05-15-fully-sold-investment-chart-design.md`.

## Test plan
- [ ] `just test` passes on macOS and iOS.
- [ ] `just format-check` passes.
- [ ] Manual: position-tracked account with all positions sold renders chart at the top, transactions below.
- [ ] Manual: position-tracked account with open positions still renders tiles + chart + positions table (no regression).
- [ ] Manual: brand-new position-tracked account with no transactions still renders the bare transaction list.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

After the PR is open, hand it off to the merge-queue per the user's standing preference (do not merge manually).

---

## Self-review

**Spec coverage:**

- Spec §Design.1 (`hasHistoricalSeries` + relaxed `showsChart`) → Tasks 1 + 2.
- Spec §Design.2 (`InvestmentAccountView.positionTrackedLayout` chart-only branch) → Task 4.
- Spec §Tests (PositionsViewInput cases + InvestmentStoreFullySoldChartTests) → Tasks 1, 2, 3.
- Spec §Verification (full suite + manual cases) → Task 6.
- Spec §"What is not changed" (PositionsView, PositionsChart, PositionsHistoryBuilder, shouldHide, legacy layout) — none of those files are touched in any task; verified by file map.

**Placeholder scan:** No "TBD", "add appropriate error handling", or "similar to Task N" placeholders. Every step has either exact code, an exact command, or both.

**Type consistency:** `hasHistoricalSeries` is the same name in Tasks 1, 2, 3, 4. `chartOnlySplit` / `standardPositionsSplit` are introduced together in Task 4 and referenced consistently in `positionTrackedLayout`. `PositionsChart(input:range:selectedInstrument:)` matches the existing initializer at `Shared/Views/Positions/PositionsChart.swift:18-22`. `loadAndBuildPositionsInput(account:profileCurrency:range:)` matches `Features/Investments/InvestmentStore+PositionsInput.swift:22-29`. `HistoricalValueSeries.Point(date:value:cost:contributions:)` matches `Domain/Models/HistoricalValueSeries.swift:18-33`. `FixedConversionService(rates:)` matches `MoolahTests/Support/FixedConversionService.swift:17`.
