# Companion Graphs for Insights — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each high-value insight detector a companion graph, render "For You" insights as full-width panels with a small side graph, and let the user click the graph to open a centered detail sheet with the enlarged chart, the insight's facts, and its actions.

**Architecture:** A new `Sendable`/`Hashable` `InsightChart` value type is computed by the pure detectors (off the main actor, alongside the `Insight`) and rendered by a single generic `InsightChartView` at two sizes. Detectors call small pure chart builders in `InsightChartBuilders`; the chart rides on `Insight.chart` through the existing `ScoredInsight` → `ForYouItem` pipeline with no new store plumbing. `ForYouCard` gains the panel layout and a `.sheet` that presents `InsightChartDetailSheet`.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, Swift Testing (`@Test`/`#expect`/`#require`), XCUITest (macOS), `just` build/test/format targets, `xcodegen`.

---

## Conventions for every task

- **Worktree:** all work happens in the worktree at
  `/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/insight-companion-graphs`.
  This plan refers to it as `$WT`. Run every build/test/format command with
  `just -d "$WT" --justfile "$WT/justfile" <target>` (never `cd && just`).
- **New `.swift` files must be added to `project.yml` membership only if not
  auto-globbed.** This project globs sources by directory, so files created under
  existing globbed directories (`Domain/Insights/`, `Features/Insights/Views/`,
  `MoolahTests/Domain/Insights/`, `MoolahUITests_macOS/`, `UITestSupport/`) are
  picked up automatically. After creating any new file, run
  `just -d "$WT" --justfile "$WT/justfile" generate` once before building so
  Xcode sees it.
- **Capture test output:** `mkdir -p "$WT/.agent-tmp"` then pipe to
  `"$WT/.agent-tmp/<name>.txt"`; delete the temp file when done.
- **Every task ends green:** the task is not complete until `build-mac`,
  the named tests, AND `format-check` all pass. `format-check` runs
  `swiftlint lint --strict` — do not introduce a baseline or a
  `// swiftlint:disable`; fix the code instead.
- **TDD:** write the failing test first, watch it fail, implement, watch it pass,
  commit. Commit messages end with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Sign convention:** never `abs()` away a sign in production code. Chart point
  values are plain magnitudes ONLY where the source aggregate is already a
  positive magnitude (`ExpenseBreakdown.totalExpenses`, `EarmarkSnapshot.spent`);
  everywhere else carry the natural signed value.

---

## File Structure

**Create:**
- `Domain/Insights/InsightChart.swift` — the `InsightChart` value type (Task 1).
- `Domain/Insights/InsightChartBuilders.swift` — pure builders that turn detector data into `InsightChart` (Tasks 2, 4, 5, 6).
- `Features/Insights/Views/InsightChartView.swift` — generic Swift Charts renderer, inline + expanded (Task 8).
- `Features/Insights/Views/InsightChartDetailSheet.swift` — the zoom sheet (Task 9).
- `MoolahTests/Domain/Insights/InsightChartBuildersTests.swift` — builder unit tests (Tasks 2, 4, 5, 6).
- `MoolahUITests_macOS/InsightChartUITests.swift` — panel→sheet UI test (Task 11).

**Modify:**
- `Domain/Insights/Insight.swift` — add `chart` property + init param (Task 1).
- `Domain/Insights/Detectors/CategoryAnomalyInsight.swift` — attach chart (Task 3).
- `Domain/Insights/Detectors/CategoryTrendInsight.swift` — attach chart (Task 3).
- `Domain/Insights/Detectors/CashFlowForecastInsights.swift` — attach chart (Task 4).
- `Domain/Insights/Detectors/NetWorthInsights.swift` — attach chart (Task 5).
- `Domain/Insights/Detectors/SavingsRateInsight.swift` — refactor to dated points + attach chart (Task 6).
- `Domain/Insights/Detectors/EarmarkBudgetInsights.swift` — attach chart (Task 7).
- `Features/Insights/Views/ForYouCard.swift` — panel layout + inline chart + zoom (Task 10).
- `UITestSupport/UITestIdentifiers+ForYou.swift` — chart + sheet identifiers (Task 10).
- `MoolahTests/Domain/Insights/SpendAndTrendInsightTests.swift` — assert charts on category insights (Task 3).
- `MoolahTests/Domain/Insights/CashFlowForecastInsightsTests.swift` — assert charts (Tasks 4, 6). *(If a savings-rate test lives elsewhere, add the assertion next to the existing one — confirm by grep.)*

---

## Task 1: `InsightChart` value type + `Insight.chart`

**Files:**
- Create: `Domain/Insights/InsightChart.swift`
- Modify: `Domain/Insights/Insight.swift:19-67`
- Test: `MoolahTests/Domain/Insights/InsightChartBuildersTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Domain/Insights/InsightChartBuildersTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("Insight chart builders")
struct InsightChartBuildersTests {
  private let currency = InsightTestSupport.currency

  @Test
  func insightCarriesAnOptionalChart() {
    let chart = InsightChart(
      kind: .line,
      unit: .percent,
      series: [
        InsightChart.Series(
          id: "rate", label: "Savings rate", role: .primary,
          points: [
            InsightChart.Point(date: InsightTestSupport.date(2026, 1, 1), value: 0.1),
            InsightChart.Point(date: InsightTestSupport.date(2026, 2, 1), value: 0.2),
          ])
      ],
      highlight: InsightChart.Point(date: InsightTestSupport.date(2026, 2, 1), value: 0.2),
      xAxis: .monthly)

    let insight = Insight(
      id: "x", kind: .savingsRateTrend, title: "t", date: InsightTestSupport.now,
      framing: .positive, actionability: .review, surprise: 0.5, chart: chart)

    #expect(insight.chart == chart)
    #expect(insight.chart?.series.first?.points.count == 2)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartBuildersTests 2>&1 | tee "$WT/.agent-tmp/t1.txt"`
Expected: FAIL — `cannot find 'InsightChart' in scope` and extra argument `chart:`.

- [ ] **Step 3: Create the `InsightChart` type**

Create `Domain/Insights/InsightChart.swift`:

```swift
import Foundation

/// A companion graph a detector attaches to an `Insight` to visualise the
/// behaviour it detected. Pure data: the detector computes it (off the main
/// actor, alongside the `Insight`) and the view renders it — no charting
/// logic lives in views, mirroring how `InsightFact` is the single source of
/// truth for any rendered number.
struct InsightChart: Sendable, Hashable {
  /// How the primary series is drawn.
  enum Kind: Sendable, Hashable {
    case line
    case bar
    case area
  }

  /// The unit of the y values, driving axis/label formatting. `currency`
  /// carries the reporting instrument so the view can format without a
  /// global currency.
  enum Unit: Sendable, Hashable {
    case currency(Instrument)
    case percent
    case count
  }

  /// The role a series plays, driving its visual treatment.
  enum SeriesRole: Sendable, Hashable {
    /// The actual measured series (solid, tinted).
    case primary
    /// A forward projection (dashed, lighter).
    case projected
    /// A reference line such as a budget or best-fit (grey, dashed).
    case baseline
  }

  /// X-axis tick granularity.
  enum XAxisStyle: Sendable, Hashable {
    case monthly
    case daily
  }

  /// A single (date, value) sample. `value` is in the chart's `unit`
  /// (reporting-currency amount, a 0...1 fraction for `percent`, or a count).
  struct Point: Sendable, Hashable {
    let date: Date
    let value: Double
  }

  struct Series: Sendable, Hashable, Identifiable {
    let id: String
    let label: String
    let role: SeriesRole
    let points: [Point]
  }

  let kind: Kind
  let unit: Unit
  let series: [Series]
  /// The point/period to mark (the anomaly, trough, or latest reading).
  let highlight: Point?
  let xAxis: XAxisStyle
}
```

