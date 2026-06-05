# Overspend Insight False-Positive Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the "For You" overspend insight from firing on annual/periodic recurring payments and one-off lumps, while still flagging genuine overspends on regular-spend categories.

**Architecture:** Two independent changes. (1) `CategoryAnomalyInsight` gains two gates — a **regularity gate** (only flag categories with an established monthly baseline, `median > 0`) and a **recurrence/lag guard** (suppress spikes that recur at a fixed cadence, ±1-month drift tolerant). (2) `AnalysisStore` loads a **36-month insight floor** (or more if the UI asks for more — never a cap) as the single source of truth, and the Analysis UI renders **display-clipped projections** of it; the insight engine reads the full loaded data through the existing `sources.analysis.*` path with no new fetch.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite`/`@Test`), GRDB (unchanged — the `:after` filter already exists), `just` build/test tooling.

**Reference spec:** `plans/2026-06-05-overspend-insight-false-positives-design.md`

---

## File Structure

**Modified:**
- `Domain/Insights/Detectors/CategoryAnomalyInsight.swift` — add Gate A (regularity) and Gate B (recurrence/lag); replace internal `Bounds` with `Gates` carrying the recurrence config.
- `Features/Analysis/AnalysisStore.swift` — 36-month load floor; cache keyed on the effective *load* window (refetch only when the request grows).
- `Features/Analysis/Views/AnalysisView.swift` — route the cards to the display-clipped projections.

**Created:**
- `Features/Analysis/AnalysisStore+DisplayWindow.swift` — pure clip helpers + `displayed*` computed projections (keeps `AnalysisStore.swift` under the 400-line `file_length` warning).
- `MoolahTests/Features/AnalysisStoreDisplayWindowTests.swift` — pure-function tests for the load-window math and the clip helpers.

**Tests extended:**
- `MoolahTests/Domain/Insights/SpendAndTrendInsightTests.swift` — new suppression/firing cases.

**Unchanged (verified, not edited):**
- `Features/Insights/InsightStore+Snapshot.swift` — `makeSnapshot()` keeps reading `sources.analysis.expenseBreakdown` (now the full ≥36-month series). No new dependency, no new fetch.
- `Backends/GRDB/Repositories/GRDBAnalysisRepository+ExpenseBreakdown.swift` — already supports `:after`.

---

## Task 1: Gate A — regularity gate in `CategoryAnomalyInsight`

An overspend is only meaningful relative to a regular baseline. A category whose median monthly spend is zero (spend in ≤ half its months) is a lump (one-off purchase) or a rare periodic payment — not an overspend.

**Files:**
- Modify: `Domain/Insights/Detectors/CategoryAnomalyInsight.swift`
- Test: `MoolahTests/Domain/Insights/SpendAndTrendInsightTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these three `@Test` methods inside `struct SpendAndTrendInsightTests` in `MoolahTests/Domain/Insights/SpendAndTrendInsightTests.swift`:

```swift
@Test
func categoryAnomalySuppressesOneOffLump() {
  // A category with a thin trickle then a huge one-off (house deposit). The
  // series is long enough to clear `minimumMonths`, but its median is 0, so
  // there is no regular baseline to "overspend" against.
  let home = Category(name: "Home")
  let magnitudes: [Decimal] = [100, 0, 0, 0, 0, 500_000]
  let months = ["202501", "202502", "202503", "202504", "202505", "202506"]
  let breakdown = zip(months, magnitudes).map { month, magnitude in
    InsightTestSupport.breakdownRow(magnitude, categoryId: home.id, month: month)
  }
  let insights = CategoryAnomalyInsight.detect(
    breakdown: breakdown, categories: Categories(from: [home]), context: context)
  #expect(!insights.contains { $0.kind == .categorySpendingAnomaly })
}

@Test
func categoryAnomalySuppressesAnnualRecurringPayment() {
  // The reported bug: an $80k annual superannuation payment, identical to last
  // year's, in an otherwise-empty category. Median is 0 → not an overspend.
  let superannuation = Category(name: "Superannuation")
  let breakdown = [
    InsightTestSupport.breakdownRow(80_000, categoryId: superannuation.id, month: "202506"),
    InsightTestSupport.breakdownRow(80_000, categoryId: superannuation.id, month: "202606"),
  ]
  let insights = CategoryAnomalyInsight.detect(
    breakdown: breakdown, categories: Categories(from: [superannuation]), context: context)
  #expect(!insights.contains { $0.kind == .categorySpendingAnomaly })
}
```

