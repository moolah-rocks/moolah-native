# Crypto Account Chart — Progressive Render + Batched Conversions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the crypto account detail screen's chart+positions surface load fast and non-blocking — the positions table appears immediately and the historical chart builds via one batched conversion call instead of ~900 sequential per-day awaits.

**Architecture:** Two independent changes. (1) `PositionsHistoryBuilder.build` is restructured from convert-per-(instrument,day) into *record-then-batch*: the day-by-day fold records pending points without converting, then a single `convertResultBatch` resolves all value conversions concurrently, then points are assembled preserving Rule 11. (2) `MultiInstrumentPositionsSplitModifier` assigns its `PositionsViewInput` in two stages — a positions-only input (table live, chart shows a loading placeholder) as soon as valuation completes, then the full input once the history series is built.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite`/`@Test`), the existing `InstrumentConversionService.convertResultBatch` batch API, `FakeConversionService` test double.

## Global Constraints

- Money/instrument rules: never `abs()` trade legs; conversions use the snapshot date (`on: day`), never `Date()`, for historical points (guides/INSTRUMENT_CONVERSION_GUIDE.md Rule 5).
- Rule 11 (guides/INSTRUMENT_CONVERSION_GUIDE.md): an aggregate/total point is emitted only if *every* contributing instrument's conversion that day is non-failure. `.knownZero` is an intentional zero (contributes 0), NOT a failure. `.failure` drops the day's total; sibling per-instrument series still chart.
- Dates: all day iteration/keys via `Calendar.utc`; chart positioning tokens anchor at noon-UTC (existing `pointDate` logic — preserve verbatim).
- Concurrency: `PositionsHistoryBuilder.build` is `@concurrent`; `BuildState` is exclusively owned by the single build task (no concurrent access). View-state assignment in the modifier is `@MainActor`.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`) — NOT XCTest. One `@Suite` per behaviour family; new suites in their own file to avoid `type_body_length`.
- Format/lint: run `just format-check` after each task; commits skip the whole-repo `swift-format` pre-commit hook only for docs-only commits (`--no-verify`), never for Swift changes.
- Build/test commands: `just build-mac`, `just test-mac`.

---

## File Structure

- `Shared/PositionsHistoryBuilder.swift` — **modify**: record-then-batch internals. Public `build(...)` signature and returned `HistoricalValueSeries` unchanged.
- `MoolahTests/Shared/PositionsHistoryBuilderBatchTests.swift` — **create**: new suite for the single-batch invariant and the `knownZero`-contributes-zero behaviour (kept in its own file per the type_body_length convention).
- `Domain/Models/PositionsViewInput.swift` — **modify**: add `isHistoryLoading: Bool` (default `false`) + a `showsChartLoadingPlaceholder` computed helper.
- `MoolahTests/Domain/PositionsViewInputLoadingTests.swift` — **create**: new suite asserting the loading flag and that it does not affect `showsChart`/`rendersNothing`.
- `Shared/Views/Positions/PositionsView.swift` — **modify**: render a chart-area loading placeholder when `isHistoryLoading` and no series yet.
- `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift` — **modify**: two-stage `positionsInput` assignment (positions-only first, full input second).

---

## Task 1: Batch the historical value conversions in `PositionsHistoryBuilder`

**Files:**
- Modify: `Shared/PositionsHistoryBuilder.swift`
- Create: `MoolahTests/Shared/PositionsHistoryBuilderBatchTests.swift`
- Existing guard (must stay green, unchanged): `MoolahTests/Shared/PositionsHistoryBuilderTests.swift`, `PositionsHistoryBuilderZoneTests.swift`, `PositionsHistoryBuilderMultiAccountTests.swift`, `PositionsContributionsTests.swift`, `MultiInstrumentPositionsCoverageTests.swift`