- [ ] **Step 4: Add `chart` to `Insight`**

In `Domain/Insights/Insight.swift`, add the stored property after `references` (around line 41) and a defaulted init parameter + assignment. The property:

```swift
  /// Deep-link handles for the UI.
  let references: InsightReferences

  /// An optional companion graph visualising the detected behaviour. `nil`
  /// when the detector has no chart for this kind or the data is too sparse;
  /// such insights fall back to a graph-less row.
  let chart: InsightChart?
```

Add to the `init` signature the new last parameter and assignment:

```swift
    facts: [InsightFact] = [],
    references: InsightReferences = InsightReferences(),
    chart: InsightChart? = nil
  ) {
    ...
    self.references = references
    self.chart = chart
  }
```

- [ ] **Step 5: Generate, then run the test to verify it passes**

Run:
```
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartBuildersTests 2>&1 | tee "$WT/.agent-tmp/t1.txt"
```
Expected: PASS (`insightCarriesAnOptionalChart`). Then
`just -d "$WT" --justfile "$WT/justfile" format-check` — expected: clean.

- [ ] **Step 6: Commit**

```bash
git -C "$WT" add Domain/Insights/InsightChart.swift Domain/Insights/Insight.swift MoolahTests/Domain/Insights/InsightChartBuildersTests.swift
git -C "$WT" commit -m "Add InsightChart value type and Insight.chart

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
rm -f "$WT/.agent-tmp/t1.txt"
```

---

## Task 2: Category-spend chart builder

**Files:**
- Create: `Domain/Insights/InsightChartBuilders.swift`
- Test: `MoolahTests/Domain/Insights/InsightChartBuildersTests.swift`

The category builder takes the per-category `[MonthlySpendPoint]` that
`CategorySpendSeries.build` already produces (positive magnitudes in reporting
currency) and the financial-month string to highlight.

- [ ] **Step 1: Write the failing test** (add to `InsightChartBuildersTests`)

```swift
  @Test
  func categorySpendChartHighlightsTheGivenMonth() throws {
    let points = [
      MonthlySpendPoint(month: "202604", date: InsightTestSupport.date(2026, 4, 1), magnitude: 100),
      MonthlySpendPoint(month: "202605", date: InsightTestSupport.date(2026, 5, 1), magnitude: 110),
      MonthlySpendPoint(month: "202606", date: InsightTestSupport.date(2026, 6, 1), magnitude: 400),
    ]
    let chart = try #require(
      InsightChartBuilders.categorySpend(
        points: points, reportingCurrency: currency, highlightMonth: "202606"))

    #expect(chart.kind == .bar)
    #expect(chart.unit == .currency(currency))
    #expect(chart.xAxis == .monthly)
    #expect(chart.series.count == 1)
    #expect(chart.series.first?.points.count == 3)
    #expect(chart.highlight?.value == 400)
  }

  @Test
  func categorySpendChartIsNilBelowTwoPoints() {
    let points = [
      MonthlySpendPoint(month: "202606", date: InsightTestSupport.date(2026, 6, 1), magnitude: 400)
    ]
    #expect(
      InsightChartBuilders.categorySpend(
        points: points, reportingCurrency: currency, highlightMonth: "202606") == nil)
  }
```

- [ ] **Step 2: Run to verify it fails**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartBuildersTests 2>&1 | tee "$WT/.agent-tmp/t2.txt"`
Expected: FAIL — `cannot find 'InsightChartBuilders' in scope`.

- [ ] **Step 3: Create the builder**

Create `Domain/Insights/InsightChartBuilders.swift`:

```swift
import Foundation

/// Pure functions that turn detector-side aggregates into an `InsightChart`.
/// Each returns `nil` when the data is too sparse to chart meaningfully (fewer
/// than two points), so the insight falls back to a graph-less row.
enum InsightChartBuilders {
  /// Minimum points before a series is worth drawing.
  private static let minimumPoints = 2

  /// A category's monthly spend (positive magnitudes), as a bar chart with the
  /// anomalous / latest financial month highlighted.
  static func categorySpend(
    points: [MonthlySpendPoint],
    reportingCurrency: Instrument,
    highlightMonth: String
  ) -> InsightChart? {
    guard points.count >= minimumPoints else { return nil }
    let ordered = points.sorted { $0.date < $1.date }
    let chartPoints = ordered.map { InsightChart.Point(date: $0.date, value: $0.magnitude) }
    let highlight = ordered.first { $0.month == highlightMonth }
      .map { InsightChart.Point(date: $0.date, value: $0.magnitude) }
    return InsightChart(
      kind: .bar,
      unit: .currency(reportingCurrency),
      series: [
        InsightChart.Series(
          id: "spend", label: "Spend", role: .primary, points: chartPoints)
      ],
      highlight: highlight,
      xAxis: .monthly)
  }
}
```

- [ ] **Step 4: Generate + run to verify it passes**

Run:
```
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartBuildersTests 2>&1 | tee "$WT/.agent-tmp/t2.txt"
```
Expected: PASS (3 tests). Then `format-check` — clean.

- [ ] **Step 5: Commit**

```bash
git -C "$WT" add Domain/Insights/InsightChartBuilders.swift MoolahTests/Domain/Insights/InsightChartBuildersTests.swift
git -C "$WT" commit -m "Add category-spend insight chart builder

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
rm -f "$WT/.agent-tmp/t2.txt"
```

---

## Task 3: Wire category anomaly + trend detectors to attach charts

**Files:**
- Modify: `Domain/Insights/Detectors/CategoryAnomalyInsight.swift:83-102`
- Modify: `Domain/Insights/Detectors/CategoryTrendInsight.swift:53-96`
- Test: `MoolahTests/Domain/Insights/SpendAndTrendInsightTests.swift`

Both detectors already build a per-category `[MonthlySpendPoint]` series via
`CategorySpendSeries.build`. We pass the relevant category's points into the
builder and attach the result.

- [ ] **Step 1: Write the failing tests** (add to `SpendAndTrendInsightTests`)

```swift
  @Test
  func categoryAnomalyAttachesHighlightedChart() throws {
    let dining = Category(name: "Dining")
    let magnitudes: [Decimal] = [100, 105, 98, 102, 100, 103, 99, 400]
    let months = ["202511", "202512", "202601", "202602", "202603", "202604", "202605", "202606"]
    let breakdown = zip(months, magnitudes).map { month, magnitude in
      InsightTestSupport.breakdownRow(magnitude, categoryId: dining.id, month: month)
    }
    let insights = CategoryAnomalyInsight.detect(
      breakdown: breakdown, categories: Categories(from: [dining]), context: context)
    let anomaly = try #require(insights.first { $0.kind == .categorySpendingAnomaly })
    let chart = try #require(anomaly.chart)
    #expect(chart.kind == .bar)
    #expect(chart.series.first?.points.count == 8)
    #expect(chart.highlight?.value == 400)
  }

  @Test
  func categoryTrendAttachesChart() throws {
    let dining = Category(name: "Dining")
    let magnitudes: [Decimal] = [100, 140, 180, 220, 260, 300]
    let months = ["202601", "202602", "202603", "202604", "202605", "202606"]
    let breakdown = zip(months, magnitudes).map { month, magnitude in
      InsightTestSupport.breakdownRow(magnitude, categoryId: dining.id, month: month)
    }
    let insights = CategoryTrendInsight.detect(
      breakdown: breakdown, categories: Categories(from: [dining]), context: context)
    let trend = try #require(
      insights.first { $0.kind == .categoryTrendRising || $0.kind == .categoryTrendFalling })
    #expect(trend.chart != nil)
    #expect(trend.chart?.kind == .bar)
  }
