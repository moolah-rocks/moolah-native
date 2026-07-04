# Contiguous price-cache extension — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the crypto/stock/FX historic price caches grow only as a single contiguous date range, so the prior-trading-day fallback only ever covers genuine no-price days — eliminating the silently-stale-value bug from never-fetched interior gaps.

**Architecture:** Extract one pure, unit-tested window planner (`ContiguousFetchPlanner`) that, given a series' current `[earliest, latest]` bounds and a requested date, returns the next **bounded, boundary-anchored** fetch window (or `nil` when covered). The three services (`CryptoPriceService`, `StockPriceService`, `ExchangeRateService`) replace their unbounded `extensionWindow`/`fetchToCoverDate` logic with a loop driven by this planner, and advance their bounds only across data the planner's window actually returned. A one-time GRDB migration purges all existing (untrustworthy) cache rows so they re-warm contiguously.

**Tech Stack:** Swift 6 actors, GRDB, Swift Testing (`@Test`/`@Suite`), `just` build/test targets, `DateKey` (Int32 yyyymmdd), `SortedDateSeries`.

**Spec:** `plans/2026-06-17-contiguous-price-cache-extension-design.md`

---

## Background the engineer needs

- All three price caches live in the **profile-index** database (shared across profiles), tables `crypto_price`/`crypto_token_meta`, `stock_price`/`stock_ticker_meta`, `exchange_rate`/`exchange_rate_meta`. Schema: `Backends/GRDB/ProfileIndexSchema+SharedInstrumentRegistry.swift`. The rate caches are **local, derived, un-synced** — safe to purge and re-warm.
- Each service is a non-`@MainActor` `actor` with `caches: [Key: …Cache]`, `hydrated…: Set<…>`, an `ISO8601DateFormatter` (`[.withFullDate]`), `now: @Sendable () -> Date`, `timeZone`, and a `database: any DatabaseWriter`.
- Dates on the wire and in bounds are ISO `"YYYY-MM-DD"` strings; in-memory series are keyed by `DateKey` (`Int32` yyyymmdd). `DateKey.from(isoString:)` / `DateKey.isoString(_:)` convert; integer order equals chronological order.
- The bug (see spec): `extensionWindow` returns an **unbounded** `[latest … requested]`; a provider serving only a recent tail makes the merge advance `latest` past an un-fetched span. Bounding the window to `W` days makes any in-window gap genuinely "queried, no data," so the boundary can never jump past unqueried days.
- **Read path is unchanged.** `inRangeFallback` (prior-trading-day `floor`) stays — it is correct once coverage is contiguous.
- **No global forward cap** (all four providers tolerate future dates — verified). Forward windows extend up to `today + forwardBuffer` so a forward-timezone market (ASX) close is never withheld.
- Build/test: `just build-mac`, `just test-mac <Filter>`, `just format-check`. Capture output to `.agent-tmp/` per CLAUDE.md. New test files are Swift Testing suites; per memory `reference_insight_chart_test_file_splitting`, keep each new suite in its own file (≤250-line `type_body_length`).

## File structure