**Interfaces:**
- Consumes: `InstrumentConversionService.convertResultBatch(_ requests: [BatchConversionRequest]) async throws -> [BatchConversionOutcome]`; `BatchConversionRequest(amount:target:date:)`; `BatchConversionOutcome` = `.value(InstrumentAmount)` / `.knownZero(targetInstrument:)` / `.failure(any Error)`.
- Produces: unchanged `HistoricalValueSeries` from `build(...)`. New private nested types `PendingDay` / `PendingEntry` (internal to the builder, not referenced elsewhere).

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Shared/PositionsHistoryBuilderBatchTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("PositionsHistoryBuilder batch")
struct PositionsHistoryBuilderBatchTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
  let accountId = UUID()

  private func date(daysAfterEpoch days: Int) -> Date {
    var c = DateComponents()
    c.year = 2026
    c.month = 1
    c.day = 1 + days
    return Calendar.utc.date(from: c)!
  }

  private func buy(
    instrument: Instrument, qty: Decimal, fiat: Decimal, daysAfterEpoch days: Int
  ) -> Transaction {
    Transaction(
      date: date(daysAfterEpoch: days),
      legs: [
        TransactionLeg(accountId: accountId, instrument: instrument, quantity: qty, type: .trade),
        TransactionLeg(accountId: accountId, instrument: aud, quantity: -fiat, type: .trade),
      ])
  }

  @Test("build issues exactly one batch covering every held (instrument, day) pair")
  func singleBatch() async {
    // BHP held days 1..5 (5 pts) + CBA held days 2..5 (4 pts) = 9 value requests.
    let txns = [
      buy(instrument: bhp, qty: 100, fiat: 4_000, daysAfterEpoch: 1),
      buy(instrument: cba, qty: 50, fiat: 5_000, daysAfterEpoch: 2),
    ]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50), cba.id: Decimal(110)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    _ = await builder.build(
      transactions: txns, accountId: accountId, hostCurrency: aud,
      range: .oneMonth, now: date(daysAfterEpoch: 5))
    // Exactly one flat batch, not N serial convertResult hops.
    #expect(service.recordedBatches.count == 1)
    #expect(service.recordedBatches.first?.count == 9)
  }

  @Test("knownZero instrument contributes 0 and keeps the day's aggregate")
  func knownZeroContributesZeroKeepsAggregate() async throws {
    // BHP priced, CBA resolves knownZero (spam/unpriced/pre-first-trade analogue).
    let txns = [
      buy(instrument: bhp, qty: 100, fiat: 4_000, daysAfterEpoch: 1),
      buy(instrument: cba, qty: 50, fiat: 5_000, daysAfterEpoch: 2),
    ]
    let service = FakeConversionService.fixedRates(
      [bhp.id: Decimal(50)], knownZero: [cba.id])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId, hostCurrency: aud,
      range: .threeMonths, now: date(daysAfterEpoch: 5))
    // Aggregate kept on every day (unlike a .failure which would drop days ≥ 2):
    // days 1..5 all have a total point.
    #expect(series.totalSeries.count == 5)
    // Day 5 total = BHP 100×50 + CBA 0 = 5000.
    #expect(series.totalSeries.last?.value == 100 * Decimal(50))
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-mac 2>&1 | tee .agent-tmp/t1.txt | grep -iE "PositionsHistoryBuilder batch|singleBatch|knownZero|fail|pass"`
Expected: `singleBatch` FAILS (`recordedBatches.count == 0` — builder still calls per-day `convert`, never `convertResultBatch`); `knownZeroContributesZeroKeepsAggregate` FAILS (`totalSeries.count` is 1, not 5 — plain `convert` throws `knownZeroSource` for CBA so days ≥ 2 drop the total).

- [ ] **Step 3: Implement record-then-batch in `PositionsHistoryBuilder`**

In `Shared/PositionsHistoryBuilder.swift`, replace the per-day-convert flow. Keep `preFoldHistory`, `applyTransactions`, `apply`, `foldContributions`, `BuildContext`, `BuildState` unchanged. Change the `build` day-loop to *record* instead of convert, then batch, then assemble.

Add nested pending types inside `PositionsHistoryBuilder`:

```swift
  /// One held instrument on one day: the quantity to value and the
  /// cost-basis snapshot for that instrument on that day.
  private struct PendingEntry {
    let instrument: Instrument
    let quantity: Decimal
    let cost: Decimal
  }

  /// One day's recorded points, captured during the fold pass before any
  /// conversion runs. `contributions` is the running cumulative
  /// contributions snapshot at that day (Rule 11 sticky latch).
  private struct PendingDay {
    let day: Date
    let pointDate: Date
    let contributions: Decimal?
    var entries: [PendingEntry]
  }