```

- [ ] **Step 2: Run to verify they fail**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac SpendAndTrendInsightTests 2>&1 | tee "$WT/.agent-tmp/t3.txt"`
Expected: FAIL — `anomaly.chart` is `nil` (`#require` throws).

- [ ] **Step 3: Attach the chart in `CategoryAnomalyInsight`**

In `CategoryAnomalyInsight.swift`, the per-category evaluation has the category's
points and `latest` in scope where the `Insight(...)` is built (lines 83-102).
The category's series is `series[categoryId]` (from the `CategorySpendSeries.build`
result at the top of `detect`). Add `chart:` as the final argument of the
`Insight(...)` initialiser:

```swift
      references: InsightReferences(
        categoryIds: resolved.map { [$0.id] } ?? [],
        instrumentIds: [context.reportingCurrency.id]),
      chart: InsightChartBuilders.categorySpend(
        points: points, reportingCurrency: context.reportingCurrency,
        highlightMonth: latest.month))
```

`points` is the `[MonthlySpendPoint]` for the current category already in scope in
the evaluation loop (the same array `latest` came from). If the in-scope variable
has a different name, use it — read lines 28-72 to confirm the local name; it is
the per-category point array passed to `evaluate`.

- [ ] **Step 4: Attach the chart in `CategoryTrendInsight`**

In `CategoryTrendInsight.swift`, `makeInsight` (lines 53-96) has the category's
points and `latest` in scope. Add as the final `Insight(...)` argument:

```swift
      references: InsightReferences(
        categoryIds: resolved.map { [$0.id] } ?? [],
        instrumentIds: [context.reportingCurrency.id]),
      chart: InsightChartBuilders.categorySpend(
        points: points, reportingCurrency: context.reportingCurrency,
        highlightMonth: latest.month))
```

Confirm the per-category point array's local name by reading lines 21-52.

- [ ] **Step 5: Run to verify they pass**

Run:
```
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t3-build.txt"
just -d "$WT" --justfile "$WT/justfile" test-mac SpendAndTrendInsightTests 2>&1 | tee "$WT/.agent-tmp/t3.txt"
```
Expected: build clean (no warnings — `SWIFT_TREAT_WARNINGS_AS_ERRORS`), tests PASS. Then `format-check` — clean.

- [ ] **Step 6: Commit**

```bash
git -C "$WT" add Domain/Insights/Detectors/CategoryAnomalyInsight.swift Domain/Insights/Detectors/CategoryTrendInsight.swift MoolahTests/Domain/Insights/SpendAndTrendInsightTests.swift
git -C "$WT" commit -m "Attach spend-over-time charts to category insights

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
rm -f "$WT/.agent-tmp/t3.txt" "$WT/.agent-tmp/t3-build.txt"
```

---

## Task 4: Cash-flow balance-forecast builder + wire the two cash-flow detectors

**Files:**
- Modify: `Domain/Insights/InsightChartBuilders.swift`
- Modify: `Domain/Insights/Detectors/CashFlowForecastInsights.swift:52-67, 99-115`
- Test: `MoolahTests/Domain/Insights/InsightChartBuildersTests.swift`, `MoolahTests/Domain/Insights/CashFlowForecastInsightsTests.swift`

The builder draws the daily-balance series with the actual tail solid
(`.primary`) and the forecast tail dashed (`.projected`), highlighting a given
date (the trough or month-end day). It uses `DailyBalance.balance`.

- [ ] **Step 1: Write the failing builder test** (add to `InsightChartBuildersTests`)

Add a local helper at the bottom of the suite (inside the struct):

```swift
  private func balance(
    _ day: Int, total: Decimal, forecast: Bool
  ) -> DailyBalance {
    let amount = InstrumentAmount(quantity: total, instrument: currency)
    let zero = InstrumentAmount.zero(instrument: currency)
    return DailyBalance(
      date: InsightTestSupport.date(2026, 6, day),
      balance: amount,
      earmarked: zero,
      availableFunds: amount,
      investments: zero,
      investmentValue: nil,
      netWorth: amount,
      bestFit: nil,
      isForecast: forecast)
  }
```

*(If `DailyBalance` exposes a shorter convenience init, prefer it — read
`Domain/Models/DailyBalance.swift:37-57`. The full memberwise init above always
compiles.)*

Then the test:

```swift
  @Test
  func balanceForecastSplitsActualAndProjected() throws {
    let balances = [
      balance(1, total: 1000, forecast: false),
      balance(2, total: 900, forecast: false),
      balance(3, total: 400, forecast: true),
      balance(4, total: 700, forecast: true),
    ]
    let chart = try #require(
      InsightChartBuilders.balanceForecast(
        balances, reportingCurrency: currency, highlight: InsightTestSupport.date(2026, 6, 3)))

    #expect(chart.kind == .line)
    #expect(chart.unit == .currency(currency))
    #expect(chart.xAxis == .daily)
    #expect(chart.series.contains { $0.role == .primary })
    #expect(chart.series.contains { $0.role == .projected })
    #expect(chart.highlight?.value == 400)
  }
```

- [ ] **Step 2: Run to verify it fails**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartBuildersTests 2>&1 | tee "$WT/.agent-tmp/t4.txt"`
Expected: FAIL — no `balanceForecast` member.

- [ ] **Step 3: Add the builder** (append inside `enum InsightChartBuilders`)

```swift
  /// Daily current-funds balance: the actual tail solid, the forecast tail
  /// dashed, with `highlight` marking the trough or projected month-end day.
  /// The two tails are joined at the boundary so the projection continues the
  /// actual line rather than starting from zero.
  static func balanceForecast(
    _ balances: [DailyBalance],
    reportingCurrency: Instrument,
    highlight: Date?
  ) -> InsightChart? {
    let ordered = balances.sorted { $0.date < $1.date }
    guard ordered.count >= minimumPoints else { return nil }

    let actual = ordered.filter { !$0.isForecast }
    let forecast = ordered.filter(\.isForecast)
    var series: [InsightChart.Series] = []
    if actual.count >= 1 {
      series.append(
        InsightChart.Series(
          id: "actual", label: "Balance", role: .primary,
          points: actual.map { InsightChart.Point(date: $0.date, value: $0.balance.doubleValue) }))
    }
    if !forecast.isEmpty {
      // Prepend the last actual point so the dashed projection visually
      // continues from the solid line.
      let bridge = actual.last.map {
        [InsightChart.Point(date: $0.date, value: $0.balance.doubleValue)]
      } ?? []
      series.append(
        InsightChart.Series(
          id: "projected", label: "Projected", role: .projected,
          points: bridge
            + forecast.map { InsightChart.Point(date: $0.date, value: $0.balance.doubleValue) }))
    }
    guard !series.isEmpty else { return nil }

    let highlightPoint = highlight.flatMap { date in
      ordered.first { $0.date == date }
        .map { InsightChart.Point(date: $0.date, value: $0.balance.doubleValue) }
    }
    return InsightChart(
      kind: .line,
      unit: .currency(reportingCurrency),
      series: series,
      highlight: highlightPoint,
      xAxis: .daily)
  }