**Create:**
- `Shared/ContiguousFetchPlanner.swift` — pure window planner (the fix's core).
- `MoolahTests/Shared/ContiguousFetchPlannerTests.swift` — exhaustive unit tests for the planner.
- `MoolahTests/Shared/ContiguousExtensionCryptoTests.swift` — crypto service contiguity tests.
- `MoolahTests/Shared/ContiguousExtensionStockTests.swift` — stock service contiguity tests.
- `MoolahTests/Shared/ContiguousExtensionFXTests.swift` — FX service contiguity tests.
- `Backends/GRDB/ProfileIndexSchema+PurgeRateCaches.swift` — purge migration body.
- `MoolahTests/Backends/PurgeRateCachesMigrationTests.swift` — migration test.

**Modify:**
- `Shared/CryptoPriceService.swift` — replace `extensionWindow`; loop the planner in `price(...)`; advance bounds within the loop.
- `Shared/StockPriceService.swift` — replace `fetchToCoverDate`'s window math; loop the planner.
- `Shared/ExchangeRateService.swift` — replace `fetchToCoverDate`'s window math; loop the planner.
- `Backends/GRDB/ProfileIndexSchema.swift` (or wherever the profile-index migrator is registered) — register the purge migration.

---

## Phase 1 — The shared window planner (pure, fully tested)

The planner is pure arithmetic on `Int32` DateKeys. No I/O, no actor. This is where the correctness lives, so it gets exhaustive tests first.

### Task 1: Planner type + "already covered returns nil"

**Files:**
- Create: `Shared/ContiguousFetchPlanner.swift`
- Test: `MoolahTests/Shared/ContiguousFetchPlannerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing

@testable import Moolah

@Suite struct ContiguousFetchPlannerTests {
  // DateKeys are yyyymmdd ints; use real calendar days so +1 day math is exercised.
  static let jan01: Int32 = 20240101
  static let jan15: Int32 = 20240115
  static let jan31: Int32 = 20240131
  static let feb15: Int32 = 20240215

  @Test func requestedInsideBoundsReturnsNil() {
    let window = ContiguousFetchPlanner.nextWindow(
      earliest: Self.jan01, latest: Self.jan31,
      requested: Self.jan15, today: Self.feb15,
      windowDays: 30, forwardBuffer: 2)
    #expect(window == nil)
  }
}
```

- [ ] **Step 2: Run it, verify it fails to compile (type missing)**

Run: `just test-mac ContiguousFetchPlannerTests 2>&1 | tee .agent-tmp/planner.txt`
Expected: FAIL — `cannot find 'ContiguousFetchPlanner' in scope`.

- [ ] **Step 3: Create the planner with the covered-case branch**

```swift
// Shared/ContiguousFetchPlanner.swift
import Foundation

/// Plans the next **bounded, boundary-anchored** fetch window for a
/// contiguous date-keyed price/rate cache. Pure arithmetic on `DateKey`
/// (`Int32` yyyymmdd) — no I/O. Bounding the window is what keeps a cache
/// contiguous: a provider can only ever serve days inside a window the
/// planner already declared queried, so the cache's `[earliest, latest]`
/// can never advance past a day that was never fetched.
///
/// `nil` means "the requested date is already inside `[earliest, latest]`"
/// — the caller reads it via the prior-trading-day fallback, no fetch.
enum ContiguousFetchPlanner {
  /// - earliest/latest: current contiguous bounds as `DateKey`, or `nil`
  ///   when the series is empty (cold cache).
  /// - requested: the `DateKey` the caller needs.
  /// - today: the `DateKey` for "now" (callers pass `now()`'s day). Forward
  ///   windows may extend up to `today + forwardBuffer` — providers tolerate
  ///   slight future dates and clamp, so this never withholds a
  ///   forward-timezone market's already-published close.
  /// - windowDays: max span of a single window (≈30). Large enough to clear
  ///   a weekend/holiday run, small enough that a provider serves it whole.
  /// - forwardBuffer: days past `today` a forward window may reach (≈2).
  static func nextWindow(
    earliest: Int32?, latest: Int32?,
    requested: Int32, today: Int32,
    windowDays: Int, forwardBuffer: Int
  ) -> ClosedRange<Int32>? {
    guard let earliest, let latest else {
      return coldWindow(
        requested: requested, today: today,
        windowDays: windowDays, forwardBuffer: forwardBuffer)
    }
    if requested >= earliest && requested <= latest { return nil }
    return nil  // filled in by later tasks
  }

  private static func coldWindow(
    requested: Int32, today: Int32, windowDays: Int, forwardBuffer: Int
  ) -> ClosedRange<Int32>? {
    return nil  // filled in by Task 4
  }
}
```

- [ ] **Step 4: Run it, verify pass**

Run: `just test-mac ContiguousFetchPlannerTests 2>&1 | tee .agent-tmp/planner.txt`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/ContiguousFetchPlanner.swift MoolahTests/Shared/ContiguousFetchPlannerTests.swift
git commit -m "feat(price-cache): ContiguousFetchPlanner skeleton + covered-case"
```

> **DateKey arithmetic note for all planner tasks:** `Int32` yyyymmdd is *not* contiguous across month boundaries (20240131 + 1 ≠ 20240201). The planner must convert via `DateKey.isoString` → `Date` (using `Calendar.utc`) → add/subtract days → `DateKey.from(isoString:)`. Add a private helper `addingDays(_:to:)` in Task 2 and use it everywhere; never do raw `Int32` ± arithmetic on DateKeys.

### Task 2: DateKey day-arithmetic helper

**Files:**
- Modify: `Shared/ContiguousFetchPlanner.swift`
- Test: `MoolahTests/Shared/ContiguousFetchPlannerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
  @Test func addingDaysCrossesMonthBoundary() {
    #expect(ContiguousFetchPlanner.addingDays(1, to: 20240131) == 20240201)
    #expect(ContiguousFetchPlanner.addingDays(-1, to: 20240301) == 20240229) // leap year
    #expect(ContiguousFetchPlanner.addingDays(30, to: 20240101) == 20240131)
  }
```

- [ ] **Step 2: Run, verify fail** (`addingDays` not found).

Run: `just test-mac ContiguousFetchPlannerTests/addingDaysCrossesMonthBoundary 2>&1 | tee .agent-tmp/planner.txt`
Expected: FAIL.

- [ ] **Step 3: Implement `addingDays` using `Calendar.utc`**

```swift
// add inside enum ContiguousFetchPlanner
static func addingDays(_ days: Int, to key: Int32) -> Int32 {
  let iso = DateKey.isoString(key)
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withFullDate]
  formatter.timeZone = TimeZone(identifier: "UTC")
  guard let date = formatter.date(from: iso),
    let shifted = Calendar.utc.date(byAdding: .day, value: days, to: date),
    let result = DateKey.from(isoString: formatter.string(from: shifted))
  else { return key }
  return result
}
```

> If `ISO8601DateFormatter` with `[.withFullDate]` parses midnight-UTC consistently in this codebase's existing services (it does — see `loadCache`), reuse that. `Calendar.utc` is the project's UTC calendar (see `guides/DATE_TIME_GUIDE.md`).

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit** (`feat(price-cache): DateKey day arithmetic helper`).

### Task 3: Forward window (bounded, anchored, future-capped)

**Files:** Modify planner + test.

- [ ] **Step 1: Write the failing tests**

```swift
  @Test func forwardWindowIsBoundedAndAnchoredAtLatest() {
    // latest=Jan15, requested far ahead → window [Jan15 … Jan15+30], not [Jan15 … requested].
    let w = ContiguousFetchPlanner.nextWindow(
      earliest: 20240101, latest: 20240115,
      requested: 20240601, today: 20240601,
      windowDays: 30, forwardBuffer: 2)
    #expect(w == 20240115...20240214) // includes latest (re-query to overwrite stale), spans 30 days
  }

  @Test func forwardWindowStopsAtRequestedWhenNearer() {
    let w = ContiguousFetchPlanner.nextWindow(
      earliest: 20240101, latest: 20240115,
      requested: 20240120, today: 20240601,
      windowDays: 30, forwardBuffer: 2)
    #expect(w == 20240115...20240120)
  }

  @Test func forwardWindowCappedAtTodayPlusBuffer() {
    // requested beyond today → cap at today+buffer, never an arbitrary future date.
    let w = ContiguousFetchPlanner.nextWindow(
      earliest: 20240101, latest: 20240115,
      requested: 20240601, today: 20240118,
      windowDays: 30, forwardBuffer: 2)
    #expect(w == 20240115...20240120) // today(18)+buffer(2)=20
  }
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement the forward branch** (replace the `requested > latest` `return nil` placeholder)