```

Replace the day loop and remove `emitDailyPoints` / `convertValue`. New `build` body from the `var day = start` loop onward:

```swift
    var pending: [PendingDay] = []
    var day = start
    while day <= endDay {
      if Task.isCancelled { return state.series(hostCurrency: hostCurrency) }
      do {
        try await applyTransactions(on: day, context: context, state: &state)
      } catch is CancellationError {
        return state.series(hostCurrency: hostCurrency)
      } catch {
        // see preFoldHistory comment
      }
      pending.append(recordDailyPoints(for: day, state: &state))
      guard let next = Calendar.utc.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }

    // One flat batch of value conversions across every (instrument, day).
    if Task.isCancelled { return state.series(hostCurrency: hostCurrency) }
    var requests: [BatchConversionRequest] = []
    for pendingDay in pending {
      for entry in pendingDay.entries {
        requests.append(
          BatchConversionRequest(
            amount: InstrumentAmount(quantity: entry.quantity, instrument: entry.instrument),
            target: hostCurrency,
            date: pendingDay.day))
      }
    }
    let outcomes: [BatchConversionOutcome]
    do {
      outcomes = try await conversionService.convertResultBatch(requests)
    } catch {
      // CancellationError (or any thrown batch error): the view is being
      // torn down; return whatever the fold produced (no value points).
      return state.series(hostCurrency: hostCurrency)
    }

    assemble(pending: pending, outcomes: outcomes, into: &state)
    return state.series(hostCurrency: hostCurrency)
  }
```

Add the `recordDailyPoints` and `assemble` helpers (replacing `emitDailyPoints`; keep the noon-UTC `pointDate` comment verbatim):

```swift
  /// Record — without converting — one `PendingEntry` per held instrument
  /// on `day`, plus the day's contributions snapshot. Conversion happens
  /// later in one batch. `day` is UTC midnight (conversion key); `pointDate`
  /// is noon UTC (zone-invariant chart positioning token).
  private func recordDailyPoints(
    for day: Date, state: inout BuildState
  ) -> PendingDay {
    let pointDate = Calendar.utc.date(byAdding: .hour, value: 12, to: day) ?? day
    var entries: [PendingEntry] = []
    for (instrument, qty) in state.quantities where qty != 0 {
      let cost = state.engine.openLots(for: instrument)
        .reduce(Decimal(0)) { $0 + $1.remainingCost }
      entries.append(PendingEntry(instrument: instrument, quantity: qty, cost: cost))
    }
    return PendingDay(
      day: day, pointDate: pointDate, contributions: state.contributions, entries: entries)
  }

  /// Fold the batch outcomes back into per-instrument and aggregate points.
  /// Outcomes are in request order — the same nested (day, entry) order the
  /// requests were built in — so a single running index re-pairs them.
  ///
  /// Rule 11: the aggregate/total point for a day is emitted only if no
  /// contributing instrument `.failure`d that day. `.knownZero` is an
  /// intentional zero (value 0, cost still counted) and keeps the day —
  /// matching `convertResult`'s documented net-worth-chart semantics
  /// (a spam / unpriced / pre-first-trade token no longer blanks the day's
  /// total the way the old per-day `convert` throw did).
  private func assemble(
    pending: [PendingDay], outcomes: [BatchConversionOutcome], into state: inout BuildState
  ) {
    var index = 0
    for pendingDay in pending {
      var aggValue: Decimal = 0
      var aggCost: Decimal = 0
      var aggOK = true
      var anyHeld = false
      for entry in pendingDay.entries {
        anyHeld = true
        let outcome = outcomes[index]
        index += 1
        switch outcome {
        case .value(let amount):
          state.perInstrument[entry.instrument.id, default: []].append(
            HistoricalValueSeries.Point(
              date: pendingDay.pointDate, value: amount.quantity, cost: entry.cost,
              contributions: nil))
          aggValue += amount.quantity
          aggCost += entry.cost
        case .knownZero:
          state.perInstrument[entry.instrument.id, default: []].append(
            HistoricalValueSeries.Point(
              date: pendingDay.pointDate, value: 0, cost: entry.cost, contributions: nil))
          aggCost += entry.cost
        case .failure:
          aggOK = false
        }
      }
      if anyHeld && aggOK {
        state.total.append(
          HistoricalValueSeries.Point(
            date: pendingDay.pointDate, value: aggValue, cost: aggCost,
            contributions: pendingDay.contributions))
      }
    }
  }