```

- [ ] **Step 4: Wire `upcomingBillWarning`**

In `CashFlowForecastInsights.swift`, the `Insight(...)` at lines 52-67 has `trough`
and `dailyBalances` in scope. Add as the final argument:

```swift
        references: InsightReferences(
          accountIds: culprit?.accountId.map { [$0] } ?? [],
          instrumentIds: [context.reportingCurrency.id]),
        chart: InsightChartBuilders.balanceForecast(
          dailyBalances, reportingCurrency: context.reportingCurrency, highlight: trough.date))
```

- [ ] **Step 5: Wire `projectedMonthEnd`**

In the same file, the `Insight(...)` at lines 99-115 has `monthEndDay` and
`dailyBalances` in scope. Add as the final argument:

```swift
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]),
        chart: InsightChartBuilders.balanceForecast(
          dailyBalances, reportingCurrency: context.reportingCurrency,
          highlight: monthEndDay.date))
```

- [ ] **Step 6: Add a detector-level assertion**

In `MoolahTests/Domain/Insights/CashFlowForecastInsightsTests.swift`, find an
existing test that produces a `.upcomingBillWarning` or `.projectedMonthEndBalance`
insight and add, after the `#require` for that insight:

```swift
    #expect(warning.chart != nil)
    #expect(warning.chart?.series.contains { $0.role == .projected } == true)
```

*(Use the existing test's local variable name in place of `warning`. If no such
test exists, add one mirroring the suite's existing daily-balance fixtures.)*

- [ ] **Step 7: Generate, build, run to verify pass**

Run:
```
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t4-build.txt"
just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartBuildersTests CashFlowForecastInsightsTests 2>&1 | tee "$WT/.agent-tmp/t4.txt"
```
Expected: build clean, tests PASS. Then `format-check` — clean.

- [ ] **Step 8: Commit**

```bash
git -C "$WT" add Domain/Insights/InsightChartBuilders.swift Domain/Insights/Detectors/CashFlowForecastInsights.swift MoolahTests/Domain/Insights/InsightChartBuildersTests.swift MoolahTests/Domain/Insights/CashFlowForecastInsightsTests.swift
git -C "$WT" commit -m "Attach balance-forecast charts to cash-flow insights

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
rm -f "$WT/.agent-tmp/t4.txt" "$WT/.agent-tmp/t4-build.txt"
```

---

## Task 5: Net-worth trend builder + wire `NetWorthInsights`

**Files:**
- Modify: `Domain/Insights/InsightChartBuilders.swift`
- Modify: `Domain/Insights/Detectors/NetWorthInsights.swift:26-42`
- Test: `MoolahTests/Domain/Insights/InsightChartBuildersTests.swift`

Uses `DailyBalance.netWorth` (actual entries only) as a line, plus an optional
grey `.baseline` from `DailyBalance.bestFit` when present.

- [ ] **Step 1: Write the failing builder test** (add to `InsightChartBuildersTests`)

```swift
  @Test
  func netWorthTrendUsesNetWorthValues() throws {
    let balances = [
      balance(1, total: 90_000, forecast: false),
      balance(15, total: 95_000, forecast: false),
      balance(30, total: 101_000, forecast: false),
    ]
    let chart = try #require(
      InsightChartBuilders.netWorthTrend(balances, reportingCurrency: currency))
    #expect(chart.kind == .line)
    #expect(chart.series.first?.role == .primary)
    #expect(chart.series.first?.points.count == 3)
    #expect(chart.highlight?.value == 101_000)
  }
```

(With the `balance` helper, `netWorth == total`.)

- [ ] **Step 2: Run to verify it fails**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartBuildersTests 2>&1 | tee "$WT/.agent-tmp/t5.txt"`
Expected: FAIL — no `netWorthTrend` member.

- [ ] **Step 3: Add the builder** (append inside `enum InsightChartBuilders`)

```swift
  /// Net worth over time (actual entries only), highlighting the latest
  /// reading. Adds a grey best-fit baseline when every actual entry carries
  /// one.
  static func netWorthTrend(
    _ balances: [DailyBalance],
    reportingCurrency: Instrument
  ) -> InsightChart? {
    let actual = balances.filter { !$0.isForecast }.sorted { $0.date < $1.date }
    guard actual.count >= minimumPoints else { return nil }

    var series = [
      InsightChart.Series(
        id: "networth", label: "Net worth", role: .primary,
        points: actual.map { InsightChart.Point(date: $0.date, value: $0.netWorth.doubleValue) })
    ]
    let fits = actual.compactMap(\.bestFit)
    if fits.count == actual.count {
      series.append(
        InsightChart.Series(
          id: "bestfit", label: "Trend", role: .baseline,
          points: zip(actual, fits).map { balance, fit in
            InsightChart.Point(date: balance.date, value: fit.doubleValue)
          }))
    }
    let last = actual[actual.count - 1]
    return InsightChart(
      kind: .line,
      unit: .currency(reportingCurrency),
      series: series,
      highlight: InsightChart.Point(date: last.date, value: last.netWorth.doubleValue),
      xAxis: .daily)
  }
```

- [ ] **Step 4: Wire `NetWorthInsights`**

In `NetWorthInsights.swift`, `detect` has `dailyBalances` and `latest` in scope.
Add as the final `Insight(...)` argument (after `references`, lines 26-42):

```swift
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]),
        chart: InsightChartBuilders.netWorthTrend(
          dailyBalances, reportingCurrency: context.reportingCurrency))
```

- [ ] **Step 5: Generate, build, run to verify pass**

Run:
```
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t5-build.txt"
just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartBuildersTests 2>&1 | tee "$WT/.agent-tmp/t5.txt"
```
Expected: build clean, tests PASS. Then `format-check` — clean.

- [ ] **Step 6: Commit**

```bash
git -C "$WT" add Domain/Insights/InsightChartBuilders.swift Domain/Insights/Detectors/NetWorthInsights.swift MoolahTests/Domain/Insights/InsightChartBuildersTests.swift
git -C "$WT" commit -m "Attach net-worth trend chart to net-worth milestone insight

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
rm -f "$WT/.agent-tmp/t5.txt" "$WT/.agent-tmp/t5-build.txt"
```

---

## Task 6: Savings-rate builder + detector refactor to dated points

**Files:**
- Modify: `Domain/Insights/InsightChartBuilders.swift`
- Modify: `Domain/Insights/Detectors/SavingsRateInsight.swift:11-49`
- Test: `MoolahTests/Domain/Insights/InsightChartBuildersTests.swift`, plus the savings-rate detector test (grep for it — likely in `CashFlowForecastInsightsTests.swift` or `FinanceInsightTests.swift`)

The detector currently throws away dates when it builds `rates: [Double]`. Refactor
it to build `points: [InsightChart.Point]` (date = `month.end`, value = rate),
derive `rates` from `points.map(\.value)`, and pass `points` to the builder.

- [ ] **Step 1: Write the failing builder test** (add to `InsightChartBuildersTests`)

```swift
  @Test
  func savingsRateChartIsPercentUnit() throws {
    let points = [
      InsightChart.Point(date: InsightTestSupport.date(2026, 3, 31), value: 0.10),
      InsightChart.Point(date: InsightTestSupport.date(2026, 4, 30), value: 0.15),
      InsightChart.Point(date: InsightTestSupport.date(2026, 5, 31), value: 0.22),
    ]
    let chart = try #require(InsightChartBuilders.savingsRate(points: points))
    #expect(chart.kind == .line)
    #expect(chart.unit == .percent)
    #expect(chart.xAxis == .monthly)
    #expect(chart.highlight?.value == 0.22)
  }