```swift
// inside nextWindow, after the in-range nil check:
if requested > latest {
  let cap = min(requested, addingDays(forwardBuffer, to: today))
  let upper = min(addingDays(windowDays, to: latest), cap)
  // Anchor at `latest` itself so a stale latest-day tick is overwritten.
  guard latest <= upper else { return nil }
  return latest...upper
}
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit** (`feat(price-cache): bounded forward window`).

### Task 4: Backward window + cold-cache window

**Files:** Modify planner + test.

- [ ] **Step 1: Write the failing tests**

```swift
  @Test func backwardWindowIsBoundedAndAnchoredAtEarliest() {
    // requested far before earliest → window [earliest-30 … earliest-1], not [requested … earliest-1].
    let w = ContiguousFetchPlanner.nextWindow(
      earliest: 20240201, latest: 20240301,
      requested: 20230101, today: 20240601,
      windowDays: 30, forwardBuffer: 2)
    #expect(w == 20240102...20240131) // earliest-1 = Jan31, back 30 days = Jan02
  }

  @Test func backwardWindowStopsAtRequestedWhenNearer() {
    let w = ContiguousFetchPlanner.nextWindow(
      earliest: 20240201, latest: 20240301,
      requested: 20240120, today: 20240601,
      windowDays: 30, forwardBuffer: 2)
    #expect(w == 20240120...20240131)
  }

  @Test func coldCacheWindowEndsAtRequestedWithPriorContext() {
    // empty cache: window ends at min(requested, today+buffer), reaches back windowDays for fallback context.
    let w = ContiguousFetchPlanner.nextWindow(
      earliest: nil, latest: nil,
      requested: 20240215, today: 20240601,
      windowDays: 30, forwardBuffer: 2)
    #expect(w == 20240116...20240215)
  }

  @Test func coldCacheWindowCapsFutureRequestAtToday() {
    let w = ContiguousFetchPlanner.nextWindow(
      earliest: nil, latest: nil,
      requested: 20240601, today: 20240215,
      windowDays: 30, forwardBuffer: 2)
    #expect(w == 20240118...20240217) // end=today+buffer=Feb17, back 30 = Jan18
  }
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement the backward branch + coldWindow**

```swift
// inside nextWindow, after the forward branch (requested < earliest case):
if requested < earliest {
  let lower = max(requested, addingDays(-windowDays, to: earliest))
  let upper = addingDays(-1, to: earliest)
  guard lower <= upper else { return nil }
  return lower...upper
}
return nil
```

```swift
// replace coldWindow body:
private static func coldWindow(
  requested: Int32, today: Int32, windowDays: Int, forwardBuffer: Int
) -> ClosedRange<Int32>? {
  let end = min(requested, addingDays(forwardBuffer, to: today))
  let start = addingDays(-windowDays, to: end)
  guard start <= end else { return nil }
  return start...end
}
```

- [ ] **Step 4: Run, verify pass** (whole suite).

Run: `just test-mac ContiguousFetchPlannerTests 2>&1 | tee .agent-tmp/planner.txt`
Expected: all PASS.

- [ ] **Step 5: format-check + commit**

```bash
just format-check 2>&1 | tee .agent-tmp/fmt.txt
git add Shared/ContiguousFetchPlanner.swift MoolahTests/Shared/ContiguousFetchPlannerTests.swift
git commit -m "feat(price-cache): backward + cold-cache windows complete planner"
```

---

## Phase 2 — Migrate CryptoPriceService