```

Remove the now-unused `emitDailyPoints` and `convertValue` methods and the `logger` if it becomes unused (the fold path still logs in `apply`/`foldContributions`, so keep `logger`).

- [ ] **Step 4: Run the new tests + the full existing builder suites**

Run: `just test-mac 2>&1 | tee .agent-tmp/t1b.txt | grep -iE "PositionsHistoryBuilder|Contributions|MultiInstrumentPositionsCoverage|fail|pass|error:"`
Expected: `singleBatch` and `knownZeroContributesZeroKeepsAggregate` PASS; every pre-existing `PositionsHistoryBuilder*`, `PositionsContributions`, and `MultiInstrumentPositionsCoverage` test still PASS unchanged (the stock/fiat `.value` and `.failure` paths are byte-identical; `aggregateSkipsOnPartialFailure` still drops days ≥ 2 because `.failingInstruments` yields `.failure`, not `.knownZero`).

- [ ] **Step 5: Verify build + format**

Run: `just build-mac 2>&1 | tail -5 && just format-check`
Expected: build succeeds; format-check clean.

- [ ] **Step 6: Commit**

```bash
git add Shared/PositionsHistoryBuilder.swift MoolahTests/Shared/PositionsHistoryBuilderBatchTests.swift
git commit -m "perf(positions): batch the historical value conversions in PositionsHistoryBuilder

Replace the per-(instrument,day) sequential convert loop with a single
convertResultBatch over all pending value points. knownZero now contributes
0 and keeps the day's aggregate (matching convertResult/net-worth semantics)
instead of the old per-day convert throw dropping the whole day."
```

---

## Task 2: Add `isHistoryLoading` to `PositionsViewInput` and render a chart loading placeholder

**Files:**
- Modify: `Domain/Models/PositionsViewInput.swift`
- Modify: `Shared/Views/Positions/PositionsView.swift`
- Create: `MoolahTests/Domain/PositionsViewInputLoadingTests.swift`

**Interfaces:**
- Produces: `PositionsViewInput.init(..., isHistoryLoading: Bool = false, ...)`; computed `var showsChartLoadingPlaceholder: Bool` (`isHistoryLoading && !showsChart && !rendersNothing`).
- Consumes (Task 3): the new `isHistoryLoading` parameter.

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Domain/PositionsViewInputLoadingTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("PositionsViewInput loading state")
struct PositionsViewInputLoadingTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  private var oneRow: [ValuedPosition] {
    [
      ValuedPosition(
        instrument: bhp, quantity: 100,
        unitPrice: InstrumentAmount(quantity: 50, instrument: aud),
        costBasis: nil, value: InstrumentAmount(quantity: 5_000, instrument: aud))
    ]
  }

  @Test("isHistoryLoading defaults to false")
  func defaultsFalse() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: oneRow, historicalValue: nil)
    #expect(input.isHistoryLoading == false)
    #expect(input.showsChartLoadingPlaceholder == false)
  }

  @Test("loading + no series + rows present shows the placeholder, not the chart")
  func placeholderWhileLoading() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: oneRow, historicalValue: nil,
      isHistoryLoading: true)
    #expect(input.showsChart == false)
    #expect(input.showsChartLoadingPlaceholder == true)
    #expect(input.rendersNothing == false)
  }

  @Test("once the series arrives the chart shows and the placeholder does not")
  func placeholderClearsWhenLoaded() {
    let point = HistoricalValueSeries.Point(
      date: Date(), value: 5_000, cost: 4_000, contributions: nil)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: oneRow,
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [bhp.id: [point]]),
      isHistoryLoading: true)
    #expect(input.showsChart == true)
    #expect(input.showsChartLoadingPlaceholder == false)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `just test-mac 2>&1 | tee .agent-tmp/t2.txt | grep -iE "PositionsViewInput loading|isHistoryLoading|error:|fail|pass"`
Expected: FAILS to compile — `extra argument 'isHistoryLoading' in call` and `value of type 'PositionsViewInput' has no member 'isHistoryLoading'/'showsChartLoadingPlaceholder'`.

- [ ] **Step 3: Add the stored flag + computed helper to `PositionsViewInput`**

In `Domain/Models/PositionsViewInput.swift`, add the stored property near `alwaysShowsFullSurface`:

```swift
  /// `true` while the historical series is still being built asynchronously
  /// (progressive render). The positions table renders immediately; the
  /// chart area shows a loading placeholder until `historicalValue` arrives.
  /// Independent of `hasAnyHistoricalActivity` (which answers "does history
  /// exist at all", not "is it loading right now").
  let isHistoryLoading: Bool