```

- [ ] **Step 2: Run to verify it fails**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartBuildersTests 2>&1 | tee "$WT/.agent-tmp/t6.txt"`
Expected: FAIL — no `savingsRate` member.

- [ ] **Step 3: Add the builder** (append inside `enum InsightChartBuilders`)

```swift
  /// Monthly savings rate as a percentage line, highlighting the latest month.
  static func savingsRate(points: [InsightChart.Point]) -> InsightChart? {
    guard points.count >= minimumPoints else { return nil }
    let ordered = points.sorted { $0.date < $1.date }
    return InsightChart(
      kind: .line,
      unit: .percent,
      series: [
        InsightChart.Series(id: "rate", label: "Savings rate", role: .primary, points: ordered)
      ],
      highlight: ordered.last,
      xAxis: .monthly)
  }
```

- [ ] **Step 4: Refactor `SavingsRateInsight.detect`**

Replace the `rates` computation (lines 11-19) and add the chart. The new body of
`detect` from the `rates` line through the `Insight` return:

```swift
    let points: [InsightChart.Point] = complete.compactMap { month in
      let income = Double(
        truncating: InsightAggregates.incomeMagnitude(month.totalIncome) as NSDecimalNumber)
      guard income > 0 else { return nil }
      let net = Double(truncating: month.totalProfit.quantity as NSDecimalNumber)
      return InsightChart.Point(date: month.end, value: net / income)
    }
    let rates = points.map(\.value)
    guard rates.count >= minimumMonths, let result = MannKendall.test(rates),
      result.statistic != 0
    else { return [] }
```

Then add the chart as the final `Insight(...)` argument (after `references`):

```swift
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]),
        chart: InsightChartBuilders.savingsRate(points: points))
```

- [ ] **Step 5: Add a detector-level assertion**

Grep for the savings-rate test:
`grep -rl "savingsRateTrend\|SavingsRateInsight" "$WT/MoolahTests"`. In the test
that asserts the climbing/slipping insight, after its `#require`, add:

```swift
    #expect(trend.chart?.unit == .percent)
    #expect(trend.chart?.series.first?.points.isEmpty == false)
```

(Use the existing local variable name in place of `trend`.)

- [ ] **Step 6: Generate, build, run to verify pass**

Run:
```
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t6-build.txt"
just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartBuildersTests 2>&1 | tee "$WT/.agent-tmp/t6.txt"
```
Then run the savings-rate detector test suite by its discovered name. Expected:
build clean, tests PASS. Then `format-check` — clean.

- [ ] **Step 7: Commit**

```bash
git -C "$WT" add Domain/Insights/InsightChartBuilders.swift Domain/Insights/Detectors/SavingsRateInsight.swift MoolahTests/Domain/Insights/
git -C "$WT" commit -m "Attach savings-rate trend chart; thread dates through detector

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
rm -f "$WT/.agent-tmp/t6.txt" "$WT/.agent-tmp/t6-build.txt"
```

---

## Task 7: Earmark projected-burndown chart + wire `EarmarkBudgetInsights`

**Files:**
- Modify: `Domain/Insights/InsightChartBuilders.swift`
- Modify: `Domain/Insights/Detectors/EarmarkBudgetInsights.swift:14-31, 76-115`
- Test: `MoolahTests/Domain/Insights/InsightChartBuildersTests.swift` + the earmark detector test (grep)

`EarmarkSnapshot` has no spend history, so this is an honest *projected* burndown
built from primitives the detector already has: a grey `.baseline` ideal-burndown
line (budget remaining: full budget at window start → 0 at window end), a
`.primary` point at the current remaining (`budget − spent`), and a dashed
`.projected` line from "now" to the projected remaining at window end
(`budget − projectedSpend`, which can go negative when over budget).

- [ ] **Step 1: Write the failing builder test** (add to `InsightChartBuildersTests`)

```swift
  @Test
  func earmarkBurndownProjectsBeyondBudget() throws {
    let start = InsightTestSupport.date(2026, 6, 1)
    let now = InsightTestSupport.date(2026, 6, 15)
    let end = InsightTestSupport.date(2026, 6, 30)
    let chart = try #require(
      InsightChartBuilders.earmarkBurndown(
        budget: 1000, spent: 700, projected: 1400,
        windowStart: start, now: now, windowEnd: end,
        reportingCurrency: currency))

    #expect(chart.kind == .line)
    #expect(chart.unit == .currency(currency))
    #expect(chart.series.contains { $0.role == .baseline })
    #expect(chart.series.contains { $0.role == .primary })
    #expect(chart.series.contains { $0.role == .projected })
    // budget(1000) - projected(1400) = -400 remaining at window end
    let projected = try #require(chart.series.first { $0.role == .projected })
    #expect(projected.points.last?.value == -400)
  }
```

- [ ] **Step 2: Run to verify it fails**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartBuildersTests 2>&1 | tee "$WT/.agent-tmp/t7.txt"`
Expected: FAIL — no `earmarkBurndown` member.

- [ ] **Step 3: Add the builder** (append inside `enum InsightChartBuilders`)

```swift
  /// A projected budget burndown (remaining budget over the window). Earmark
  /// snapshots carry no spend history, so this shows the ideal-burndown
  /// baseline, the current remaining, and a dashed projection to the window
  /// end — never faked historical data. `projected` is total projected spend;
  /// the projected remaining is `budget - projected` and may go negative.
  static func earmarkBurndown(
    budget: Double,
    spent: Double,
    projected: Double,
    windowStart: Date,
    now: Date,
    windowEnd: Date,
    reportingCurrency: Instrument
  ) -> InsightChart? {
    guard budget > 0, windowStart < windowEnd else { return nil }
    let currentRemaining = budget - spent
    let projectedRemaining = budget - projected
    return InsightChart(
      kind: .line,
      unit: .currency(reportingCurrency),
      series: [
        InsightChart.Series(
          id: "ideal", label: "Budget", role: .baseline,
          points: [
            InsightChart.Point(date: windowStart, value: budget),
            InsightChart.Point(date: windowEnd, value: 0),
          ]),
        InsightChart.Series(
          id: "actual", label: "Remaining", role: .primary,
          points: [InsightChart.Point(date: now, value: currentRemaining)]),
        InsightChart.Series(
          id: "projected", label: "Projected", role: .projected,
          points: [
            InsightChart.Point(date: now, value: currentRemaining),
            InsightChart.Point(date: windowEnd, value: projectedRemaining),
          ]),
      ],
      highlight: InsightChart.Point(date: now, value: currentRemaining),
      xAxis: .daily)
  }
```

- [ ] **Step 4: Build the chart in `detect` and pass it to both branches**

`Window` and `Projection` are private to the file, so build the chart inside
`detect` (where `window` and `projection` are in scope) and thread it through.

In `detect` (lines 14-31), after the `guard let ... projection = ...` and before
the `if projection.fraction ...`, add:

```swift
      let chart = InsightChartBuilders.earmarkBurndown(
        budget: projection.budgetMagnitude,
        spent: projection.spentMagnitude,
        projected: projection.projected,
        windowStart: window.start,
        now: context.now,
        windowEnd: window.end,
        reportingCurrency: context.reportingCurrency)
