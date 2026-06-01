# Show historic value chart for fully-sold position-tracked investment accounts

**Status:** Approved 2026-05-15
**Scope:** UX fix in `Features/Investments/` + `Domain/Models/PositionsViewInput.swift`

## Problem

In a position-tracked investment account (`valuationMode == .calculatedFromTrades`), once the user has sold every holding the current value is zero and `valuedPositions` is empty. `PositionsViewInput.shouldHide` returns `true` (its rule includes "positions is empty"), which causes `InvestmentAccountView.positionTrackedLayout` to collapse to a bare transaction list. The historic value-over-time chart vanishes, even though the account still has meaningful historical performance data the user wants to review.

`PositionsHistoryBuilder.build` already emits historical points correctly for these accounts — it walks transactions chronologically and emits a point for every day a non-zero quantity existed. The data is there; only the view-layer gating hides it.

## Goal

When all positions in a position-tracked account have been sold:

- Show the value-over-time chart at the top of the account view.
- Do **not** show the three performance tiles (`AccountPerformanceTiles`) or the positions table — both are about "now", which is empty.
- Keep the transaction list below, unchanged.

When the account is truly empty (no historical positions either), keep today's behaviour: render just the bare transaction list.

## Non-goals

- Changing the default time range (`.threeMonths`). If every sale happened more than three months ago, the chart will show its existing "No chart data yet" empty state until the user picks `.allTime`. Worth a follow-up but not in scope here.
- Changing `PositionsView`'s rendering behaviour — it continues to short-circuit on `shouldHide`. The new "chart-only" path is a sibling at the view layer, not a new internal mode.
- Changing `PositionsHistoryBuilder` — it already produces the correct series for these accounts.
- Changing the legacy `.recordedValue` valuation path. This change is isolated to the position-tracked layout.

## Design

### 1. `Domain/Models/PositionsViewInput.swift`

Add a computed property:

```swift
/// `true` iff `historicalValue` exists and its aggregate series has at
/// least one point. Lets the view layer decide whether to render a
/// chart-only surface when `shouldHide` is true but historical
/// performance data is available.
var hasHistoricalSeries: Bool {
  guard let series = historicalValue else { return false }
  return !series.total.isEmpty
}
```

Relax `showsChart` so an empty `positions` array with a non-empty historical series still renders the chart:

```swift
var showsChart: Bool {
  guard let series = historicalValue, !series.total.isEmpty else { return false }
  return positions.isEmpty || positions.contains(where: { $0.hasCostBasis })
}
```

Rationale:

- When `positions` is non-empty, keep the existing rule (at least one row must have cost basis — distinguishes "investment" from "cash-only" accounts).
- When `positions` is empty but the historical series has points, the account previously held investments. The series itself is the relevant signal.

`showsAggregateChart` (`showsChart && totalValue != nil`) does not need a separate change: when `positions` is empty, `totalValue` returns `InstrumentAmount.zero(hostCurrency)` (not `nil`), so it stays compatible with the relaxed `showsChart`.

`shouldHide` is **not** changed. Its contract — "the positions table component should render nothing" — stays accurate. The chart is composed at the view layer alongside `PositionsView`, not inside it.

### 2. `Features/Investments/Views/InvestmentAccountView.swift`

Modify `positionTrackedLayout`. Today:

```swift
@ViewBuilder private var positionTrackedLayout: some View {
  if positionsInput.shouldHide && !isLoadingPositions {
    makeAccountTransactionList()
  } else {
    PositionsTransactionsSplit(
      defaultTab: .positions,
      autosaveName: "positions-transactions-split.with-chart",
      initialTopHeight: 540
    ) {
      if isLoadingPositions && positionsInput.positions.isEmpty {
        ProgressView()...
      } else {
        PositionsView(input: positionsInput, range: $positionsRange)
      }
    } transactions: {
      makeAccountTransactionList()
    }
  }
}
```

After:

```swift
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
```

Where `chartOnlySplit` reuses the same `PositionsTransactionsSplit` shape (same `autosaveName`, same `initialTopHeight`) but the top pane is the chart on its own:

```swift
@ViewBuilder private var chartOnlySplit: some View {
  PositionsTransactionsSplit(
    defaultTab: .positions,
    autosaveName: "positions-transactions-split.with-chart",
    initialTopHeight: 540
  ) {
    PositionsChart(
      input: positionsInput,
      range: $positionsRange,
      selectedInstrument: .constant(nil)
    )
  } transactions: {
    makeAccountTransactionList()
  }
}
```

`selectedInstrument` is bound to `.constant(nil)` because there are no positions to filter to; per-instrument selection chips are meaningless in this state. `PositionsChart`'s body already renders its own range picker and an empty-state message ("No chart data yet") when `visiblePoints` is empty for the active range.

`standardPositionsSplit` is the existing `PositionsTransactionsSplit { PositionsView }` body, hoisted into its own `@ViewBuilder` so the if/else above stays readable.

### 3. Tests

Add to `MoolahTests/Domain/PositionsViewInputTests.swift` (Swift Testing):

- `hasHistoricalSeries` returns `false` when `historicalValue` is `nil`.
- `hasHistoricalSeries` returns `false` when `historicalValue?.total.isEmpty == true`.
- `hasHistoricalSeries` returns `true` when `historicalValue?.total` has at least one point.
- `showsChart` returns `true` when `positions.isEmpty` and the historical aggregate series has points.
- `showsChart` continues to return `false` when `positions.isEmpty` and `historicalValue` is `nil` or has empty `total`.
- Existing positive/negative cases for `showsChart` with non-empty `positions` continue to pass unchanged.

Add `MoolahTests/Features/Investments/InvestmentStoreFullySoldChartTests.swift` (Swift Testing):

- Seed a position-tracked account on `TestBackend`: buys + matching sells so every position quantity returns to zero.
- Call `investmentStore.loadAndBuildPositionsInput(account:profileCurrency:range:)` with `range: .allTime`.
- Assert on the returned `PositionsViewInput`:
  - `shouldHide == true` (no current positions)
  - `hasHistoricalSeries == true`
  - `showsChart == true`
  - `showsAggregateChart == true`
- Companion case: an account with no transactions at all → `shouldHide == true`, `hasHistoricalSeries == false`, `showsChart == false`. Confirms the "bare transactions" path is still chosen.

UI test coverage is out of scope. The store-level test plus the existing screen driver are sufficient — the view-layer wiring is a thin pass-through into `PositionsChart`, which already has its own previews and tests.

## Verification

- `just test` passes.
- Manual: load a position-tracked account with all positions sold and confirm the chart renders at the top with transactions below. Range picker still works.
- Manual: load a brand-new position-tracked account with no transactions and confirm the bare transaction list still appears.
- Manual: load a position-tracked account with open positions and confirm the existing chart + tiles + positions table layout is unchanged.