```

Add the parameter to `init` (default `false`, placed after `alwaysShowsFullSurface`'s existing default so it stays source-compatible with all current call sites) and assign it:

```swift
    isHistoryLoading: Bool = false,
```
```swift
    self.isHistoryLoading = isHistoryLoading
```

Add the computed helper alongside `showsChart`:

```swift
  /// Show a chart-area loading placeholder when the series is still being
  /// built and there is a table worth rendering beneath it.
  var showsChartLoadingPlaceholder: Bool {
    isHistoryLoading && !showsChart && !rendersNothing
  }
```

- [ ] **Step 4: Render the placeholder in `PositionsView`**

In `Shared/Views/Positions/PositionsView.swift`, extend the chart region in `body`:

```swift
        if input.showsChart {
          Divider()
          PositionsChart(
            input: input,
            range: $range,
            selection: $selection
          )
          .padding(.vertical, 8)
        } else if input.showsChartLoadingPlaceholder {
          Divider()
          ProgressView()
            .frame(maxWidth: .infinity, minHeight: 160)
            .padding(.vertical, 8)
        }
```

- [ ] **Step 5: Run the tests + build**

Run: `just test-mac 2>&1 | tee .agent-tmp/t2b.txt | grep -iE "PositionsViewInput loading|fail|pass|error:"` then `just build-mac 2>&1 | tail -5 && just format-check`
Expected: all three loading tests PASS; existing `PositionsViewInputChartTests` still PASS; build + format clean.

- [ ] **Step 6: Commit**

```bash
git add Domain/Models/PositionsViewInput.swift Shared/Views/Positions/PositionsView.swift MoolahTests/Domain/PositionsViewInputLoadingTests.swift
git commit -m "feat(positions): chart-area loading placeholder via isHistoryLoading flag"
```

---

## Task 3: Two-stage progressive assignment in `MultiInstrumentPositionsSplitModifier`

**Files:**
- Modify: `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`

**Interfaces:**
- Consumes: `PositionsViewInput.init(..., isHistoryLoading:)` from Task 2; existing `PositionsValuator`, `MultiInstrumentPositionsAssembler`.
- Produces: no new public API — internal sequencing change.

**Rationale:** `valuatePositions()` already computes `rows` (fast, batched, current-date prices) and `assetKeys` before the slow `buildHistoryInput`. Assign a positions-only `PositionsViewInput` (with `isHistoryLoading: true`) at that point so the table renders immediately, then let `buildHistoryInput` overwrite it with the full series-bearing input.

- [ ] **Step 1: Insert the first-stage assignment**

In `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`, in `valuatePositions()`, immediately before the `if !accountIds.isEmpty, let repository = ...` block that calls `buildHistoryInput`, add the positions-only stage:

```swift
    guard !Task.isCancelled else { return }
    // Progressive render: show the positions table immediately with the
    // current valuation; the historical chart fills in from buildHistoryInput
    // below. isHistoryLoading drives the chart-area loading placeholder.
    if !accountIds.isEmpty {
      positionsInput = PositionsViewInput(
        title: title,
        hostCurrency: hostCurrency,
        positions: rows,
        historicalValue: nil,
        assetKeysByInstrumentId: assetKeys,
        isHistoryLoading: true)
    }
    if !accountIds.isEmpty, let repository = session?.backend.transactions {
      await buildHistoryInput(
        conversionService: conversionService,
        rows: rows,
        assetKeys: assetKeys,
        repository: repository
      )
      return
    }