```

Then pass `chart: chart` to both calls:

```swift
      if projection.fraction > 1 + overspendTolerance {
        insights.append(
          overspend(earmark, budget: budget, projection: projection, context: context, chart: chart))
      } else if projection.fraction < 1 - underspendTolerance, projection.elapsedFraction >= 0.5 {
        insights.append(
          underspend(earmark, budget: budget, projection: projection, context: context, chart: chart))
      }
```

Add the `chart: InsightChart?` parameter to both `overspend` and `underspend`
signatures and pass it as the final `Insight(...)` argument in each:

```swift
  private static func overspend(
    _ earmark: EarmarkSnapshot,
    budget: InstrumentAmount,
    projection: Projection,
    context: InsightContext,
    chart: InsightChart?
  ) -> Insight {
    ...
      references: InsightReferences(earmarkIds: [earmark.id]),
      chart: chart)
  }
```

…and identically for `underspend` (final arg `chart: chart`).

- [ ] **Step 5: Add a detector-level assertion**

Grep for the earmark detector test:
`grep -rl "earmarkBurndownProjection\|EarmarkBudgetInsights" "$WT/MoolahTests"`. In
the over-budget test, after the `#require`, add:

```swift
    #expect(overBudget.chart?.series.contains { $0.role == .projected } == true)
```

(Use the existing local variable name in place of `overBudget`.)

- [ ] **Step 6: Generate, build, run to verify pass**

Run:
```
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t7-build.txt"
just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartBuildersTests 2>&1 | tee "$WT/.agent-tmp/t7.txt"
```
Then run the earmark detector suite by its discovered name. Expected: build clean,
tests PASS. Then `format-check` — clean.

- [ ] **Step 7: Commit**

```bash
git -C "$WT" add Domain/Insights/InsightChartBuilders.swift Domain/Insights/Detectors/EarmarkBudgetInsights.swift MoolahTests/Domain/Insights/
git -C "$WT" commit -m "Attach projected-burndown chart to earmark budget insights

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
rm -f "$WT/.agent-tmp/t7.txt" "$WT/.agent-tmp/t7-build.txt"
```

---

## Task 8: `InsightChartView` — generic renderer (inline + expanded)

**Files:**
- Create: `Features/Insights/Views/InsightChartView.swift`

A single view renders any `InsightChart` at two sizes. Inline: a compact
sparkline, axes hidden, fixed height, non-interactive. Expanded: axes, formatted
labels, a larger frame. Tint comes from the insight's framing so the graph
matches the row icon.

This is a view; it is exercised by the Task 11 UI test and a `#Preview`. There is
no unit test step (SwiftUI views are validated via preview + UI test per the
project's thin-view discipline).

- [ ] **Step 1: Create the view**

Create `Features/Insights/Views/InsightChartView.swift`:

```swift
import Charts
import SwiftUI

/// Renders an `InsightChart` at one of two sizes. The detector computed the
/// data; this view only draws it (thin-view discipline).
struct InsightChartView: View {
  enum Style {
    case inline
    case expanded
  }

  let chart: InsightChart
  let tint: Color
  var style: Style = .inline

  var body: some View {
    if style == .inline {
      baseChart
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 48)
        .allowsHitTesting(false)
    } else {
      baseChart
        .chartXAxis { xAxisMarks }
        .chartYAxis { yAxisMarks }
        .frame(height: 240)
    }
  }

  private var baseChart: some View {
    Chart {
      ForEach(chart.series) { series in
        ForEach(series.points, id: \.date) { point in
          marks(for: point, in: series)
        }
      }
      if let highlight = chart.highlight {
        PointMark(
          x: .value("Date", highlight.date),
          y: .value("Value", highlight.value)
        )
        .foregroundStyle(.red)
        .symbolSize(style == .inline ? 18 : 60)
        if style == .expanded {
          RuleMark(x: .value("Date", highlight.date))
            .foregroundStyle(.red.opacity(0.25))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
      }
    }
  }

  @ChartContentBuilder
  private func marks(
    for point: InsightChart.Point, in series: InsightChart.Series
  ) -> some ChartContent {
    switch chart.kind {
    case .bar:
      BarMark(
        x: .value("Date", point.date),
        y: .value("Value", point.value)
      )
      .foregroundStyle(color(for: series.role).opacity(series.role == .primary ? 1 : 0.5))
    case .line, .area:
      LineMark(
        x: .value("Date", point.date),
        y: .value("Value", point.value),
        series: .value("Series", series.id)
      )
      .foregroundStyle(color(for: series.role))
      .lineStyle(strokeStyle(for: series.role))
      .interpolationMethod(.monotone)
    }
  }

  private func color(for role: InsightChart.SeriesRole) -> Color {
    switch role {
    case .primary: tint
    case .projected: tint.opacity(0.5)
    case .baseline: .gray
    }
  }

  private func strokeStyle(for role: InsightChart.SeriesRole) -> StrokeStyle {
    switch role {
    case .primary: StrokeStyle(lineWidth: 2)
    case .projected: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
    case .baseline: StrokeStyle(lineWidth: 1, dash: [2, 3])
    }
  }

  private var instrument: Instrument? {
    if case .currency(let value) = chart.unit { return value }
    return nil
  }

  @AxisContentBuilder
  private var xAxisMarks: some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
      AxisGridLine()
      AxisTick()
      switch chart.xAxis {
      case .monthly: AxisValueLabel(format: .dateTime.month(.abbreviated))
      case .daily: AxisValueLabel(format: .dateTime.month(.abbreviated).day())
      }
    }
  }

  @AxisContentBuilder
  private var yAxisMarks: some AxisContent {
    AxisMarks { value in
      AxisGridLine()
      AxisValueLabel {
        if let raw = value.as(Double.self) {
          Text(formattedY(raw)).monospacedDigit()
        }
      }
    }
  }

  private func formattedY(_ raw: Double) -> String {
    switch chart.unit {
    case .currency(let instrument):
      return InstrumentAmount(quantity: Decimal(raw), instrument: instrument).formatNoSymbol
    case .percent:
      return raw.formatted(.percent.precision(.fractionLength(0)))
    case .count:
      return Int(raw.rounded()).formatted()
    }
  }
}

#Preview("Inline") {
  InsightChartView(
    chart: InsightChart(
      kind: .bar,
      unit: .currency(.AUD),
      series: [
        InsightChart.Series(
          id: "spend", label: "Spend", role: .primary,
          points: (0..<6).map {
            InsightChart.Point(
              date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 2_600_000),
              value: Double(100 + $0 * 40))
          })
      ],
      highlight: InsightChart.Point(
        date: Date(timeIntervalSince1970: 1_700_000_000 + 5 * 2_600_000), value: 300),
      xAxis: .monthly),
    tint: .orange,
    style: .inline
  )
  .padding()
  .frame(width: 220)
}

#Preview("Expanded") {
  InsightChartView(
    chart: InsightChart(
      kind: .line,
      unit: .percent,
      series: [
        InsightChart.Series(
          id: "rate", label: "Savings rate", role: .primary,
          points: (0..<6).map {
            InsightChart.Point(
              date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 2_600_000),
              value: 0.1 + Double($0) * 0.02)
          })
      ],
      highlight: nil,
      xAxis: .monthly),
    tint: .green,
    style: .expanded
  )
  .padding()
  .frame(width: 480)
}
```

- [ ] **Step 2: Generate + build to verify it compiles**

Run:
```
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t8-build.txt"
```
Expected: build clean (no warnings). If `Instrument.AUD` is unavailable in the
previews' module scope, it is defined at `Domain/Models/Instrument.swift:91` — it
is in-module, so it resolves. Then `format-check` — clean.

- [ ] **Step 3: Optionally render the preview**

Per `reviewing-ui-with-preview`, render `InsightChartView` "Inline" and "Expanded"
with `mcp__xcode__RenderPreview` to eyeball the sparkline and axes. Not required to
pass, but do it before the UI wiring so the visual is known-good.

- [ ] **Step 4: Commit**

```bash
git -C "$WT" add Features/Insights/Views/InsightChartView.swift
git -C "$WT" commit -m "Add generic InsightChartView (inline + expanded)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
rm -f "$WT/.agent-tmp/t8-build.txt"
```

---

## Task 9: `InsightChartDetailSheet` — the zoom sheet

**Files:**
- Create: `Features/Insights/Views/InsightChartDetailSheet.swift`

A centered sheet: framing icon + headline + close, the expanded chart, the
insight's `facts`, and its actions (`View` when there's a nav target, `Show less`).
It reads only data already on the `Insight`.