The driving loop pattern (used identically in all three services): while the planner returns a window and the requested date is still uncovered, fetch the window, merge it (advancing bounds to the returned data within the window), and re-check. Stop when covered, when a window makes **no progress** (boundary didn't move — genuine no-more-data, leave for a later call to re-query), or when a fetch throws.

### Task 5: Crypto — failing contiguity test (reproduce the bug)

**Files:**
- Test: `MoolahTests/Shared/ContiguousExtensionCryptoTests.swift`

- [ ] **Step 1: Write the failing test** — a fake `CryptoPriceClient` that, like CoinGecko-free, only serves dates within 365 days of `today`, and otherwise returns `[:]`. Drive a far-back request and assert the cache has **no interior gap** between the served block and the original bounds (today's behaviour leaves a gap; the fix must not).

```swift
import Testing
import Foundation
@testable import Moolah

@Suite struct ContiguousExtensionCryptoTests {
  /// Serves a daily price for every day in the requested range that is
  /// within `horizonDays` of `today`; older days return empty (mimics
  /// CoinGecko free tier's 365-day refusal collapsing to empty).
  struct HorizonClient: CryptoPriceClient {
    let today: Date
    let horizonDays: Int
    var syncProvider: SyncProvider { .binance }
    func dailyPrice(for m: CryptoProviderMapping, on d: Date) async throws -> Decimal { 1 }
    func currentPrices(for m: [CryptoProviderMapping]) async throws -> [String: Decimal] { [:] }
    func dailyPrices(for m: CryptoProviderMapping, in range: ClosedRange<Date>) async throws -> [String: Decimal] {
      let cal = Calendar.utc
      let cutoff = cal.date(byAdding: .day, value: -horizonDays, to: today)!
      let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]; fmt.timeZone = TimeZone(identifier: "UTC")
      var out: [String: Decimal] = [:]
      var day = range.lowerBound
      while day <= range.upperBound {
        if day >= cutoff { out[fmt.string(from: day)] = 100 }
        day = cal.date(byAdding: .day, value: 1, to: day)!
      }
      return out
    }
  }

  @Test func farBackRequestLeavesNoInteriorGap() async throws {
    let today = ISO8601DateFormatter.utcDay("2026-06-17")
    let service = CryptoPriceService(
      clients: [HorizonClient(today: today, horizonDays: 365)],
      database: try TestDatabases.rateCache(),  // in-memory profile-index schema
      now: { today }, timeZone: TimeZone(identifier: "UTC")!)
    let mapping = CryptoProviderMapping(
      instrumentId: "1:binance-test", coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: "TESTUSDT")
    let instrument = Instrument.crypto(chainId: 1, contractAddress: "0xtest", symbol: "TEST", name: "Test", decimals: 8)

    // Warm a recent block (within horizon), then request a date >365 days back.
    _ = try? await service.price(for: instrument, mapping: mapping, on: today)
    _ = try? await service.price(
      for: instrument, mapping: mapping,
      on: ISO8601DateFormatter.utcDay("2024-07-12"))

    // The cache must not contain an interior hole: every day between its
    // earliest and latest must be present OR the bounds must not span the
    // un-served region. Assert no gap larger than the bounded window.
    let maxGap = try await service.debugMaxInteriorGapDays(tokenId: instrument.id)
    #expect(maxGap <= 31)  // bounded window; never a multi-month void
  }
}
```

> This test needs two test-only helpers: `TestDatabases.rateCache()` (an in-memory `DatabaseQueue` migrated with the profile-index rate-cache schema — model it on the existing rate-cache test harness; search `MoolahTests` for how `crypto_price` tables are set up in current `CryptoPriceServiceTests`), `ISO8601DateFormatter.utcDay(_:)` (likely already exists in test support — search; if not, add a one-line helper), and `CryptoPriceService.debugMaxInteriorGapDays(tokenId:)` (Step 3).

- [ ] **Step 2: Run, verify fail** — with today's unbounded logic the far-back request either leaves a multi-month gap (maxGap ≫ 31) or the helper doesn't exist.

Run: `just test-mac ContiguousExtensionCryptoTests 2>&1 | tee .agent-tmp/crypto.txt`
Expected: FAIL.

- [ ] **Step 3: Add the `debugMaxInteriorGapDays` test helper** to `CryptoPriceService` (guard with `#if DEBUG`)

```swift
#if DEBUG
  func debugMaxInteriorGapDays(tokenId: String) -> Int {
    guard let cache = caches[tokenId] else { return 0 }
    let keys = cache.prices.sortedKeys
    var maxGap = 0
    for i in 1..<max(keys.count, 1) where keys.count > 1 {
      let a = DateKey.isoString(keys[i - 1]); let b = DateKey.isoString(keys[i])
      let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]; fmt.timeZone = TimeZone(identifier: "UTC")
      if let da = fmt.date(from: a), let db = fmt.date(from: b) {
        let days = Calendar.utc.dateComponents([.day], from: da, to: db).day ?? 0
        maxGap = max(maxGap, days - 1)
      }
    }
    return maxGap
  }
#endif
```

- [ ] **Step 4: Run, verify the test still fails for the right reason** (now compiles, asserts gap too large). Confirm `maxGap` is large (multi-month) under current logic.

- [ ] **Step 5: Commit the failing test** (`test(price-cache): crypto far-back request must not leave interior gap`).

### Task 6: Crypto — drive `price(...)` with the bounded planner loop

**Files:**
- Modify: `Shared/CryptoPriceService.swift` (replace `extensionWindow` use in `price(...)`, lines ~156-199, and delete/retire the unbounded `extensionWindow`).

- [ ] **Step 1: Replace the single-shot extension with a bounded loop**

Replace the out-of-range section of `price(for:mapping:on:)` (everything from the `extensionWindow(...)` computation through the `withTaskCancellationHandler` return) with a loop that pulls windows from the planner. Keep the existing in-flight coalescing (`extensionTasks`) wrapping the *per-window* fetch.

```swift
// after inRangeFallback returned nil (out of range):
let requestedKey = DateKey.from(isoString: dateString) ?? Int32.max
let todayKey = DateKey.from(isoString: dateFormatter.string(from: now())) ?? requestedKey
var guardSteps = 0
while guardSteps < 64 {  // safety bound; ~64×30d windows covers any real history
  guardSteps += 1
  let bounds = boundsKeys(tokenId: tokenId)  // (earliest?, latest?) as DateKey from caches[tokenId]
  guard let window = ContiguousFetchPlanner.nextWindow(
    earliest: bounds.earliest, latest: bounds.latest,
    requested: requestedKey, today: todayKey,
    windowDays: 30, forwardBuffer: 2)
  else { break }  // requested now in range
  let before = bounds
  let interval = DateKey.isoString(window.lowerBound)...DateKey.isoString(window.upperBound)
  let fetchInterval = parseInterval(interval)  // ClosedRange<Date> via dateFormatter
  do {
    try await fetchWindowCoalesced(
      instrument: instrument, mapping: mapping, fetchInterval: fetchInterval)
  } catch {
    // provider chain fully failed for this window: leave bounds, surface below.
    break
  }
  if let cached = lookupPrice(tokenId: tokenId, dateString: dateString) { return cached }
  if let inRange = try inRangeFallback(tokenId: tokenId, dateString: dateString) { return inRange }
  // No progress (bounds unchanged) → genuine no-more-data this side; stop and
  // let a later call re-query the boundary (recent data may publish later).
  if boundsKeys(tokenId: tokenId) == before { break }
}
if let inRange = try inRangeFallback(tokenId: tokenId, dateString: dateString) { return inRange }
throw CryptoPriceError.noPriceAvailable(tokenId: tokenId, date: dateString)
```

> `boundsKeys(tokenId:)`, `parseInterval(_:)`, and `fetchWindowCoalesced(...)` are introduced in Steps 2–3. `fetchWindowCoalesced` is the existing `extensionTasks` coalescing wrapper refactored to fetch a *given* interval (not compute its own window) and to **merge without computing a window** — it calls `fetchRange(instrument:mapping:from:to:)` (already bounded-safe given a bounded interval) rather than `fetchAndExtendCache` (which returns a single price). The merge inside `fetchRange` already advances bounds to `min/max` of returned data — correct now that the *window* is bounded.

- [ ] **Step 2: Add `boundsKeys` and `parseInterval` helpers**

```swift
private func boundsKeys(tokenId: String) -> (earliest: Int32?, latest: Int32?) {
  guard let cache = caches[tokenId] else { return (nil, nil) }
  return (DateKey.from(isoString: cache.earliestDate), DateKey.from(isoString: cache.latestDate))
}

private func parseInterval(_ iso: ClosedRange<String>) -> ClosedRange<Date> {
  let lower = dateFormatter.date(from: iso.lowerBound) ?? now()
  let upper = dateFormatter.date(from: iso.upperBound) ?? now()
  return lower...max(lower, upper)
}
```

- [ ] **Step 3: Refactor the coalescing wrapper to fetch a given interval**

Adapt the existing `extensionTasks` coalescing (currently inside `price`) into:

```swift
private func fetchWindowCoalesced(
  instrument: Instrument, mapping: CryptoProviderMapping, fetchInterval: ClosedRange<Date>
) async throws {
  let tokenId = instrument.id
  if let inFlight = extensionTasks[tokenId] { _ = try? await inFlight.task.value; return }
  let requestId = UUID()
  let task = Task<Decimal, Error> { [self] in
    try await self.fetchRange(
      instrument: instrument, mapping: mapping,
      from: fetchInterval.lowerBound, to: fetchInterval.upperBound)
    return 0
  }
  extensionTasks[tokenId] = (requestId, task)
  defer { if extensionTasks[tokenId]?.id == requestId { extensionTasks.removeValue(forKey: tokenId) } }
  _ = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
```

> `extensionTasks` type stays `[String: (id: UUID, task: Task<Decimal, Error>)]`; the `Decimal` payload is now unused (return 0) — acceptable, or retype to `Task<Void, Error>` in a follow-up. Keep `fetchAndExtendCache` only if still referenced elsewhere; otherwise delete it and `extensionWindow` (now dead). Grep before deleting.

- [ ] **Step 4: Run the crypto contiguity test, verify pass**

Run: `just test-mac ContiguousExtensionCryptoTests 2>&1 | tee .agent-tmp/crypto.txt`
Expected: PASS (`maxGap <= 31`).

- [ ] **Step 5: Run the full existing crypto suite to catch regressions**

Run: `just test-mac CryptoPriceServiceTests CryptoPriceServiceStablecoinTests CryptoRateLookupTests 2>&1 | tee .agent-tmp/crypto-reg.txt`
Expected: PASS. Fix any fallout (e.g. tests asserting the old unbounded window shape — update them to the bounded behaviour, noting the change).

- [ ] **Step 6: format-check + commit**

```bash
just format-check 2>&1 | tee .agent-tmp/fmt.txt
git add Shared/CryptoPriceService.swift MoolahTests/Shared/ContiguousExtensionCryptoTests.swift
git commit -m "fix(price-cache): bounded contiguous extension in CryptoPriceService"
```

### Task 7: Crypto — `prices(in:)` and `warmRange` use bounded sub-ranges

**Files:** Modify `Shared/CryptoPriceService.swift`, `Shared/CryptoPriceService+FetchRange.swift` (`uncoveredSubRanges`).

- [ ] **Step 1: Write the failing test** — a range request spanning a huge gap (cold-to-far) must fill in bounded windows without creating an interior hole.

```swift
  @Test func rangeRequestFillsContiguouslyInWindows() async throws {
    let today = ISO8601DateFormatter.utcDay("2026-06-17")
    let service = CryptoPriceService(
      clients: [HorizonClient(today: today, horizonDays: 100000)],  // serves everything
      database: try TestDatabases.rateCache(), now: { today }, timeZone: TimeZone(identifier: "UTC")!)
    let mapping = CryptoProviderMapping(instrumentId: "1:r", coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: "RUSDT")
    let instrument = Instrument.crypto(chainId: 1, contractAddress: "0xr", symbol: "R", name: "R", decimals: 8)
    let lo = ISO8601DateFormatter.utcDay("2024-01-01")
    _ = try await service.prices(for: instrument, mapping: mapping, in: lo...today)
    #expect(try await service.debugMaxInteriorGapDays(tokenId: instrument.id) <= 31)
  }
```

- [ ] **Step 2: Run, verify fail** (unbounded `uncoveredSubRanges` may emit one giant range).

- [ ] **Step 3: Bound the sub-ranges** — in `uncoveredSubRanges`, split each backward/forward sub-range into `windowDays`-sized chunks (reuse `ContiguousFetchPlanner` or a `chunked(by:)` helper) so no single fetch exceeds a window. Drive them through `fetchRange` in order, anchored at the moving boundary.

```swift
// after computing `result: [ClosedRange<Date>]`, chunk each entry:
return result.flatMap { Self.chunked($0, days: 30) }
```

Add a `static func chunked(_ range: ClosedRange<Date>, days: Int) -> [ClosedRange<Date>]` using `Calendar.utc`.

- [ ] **Step 4: Run, verify pass** (range test + existing `warmRange`/`prices` tests).

Run: `just test-mac ContiguousExtensionCryptoTests CryptoPriceServiceTests 2>&1 | tee .agent-tmp/crypto.txt`

- [ ] **Step 5: format-check + commit** (`fix(price-cache): bound crypto range/warm sub-ranges`).

---

## Phase 3 — Migrate StockPriceService

Same pattern. Stock differs only in keying (`ticker`), single-provider client, and `instrument_id` in meta. Markets close weekends/holidays, so genuine gaps exist — the contiguity test must use a fake client that serves only weekdays and assert gaps are **only** weekend-sized.

### Task 8: Stock — failing contiguity test

**Files:** Test `MoolahTests/Shared/ContiguousExtensionStockTests.swift`.

- [ ] **Step 1: Write the failing test** — fake `StockPriceClient` (`fetchDailyPrices(ticker:from:to:)` → `StockPriceResponse`) that serves weekdays only and refuses (empty) dates older than a horizon. Warm recent, request far-back, assert max interior gap ≤ 4 days (a long weekend), never multi-week.

```swift
@Suite struct ContiguousExtensionStockTests {
  struct WeekdayHorizonClient: StockPriceClient {
    let today: Date; let horizonDays: Int
    func fetchDailyPrices(ticker: String, from: Date, to: Date) async throws -> StockPriceResponse {
      let cal = Calendar.utc
      let cutoff = cal.date(byAdding: .day, value: -horizonDays, to: today)!
      let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]; fmt.timeZone = TimeZone(identifier: "UTC")
      var out: [String: Decimal] = [:]; var d = from
      while d <= to {
        let wd = cal.component(.weekday, from: d)
        if d >= cutoff && wd != 1 && wd != 7 { out[fmt.string(from: d)] = 50 }
        d = cal.date(byAdding: .day, value: 1, to: d)!
      }
      return StockPriceResponse(instrument: .fiat(code: "AUD"), prices: out)
    }
  }
  @Test func farBackStockRequestLeavesOnlyWeekendGaps() async throws { /* mirror crypto Task 5, assert <= 4 */ }
}
```

- [ ] **Step 2: Run, verify fail.** (`just test-mac ContiguousExtensionStockTests`)
- [ ] **Step 3:** Add `StockPriceService.debugMaxInteriorGapDays(ticker:)` (`#if DEBUG`, mirror crypto helper, keyed by ticker).
- [ ] **Step 4: Run, confirm fails for the right reason (gap too large).**
- [ ] **Step 5: Commit** the failing test.

### Task 9: Stock — bounded planner loop in `price(ticker:on:)`

**Files:** Modify `Shared/StockPriceService.swift` (replace `fetchToCoverDate` window math + the call site in `price`).

- [ ] **Step 1:** Replace `fetchToCoverDate`'s internal window computation with the `ContiguousFetchPlanner`-driven bounded loop (mirror Task 6, keyed by `ticker`; the fetch is the single `client.fetchDailyPrices(ticker:from:to:)` → merge via existing `mergeReturningDelta(ticker:instrument:newPrices:)`). Bound each fetch to one window; loop until covered / no-progress / throw. Stock keeps propagating the throw to `price(...)` per its current contract — but only after the bounded loop exhausts, and only when nothing is in range.
- [ ] **Step 2:** Add `boundsKeys(ticker:)` helper (mirror crypto).
- [ ] **Step 3: Run the stock contiguity test + existing `StockPriceServiceTests`, verify pass.**

Run: `just test-mac ContiguousExtensionStockTests StockPriceServiceTests 2>&1 | tee .agent-tmp/stock.txt`

- [ ] **Step 4:** Bound `prices(ticker:in:)` sub-ranges (mirror Task 7 if stock has a range method that emits unbounded sub-ranges).
- [ ] **Step 5: format-check + commit** (`fix(price-cache): bounded contiguous extension in StockPriceService`).

---

## Phase 4 — Migrate ExchangeRateService

FX is the structural outlier: cache value is `SortedDateSeries<[String: Decimal]>` (a per-day quote map), keyed by `base`, fetched via `client.fetchRates(base:from:to:)` → `[String:[String:Decimal]]`. The planner is value-agnostic (operates on DateKeys only), so it drops in unchanged; only the merge/lookup stay FX-specific.

### Task 10: FX — failing contiguity test

**Files:** Test `MoolahTests/Shared/ContiguousExtensionFXTests.swift`.

- [ ] **Step 1: Write the failing test** — fake `ExchangeRateClient` (`fetchRates(base:from:to:)`) serving weekdays only within a horizon, returning `[date: ["AUD": rate]]`. Warm recent, request far-back, assert max interior gap (over the day-map keys) ≤ 4. Add `ExchangeRateService.debugMaxInteriorGapDays(base:)` (`#if DEBUG`).
- [ ] **Step 2: Run, verify fail.** (`just test-mac ContiguousExtensionFXTests`)
- [ ] **Step 3:** Add the debug helper.
- [ ] **Step 4: Confirm fails for the right reason.**
- [ ] **Step 5: Commit** the failing test.

### Task 11: FX — bounded planner loop in `rate(...)`/`fetchToCoverDate`

**Files:** Modify `Shared/ExchangeRateService.swift`.

- [ ] **Step 1:** Replace `fetchToCoverDate(base:date:dateString:)`'s window math with the `ContiguousFetchPlanner` bounded loop (mirror Task 6, keyed by `base`; fetch via `fetchAndMerge(base:from:to:)` which already merges + persists). `fetchToCoverDate` currently *swallows* errors — preserve that (FX falls back to cached on failure); the loop simply stops on a throwing/no-progress window.
- [ ] **Step 2:** Add `boundsKeys(base:)` helper.
- [ ] **Step 3:** Bound `rates(from:to:in:)` sub-ranges and `prefetchLatest(base:)` to windows.
- [ ] **Step 4: Run the FX contiguity test + existing `ExchangeRateServiceTests`, verify pass.**

Run: `just test-mac ContiguousExtensionFXTests ExchangeRateServiceTests 2>&1 | tee .agent-tmp/fx.txt`

- [ ] **Step 5: format-check + commit** (`fix(price-cache): bounded contiguous extension in ExchangeRateService`).

---

## Phase 5 — Purge the existing untrustworthy caches

A one-time migration on the **profile-index** database deletes every row from all six cache tables so they re-warm contiguously under the fixed logic. Mirrors the precedent `v7_purge_intraday_cached_prices`.

### Task 12: Purge migration

**Files:**
- Create: `Backends/GRDB/ProfileIndexSchema+PurgeRateCaches.swift`
- Modify: the profile-index migrator registration (find it: `grep -rn "registerMigration" Backends/GRDB/ProfileIndexSchema*.swift`)
- Test: `MoolahTests/Backends/PurgeRateCachesMigrationTests.swift`

- [ ] **Step 1: Write the failing test** — open an in-memory profile-index DB at the pre-purge schema version, insert a crypto_price row + a stock_price row + an exchange_rate row (+ their meta rows), run the migrator to latest, assert all six tables are empty.

```swift
import Testing
import GRDB
@testable import Moolah

@Suite struct PurgeRateCachesMigrationTests {
  @Test func purgeEmptiesAllSixCacheTables() throws {
    let dbQueue = try DatabaseQueue()
    var migrator = ProfileIndexSchema.migrator
    // migrate to the version *before* the purge, seed rows, then to latest.
    try migrator.migrate(dbQueue, upTo: "<id-of-migration-before-purge>")
    try dbQueue.write { db in
      try db.execute(sql: "INSERT INTO crypto_price VALUES ('t','2024-01-01',1.0)")
      try db.execute(sql: "INSERT INTO crypto_token_meta VALUES ('t','T','2024-01-01','2024-01-01')")
      try db.execute(sql: "INSERT INTO stock_price VALUES ('X.AX','2024-01-01',1.0)")
      try db.execute(sql: "INSERT INTO stock_ticker_meta VALUES ('X.AX','AUD','2024-01-01','2024-01-01')")
      try db.execute(sql: "INSERT INTO exchange_rate VALUES ('USD','AUD','2024-01-01',1.5)")
      try db.execute(sql: "INSERT INTO exchange_rate_meta VALUES ('USD','2024-01-01','2024-01-01')")
    }
    try migrator.migrate(dbQueue)  // applies the purge
    try dbQueue.read { db in
      for t in ["crypto_price","crypto_token_meta","stock_price","stock_ticker_meta","exchange_rate","exchange_rate_meta"] {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)") == 0)
      }
    }
  }
}
```

> Replace `<id-of-migration-before-purge>` with the actual current last migration id from the profile-index migrator.

- [ ] **Step 2: Run, verify fail** (migration not registered → tables still populated).

Run: `just test-mac PurgeRateCachesMigrationTests 2>&1 | tee .agent-tmp/purge.txt`
Expected: FAIL.

- [ ] **Step 3: Write the migration body + register it**

```swift
// Backends/GRDB/ProfileIndexSchema+PurgeRateCaches.swift
import Foundation
import GRDB

extension ProfileIndexSchema {
  /// One-time wipe of all historic price/rate caches. They could contain
  /// never-fetched interior gaps masked by the prior-day fallback (silently
  /// stale values); the data is local, derived and cheap to refetch, so we
  /// clear it and let the corrected contiguous extension rebuild it.
  static func purgeRateCaches(_ db: Database) throws {
    for table in [
      "crypto_price", "crypto_token_meta",
      "stock_price", "stock_ticker_meta",
      "exchange_rate", "exchange_rate_meta",
    ] {
      try db.execute(sql: "DELETE FROM \(table)")
    }
  }
}
```

Register (append after the current last profile-index migration):

```swift
migrator.registerMigration("vNN_purge_rate_caches", migrate: purgeRateCaches)
```

> Use the next sequential `vNN_…` id matching the profile-index migrator's existing naming. Per `guides/DATABASE_SCHEMA_GUIDE.md`, migrations are frozen once shipped — append, never edit.

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5:** Update the test's `<id-of-migration-before-purge>` to the real prior id; rerun. format-check + commit.

```bash
just format-check 2>&1 | tee .agent-tmp/fmt.txt
git add Backends/GRDB/ProfileIndexSchema+PurgeRateCaches.swift Backends/GRDB/ProfileIndexSchema*.swift MoolahTests/Backends/PurgeRateCachesMigrationTests.swift
git commit -m "feat(price-cache): purge untrustworthy rate caches for contiguous rebuild"
```

---

## Phase 6 — Whole-suite verification

### Task 13: Full build, test, format, review

- [ ] **Step 1: Full macOS suite**

Run: `just test-mac 2>&1 | tee .agent-tmp/full-mac.txt`
Then: `grep -i 'failed\|error:' .agent-tmp/full-mac.txt`
Expected: no failures. Investigate any (esp. existing price-service tests pinning the old window shape — update them to the bounded behaviour and note the change).

- [ ] **Step 2: iOS suite**

Run: `just test-ios 2>&1 | tee .agent-tmp/full-ios.txt`

- [ ] **Step 3: format-check + warning check**

Run: `just format-check 2>&1 | tee .agent-tmp/fmt.txt` (expect clean — no SwiftLint baseline). Build warning-free (`SWIFT_TREAT_WARNINGS_AS_ERRORS`).

- [ ] **Step 4: Run the review agents** (`code-review`, `concurrency-review`, `database-schema-review`, `database-code-review`) over the diff; apply all findings.

- [ ] **Step 5: Clean up `.agent-tmp/` and commit any review fixes.**

```bash
rm -f .agent-tmp/planner.txt .agent-tmp/crypto*.txt .agent-tmp/stock.txt .agent-tmp/fx.txt .agent-tmp/purge.txt .agent-tmp/fmt.txt .agent-tmp/full-*.txt
```

---

## Self-review notes (author)

- **Spec coverage:** invariant → planner (Phase 1) + per-service loops (Phases 2-4); bounded windows → Tasks 3/4/7/9/11; no-disconnected-island → planner always anchors at a boundary; boundary advances only across queried windows → bounded windows + merge (existing min/max merge is safe once windows are bounded); recovery wipe → Phase 5; no global forward cap → Task 3 (`today + forwardBuffer`, providers tolerate future dates); shared core → `ContiguousFetchPlanner`.
- **Out of scope (per spec):** provider mappings (#1140); fallback semantics; the income/expense unavailable-month rule.
- **Known follow-up to confirm during execution:** exact current last migration id of the profile-index migrator (Task 12); whether `fetchAndExtendCache`/`extensionWindow` become dead after Task 6 (grep before deleting); whether existing `CryptoPriceServiceTests`/`StockPriceServiceTests`/`ExchangeRateServiceTests` assert the old unbounded window shape (update + note).
- **Risk:** the bounded loop changes deep-backfill from one request to several windowed fetches — a cold deep range now fills progressively (acceptable per design sign-off). Guard bound (`guardSteps < 64`) prevents runaway loops.