```

(The existing `positionsInput = PositionsViewInput(... historicalValue: nil ...)` fallback for the `accountIds.isEmpty` branch at the end of the method stays as-is — that path has no history and no loading state.)

- [ ] **Step 2: Confirm `buildHistoryInput` overwrites the loading stage**

Read `buildHistoryInput` — its final `positionsInput = input` (after the `guard !Task.isCancelled`) already replaces the first-stage value with the full assembled input (which defaults `isHistoryLoading: false`). No change needed; verify by inspection that both assignments target the same `@State positionsInput` and the second runs after the first.

- [ ] **Step 3: Build + format**

Run: `just build-mac 2>&1 | tail -5 && just format-check`
Expected: build succeeds; format-check clean.

- [ ] **Step 4: Live verification against the repro (required — ViewModifier sequencing has no unit seam)**

The dev Test Profile is only in the debug build. With the debug app running (`just run-mac-with-logs`), drive it via the automate-app wrapper:

```bash
MT=.claude/skills/automate-app/scripts/moolah-tell
$MT 'navigate to account "Macquarie Transactions" of profile "Test Profile"'
sleep 3
$MT 'navigate to account "Crypto - Ethereum (ajsutton.eth)" of profile "Test Profile"'
# Immediately capture the window: the positions table + a chart spinner should
# be visible well before the ~16s the old build took.
$MT 'capture screenshot of profile "Test Profile"'
```

Expected: the positions table paints within a second (spinner in the chart area), and the chart fills in shortly after — versus the pre-fix ~16s blank/blocked pane. Confirm warm re-entry stays instant.

- [ ] **Step 5: Commit**

```bash
git add Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift
git commit -m "feat(positions): progressive render — table first, chart streams in

Assign a positions-only PositionsViewInput (isHistoryLoading) as soon as
valuation completes so the crypto account table paints immediately instead
of blocking on the historical chart build."
```

---

## Task 4: Review gate + PR

- [ ] **Step 1: Run the AI review gate**

Route the working-tree diff through the required reviewers (per guides/AI_PROJECT_GUIDE.md / AI_REVIEW_GATE_GUIDE.md), fixing every finding and re-reviewing until clean:
- `@concurrency-review` — `build` is `@concurrent` + task-group batch; two-stage `@MainActor` assignment.
- `@instrument-conversion-review` — batch outcome mapping, Rule 11, `knownZero`/`failure` semantics, `on: day` per-day rate.
- `@ui-review` — chart loading placeholder.
- `@code-review` — naming, thin-view discipline, dead-code removal (`emitDailyPoints`/`convertValue`).

- [ ] **Step 2: Full suite green**

Run: `just test-mac 2>&1 | tail -30`
Expected: whole macOS suite passes (iOS optional per project norms).

- [ ] **Step 3: Push + open PR + land**

Push the branch, open a PR (body references the spec + this plan and the ~16s→fast measurement), then land via the `landing-prs` skill (auto-queued by default).

---

## Self-Review

**Spec coverage:**
- Progressive render (spec Part 1) → Tasks 2 + 3. ✓ (loading signal = `isHistoryLoading` flag, as the spec's "flag or enum" allowed — flag chosen for minimality.)
- Batch conversions (spec Part 2) → Task 1, record-then-batch via `convertResultBatch`, Rule 11 preserved, fold-pass conversions left inline. ✓
- Known-zero mapping decision (spec open question) → resolved in Task 1: `knownZero → value 0, day kept`, matching `convertResult`'s documented net-worth semantics; locked by `knownZeroContributesZeroKeepsAggregate`. ✓
- Protocol reachability (spec "confirm convertResultBatch on the existential") → confirmed: it is a protocol requirement with a default impl; no protocol change needed. ✓
- Testing (spec) → single-batch invariant, knownZero behaviour, loading-flag unit tests, existing suites as byte-identical guard, live UI verification. Benchmark listed as optional in spec; omitted from the plan as YAGNI for the first cut (re-profile in Task 3 Step 4 is the guard). ✓
- Review gates (spec) → Task 4. ✓

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `isHistoryLoading` / `showsChartLoadingPlaceholder` consistent across Tasks 2–3; `PendingDay`/`PendingEntry` used only within Task 1; `convertResultBatch`/`BatchConversionRequest`/`BatchConversionOutcome` signatures match `Domain/Services/InstrumentConversionService.swift`.