- [ ] **Step 1: Create the sheet**

Create `Features/Insights/Views/InsightChartDetailSheet.swift`:

```swift
import SwiftUI

/// The zoomed companion-graph view, presented as a centered sheet when the
/// user taps an insight's inline chart. Reads only what the `Insight` already
/// carries — no recompute.
struct InsightChartDetailSheet: View {
  let insight: Insight
  let headline: String
  let onNavigate: (SidebarSelection) -> Void
  let onDismiss: () -> Void

  @Environment(\.dismiss) private var dismiss

  private var target: SidebarSelection? {
    InsightNavigationTarget.sidebarSelection(for: insight.references)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      if let chart = insight.chart {
        InsightChartView(chart: chart, tint: framingColor, style: .expanded)
          .accessibilityIdentifier(UITestIdentifiers.ForYou.chartDetail)
      }
      if !insight.facts.isEmpty {
        factsList
      }
      Spacer(minLength: 0)
      actions
    }
    .padding(24)
    .frame(minWidth: 420, minHeight: 420)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: framingIcon)
        .foregroundStyle(framingColor)
        .accessibilityHidden(true)
      Text(headline)
        .font(.headline)
      Spacer()
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close")
    }
  }

  private var factsList: some View {
    VStack(spacing: 0) {
      ForEach(insight.facts) { fact in
        HStack {
          Text(fact.label).foregroundStyle(.secondary)
          Spacer()
          Text(fact.value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.subheadline)
        .padding(.vertical, 8)
        Divider()
      }
    }
  }

  @ViewBuilder private var actions: some View {
    HStack(spacing: 12) {
      Button(role: .destructive) {
        onDismiss()
        dismiss()
      } label: {
        Label("Show less", systemImage: "hand.thumbsdown")
      }
      Spacer()
      if let target {
        Button {
          onNavigate(target)
          dismiss()
        } label: {
          Label("View", systemImage: "arrow.forward")
        }
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  private var framingColor: Color {
    switch insight.framing {
    case .positive: .green
    case .neutral: .secondary
    case .negative: .red
    }
  }

  private var framingIcon: String {
    switch insight.framing {
    case .positive: "checkmark.circle.fill"
    case .neutral: "info.circle.fill"
    case .negative: "exclamationmark.triangle.fill"
    }
  }
}
```

*(`framingColor`/`framingIcon` mirror the existing `InsightRow` switch at
`ForYouCard.swift:155-177`. If those mappings differ there, match this sheet to
the row so the icon/colour are consistent.)*

- [ ] **Step 2: Add the `chartDetail` identifier** (so this file compiles)

This depends on `UITestIdentifiers.ForYou.chartDetail`, added in Task 10 Step 1.
**Do Task 10 Step 1 now** (add the two identifiers), then return here.

- [ ] **Step 3: Generate + build to verify it compiles**

Run:
```
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t9-build.txt"
```
Expected: build clean. Then `format-check` — clean.

- [ ] **Step 4: Commit**

```bash
git -C "$WT" add Features/Insights/Views/InsightChartDetailSheet.swift UITestSupport/UITestIdentifiers+ForYou.swift
git -C "$WT" commit -m "Add InsightChartDetailSheet zoom view

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
rm -f "$WT/.agent-tmp/t9-build.txt"
```

---

## Task 10: Panel layout in `ForYouCard` + inline chart + zoom wiring

**Files:**
- Modify: `UITestSupport/UITestIdentifiers+ForYou.swift:3-22`
- Modify: `Features/Insights/Views/ForYouCard.swift:38-178`

Convert `InsightRow` to the panel layout (option B): headline + impact + controls
on the left, the inline chart on the right when present. Tapping the chart opens
the detail sheet. Insights with `chart == nil` render exactly as today.

- [ ] **Step 1: Add chart + sheet identifiers**

In `UITestSupport/UITestIdentifiers+ForYou.swift`, add to `enum ForYou`:

```swift
    public static func chart(_ id: String) -> String { "foryou.chart.\(id)" }
    public static let chartDetail = "foryou.chartdetail"
```

- [ ] **Step 2: Add the inline chart + zoom to `InsightRow`**

In `ForYouCard.swift`, `InsightRow` already exposes `private var insight: Insight`.
Add zoom state and a trailing chart to the row body. The existing body reflows an
`HStack`/`VStack` by accessibility size (lines 50-81); add the inline chart as a
trailing element of the horizontal layout (only at standard sizes — at
accessibility sizes it stacks below). Add this `@State` to `InsightRow`:

```swift
  @State private var isZoomed = false
```

Add the inline chart view, shown only when the insight has a chart. Insert it as
the trailing item in the row's primary `HStack` (after the headline/impact/controls
`VStack`, before the row closes), wrapped in a `Button` so the tap target is
accessible:

```swift
      if let chart = insight.chart {
        Button {
          isZoomed = true
        } label: {
          InsightChartView(chart: chart, tint: framingColor, style: .inline)
            .frame(width: 200)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(UITestIdentifiers.ForYou.chart(insight.id))
        .accessibilityLabel("Show \(item.headline) chart")
      }
```

Attach the sheet to the row's outermost view (the same view that carries
`.accessibilityIdentifier(UITestIdentifiers.ForYou.row(insight.id))` near line 79):

```swift
      .sheet(isPresented: $isZoomed) {
        InsightChartDetailSheet(
          insight: insight,
          headline: item.headline,
          onNavigate: onNavigate,
          onDismiss: onDismiss)
      }
```

`framingColor` is the existing private computed property on `InsightRow`
(`ForYouCard.swift:155`); reuse it. Do **not** change the graph-less path — when
`insight.chart == nil` the row renders exactly as before.

- [ ] **Step 3: Generate + build**

Run:
```
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t10-build.txt"
```
Expected: build clean (no warnings). Then `format-check` — clean.

- [ ] **Step 4: Render the preview to confirm the panel layout**

Per `reviewing-ui-with-preview`, render the existing `ForYouCard` `#Preview` (if
one exists; otherwise add a `#Preview` that builds a `ForYouCard` with one charted
and one graph-less `ForYouItem`) via `mcp__xcode__RenderPreview`. Confirm the side
graph appears and graph-less rows are unchanged.

- [ ] **Step 5: Commit**

```bash
git -C "$WT" add Features/Insights/Views/ForYouCard.swift UITestSupport/UITestIdentifiers+ForYou.swift
git -C "$WT" commit -m "Render For You insights as panels with a side graph and zoom

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
rm -f "$WT/.agent-tmp/t10-build.txt"
```

---

## Task 11: UI test — panel graph opens the detail sheet