(The existing `categoryAnomalyFlagsSpike` — dining spends every month, median ≈ 101 — is the "still fires" guard; do not modify it.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-mac SpendAndTrendInsightTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: `categoryAnomalySuppressesOneOffLump` and `categoryAnomalySuppressesAnnualRecurringPayment` FAIL (an anomaly is currently emitted). `categoryAnomalyFlagsSpike` PASSES.

- [ ] **Step 3: Implement Gate A**

In `Domain/Insights/Detectors/CategoryAnomalyInsight.swift`, in `evaluate(...)`, insert the regularity gate as the **first** statement after `let magnitudes = points.map(\.magnitude)` (before the `SeasonalDecomposition.decompose` call):

```swift
let magnitudes = points.map(\.magnitude)
// Gate A — regularity. An overspend is only meaningful against an established
// baseline. A category with spend in <= half its months (median 0) is a lump
// (one-off purchase) or a rare periodic payment, not an overspend.
guard DescriptiveStatistics.median(magnitudes) > 0 else { return nil }
let decomposition = SeasonalDecomposition.decompose(magnitudes, period: 12)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `just test-mac SpendAndTrendInsightTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: all of `categoryAnomalySuppressesOneOffLump`, `categoryAnomalySuppressesAnnualRecurringPayment`, `categoryAnomalyFlagsSpike`, `categoryAnomalyAttachesHighlightedChart` PASS.

- [ ] **Step 5: Commit**

```bash
git -C "$PWD" add Domain/Insights/Detectors/CategoryAnomalyInsight.swift MoolahTests/Domain/Insights/SpendAndTrendInsightTests.swift
git -C "$PWD" commit -m "Insight: suppress overspend on categories without a regular baseline (Gate A)"
```

---

## Task 2: Gate B — recurrence/lag guard in `CategoryAnomalyInsight`

Within a *regular* category, suppress a spike that recurs at a fixed cadence (annual/semi-annual/quarterly), tolerating ±1 month of date drift, so a known periodic bill does not nag every cycle.

**Files:**
- Modify: `Domain/Insights/Detectors/CategoryAnomalyInsight.swift`
- Test: `MoolahTests/Domain/Insights/SpendAndTrendInsightTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these two `@Test` methods to `SpendAndTrendInsightTests`:

```swift
@Test
func categoryAnomalySuppressesDriftedRecurrence() {
  // A regular ~$100/month category (passes Gate A) with a $600 spike that
  // recurred ~12 months earlier, drifted by one month (June yr1 -> July yr2).
  let utilities = Category(name: "Utilities")
  var magnitudes = Array(repeating: Decimal(100), count: 14)
  magnitudes[0] = 600  // 202506 (June, prior year)
  magnitudes[13] = 600  // 202607 (July, this year) — the latest spike
  let months = [
    "202506", "202507", "202508", "202509", "202510", "202511", "202512",
    "202601", "202602", "202603", "202604", "202605", "202606", "202607",
  ]
  let breakdown = zip(months, magnitudes).map { month, magnitude in
    InsightTestSupport.breakdownRow(magnitude, categoryId: utilities.id, month: month)
  }
  let insights = CategoryAnomalyInsight.detect(
    breakdown: breakdown, categories: Categories(from: [utilities]), context: context)
  #expect(!insights.contains { $0.kind == .categorySpendingAnomaly })
}

@Test
func categoryAnomalySuppressesQuarterlyRecurrence() {
  // A regular ~$100/month category with a $600 spike every 3 months. The
  // latest spike matches the lag-3 occurrence, so it is a predictable bill.
  let utilities = Category(name: "Water")
  var magnitudes = Array(repeating: Decimal(100), count: 12)
  for index in [2, 5, 8, 11] { magnitudes[index] = 600 }
  let months = [
    "202507", "202508", "202509", "202510", "202511", "202512",
    "202601", "202602", "202603", "202604", "202605", "202606",
  ]
  let breakdown = zip(months, magnitudes).map { month, magnitude in
    InsightTestSupport.breakdownRow(magnitude, categoryId: utilities.id, month: month)
  }
  let insights = CategoryAnomalyInsight.detect(
    breakdown: breakdown, categories: Categories(from: [utilities]), context: context)
  #expect(!insights.contains { $0.kind == .categorySpendingAnomaly })
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-mac SpendAndTrendInsightTests 2>&1 | tee .agent-tmp/t2.txt`
Expected: `categoryAnomalySuppressesDriftedRecurrence` and `categoryAnomalySuppressesQuarterlyRecurrence` FAIL (the spike is currently flagged). `categoryAnomalyFlagsSpike` still PASSES (its spike has no comparable lag-3/6/12 occurrence).

- [ ] **Step 3: Replace `Bounds` with `Gates` and thread the recurrence config**

In `Domain/Insights/Detectors/CategoryAnomalyInsight.swift`:

Add two defaulted parameters to `detect` (they do not count toward `function_parameter_count` because `ignores_default_parameters` is on):

```swift
static func detect(
  breakdown: [ExpenseBreakdown],
  categories: Categories,
  context: InsightContext,
  minimumMonths: Int = 6,
  threshold: Double = 3,
  minimumOverspendFraction: Double = 0.25,
  recurrenceLags: [Int] = [12, 6, 3],
  recurrenceTolerance: Double = 0.6
) -> [Insight] {
  let series = CategorySpendSeries.build(
    from: breakdown, reportingCurrency: context.reportingCurrency)

  let gates = Gates(
    zScore: threshold,
    overspendFraction: minimumOverspendFraction,
    recurrenceLags: recurrenceLags,
    recurrenceTolerance: recurrenceTolerance)
  var insights: [Insight] = []
  for (categoryId, points) in series where points.count >= minimumMonths {
    guard
      let insight = evaluate(
        categoryId: categoryId,
        points: points,
        categories: categories,
        context: context,
        gates: gates)
    else { continue }
    insights.append(insight)
  }
  return insights
}
```

Replace the `Bounds` struct with `Gates`:

```swift
/// The gate values an anomaly must clear, bundled to keep `evaluate` within
/// the parameter-count budget.
private struct Gates {
  let zScore: Double
  let overspendFraction: Double
  /// Cadence lags (months) checked for a recurring spike: annual, semi-annual,
  /// quarterly.
  let recurrenceLags: [Int]
  /// A prior spike at a cadence lag of at least this fraction of the latest
  /// spike's magnitude counts as "recurring".
  let recurrenceTolerance: Double
}
```

Update `evaluate`'s signature and the two gate references, and add the Gate B check immediately before the `let resolved = ...` line that begins building the `Insight`:

```swift
private static func evaluate(
  categoryId: UUID,
  points: [MonthlySpendPoint],
  categories: Categories,
  context: InsightContext,
  gates: Gates
) -> Insight? {
  let magnitudes = points.map(\.magnitude)
  // Gate A — regularity (see Task 1).
  guard DescriptiveStatistics.median(magnitudes) > 0 else { return nil }
  let decomposition = SeasonalDecomposition.decompose(magnitudes, period: 12)
  let remainder = decomposition.remainder
  guard let latest = points.last, remainder.count == points.count else { return nil }

  let latestRemainder = remainder[remainder.count - 1]
  let priorRemainders = Array(remainder.dropLast())
  let zScore = DescriptiveStatistics.robustZScore(of: latestRemainder, in: priorRemainders)
  guard zScore >= gates.zScore, latestRemainder > 0 else { return nil }

  let expected =
    decomposition.trend[remainder.count - 1]
    + decomposition.seasonal[remainder.count - 1]
  guard expected > 0 else { return nil }
  let overspendFraction = latestRemainder / expected
  guard overspendFraction >= gates.overspendFraction else { return nil }

  // Gate B — recurrence. Suppress a spike that recurs at a fixed cadence
  // (annual/semi-annual/quarterly), tolerating +/-1 month of date drift, so a
  // predictable periodic bill does not nag every cycle.
  guard
    !isRecurringSpike(
      magnitudes: magnitudes, lags: gates.recurrenceLags,
      tolerance: gates.recurrenceTolerance)
  else { return nil }

  let resolved =
    categoryId == CategorySpendSeries.uncategorizedKey
    ? nil : categories.by(id: categoryId)
  // ... unchanged Insight construction ...
}
```

Add the `isRecurringSpike` helper (place it next to `percent(_:)`):

```swift
/// True when the latest month's spike has a comparable spike (>= `tolerance`
/// of its magnitude) at one of the cadence `lags`, allowing +/-1 month of
/// date drift across month buckets.
private static func isRecurringSpike(
  magnitudes: [Double], lags: [Int], tolerance: Double
) -> Bool {
  guard let latest = magnitudes.last, latest > 0 else { return false }
  let latestIndex = magnitudes.count - 1
  let floor = latest * tolerance
  for lag in lags {
    for offset in -1...1 {
      let index = latestIndex - lag + offset
      guard index >= 0, index < latestIndex else { continue }
      if magnitudes[index] >= floor { return true }
    }
  }
  return false
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `just test-mac SpendAndTrendInsightTests 2>&1 | tee .agent-tmp/t2.txt`
Expected: all `SpendAndTrendInsightTests` PASS — the two new recurrence tests, plus the Task 1 suppression tests, plus `categoryAnomalyFlagsSpike` and `categoryAnomalyAttachesHighlightedChart`.

- [ ] **Step 5: Commit**

```bash
git -C "$PWD" add Domain/Insights/Detectors/CategoryAnomalyInsight.swift MoolahTests/Domain/Insights/SpendAndTrendInsightTests.swift
git -C "$PWD" commit -m "Insight: suppress cadenced recurring spikes in overspend detector (Gate B)"
```

---

## Task 3: `AnalysisStore` — 36-month insight load floor

Load at least 36 months for the insight engine, regardless of the Analysis display filter; never cap a larger UI request; refetch only when the request reaches further back than the cache.

**Files:**
- Modify: `Features/Analysis/AnalysisStore.swift`
- Create: `Features/Analysis/AnalysisStore+DisplayWindow.swift` (the pure `effectiveLoadMonths` helper lands here; clip helpers are added in Task 4)
- Test: `MoolahTests/Features/AnalysisStoreDisplayWindowTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Features/AnalysisStoreDisplayWindowTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — effective load window")
struct AnalysisStoreLoadWindowTests {

  @Test("a narrow display filter still loads the insight floor")
  func narrowFilterLoadsFloor() {
    #expect(
      AnalysisStore.effectiveLoadMonths(historyMonths: 3, floorMonths: 36) == 36)
  }

  @Test("a wide display filter loads the wider window, not the floor")
  func wideFilterLoadsRequested() {
    #expect(
      AnalysisStore.effectiveLoadMonths(historyMonths: 60, floorMonths: 36) == 60)
  }

  @Test("All (0) loads everything")
  func allLoadsEverything() {
    #expect(
      AnalysisStore.effectiveLoadMonths(historyMonths: 0, floorMonths: 36) == Int.max)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `just test-mac AnalysisStoreLoadWindowTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: FAIL to build — `effectiveLoadMonths` does not exist yet.

- [ ] **Step 3: Add the floor constant and the pure window helper**

Create `Features/Analysis/AnalysisStore+DisplayWindow.swift`:

```swift
import Foundation

// MARK: - Load window + display clipping

extension AnalysisStore {
  /// Minimum history (months) loaded for the insight engine, regardless of the
  /// Analysis screen's display filter. Three years gives the category-anomaly
  /// detector enough same-month samples to recognise an annual pattern instead
  /// of mis-flagging it as an overspend. A *minimum*, never a cap.
  static let insightHistoryFloorMonths = 36

  /// The effective load window in months: the larger of the user's display
  /// filter and the insight floor. `historyMonths == 0` ("All") loads
  /// everything, represented as `Int.max`.
  static func effectiveLoadMonths(historyMonths: Int, floorMonths: Int) -> Int {
    historyMonths == 0 ? Int.max : max(historyMonths, floorMonths)
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `just test-mac AnalysisStoreLoadWindowTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: all three PASS.

- [ ] **Step 5: Wire the floor into `loadAll` and re-key the cache**

In `Features/Analysis/AnalysisStore.swift`, replace the cache fields (currently `cachedHistoryMonths` / `hasCachedData` around lines 17–22):

```swift
/// The effective *load* window (months) of the currently cached data —
/// `max(historyMonths, insightHistoryFloorMonths)`, or `Int.max` for "All".
/// Keyed on the load window (not the display filter) so narrowing the UI
/// window re-clips from cache instead of refetching; only a request that
/// reaches further back than the cache triggers a new load.
private var cachedLoadMonths: Int?
private var cachedForecastMonths: Int?
private var hasCachedData: Bool {
  cachedLoadMonths != nil && !dailyBalances.isEmpty
}
```

Replace the body of `loadAll()` (the cache/fetch section, currently lines 79–133) with:

```swift
func loadAll() async {
  monthEnd = Calendar.current.component(.day, from: Date())
  error = nil

  // Load the larger of the user's display window and the insight floor.
  let requestedLoadMonths = Self.effectiveLoadMonths(
    historyMonths: historyMonths, floorMonths: Self.insightHistoryFloorMonths)

  // Refetch only when the request reaches further back than the cache, the
  // forecast window changed, or nothing is loaded yet. Narrowing the display
  // filter needs no fetch — `displayed*` re-clips the cached data.
  let needsLoad =
    !hasCachedData
    || forecastMonths != cachedForecastMonths
    || requestedLoadMonths > (cachedLoadMonths ?? 0)
  guard needsLoad else { return }

  isLoading = true
  let growing = requestedLoadMonths > (cachedLoadMonths ?? 0)
  if growing {
    // Dropping stale narrower data so the spinner shows while we widen.
    dailyBalances = []
    expenseBreakdown = []
    incomeAndExpense = []
  }

  do {
    let after: Date? =
      historyMonths == 0
      ? nil
      : afterDate(monthsAgo: max(historyMonths, Self.insightHistoryFloorMonths))
    let forecastUntil = forecastDate(monthsAhead: forecastMonths)

    let data = try await repository.loadAll(
      historyAfter: after,
      forecastUntil: forecastUntil,
      monthEnd: monthEnd
    )

    dailyBalances = Self.extrapolateBalances(
      data.dailyBalances, today: Date(), forecastUntil: forecastUntil
    )
    expenseBreakdown = data.expenseBreakdown
    incomeAndExpense = data.incomeAndExpense.sorted { $0.month > $1.month }

    cachedLoadMonths = requestedLoadMonths
    cachedForecastMonths = forecastMonths
    lastLoadedAt = Date()
  } catch is CancellationError {
    // View teardown / supersession — see AnalysisView's `.task`. A re-mount
    // issues its own `loadAll()`.
    isLoading = false
    return
  } catch {
    logger.error("Failed to load analysis data: \(error)")
    self.error = error
  }

  isLoading = false
}
```

- [ ] **Step 6: Build and run the AnalysisStore suite**

Run: `just build-mac 2>&1 | tee .agent-tmp/t3-build.txt`
Expected: builds with no warnings (project treats warnings as errors).

Run: `just test-mac AnalysisStoreLoadWindowTests AnalysisStoreRefreshIfStaleTests AnalysisStoreFilterPersistenceTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: all PASS (the refresh/persistence suites are unaffected — they don't assert refetch-on-filter-change).

- [ ] **Step 7: Commit**

```bash
git -C "$PWD" add Features/Analysis/AnalysisStore.swift Features/Analysis/AnalysisStore+DisplayWindow.swift MoolahTests/Features/AnalysisStoreDisplayWindowTests.swift
git -C "$PWD" commit -m "Analysis: load a 36-month insight floor, refetch only when the window grows"
```

---

## Task 4: `AnalysisStore` — display-window clipping for the UI

The store now holds the full ≥36-month data. The Analysis UI takes a smaller window into it via clipped projections; insights keep reading the full arrays.

**Files:**
- Modify: `Features/Analysis/AnalysisStore+DisplayWindow.swift` (add clip helpers + `displayed*` projections)
- Modify: `Features/Analysis/AnalysisStore.swift` (`categoriesOverTime` builds from the clipped breakdown)
- Modify: `Features/Analysis/Views/AnalysisView.swift` (cards read `displayed*`)
- Test: `MoolahTests/Features/AnalysisStoreDisplayWindowTests.swift`

- [ ] **Step 1: Write the failing tests**

Add a second suite to `MoolahTests/Features/AnalysisStoreDisplayWindowTests.swift`:

```swift
@Suite("AnalysisStore — display clipping")
struct AnalysisStoreClipTests {
  // 2026-06-15 anchor so month maths is deterministic.
  private let now = {
    var c = DateComponents()
    c.year = 2026; c.month = 6; c.day = 15
    return Calendar.current.date(from: c) ?? Date()
  }()

  private func breakdown(_ month: String) -> ExpenseBreakdown {
    ExpenseBreakdown(
      categoryId: UUID(), month: month,
      totalExpenses: InstrumentAmount(quantity: -100, instrument: .defaultTestInstrument))
  }

  @Test("breakdown clips to the display window, keeping recent months")
  func clipsBreakdown() {
    let rows = ["202506", "202507", "202601", "202606"].map(breakdown)
    // 3-month display window from 2026-06 keeps 202603..202606 → only 202606.
    let clipped = AnalysisStore.clipBreakdown(rows, historyMonths: 3, now: now)
    #expect(clipped.map(\.month) == ["202606"])
  }

  @Test("breakdown All (0) returns everything")
  func clipsBreakdownAll() {
    let rows = ["202506", "202606"].map(breakdown)
    #expect(AnalysisStore.clipBreakdown(rows, historyMonths: 0, now: now).count == 2)
  }

  @Test("balances clip by date but always keep forecast rows")
  func clipsBalancesKeepingForecast() {
    let old = DailyBalance(
      date: cal(monthsFromNow: -10),
      balance: InstrumentAmount(quantity: 1, instrument: .defaultTestInstrument))
    let recent = DailyBalance(
      date: cal(monthsFromNow: -1),
      balance: InstrumentAmount(quantity: 2, instrument: .defaultTestInstrument))
    let forecast = DailyBalance(
      date: cal(monthsFromNow: 2),
      balance: InstrumentAmount(quantity: 3, instrument: .defaultTestInstrument),
      earmarked: .zero(instrument: .defaultTestInstrument),
      availableFunds: InstrumentAmount(quantity: 3, instrument: .defaultTestInstrument),
      investments: .zero(instrument: .defaultTestInstrument),
      investmentValue: nil,
      netWorth: InstrumentAmount(quantity: 3, instrument: .defaultTestInstrument),
      bestFit: nil,
      isForecast: true)
    let clipped = AnalysisStore.clipBalances(
      [old, recent, forecast], historyMonths: 3, now: now)
    // `old` (10 months back) drops; `recent` stays; `forecast` always stays.
    #expect(clipped.contains { $0.balance.quantity == 2 })
    #expect(clipped.contains { $0.balance.quantity == 3 })
    #expect(!clipped.contains { $0.balance.quantity == 1 })
  }

  private func cal(monthsFromNow: Int) -> Date {
    Calendar.current.date(byAdding: .month, value: monthsFromNow, to: now) ?? now
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-mac AnalysisStoreClipTests 2>&1 | tee .agent-tmp/t4.txt`
Expected: FAIL to build — `clipBreakdown` / `clipBalances` do not exist yet.

- [ ] **Step 3: Add the clip helpers and `displayed*` projections**

Append to `extension AnalysisStore` in `Features/Analysis/AnalysisStore+DisplayWindow.swift`:

```swift
// MARK: - Display clipping (pure)

/// First `YYYYMM` bucket visible for a display window, or `nil` for "All".
static func displayStartMonth(historyMonths: Int, now: Date) -> String? {
  guard historyMonths > 0,
    let start = Calendar.current.date(byAdding: .month, value: -historyMonths, to: now)
  else { return nil }
  let components = Calendar.current.dateComponents([.year, .month], from: start)
  return String(format: "%04d%02d", components.year ?? 0, components.month ?? 0)
}

/// Clips breakdown rows to the display window (string compare on `YYYYMM`).
static func clipBreakdown(
  _ rows: [ExpenseBreakdown], historyMonths: Int, now: Date
) -> [ExpenseBreakdown] {
  guard let startMonth = displayStartMonth(historyMonths: historyMonths, now: now)
  else { return rows }
  return rows.filter { $0.month >= startMonth }
}

/// Clips income/expense rows to the display window (string compare on `YYYYMM`).
static func clipIncomeExpense(
  _ rows: [MonthlyIncomeExpense], historyMonths: Int, now: Date
) -> [MonthlyIncomeExpense] {
  guard let startMonth = displayStartMonth(historyMonths: historyMonths, now: now)
  else { return rows }
  return rows.filter { $0.month >= startMonth }
}

/// Clips daily balances to the display window. Forecast rows (future-dated)
/// are always kept so the net-worth chart still draws its forecast tail.
static func clipBalances(
  _ balances: [DailyBalance], historyMonths: Int, now: Date
) -> [DailyBalance] {
  guard historyMonths > 0,
    let start = Calendar.current.date(byAdding: .month, value: -historyMonths, to: now)
  else { return balances }
  let startDay = Calendar.current.startOfDay(for: start)
  return balances.filter { $0.isForecast || $0.date >= startDay }
}

// MARK: - Display projections (consumed by AnalysisView)

/// Daily balances clipped to the current display window.
var displayedDailyBalances: [DailyBalance] {
  Self.clipBalances(dailyBalances, historyMonths: historyMonths, now: Date())
}

/// Expense breakdown clipped to the current display window.
var displayedExpenseBreakdown: [ExpenseBreakdown] {
  Self.clipBreakdown(expenseBreakdown, historyMonths: historyMonths, now: Date())
}

/// Income/expense rows clipped to the current display window.
var displayedIncomeAndExpense: [MonthlyIncomeExpense] {
  Self.clipIncomeExpense(incomeAndExpense, historyMonths: historyMonths, now: Date())
}
```

- [ ] **Step 4: Point `categoriesOverTime` at the clipped breakdown**

In `Features/Analysis/AnalysisStore.swift`, change the instance method `categoriesOverTime(categories:)` (currently line ~194) to build from the clipped projection:

```swift
func categoriesOverTime(categories: Categories) -> [CategoryOverTimeEntry] {
  Self.buildCategoriesOverTime(from: displayedExpenseBreakdown, categories: categories)
}
```

- [ ] **Step 5: Route the Analysis cards to the clipped projections**

In `Features/Analysis/Views/AnalysisView.swift`, update the card inputs:
- `NetWorthGraphCard(balances: store.dailyBalances)` → `NetWorthGraphCard(balances: store.displayedDailyBalances)`
- the `ExpenseBreakdownCard` input `breakdown: store.expenseBreakdown` → `breakdown: store.displayedExpenseBreakdown`
- both `IncomeExpenseTableCard(data: store.incomeAndExpense)` call sites → `IncomeExpenseTableCard(data: store.displayedIncomeAndExpense)`

Leave the instrument derivation `store.dailyBalances.first?.balance.instrument ?? .AUD` and the `store.isLoading && store.dailyBalances.isEmpty` loading check reading the full `dailyBalances` (the instrument is uniform across the series, and "empty" must reflect the real load state).

- [ ] **Step 6: Build and run the clip + insight suites**

Run: `just build-mac 2>&1 | tee .agent-tmp/t4-build.txt`
Expected: builds with no warnings.

Run: `just test-mac AnalysisStoreClipTests AnalysisStoreLoadWindowTests 2>&1 | tee .agent-tmp/t4.txt`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git -C "$PWD" add Features/Analysis/AnalysisStore+DisplayWindow.swift Features/Analysis/AnalysisStore.swift Features/Analysis/Views/AnalysisView.swift MoolahTests/Features/AnalysisStoreDisplayWindowTests.swift
git -C "$PWD" commit -m "Analysis: render display-clipped projections; insights read the full series"
```

---

## Task 5: Verify the insight path sees the full series (no code change expected)

Confirm `InsightStore.makeSnapshot()` still reads the full loaded data and that no other consumer was accidentally narrowed.

**Files:**
- Inspect only: `Features/Insights/InsightStore+Snapshot.swift`, all readers of `expenseBreakdown` / `dailyBalances` / `incomeAndExpense`.

- [ ] **Step 1: Confirm `makeSnapshot` reads the full arrays**

Run: `grep -n "sources.analysis" Features/Insights/InsightStore+Snapshot.swift`
Expected: `expenseBreakdown: sources.analysis.expenseBreakdown`, `dailyBalances: sources.analysis.dailyBalances`, `monthly: sources.analysis.incomeAndExpense` — i.e. the full (un-clipped) properties. No change needed.

- [ ] **Step 2: Confirm no other consumer should have been clipped**

Run: `grep -rn "\.expenseBreakdown\|\.dailyBalances\|\.incomeAndExpense" Features --include="*.swift" | grep -v "displayed\|AnalysisStore.swift\|InsightStore+Snapshot.swift\|AnalysisStore+DisplayWindow.swift"`
Expected: only `AnalysisView.swift`'s deliberately-full reads (instrument derivation, loading check). If any *other* Analysis card reads a full array where it should show the user's window, switch it to the matching `displayed*` projection and note it in the commit. Insight/reporting reads of the full arrays are correct as-is.

- [ ] **Step 3: Commit only if a consumer was re-routed**

```bash
git -C "$PWD" add -A && git -C "$PWD" commit -m "Analysis: route remaining display consumer to clipped projection"
```

(Skip this commit if Step 2 found nothing to change.)

---

## Task 6: Full verification, formatting, and review

**Files:** none (verification only).

- [ ] **Step 1: Format**

Run: `just format`
Then: `just format-check`
Expected: `format-check` exits 0 (no diff, no SwiftLint violation). Fix any reported violation by editing the code (split/rename) — never by adding a baseline or `swiftlint:disable`.

- [ ] **Step 2: Full test suite (both platforms)**

Run: `mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/full-test.txt`
Then: `grep -i 'failed\|error:' .agent-tmp/full-test.txt`
Expected: no failures. Pay attention to `SpendAndTrendInsightTests`, `AnalysisStoreDisplayWindowTests`, and the existing `AnalysisStore*` suites.

- [ ] **Step 3: Compiler warnings**

Run: `just build-mac 2>&1 | tee .agent-tmp/warn.txt` and check for `warning:` in user code.
Expected: none (warnings-as-errors would already have failed the build).

- [ ] **Step 4: Agent reviews**

Dispatch the project review agents on the diff:
- `code-review` — `CategoryAnomalyInsight.swift`, `AnalysisStore.swift`, `AnalysisStore+DisplayWindow.swift` (naming, thin-view discipline, type choice).
- `concurrency-review` — `AnalysisStore` changes (main-actor isolation, the `loadAll` guard/early-return, cache fields).
- `ui-review` — `AnalysisView.swift` (the clipped projections feeding the cards).

Apply all Critical/Important/Minor findings (per project policy: pre-existing-in-another-file is not a skip reason; ask before deferring).

- [ ] **Step 5: Manual end-to-end check (Large Test Profile)**

Using the `automate-app` / `run-mac-app-with-logs` skill, launch with the Large Test Profile and open the For You surface. Confirm the *"You've overspent by 600% on superannuation"* card is gone, and that a genuinely irregular-but-regular category spike (if present) still surfaces. Set the Analysis screen to 3 months, then 5 years, then All, and confirm the net-worth/category/income cards re-window without a reload stutter and the 5-year/All views are not capped to 36 months.

- [ ] **Step 6: Finish the branch**

Use `superpowers:finishing-a-development-branch` to push and open the PR, then land it per the project's `landing-prs` skill. PR body should reference the design + plan docs and the reported false-positive.

---

## Self-Review (completed during planning)

- **Spec coverage:** Gate A regularity → Task 1; Gate B recurrence/lag → Task 2; load floor + max-not-cap + cache-on-load-window → Task 3; load-wide/window-for-UI → Task 4; insights read full via existing path → Task 5; tests for every gate + window/clip → Tasks 1,2,3,4; format/build/review → Task 6. All spec sections mapped.
- **Type consistency:** `Gates` (not `Bounds`) is used in both `detect` and `evaluate`; `effectiveLoadMonths`, `clipBreakdown`, `clipBalances`, `clipIncomeExpense`, `displayStartMonth`, `displayed{DailyBalances,ExpenseBreakdown,IncomeAndExpense}`, `insightHistoryFloorMonths`, `cachedLoadMonths` are named identically at definition and call sites.
- **No placeholders:** every code step contains complete, compiling code and exact `just` commands with expected output.