**Files:**
- Create: `MoolahUITests_macOS/InsightChartUITests.swift`
- Possibly modify: a UI-test seed if no seeded insight produces a chart (read `UITestSupport/UITestSeeds.swift`)

Follow `guides/UI_TEST_GUIDE.md` and the existing For You driver. Tests import only
`XCTest`; element resolution goes through the screen driver; wait on post-conditions
(no sleeps). **Before writing, read an existing `MoolahUITests_macOS` test and its
screen driver to match the driver pattern** (the For You card already has
identifiers, so there is likely a driver to extend).

- [ ] **Step 1: Confirm a seed produces a charted insight**

Read `UITestSupport/UITestSeeds.swift` and the For You UI test seed. The detail
sheet only opens for an insight whose `chart != nil`. Identify (or add) a seed whose
data triggers one of the wired detectors (e.g. a category with a clear spending
spike across ≥6 months → `categorySpendingAnomaly`, which now carries a chart).
If an existing "For You" seed already yields a charted insight, reuse it.

- [ ] **Step 2: Write the failing UI test**

Create `MoolahUITests_macOS/InsightChartUITests.swift`, mirroring the existing For
You UI test's launch + driver usage. Skeleton (adapt identifiers/driver calls to
the real driver API):

```swift
import XCTest

final class InsightChartUITests: XCTestCase {
  func testTappingInsightChartOpensDetailSheet() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-uiTestSeed", "<the charted-insight seed name>"]
    app.launch()

    // Navigate to Analysis where the For You card renders.
    // (Use the existing driver/navigation helper — match the For You UI test.)

    // The inline chart button carries UITestIdentifiers.ForYou.chart(<id>).
    let chart = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "foryou.chart.")).firstMatch
    XCTAssertTrue(chart.waitForExistence(timeout: 10))
    chart.tap()

    // The detail sheet's expanded chart carries chartDetail.
    let detail = app.otherElements["foryou.chartdetail"]
      .firstMatch
    XCTAssertTrue(detail.waitForExistence(timeout: 10))
  }
}
```

Note: a SwiftUI `Chart` may surface as a different element type; resolve via the
identifier with `.descendants(matching: .any)` if `otherElements` does not match —
confirm by reading the on-failure UI tree artifact per `guides/UI_TEST_GUIDE.md`.

- [ ] **Step 3: Run to verify it fails (then passes)**

First, ensure no stale runners (per the macOS test-runner hang remedy):
`pkill -f Moolah` for stale test-host/xctest processes if `just test-mac` hangs
"before establishing connection".

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac InsightChartUITests 2>&1 | tee "$WT/.agent-tmp/t11.txt"`
First run (before the seed/identifiers are correct): expected FAIL with a clear
"element not found"; inspect the captured UI tree. Iterate identifiers/seed until
it PASSES. If the local UI host is wedged and cannot run, gate on the PR's CI "UI
Test" job instead (per project guidance) and note it on the PR.

- [ ] **Step 4: `format-check`, then commit**

Run `just -d "$WT" --justfile "$WT/justfile" format-check` — clean.

```bash
git -C "$WT" add MoolahUITests_macOS/InsightChartUITests.swift UITestSupport/
git -C "$WT" commit -m "UI test: insight chart panel opens the detail sheet

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
rm -f "$WT/.agent-tmp/t11.txt"
```

---

## Task 12: Full-suite green + review + PR

**Files:** none (verification + review)

- [ ] **Step 1: Run the full macOS test suite**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac 2>&1 | tee "$WT/.agent-tmp/full.txt"`
Then `grep -i 'failed\|error:' "$WT/.agent-tmp/full.txt"`. Expected: no insight or
chart failures. (The repo's known date-flaky tests were fixed in PR #1051; a clean
run is expected.)

- [ ] **Step 2: Run iOS build to confirm cross-platform**

Run: `just -d "$WT" --justfile "$WT/justfile" build-ios 2>&1 | tee "$WT/.agent-tmp/ios.txt"`
Expected: build clean. The sheet and Swift Charts usage are universal.

- [ ] **Step 3: `format-check` on the whole tree**

Run: `just -d "$WT" --justfile "$WT/justfile" format-check`
Expected: clean (no swift-format diff, no SwiftLint violations).

- [ ] **Step 4: Run the review agents**

Invoke `@code-review` (CODE_GUIDE + architecture/thin-view), `@concurrency-review`
(the chart is `Sendable` and crosses the off-main boundary), and `@ui-review`
(the panel + sheet, accessibility, HIG). Apply ALL findings (Critical/Important/
Minor) per project policy; do not rationalise any away.

- [ ] **Step 5: Push the branch and open the PR**

```bash
git -C "$WT" push origin worktree-insight-companion-graphs:worktree-insight-companion-graphs
gh pr create --repo moolah-rocks/moolah-native --base main \
  --head worktree-insight-companion-graphs \
  --title "Companion graphs for insights" \
  --body "$(cat <<'EOF'
Adds an optional `InsightChart` to `Insight`, computed by the detectors and
rendered by a generic `InsightChartView`. For You insights now show as
full-width panels with a side graph; tapping the graph opens a centered detail
sheet with the enlarged chart, the insight's facts, and its actions.

First cut wires charts for four insight families: category spending
(anomaly/trend), cash-flow forecast (projected month-end / upcoming bill), net
worth milestone, savings-rate trend, and earmark projected burndown. Graph-less
insights are unchanged. Remaining kinds get charts incrementally.

Design + plan: `plans/2026-06-04-insight-companion-graphs-design.md`,
`plans/2026-06-04-insight-companion-graphs-implementation.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 6: Land via the project's merge flow**

Per the `landing-prs` skill, set the PR to auto-merge (`gh pr merge --auto
--rebase`) once CI is green. Do not use the user-level merge-queue skill.

---

## Self-Review (completed during planning)

- **Spec coverage:** `InsightChart` model (Task 1) ✓; generic builder approach
  (Tasks 2,4,5,6,7) ✓; four families wired — category (Task 3), cash-flow (Task 4),
  savings (Task 6), net-worth + earmark (Tasks 5,7) ✓; panel layout B (Task 10) ✓;
  centered detail sheet with facts + actions (Task 9) ✓; graph-less fallback (Task
  10 Step 2) ✓; sparse-data → `nil` (builders' `minimumPoints`) ✓; honest earmark
  projection, not faked history (Task 7) ✓; testing — builder unit + detector +
  one UI test (Tasks 2-7, 11) ✓.
- **Placeholder scan:** the few "confirm the local variable name / driver API /
  seed name by reading X" notes are directed verification steps with the exact
  file:line to read and the full surrounding code shown — not hand-waved content.
- **Type consistency:** `InsightChart`, `InsightChart.Point/Series/Unit/Kind/
  SeriesRole/XAxisStyle`, `InsightChartBuilders.{categorySpend,balanceForecast,
  netWorthTrend,savingsRate,earmarkBurndown}`, and `InsightChartView`/
  `InsightChartDetailSheet` names match across every task. `Insight.chart` is the
  single new property threaded through all detectors and the view.
- **Deviation from spec:** `Point.value` is `Double` (not `Decimal`) to match the
  Swift Charts `LineMark`/`BarMark` y-value idiom and the existing
  `NetWorthGraphCard`; currency values are reconstructed as
  `InstrumentAmount(quantity: Decimal(value), instrument:)` for label formatting,
  exactly as `NetWorthGraphCard` does. Update the design doc's data-model snippet
  to say `Double` if strict consistency is wanted.
