# Shared stock/crypto price-series engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the ~85%-identical daily-price-series orchestration duplicated between `StockPriceService` and `CryptoPriceService` into default methods on an `Actor`-constrained protocol `PriceSeriesOrchestrating`, so both services route their `price(...)` / `prices(...)` through one shared implementation parameterised by three plugs.

**Architecture:** The shared orchestration lives in a protocol extension on `protocol PriceSeriesOrchestrating: Actor`. Each service actor conforms; the shared methods run `self`-isolated and mutate `self.caches[key]` **per key** (never a whole-dict snapshot — that was rejected as a concurrent-different-instrument data race). The three genuine differences (provider fetch, quote denomination, optional first-trade floor) become protocol requirements ("plugs") the actors satisfy by wrapping their existing per-service code. Tables, `loadCache`, `persistDelta`, the crypto fallback chain, coalescing, live/warming, and Sub-project A's resolution all stay per-service. The shared `generateDateSeries` standardises on `Calendar.utc` (crypto's already-correct choice), fixing stock's host-local day-stepping bug.

**Tech Stack:** Swift 6 actors + `Sendable` (`guides/CONCURRENCY_GUIDE.md`); GRDB persistence (untouched); Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`), **not** XCTest; one-extension-per-protocol conformances per `guides/CODE_GUIDE.md`.

## Global Constraints

- **No schema migration.** `stock_price` / `stock_ticker_meta` and `crypto_price` / `crypto_token_meta` stay exactly as defined in `Backends/GRDB/ProfileSchema+RateCaches.swift` (incl. the `WITHOUT ROWID` / `*_meta` ROWID split). `StockPriceRecord` / `CryptoPriceRecord` unchanged.
- **`ExchangeRateService` untouched.** Out of scope — it remains the pairwise/multi-quote fiat bridge.
- **Public APIs unchanged.** Both services keep every method signature and actor isolation: `price(ticker:on:)`, `prices(ticker:in:)`, `instrument(for:)`, `price(for:on:)`, `price(for:mapping:on:)`, `prices(for:mapping:in:)`, `registration(for:)`, `purgeCache`, `currentPrices`, `prefetchLatest`, `warmRange`, `priceLookup`. Sub-project A's `StockPriceSource` / `CryptoPriceSource` keep working with no edits.
- **Behaviour-neutral on results.** Conversion / aggregation results and **all crypto suites** are unchanged with expectations unchanged. The ONLY intentional change is stock `generateDateSeries` host-local → `Calendar.utc` (a timezoneless-date correctness fix that gets a `datetime-review` pass). If any step would force changing a CRYPTO suite's expectation, **STOP and flag** — do not proceed.
- **No whole-`caches` snapshot, no `inout` collection.** The shared code mutates `self.caches[key]` per key on the actor. The rejected snapshot/`defer`-writeback design clobbers concurrent different-instrument updates and is forbidden.
- **Swift-6 obstacle escape hatch.** If the `Actor`-constrained protocol with mutable `var caches`/`var hydrated` `{ get set }` requirements hits a concrete Swift-6 compile obstacle, **surface it (BLOCKED)** rather than fall back to the rejected snapshot/`inout` design.
- **Calendar discipline.** Timezoneless `YYYY-MM-DD` day stepping uses `Calendar.utc` (defined `Shared/Extensions/Calendar+UTC.swift`). Never `Calendar(identifier: .gregorian)` (host-local) for day labels. See `guides/DATE_TIME_GUIDE.md`.
- **Tooling.** Build/verify via `just` ONLY: `just build-mac`, `just test-mac <ExactSuiteTypeName>`, `just format-check`. Suite filters need the **exact** suite TYPE name — a substring runs 0 tests but still prints SUCCEEDED. Pipe output to `.agent-tmp/` (gitignored); delete temp files when done. Run `just format` before every commit. `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` — fix all warnings.
- **Commit footer (every commit):**
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Q4LphNRBYdAZSbgHNmmCg6
  ```

---

## Reference: exact existing signatures the plan relies on

These are read from the current worktree (`price-series-engine`, built on merged Sub-project A). Implementers MUST NOT re-derive these — use them verbatim.

**Cache structs:**
```swift
// Domain/Models/StockPriceCache.swift
struct StockPriceCache: Codable, Sendable, Equatable {
  let ticker: String
  let instrument: Instrument          // denomination (e.g. .AUD)
  var earliestDate: String            // "YYYY-MM-DD"
  var latestDate: String              // "YYYY-MM-DD"
  var prices: SortedDateSeries<Decimal>
}
// Domain/Models/CryptoPriceCache.swift
struct CryptoPriceCache: Codable, Sendable, Equatable {
  let tokenId: String
  let symbol: String                  // display only
  var earliestDate: String
  var latestDate: String
  var prices: SortedDateSeries<Decimal>
  var firstTradedOn: String?          // confirmed first-trade floor; nil = unconfirmed
}
```

**Supporting types/helpers (do not modify):**
- `DateKey.from(isoString: String) -> Int32?`, `DateKey.isoString(_ key: Int32) -> String` (`Shared/DateKey.swift`).
- `SortedDateSeries<Decimal>`: `.exact(_ key: Int32) -> Decimal?`, `.floor(_ key: Int32) -> Decimal?`, `init()`, `init(sortedEntries:)`, `mutating upsert(_:forKey:)` (`Shared/SortedDateSeries.swift`).
- `ContiguousFetchPlanner.nextWindow(earliest: Int32?, latest: Int32?, requested: Int32, today: Int32, config: Config) -> ClosedRange<Int32>?`; `ContiguousFetchPlanner.Config(windowDays: Int, forwardBuffer: Int)` (`Shared/ContiguousFetchPlanner.swift`). Both services use `Config(windowDays: 30, forwardBuffer: 2)`.
- `cappedToYesterday(_ date: Date, now: () -> Date, timeZone: TimeZone = .current) -> Date` (`Shared/PriceCacheCap.swift`).
- `Calendar.utc` and `TimeZone.utc` (`Shared/Extensions/Calendar+UTC.swift`).
- `StockPriceError.noPriceAvailable(ticker:date:)`, `.unknownTicker(_)` (`Shared/StockPriceService.swift`).
- `CryptoPriceError.noPriceAvailable(tokenId:date:)`, `.beforeFirstTrade(tokenId:date:)`, `.noProviderMapping(tokenId:provider:)` (`Domain/Repositories/CryptoPriceClient.swift`).

**Stock per-service internals (already exist, stay; invoked through plugs):**
- `StockPriceService.caches: [String: StockPriceCache]`, `hydratedTickers: Set<String>`, `now: @Sendable () -> Date`, `timeZone: TimeZone`, `dateFormatter: ISO8601DateFormatter` (`[.withFullDate]`), `logger`.
- `loadCache(ticker:)` (private; will widen to satisfy `hydrate`), `fetchAndMerge(ticker:from:to:)`, `mergeReturningDelta(ticker:instrument:newPrices:)`, `persistDelta(ticker:deltaRecords:)`, `boundsKeys(ticker:) -> (earliest: Int32?, latest: Int32?)`, `lookupPrice(ticker:dateString:)`, `fallbackPrice(ticker:dateString:)`.

**Crypto per-service internals (already exist, stay; invoked through plugs):**
- `CryptoPriceService.caches: [String: CryptoPriceCache]`, `hydratedTokenIds: Set<String>`, `extensionTasks: [String: (id: UUID, task: Task<Void, Error>)]`, `now`, `timeZone`, `dateFormatter`, `logger`.
- `loadCache(tokenId:)`, `fetchWindowCoalesced(instrument:mapping:fetchInterval:)`, `fetchRange(instrument:mapping:from:to:)`, `mergeReturningDelta(tokenId:symbol:newPrices:)`, `persistDelta(tokenId:deltaRecords:)`, `persistFirstTradedOn(tokenId:date:)`, `boundsKeys(tokenId:) -> (earliest: Int32?, latest: Int32?)`, `parseInterval(_ iso: ClosedRange<String>) -> ClosedRange<Date>`, `lookupPrice(tokenId:dateString:)`, `fallbackPrice(tokenId:dateString:)`, `inRangeFallback(tokenId:dateString:) throws -> Decimal?`, `confirmFirstTradedOnIfExhausted(tokenId:lastFetchError:)`, `registration(for:)`, `priceLookup(for:on:)`, `purgeCache(instrumentId:)`.

---

## File Structure

**New files:**
- `Shared/PriceSeriesCache.swift` — the `PriceSeriesCache` protocol (Task 1).
- `Shared/StockPriceCache+PriceSeriesCache.swift` — stock conformance (Task 1).
- `Shared/CryptoPriceCache+PriceSeriesCache.swift` — crypto conformance (Task 1).
- `Shared/PriceSeriesOrchestrating.swift` — the `PriceSeriesOrchestrating` protocol + its shared default-method extension (Task 2).
- `MoolahTests/Shared/PriceSeriesOrchestratingTests.swift` — engine-level TDD suite with a fake conforming actor (Task 2).

**Modified files:**
- `Shared/StockPriceService.swift` — conformance + plug implementations + thin call-throughs; `generateDateSeries`/`buildResultSeries` deleted (Task 4).
- `Shared/StockPriceService+FetchRange.swift` — `fetchToCoverDate`/`coverRangeContiguously` deleted (logic now shared); `boundsKeys`/`fetchAndMerge` retained behind plug (Task 4).
- `Shared/CryptoPriceService.swift` — conformance + plug implementations + thin call-throughs; inline carry-forward loop + `generateDateSeries` deleted (Task 3).
- `Shared/CryptoPriceService+FetchRange.swift` — `extendContiguously`/`coverRangeContiguously`/`extendOneDirection`/`resolveAfterExtension`/`midLoopCacheHit` deleted (logic now shared); `fetchWindowCoalesced`/`fetchRange`/`boundsKeys`/`parseInterval`/`confirmFirstTradedOnIfExhausted` retained behind plugs (Task 3).

**Unchanged (verify still green):** `+Merge.swift`, `+Persistence.swift`, `+PriceLookup.swift`, `+Live.swift`, `+Warming.swift`, the two cache record types, `ContiguousFetchPlanner`, `SortedDateSeries`, `PriceCacheCap`.

Project file regeneration: after creating new `.swift` files run `just generate` (xcodegen picks up new files via globs) **before** `just build-mac`. If a build error reports the new file is not in the target, that's the cause — run `just generate`.

---

## Task 1: `PriceSeriesCache` protocol + conform both cache structs

**Files:**
- Create: `Shared/PriceSeriesCache.swift`
- Create: `Shared/StockPriceCache+PriceSeriesCache.swift`
- Create: `Shared/CryptoPriceCache+PriceSeriesCache.swift`
- Test (existing, must stay green): `MoolahTests/Shared/StockPriceServiceTests.swift`, `MoolahTests/Shared/CryptoPriceServiceTests.swift`

**Interfaces:**
- Produces: `protocol PriceSeriesCache: Sendable, Equatable { var earliestDate: String { get set }; var latestDate: String { get set }; var prices: SortedDateSeries<Decimal> { get set } }`, with `StockPriceCache` and `CryptoPriceCache` conforming. Task 2's `associatedtype Cache: PriceSeriesCache` binds to these.

This task is trivial and behaviour-neutral: the struct fields already exist with the right names and mutability. No test of new behaviour is warranted (DRY/YAGNI) — the deliverable is a compile-checked conformance, gated by the existing suites still passing. The "test" is the build + existing suites.

- [ ] **Step 1: Create the protocol**

`Shared/PriceSeriesCache.swift`:
```swift
import Foundation

/// The cache fields the shared `PriceSeriesOrchestrating` default methods
/// read and mutate. Abstracts only the common series state — NOT the
/// per-service meta (stock's `instrument`, crypto's `symbol` /
/// `firstTradedOn`), which the orchestration reaches through plugs.
protocol PriceSeriesCache: Sendable, Equatable {
  /// Contiguous lower bound, ISO `YYYY-MM-DD`.
  var earliestDate: String { get set }
  /// Contiguous upper bound, ISO `YYYY-MM-DD`.
  var latestDate: String { get set }
  /// `DateKey`-keyed daily values (close price in the cache's denomination).
  var prices: SortedDateSeries<Decimal> { get set }
}
```

- [ ] **Step 2: Conform `StockPriceCache`**

`Shared/StockPriceCache+PriceSeriesCache.swift`:
```swift
import Foundation

extension StockPriceCache: PriceSeriesCache {}
```
(`earliestDate`, `latestDate`, `prices` already exist as `var` with matching types, so the conformance needs no members.)

- [ ] **Step 3: Conform `CryptoPriceCache`**

`Shared/CryptoPriceCache+PriceSeriesCache.swift`:
```swift
import Foundation

extension CryptoPriceCache: PriceSeriesCache {}
```

- [ ] **Step 4: Regenerate project + build**

Run: `just generate && just build-mac 2>&1 | tee .agent-tmp/t1-build.txt`
Expected: build succeeds, no warnings.

- [ ] **Step 5: Run the two anchor suites**

Run: `just test-mac StockPriceServiceTests CryptoPriceServiceTests 2>&1 | tee .agent-tmp/t1-test.txt`
Expected: both suites PASS, expectations unchanged. (`grep -i 'failed\|error:' .agent-tmp/t1-test.txt` → no test failures.)

- [ ] **Step 6: format-check**

Run: `just format && just format-check 2>&1 | tee .agent-tmp/t1-fmt.txt`
Expected: exit 0, no diff, no SwiftLint violation.

- [ ] **Step 7: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native.instrument-pricing-unification add Shared/PriceSeriesCache.swift Shared/StockPriceCache+PriceSeriesCache.swift Shared/CryptoPriceCache+PriceSeriesCache.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native.instrument-pricing-unification commit -m "refactor(price-series): add PriceSeriesCache protocol + conform both caches

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q4LphNRBYdAZSbgHNmmCg6"
```
Then `rm .agent-tmp/t1-*.txt`.

---

## Task 2: `PriceSeriesOrchestrating` protocol + shared default-method orchestration + `PriceSeriesOrchestratingTests` (TDD)

This is the heart of the sub-project. Write the test suite FIRST against a fake conforming actor, then implement the shared defaults to make it pass. **Neither real service conforms in this task** — Tasks 3 and 4 do that.

**Files:**
- Create: `Shared/PriceSeriesOrchestrating.swift` (protocol + extension with all shared defaults)
- Create: `MoolahTests/Shared/PriceSeriesOrchestratingTests.swift` (fake actor + tests)

**Interfaces:**
- Produces, the protocol:
  ```swift
  protocol PriceSeriesOrchestrating: Actor {
    associatedtype Cache: PriceSeriesCache
    var caches: [String: Cache] { get set }
    var hydrated: Set<String> { get set }
    var now: @Sendable () -> Date { get }
    var timeZone: TimeZone { get }
    var dateFormatter: ISO8601DateFormatter { get }
    var plannerConfig: ContiguousFetchPlanner.Config { get }

    func fetchAndMerge(instrumentKey: String, window: ClosedRange<Date>) async throws
    func quote(for instrumentKey: String) -> Instrument?
    func firstTradeFloor(for instrumentKey: String) -> String?
    func confirmFirstTradeOnBackwardExhaustion(instrumentKey: String, lastFetchError: (any Error)?) async throws
    func hydrate(instrumentKey: String) async throws
    func belowFloorError(instrumentKey: String, date: String) -> any Error
    func noPriceError(instrumentKey: String, date: String) -> any Error
  }
  ```
- Produces, the shared defaults (extension on `PriceSeriesOrchestrating`):
  - `func price(instrumentKey: String, on date: Date) async throws -> Decimal`
  - `func prices(instrumentKey: String, in range: ClosedRange<Date>) async throws -> [(date: Date, price: Decimal)]`
  - plus the lifted internals listed in Step 3.
- Consumes (Tasks 3, 4): each real actor satisfies the requirements and calls the two public defaults.

### Design notes the implementer must honour (from spec §2)

1. **Per-key mutation only.** Every default method reads/writes `caches[instrumentKey]` for exactly the key it is handed. There is NO snapshot of the whole dict and NO `inout [String: Cache]`. This is the data-race guard — the concurrent two-instrument test (Step 1) proves it.
2. **`generateDateSeries` uses `Calendar.utc`** (one calendar for both services). This is the intentional stock fix.
3. **Plug call sites must match today's crypto behaviour exactly** so the crypto suites stay green:
   - Pre-fetch floor short-circuit (mirrors `CryptoPriceService.swift:244`): after the post-hydrate exact miss, if `firstTradeFloor(for:)` is non-nil and `dateString < floor`, throw `belowFloorError`.
   - Backward-exhaustion confirm (mirrors `+FetchRange.swift:55-62, 151-158`): inside the window loop, when a window made no boundary progress (`boundsKeys == before`) AND the walk was backward (`before.earliest.map { requestedKey < $0 } ?? false`), call `confirmFirstTradeOnBackwardExhaustion(instrumentKey:lastFetchError:)` before breaking.
   - Post-loop resolution (mirrors `resolveAfterExtension`, `+FetchRange.swift:174-197`): exact → floor fallback → in-range-fallback-semantics → re-check `firstTradeFloor` (a backward walk may have just confirmed it) → throw `lastFetchError` if any → else `noPriceError`.
4. **The "in-range fallback" semantics** (`inRangeFallback`, crypto `+CryptoPriceService.swift:276`): when `dateString` is within `[earliestDate, latestDate]` but there's no row on/before it, the crypto path throws `noPriceAvailable` rather than re-fetching. Reproduce in the shared resolution by: if `caches[key]` exists with `dateString >= earliestDate && dateString <= latestDate`, return `floor(dateString)` if present else throw `noPriceError`. (Stock's old `price(ticker:on:)` did not have an explicit in-range short-circuit, but its behaviour — exact, else floor, else fetch — is a strict subset; the shared method's order (exact → hydrate → exact → floor-short-circuit → in-range → extend → resolve) reproduces both. Verify against stock suites in Task 4.)
5. **Window loop bound:** `guardSteps < 250`, log a warning on hitting the bound. No-progress break = `boundsKeys == before`. Forward endpoint first then backward (`for requestedKey in [upperKey, lowerKey]`) for the range path; single window-cover for the single-price path toward the requested key.
6. **`fetchAndMerge` is the single fetch seam.** The shared loop computes the window `ClosedRange<Date>` (via `dateFormatter.date(from: DateKey.isoString(window.lowerBound/upperBound))`, fallback to the requested date) and passes it to the plug. The plug owns provider chain / coalescing / persistence and may throw on genuine failure; the shared loop captures the thrown error as `lastFetchError`, breaks the current direction, and feeds it to resolution. A `CancellationError` must be rethrown unchanged (do not capture it as `lastFetchError`).
7. **`boundsKeys` is computed inline in the shared code** from `caches[key]` (not a plug): `(DateKey.from(isoString: cache.earliestDate), DateKey.from(isoString: cache.latestDate))`, `(nil, nil)` when cold. This is identical to both services' existing `boundsKeys`.

- [ ] **Step 1: Write the failing test suite**

`MoolahTests/Shared/PriceSeriesOrchestratingTests.swift`:
```swift
import Foundation
import Testing

@testable import Moolah

/// Minimal cache satisfying `PriceSeriesCache` for the fake actor.
private struct FakeCache: PriceSeriesCache {
  var earliestDate: String
  var latestDate: String
  var prices: SortedDateSeries<Decimal>
  var firstTradedOn: String?
}

/// A minimal actor that conforms to `PriceSeriesOrchestrating` to drive the
/// shared default methods in isolation. The fetcher plug mutates
/// `self.caches[key]` per key (never a snapshot), optionally suspending on an
/// injected gate so the concurrent-two-instrument race can be probed.
private actor FakeService: PriceSeriesOrchestrating {
  typealias Cache = FakeCache

  var caches: [String: FakeCache] = [:]
  var hydrated: Set<String> = []
  let now: @Sendable () -> Date
  let timeZone: TimeZone
  let dateFormatter: ISO8601DateFormatter
  let plannerConfig = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)

  /// Per-key wire data the fetcher serves; `fetchAndMerge` merges the slice of
  /// these dates that fall inside the requested window into `caches[key]`.
  private var wire: [String: [String: Decimal]]
  private var floors: [String: String]
  private(set) var fetchCount = 0
  private(set) var hydrateCount: [String: Int] = [:]
  /// Optional gate the fetcher awaits before mutating, to interleave two calls.
  private var gate: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)?

  init(
    wire: [String: [String: Decimal]] = [:],
    floors: [String: String] = [:],
    now: @Sendable @escaping () -> Date,
    gated: Bool = false
  ) {
    self.wire = wire
    self.floors = floors
    self.now = now
    self.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    self.dateFormatter = formatter
    if gated {
      var cont: AsyncStream<Void>.Continuation!
      let stream = AsyncStream<Void> { cont = $0 }
      self.gate = (stream, cont)
    }
  }

  func openGate() { gate?.continuation.yield() }

  // Plug 1
  func fetchAndMerge(instrumentKey: String, window: ClosedRange<Date>) async throws {
    fetchCount += 1
    if let gate {
      var iterator = gate.stream.makeAsyncIterator()
      _ = await iterator.next()  // suspend until openGate()
    }
    guard let rows = wire[instrumentKey] else { return }
    let lo = dateFormatter.string(from: window.lowerBound)
    let hi = dateFormatter.string(from: window.upperBound)
    let slice = rows.filter { $0.key >= lo && $0.key <= hi }
    guard !slice.isEmpty else { return }
    var cache =
      caches[instrumentKey]
      ?? FakeCache(earliestDate: hi, latestDate: lo, prices: SortedDateSeries(), firstTradedOn: nil)
    for (day, price) in slice {
      guard let key = DateKey.from(isoString: day) else { continue }
      cache.prices.upsert(price, forKey: key)
    }
    let keys = slice.keys.sorted()
    if cache.prices.isEmpty == false {
      cache.earliestDate = min(cache.earliestDate.isEmpty ? keys.first! : cache.earliestDate, keys.first!)
      cache.latestDate = max(cache.latestDate.isEmpty ? keys.last! : cache.latestDate, keys.last!)
    }
    caches[instrumentKey] = cache  // per-key write, no snapshot
  }

  // Plug 2
  func quote(for instrumentKey: String) -> Instrument? { .USD }

  // Plug 3
  func firstTradeFloor(for instrumentKey: String) -> String? {
    caches[instrumentKey]?.firstTradedOn ?? floors[instrumentKey]
  }
  func confirmFirstTradeOnBackwardExhaustion(instrumentKey: String, lastFetchError: (any Error)?) async throws {
    guard lastFetchError == nil, var cache = caches[instrumentKey],
      cache.firstTradedOn == nil, !cache.earliestDate.isEmpty
    else { return }
    cache.firstTradedOn = cache.earliestDate
    caches[instrumentKey] = cache
  }

  // Hydration plug
  func hydrate(instrumentKey: String) async throws {
    hydrateCount[instrumentKey, default: 0] += 1
    hydrated.insert(instrumentKey)
  }

  // Error factories
  func belowFloorError(instrumentKey: String, date: String) -> any Error {
    CryptoPriceError.beforeFirstTrade(tokenId: instrumentKey, date: date)
  }
  func noPriceError(instrumentKey: String, date: String) -> any Error {
    CryptoPriceError.noPriceAvailable(tokenId: instrumentKey, date: date)
  }
}

@Suite("PriceSeriesOrchestrating")
struct PriceSeriesOrchestratingTests {
  private func day(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.date(from: s)!
  }
  /// Fixed "now" so the cap lands on a stable yesterday (2026-04-30).
  private let fixedNow: @Sendable () -> Date = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
    return f.date(from: "2026-05-01")!
  }

  @Test
  func fetchesAndReturnsExactPrice() async throws {
    let service = FakeService(
      wire: ["AAA": ["2026-04-20": Decimal(10), "2026-04-21": Decimal(11)]], now: fixedNow)
    let price = try await service.price(instrumentKey: "AAA", on: day("2026-04-21"))
    #expect(price == Decimal(11))
  }

  @Test
  func capsRequestAtYesterday() async throws {
    // now = 2026-05-01 → yesterday = 2026-04-30; wire only has 04-30.
    let service = FakeService(wire: ["AAA": ["2026-04-30": Decimal(7)]], now: fixedNow)
    // Requesting "today" (2026-05-01) must resolve to yesterday's close.
    let price = try await service.price(instrumentKey: "AAA", on: day("2026-05-01"))
    #expect(price == Decimal(7))
  }

  @Test
  func hydratesExactlyOnce() async throws {
    let service = FakeService(wire: ["AAA": ["2026-04-21": Decimal(11)]], now: fixedNow)
    _ = try await service.price(instrumentKey: "AAA", on: day("2026-04-21"))
    _ = try await service.price(instrumentKey: "AAA", on: day("2026-04-21"))
    let counts = await service.hydrateCount
    #expect(counts["AAA"] == 1)
  }

  @Test
  func priorTradingDayFloorFallback() async throws {
    let service = FakeService(wire: ["AAA": ["2026-04-20": Decimal(10)]], now: fixedNow)
    // 04-21 has no row; floor lands on 04-20.
    let price = try await service.price(instrumentKey: "AAA", on: day("2026-04-21"))
    #expect(price == Decimal(10))
  }

  @Test
  func noProgressBreakThrowsNoPrice() async throws {
    // Empty wire → fetch never advances bounds → loop breaks → noPriceError.
    let service = FakeService(wire: ["AAA": [:]], now: fixedNow)
    await #expect(throws: CryptoPriceError.self) {
      _ = try await service.price(instrumentKey: "AAA", on: day("2026-04-21"))
    }
    let count = await service.fetchCount
    #expect(count < 250)  // bounded, not the guard limit
  }

  @Test
  func belowFloorShortCircuits() async throws {
    let service = FakeService(
      wire: ["AAA": ["2026-04-20": Decimal(10)]], floors: ["AAA": "2026-04-15"], now: fixedNow)
    await #expect(throws: CryptoPriceError.beforeFirstTrade(tokenId: "AAA", date: "2026-04-10")) {
      _ = try await service.price(instrumentKey: "AAA", on: day("2026-04-10"))
    }
  }

  @Test
  func backwardExhaustionConfirmsFloor() async throws {
    // wire starts at 04-20; a request for 04-10 walks backward, exhausts with
    // no error, and the confirm hook sets firstTradedOn = earliestDate (04-20).
    let service = FakeService(wire: ["AAA": ["2026-04-20": Decimal(10)]], now: fixedNow)
    _ = try? await service.price(instrumentKey: "AAA", on: day("2026-04-21"))  // seed 04-20
    _ = try? await service.price(instrumentKey: "AAA", on: day("2026-04-10"))  // backward walk
    let floor = await service.firstTradeFloor(for: "AAA")
    #expect(floor == "2026-04-20")
  }

  @Test
  func carryForwardSeriesUTC() async throws {
    // 04-20 present, 04-21/04-22 absent → carried forward over a UTC day walk.
    let service = FakeService(wire: ["AAA": ["2026-04-20": Decimal(10)]], now: fixedNow)
    let series = try await service.prices(
      instrumentKey: "AAA", in: day("2026-04-20")...day("2026-04-22"))
    #expect(series.map(\.price) == [Decimal(10), Decimal(10), Decimal(10)])
    #expect(series.map { self.dayString($0.date) } == ["2026-04-20", "2026-04-21", "2026-04-22"])
  }

  private func dayString(_ d: Date) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; f.timeZone = .utc
    return f.string(from: d)
  }

  @Test
  func concurrentTwoInstrumentsNoCacheClobber() async throws {
    // The data-race regression test: two overlapping price(...) calls for
    // different keys, each suspending inside the gated fetcher, must each
    // commit their own cache entry — neither drops the other's.
    let service = FakeService(
      wire: ["AAA": ["2026-04-21": Decimal(11)], "BBB": ["2026-04-21": Decimal(22)]],
      now: fixedNow, gated: true)
    async let a = service.price(instrumentKey: "AAA", on: day("2026-04-21"))
    async let b = service.price(instrumentKey: "BBB", on: day("2026-04-21"))
    // Let both calls reach the gate, then release both fetches.
    await service.openGate()
    await service.openGate()
    let (pa, pb) = try await (a, b)
    #expect(pa == Decimal(11))
    #expect(pb == Decimal(22))
    let caches = await service.caches
    #expect(caches["AAA"] != nil)
    #expect(caches["BBB"] != nil)  // neither clobbered
  }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `just generate && just test-mac PriceSeriesOrchestratingTests 2>&1 | tee .agent-tmp/t2-fail.txt`
Expected: FAIL to compile — `PriceSeriesOrchestrating` is not defined yet (no `price(instrumentKey:on:)` / `prices(instrumentKey:in:)` defaults). Confirm the error names the missing protocol, not an unrelated typo.

- [ ] **Step 3: Write the protocol + shared defaults**

`Shared/PriceSeriesOrchestrating.swift`:
```swift
import Foundation
import OSLog

/// Shared daily-price-series orchestration for the stock and crypto price
/// services. Default-implemented on an `Actor`-constrained protocol so the
/// shared code runs each conforming actor's own isolation and mutates
/// `caches[instrumentKey]` PER KEY — never a whole-dict snapshot — which is
/// what preserves the actors' concurrent-different-instrument re-entrancy
/// contract (a snapshot/defer-writeback design would clobber a concurrent
/// call's committed cache entry). The three genuine differences (provider
/// fetch, quote denomination, optional first-trade floor) are plugs.
protocol PriceSeriesOrchestrating: Actor {
  associatedtype Cache: PriceSeriesCache

  /// Per-instrument caches, keyed ticker / tokenId. Mutated per key by the
  /// shared defaults on `self`; satisfied by each actor's stored property.
  var caches: [String: Cache] { get set }
  /// Keys hydrated from SQL (so a genuinely empty cache is not re-queried).
  var hydrated: Set<String> { get set }

  var now: @Sendable () -> Date { get }
  var timeZone: TimeZone { get }
  var dateFormatter: ISO8601DateFormatter { get }
  var plannerConfig: ContiguousFetchPlanner.Config { get }

  /// Plug 1 — fetch the window, merge into `caches[instrumentKey]`, persist.
  /// Owns the single-client (stock) vs fallback-chain + coalescing (crypto)
  /// difference. Throws on genuine provider failure; rethrows `CancellationError`.
  func fetchAndMerge(instrumentKey: String, window: ClosedRange<Date>) async throws
  /// Plug 2 — the instrument's quote denomination (stock: listing currency;
  /// crypto: `.USD`). `nil` when unknown (cold cache).
  func quote(for instrumentKey: String) -> Instrument?
  /// Plug 3a — confirmed first-trade floor (`YYYY-MM-DD`); `nil` for stock.
  func firstTradeFloor(for instrumentKey: String) -> String?
  /// Plug 3b — confirm+persist the floor on a no-error backward exhaustion;
  /// no-op for stock.
  func confirmFirstTradeOnBackwardExhaustion(
    instrumentKey: String, lastFetchError: (any Error)?) async throws

  /// Hydrate `caches[instrumentKey]` + insert into `hydrated` from SQL.
  func hydrate(instrumentKey: String) async throws

  func belowFloorError(instrumentKey: String, date: String) -> any Error
  func noPriceError(instrumentKey: String, date: String) -> any Error
}

extension PriceSeriesOrchestrating {
  // MARK: - Public orchestration

  /// Single price: cap → exact → hydrate-once → exact → floor-short-circuit →
  /// in-range → extend-contiguously → resolve. Mutates `caches[key]` per key.
  func price(instrumentKey key: String, on date: Date) async throws -> Decimal {
    let capped = cappedToYesterday(date, now: now, timeZone: timeZone)
    let dateString = dateFormatter.string(from: capped)

    if let hit = exact(key: key, dateString: dateString) { return hit }
    if !hydrated.contains(key) { try await hydrate(instrumentKey: key) }
    if let hit = exact(key: key, dateString: dateString) { return hit }

    if let floor = firstTradeFloor(for: key), dateString < floor {
      throw belowFloorError(instrumentKey: key, date: dateString)
    }

    if let inRange = try inRangeResolution(key: key, dateString: dateString) {
      return inRange
    }

    return try await extendAndResolve(key: key, date: capped, dateString: dateString)
  }

  /// Range: hydrate-once → cap upper → cover forward+backward → carry-forward
  /// series over the caller's range using `Calendar.utc` day stepping.
  func prices(
    instrumentKey key: String, in range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    if !hydrated.contains(key) { try await hydrate(instrumentKey: key) }
    let fetchUpper = cappedToYesterday(range.upperBound, now: now, timeZone: timeZone)
    if range.lowerBound <= fetchUpper,
      let lowerKey = DateKey.from(isoString: dateFormatter.string(from: range.lowerBound)),
      let upperKey = DateKey.from(isoString: dateFormatter.string(from: fetchUpper))
    {
      try await coverRange(key: key, lowerKey: lowerKey, upperKey: upperKey)
    }
    return buildResultSeries(key: key, in: range)
  }

  // MARK: - Shared internals (lifted verbatim, operating on self.caches[key])

  private func exact(key: String, dateString: String) -> Decimal? {
    guard let dk = DateKey.from(isoString: dateString) else { return nil }
    return caches[key]?.prices.exact(dk)
  }

  private func floorPrice(key: String, dateString: String) -> Decimal? {
    guard let dk = DateKey.from(isoString: dateString), let cache = caches[key] else { return nil }
    return cache.prices.floor(dk)
  }

  /// In-range short-circuit (mirrors crypto `inRangeFallback`): when the date
  /// sits inside `[earliest, latest]`, return the floor if present, else throw
  /// `noPriceError` rather than re-fetch. `nil` ⇒ out of range, caller extends.
  private func inRangeResolution(key: String, dateString: String) throws -> Decimal? {
    guard let cache = caches[key],
      dateString >= cache.earliestDate, dateString <= cache.latestDate
    else { return nil }
    if let f = floorPrice(key: key, dateString: dateString) { return f }
    throw noPriceError(instrumentKey: key, date: dateString)
  }

  private func boundsKeys(key: String) -> (earliest: Int32?, latest: Int32?) {
    guard let cache = caches[key] else { return (nil, nil) }
    return (DateKey.from(isoString: cache.earliestDate), DateKey.from(isoString: cache.latestDate))
  }

  private func windowDates(_ window: ClosedRange<Int32>, fallback: Date) -> ClosedRange<Date> {
    let lo = dateFormatter.date(from: DateKey.isoString(window.lowerBound)) ?? fallback
    let hi = dateFormatter.date(from: DateKey.isoString(window.upperBound)) ?? fallback
    return lo...max(lo, hi)
  }

  /// Extend toward a single requested date, then resolve. Mirrors crypto
  /// `extendContiguously` + `resolveAfterExtension`.
  private func extendAndResolve(
    key: String, date: Date, dateString: String
  ) async throws -> Decimal {
    let requestedKey = DateKey.from(isoString: dateString) ?? Int32.max
    let lastError = try await runWindowLoop(
      key: key, requestedKey: requestedKey, fallback: date,
      midLoopHit: { [self] in
        if let hit = exact(key: key, dateString: dateString) { return hit }
        return try inRangeResolution(key: key, dateString: dateString)
      })
    if let hit = exact(key: key, dateString: dateString) { return hit }
    if let f = floorPrice(key: key, dateString: dateString) { return f }
    if let inRange = try inRangeResolution(key: key, dateString: dateString) { return inRange }
    if let floor = firstTradeFloor(for: key), dateString < floor {
      throw belowFloorError(instrumentKey: key, date: dateString)
    }
    if let lastError { throw lastError }
    throw noPriceError(instrumentKey: key, date: dateString)
  }

  /// Cover `[lowerKey, upperKey]` forward-then-backward, then surface the last
  /// provider error if an endpoint is still uncovered. Mirrors crypto
  /// `coverRangeContiguously`.
  private func coverRange(key: String, lowerKey: Int32, upperKey: Int32) async throws {
    var lastError: (any Error)?
    for requestedKey in [upperKey, lowerKey] {
      let err = try await runWindowLoop(
        key: key, requestedKey: requestedKey, fallback: now(), midLoopHit: { nil })
      if let err { lastError = err }
    }
    if let lastError {
      let todayKey = DateKey.from(isoString: dateFormatter.string(from: now())) ?? upperKey
      let bounds = boundsKeys(key: key)
      let stillUncovered = [upperKey, lowerKey].contains { k in
        ContiguousFetchPlanner.nextWindow(
          earliest: bounds.earliest, latest: bounds.latest,
          requested: k, today: todayKey, config: plannerConfig) != nil
      }
      if stillUncovered { throw lastError }
    }
  }

  /// The bounded planner loop toward `requestedKey`. Returns the captured
  /// provider error (if the chain failed) or `nil`. `midLoopHit` lets the
  /// single-price path early-exit on a cache hit between windows; the range
  /// path passes `{ nil }`. Rethrows `CancellationError` unchanged.
  private func runWindowLoop(
    key: String,
    requestedKey: Int32,
    fallback: Date,
    midLoopHit: () throws -> Decimal?
  ) async throws -> (any Error)? {
    let todayKey = DateKey.from(isoString: dateFormatter.string(from: now())) ?? requestedKey
    var lastError: (any Error)?
    var guardSteps = 0
    while guardSteps < 250 {
      guardSteps += 1
      let bounds = boundsKeys(key: key)
      guard
        let window = ContiguousFetchPlanner.nextWindow(
          earliest: bounds.earliest, latest: bounds.latest,
          requested: requestedKey, today: todayKey, config: plannerConfig)
      else { break }
      let before = bounds
      do {
        try await fetchAndMerge(
          instrumentKey: key, window: windowDates(window, fallback: fallback))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastError = error
        break
      }
      if try midLoopHit() != nil { break }
      if boundsKeys(key: key) == before {
        let wasBackward = before.earliest.map { requestedKey < $0 } ?? false
        if wasBackward {
          try await confirmFirstTradeOnBackwardExhaustion(
            instrumentKey: key, lastFetchError: lastError)
        }
        break
      }
    }
    if guardSteps >= 250 {
      Logger(subsystem: "com.moolah.app", category: "PriceSeriesOrchestrating")
        .warning("window loop guard limit reached for \(key, privacy: .public)")
    }
    return lastError
  }

  /// Carry-forward daily series over `range`, stepping with `Calendar.utc`
  /// (the intentional stock fix). Non-trading gaps carry the last known close;
  /// nothing is emitted before the first known close.
  private func buildResultSeries(
    key: String, in range: ClosedRange<Date>
  ) -> [(date: Date, price: Decimal)] {
    var results: [(date: Date, price: Decimal)] = []
    var lastKnownPrice: Decimal?
    var current = range.lowerBound
    while current <= range.upperBound {
      let dateString = dateFormatter.string(from: current)
      if let dk = DateKey.from(isoString: dateString), let price = caches[key]?.prices.exact(dk) {
        lastKnownPrice = price
        results.append((current, price))
      } else if let fallback = lastKnownPrice {
        results.append((current, fallback))
      }
      guard let next = Calendar.utc.date(byAdding: .day, value: 1, to: current) else { break }
      current = next
    }
    return results
  }
}
```

Implementation note: `runWindowLoop`'s `midLoopHit` is a non-async `throws` closure (the mid-loop hit only reads cache state). If the compiler complains about `throws` in the `() throws -> Decimal?` type colliding with the `async` context, keep it non-async — it does not await. The `quote(for:)` plug is declared on the protocol for Tasks 3/4's read-side accessors and the `quote`-contract test (Step 6 of Tasks 3/4); the shared defaults above do not call it because denomination is recorded during merge, not during the series walk — that matches today's behaviour. Do not add a spurious call.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `just generate && just test-mac PriceSeriesOrchestratingTests 2>&1 | tee .agent-tmp/t2-pass.txt`
Expected: all `@Test`s PASS. In particular `concurrentTwoInstrumentsNoCacheClobber` proves the per-key mutation is race-safe. (`grep -i 'failed\|error:' .agent-tmp/t2-pass.txt` → none.)

If `caches[key]` set/get from the protocol requirement fails to compile under Swift 6 (actor-isolated mutable stored-property requirement), this is the documented obstacle — surface it as **BLOCKED** per Global Constraints; do NOT switch to a snapshot/`inout` design.

- [ ] **Step 5: Build the whole app (no real service conforms yet, must still compile)**

Run: `just build-mac 2>&1 | tee .agent-tmp/t2-build.txt`
Expected: success, no warnings.

- [ ] **Step 6: format-check**

Run: `just format && just format-check 2>&1 | tee .agent-tmp/t2-fmt.txt`
Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native.instrument-pricing-unification add Shared/PriceSeriesOrchestrating.swift MoolahTests/Shared/PriceSeriesOrchestratingTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native.instrument-pricing-unification commit -m "feat(price-series): shared PriceSeriesOrchestrating default-method engine + tests

Lifts the duplicated cap/hydrate/window-loop/carry-forward orchestration into
default methods on an Actor-constrained protocol. Includes a concurrent
two-instrument regression test proving no cross-instrument cache clobber.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q4LphNRBYdAZSbgHNmmCg6"
```
Then `rm .agent-tmp/t2-*.txt`.

---

## Task 3: Convert `CryptoPriceService` to conform

Route `price(for:mapping:on:)` / `prices(for:mapping:in:)` through the shared defaults and implement the plugs by wrapping existing per-service code. Crypto already uses `Calendar.utc`, so **no date behaviour changes** — every crypto suite must pass with expectations unchanged. If any crypto expectation would have to change, **STOP and flag**.

**Files:**
- Modify: `Shared/CryptoPriceService.swift` (add conformance, plugs, thin call-throughs; delete inline carry-forward loop + `generateDateSeries`)
- Modify: `Shared/CryptoPriceService+FetchRange.swift` (delete `extendContiguously`, `coverRangeContiguously`, `extendOneDirection`, `resolveAfterExtension`, `midLoopCacheHit`; **keep** `fetchWindowCoalesced`, `fetchRange`, `boundsKeys`, `parseInterval`, `confirmFirstTradedOnIfExhausted`)

**Interfaces:**
- Consumes: `PriceSeriesOrchestrating` defaults `price(instrumentKey:on:)`, `prices(instrumentKey:in:)` (Task 2).
- Produces: unchanged public API — Sub-project A's `CryptoPriceSource`, `priceLookup`, `registration(for:)` keep calling `price(for:mapping:on:)`.

**Plug mapping (verbatim wrappers):**
- `hydrated` requirement ← rename stored `hydratedTokenIds` to `hydrated` (update its declaration comment and the two read sites in `price(for:mapping:on:)`/`prices(for:mapping:in:)` and `purgeCache`'s `hydratedTokenIds.remove` → `hydrated.remove`). Keep a single name; do NOT keep both.
- `plannerConfig` ← stored `let plannerConfig = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)`.
- `fetchAndMerge(instrumentKey:window:)` ← needs the `Instrument` + `CryptoProviderMapping`, which the window-only signature lacks. Resolve by stashing the in-flight `(instrument, mapping)` for the current extend on the actor before entering the shared default. Concretely: add `private var pendingFetchContext: [String: (instrument: Instrument, mapping: CryptoProviderMapping)] = [:]`, set it in the thin call-throughs, and have `fetchAndMerge` read it:
  ```swift
  func fetchAndMerge(instrumentKey: String, window: ClosedRange<Date>) async throws {
    guard let ctx = pendingFetchContext[instrumentKey] else { return }
    try await fetchWindowCoalesced(
      instrument: ctx.instrument, mapping: ctx.mapping, fetchInterval: window)
  }
  ```
  `fetchWindowCoalesced` already calls `fetchRange` (the 4-provider chain) and persists via `mergeReturningDelta`/`persistDelta`. The coalescing `extensionTasks` table stays untouched.
- `quote(for:)` ← `.USD` (constant).
- `firstTradeFloor(for:)` ← `caches[instrumentKey]?.firstTradedOn`.
- `confirmFirstTradeOnBackwardExhaustion(instrumentKey:lastFetchError:)` ← `try await confirmFirstTradedOnIfExhausted(tokenId: instrumentKey, lastFetchError: lastFetchError)` (existing method in `+FetchRange.swift`, unchanged).
- `hydrate(instrumentKey:)` ← `try await loadCache(tokenId: instrumentKey)` (existing).
- `belowFloorError(instrumentKey:date:)` ← `CryptoPriceError.beforeFirstTrade(tokenId: instrumentKey, date: date)`.
- `noPriceError(instrumentKey:date:)` ← `CryptoPriceError.noPriceAvailable(tokenId: instrumentKey, date: date)`.

- [ ] **Step 1: Write the conformance characterization test (pin existing behaviour through the new path)**

Add to `MoolahTests/Shared/CryptoPriceServiceTests.swift` (same `@Suite`, mirror its existing `makeService` helper — read the file for the exact helper signature; it builds a `CryptoPriceService` with `FixedCryptoPriceClient`-style fakes and UTC zone):
```swift
@Test
func conformsToPriceSeriesOrchestrating() async throws {
  // Compile-time + runtime proof the public entry routes through the shared
  // default and still returns the cached close. (Behaviour identical to
  // `cacheMissFetchesFromClient`; this asserts the routing did not regress.)
  let service = try makeService(/* same fixtures the suite's happy-path test uses */)
  let price = try await service.price(
    for: /* instrument */, mapping: /* mapping */, on: date("2026-04-21"))
  #expect(price == /* expected close */)
}
```
(Use the suite's existing fixture builders for the instrument/mapping/expected value — do not invent new ones. If the suite already has an equivalent happy-path test, this step is satisfied by that test continuing to pass; in that case skip adding a duplicate and rely on the full-suite run in Step 4.)

- [ ] **Step 2: Run to verify it fails**

Run: `just test-mac CryptoPriceServiceTests 2>&1 | tee .agent-tmp/t3-fail.txt`
Expected: FAIL to compile — `CryptoPriceService` does not yet conform to `PriceSeriesOrchestrating` and the inline `price(for:mapping:on:)` still has its own body. (If you skipped adding a test in Step 1, instead this step is: run the suite, confirm it's currently green BEFORE you start editing, so any post-edit failure is attributable.)

- [ ] **Step 3: Implement the conformance**

In `Shared/CryptoPriceService.swift`:
1. Rename `hydratedTokenIds` → `hydrated` throughout this file and `+Persistence.swift` (`loadCache` inserts into it) and `purgeCache`.
2. Add `let plannerConfig = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)` and `private var pendingFetchContext: [String: (instrument: Instrument, mapping: CryptoProviderMapping)] = [:]`.
3. Replace the body of `price(for:mapping:on:)` with a thin call-through that stashes context and delegates:
   ```swift
   func price(
     for instrument: Instrument, mapping: CryptoProviderMapping, on date: Date
   ) async throws -> Decimal {
     pendingFetchContext[instrument.id] = (instrument, mapping)
     defer { pendingFetchContext[instrument.id] = nil }
     return try await price(instrumentKey: instrument.id, on: date)
   }
   ```
   **Re-entrancy caveat:** the `defer` clears the context on return; because the shared default only fetches while this call is on the stack for `instrument.id`, and a concurrent call for a *different* id uses a different dict key, the per-key stash is race-safe for the same reason `caches[key]` is. A concurrent call for the *same* id sets the same context value (identical instrument/mapping), so the last-writer-wins is harmless. Document this in a comment.
4. Replace the body of `prices(for:mapping:in:)` similarly:
   ```swift
   func prices(
     for instrument: Instrument, mapping: CryptoProviderMapping, in range: ClosedRange<Date>
   ) async throws -> [(date: Date, price: Decimal)] {
     pendingFetchContext[instrument.id] = (instrument, mapping)
     defer { pendingFetchContext[instrument.id] = nil }
     return try await prices(instrumentKey: instrument.id, in: range)
   }
   ```
5. Delete the inline carry-forward loop in the old `prices(...)` body and the `generateDateSeries` in the `// MARK: - Cache lookup & merge` extension (now shared). **Keep** `lookupPrice`, `fallbackPrice`, `inRangeFallback` only if still referenced elsewhere; if nothing else calls them after the deletion, remove them too (the shared engine has private equivalents). Grep first: `grep -rn "lookupPrice\|fallbackPrice\|inRangeFallback" Shared/ MoolahTests/` — keep any that the warming/live/attribution tests reference; delete the rest to avoid dead-code SwiftLint violations.
6. Add the conformance + plugs as a **single new extension** (one-extension-per-protocol) in `Shared/CryptoPriceService.swift`:
   ```swift
   extension CryptoPriceService: PriceSeriesOrchestrating {
     typealias Cache = CryptoPriceCache

     func fetchAndMerge(instrumentKey: String, window: ClosedRange<Date>) async throws {
       guard let ctx = pendingFetchContext[instrumentKey] else { return }
       try await fetchWindowCoalesced(
         instrument: ctx.instrument, mapping: ctx.mapping, fetchInterval: window)
     }
     func quote(for instrumentKey: String) -> Instrument? { .USD }
     func firstTradeFloor(for instrumentKey: String) -> String? {
       caches[instrumentKey]?.firstTradedOn
     }
     func confirmFirstTradeOnBackwardExhaustion(
       instrumentKey: String, lastFetchError: (any Error)?
     ) async throws {
       try await confirmFirstTradedOnIfExhausted(
         tokenId: instrumentKey, lastFetchError: lastFetchError)
     }
     func hydrate(instrumentKey: String) async throws {
       try await loadCache(tokenId: instrumentKey)
     }
     func belowFloorError(instrumentKey: String, date: String) -> any Error {
       CryptoPriceError.beforeFirstTrade(tokenId: instrumentKey, date: date)
     }
     func noPriceError(instrumentKey: String, date: String) -> any Error {
       CryptoPriceError.noPriceAvailable(tokenId: instrumentKey, date: date)
     }
   }
   ```
   The actor's stored `caches`, `hydrated`, `now`, `timeZone`, `dateFormatter`, `plannerConfig` satisfy the remaining requirements directly.
7. In `Shared/CryptoPriceService+FetchRange.swift`, delete `extendContiguously`, `coverRangeContiguously`, `extendOneDirection`, `resolveAfterExtension`, `midLoopCacheHit`. Keep `fetchWindowCoalesced`, `fetchRange`, `boundsKeys(tokenId:)`, `parseInterval`, `confirmFirstTradedOnIfExhausted`. (If `boundsKeys(tokenId:)` / `parseInterval` are now only used by `fetchWindowCoalesced`/`fetchRange`, keep them; if fully dead, delete to avoid SwiftLint unused warnings — grep to confirm.)

- [ ] **Step 4: Run the FULL crypto suite list (expectations unchanged)**

Run (exact suite TYPE names from spec §5):
```bash
just test-mac CryptoPriceServiceTests CryptoPriceServiceTestsMore CryptoPriceServiceFallbackTests CryptoPriceServiceBoundaryRangeTests CryptoPriceServiceCapTests CryptoPriceServicePersistenceTests CryptoPriceServiceCoalescingTests CryptoPriceServiceAttributionTests CryptoPriceServiceWarmRangeTests CryptoPriceServiceStablecoinTests CryptoPriceServiceMetadataTests CryptoPriceServicePriceLookupTests CryptoPreListingZeroTests 2>&1 | tee .agent-tmp/t3-crypto.txt
```
Expected: ALL PASS, **no expectation edits**. `grep -i 'failed\|error:' .agent-tmp/t3-crypto.txt` → none. If any crypto test fails, the conversion changed behaviour — **STOP and flag** rather than editing a crypto expectation.

- [ ] **Step 5: Run downstream integration suites**

Run: `just test-mac PreListingDailyBalanceTests PriceSourceTests 2>&1 | tee .agent-tmp/t3-downstream.txt`
Expected: PASS (first-trade floor end-to-end + Sub-project A resolvers over the service).

- [ ] **Step 6: Build + format-check**

Run: `just build-mac 2>&1 | tee .agent-tmp/t3-build.txt && just format && just format-check 2>&1 | tee .agent-tmp/t3-fmt.txt`
Expected: build clean (no warnings — watch for "unused" on any deleted helper's leftover references), format-check exit 0.

- [ ] **Step 7: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native.instrument-pricing-unification add Shared/CryptoPriceService.swift Shared/CryptoPriceService+FetchRange.swift Shared/CryptoPriceService+Persistence.swift MoolahTests/Shared/CryptoPriceServiceTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native.instrument-pricing-unification commit -m "refactor(price-series): route CryptoPriceService through shared engine

price(for:mapping:on:) / prices(for:mapping:in:) now delegate to the shared
PriceSeriesOrchestrating defaults; the 4-provider chain + coalescing + first-
trade floor stay per-service behind plugs. All crypto suites green, unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q4LphNRBYdAZSbgHNmmCg6"
```
Then `rm .agent-tmp/t3-*.txt`.

---

## Task 4: Convert `StockPriceService` to conform — lands the `Calendar.utc` fix

Route `price(ticker:on:)` / `prices(ticker:in:)` through the shared defaults. This task **lands the intentional stock date-stepping fix** (host-local → `Calendar.utc`). Verify the stock suites; if any expected date series shifts, that test encoded the host-zone bug — correct it to the UTC expectation (do NOT preserve the buggy behaviour) and note it for `datetime-review`.

**Files:**
- Modify: `Shared/StockPriceService.swift` (conformance, plugs, thin call-throughs; delete `generateDateSeries`, `buildResultSeries`; route `price`/`prices`)
- Modify: `Shared/StockPriceService+FetchRange.swift` (delete `fetchToCoverDate`, `coverRangeContiguously`; **keep** `boundsKeys(ticker:)`, and `fetchAndMerge(ticker:from:to:)` stays in `StockPriceService.swift`)

**Interfaces:**
- Consumes: `PriceSeriesOrchestrating` defaults (Task 2).
- Produces: unchanged public API — `StockPriceSource` keeps calling `price`/`prices`/`instrument(for:)`.

**Plug mapping (verbatim wrappers):**
- `hydrated` ← rename stored `hydratedTickers` → `hydrated` (update `price`, `prices`, `instrument(for:)`, and `loadCache`'s `hydratedTickers.insert`).
- `plannerConfig` ← `let plannerConfig = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)`.
- `fetchAndMerge(instrumentKey:window:)` ← `try await fetchAndMerge(ticker: instrumentKey, from: window.lowerBound, to: window.upperBound)` (existing single-client method, unchanged). No coalescing, no pending-context stash needed (stock's `fetchAndMerge` takes only ticker+dates).
- `quote(for:)` ← `caches[instrumentKey]?.instrument` (listing currency; also backs `instrument(for:)`).
- `firstTradeFloor(for:)` ← `nil` (stock has no first-trade concept).
- `confirmFirstTradeOnBackwardExhaustion(...)` ← no-op (`{ }`).
- `hydrate(instrumentKey:)` ← `try await loadCache(ticker: instrumentKey)` (widen `loadCache` from `private` to non-private so the plug — in the same file — can call it; it already is callable in-file, but confirm access).
- `belowFloorError(instrumentKey:date:)` ← `StockPriceError.noPriceAvailable(ticker: instrumentKey, date: date)` (never invoked — floor is always nil — but the factory must return a real error).
- `noPriceError(instrumentKey:date:)` ← `StockPriceError.noPriceAvailable(ticker: instrumentKey, date: date)`.

- [ ] **Step 1: Write the failing routing test + a UTC carry-forward assertion**

Add to `MoolahTests/Shared/StockPriceServiceTests.swift` (mirror the existing `makeService` / `date` / `bhpResponse` helpers in that file):
```swift
@Test
func rangeCarriesForwardOverWeekendUTC() async throws {
  // BHP closes Fri 04-10 at 38.25; Sat 04-11/Sun 04-12 carry forward.
  // Asserts the shared Calendar.utc day walk emits the correct labels.
  let service = try makeService(responses: ["BHP.AX": bhpResponse()])
  _ = try await service.price(ticker: "BHP.AX", on: date("2026-04-07"))
  let series = try await service.prices(
    ticker: "BHP.AX", in: date("2026-04-10")...date("2026-04-12"))
  #expect(series.map(\.price) == [dec("38.25"), dec("38.25"), dec("38.25")])
}
```
(`bhpResponse()` has `2026-04-11: 38.60` — adjust the expected values to the suite's actual fixture: 04-10 = 38.25, 04-11 = 38.60, 04-12 carries 38.60. Read the fixture in the file and assert exactly what the carry-forward produces; the point is the three UTC day labels are present and contiguous.)

- [ ] **Step 2: Run to verify it fails / pins current behaviour**

Run: `just test-mac StockPriceServiceTests 2>&1 | tee .agent-tmp/t4-fail.txt`
Expected: FAIL to compile if `StockPriceService` doesn't conform yet / the test references nothing new it's a new test → it should pass against the CURRENT host-local code on a UTC host. Run it now to confirm green on the unmodified code (so a post-edit failure flags the date-fix surfacing). If it's red on the current code on this host, that itself is the host-local bug — note it.

- [ ] **Step 3: Implement the conformance**

In `Shared/StockPriceService.swift`:
1. Rename `hydratedTickers` → `hydrated` everywhere in the file (decl, `price`, `prices`, `instrument(for:)`, `loadCache`).
2. Add `let plannerConfig = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)`.
3. Replace `price(ticker:on:)` body with the thin call-through:
   ```swift
   func price(ticker: String, on date: Date) async throws -> Decimal {
     try await price(instrumentKey: ticker, on: date)
   }
   ```
4. Replace `prices(ticker:in:)` body:
   ```swift
   func prices(
     ticker: String, in range: ClosedRange<Date>
   ) async throws -> [(date: Date, price: Decimal)] {
     try await prices(instrumentKey: ticker, in: range)
   }
   ```
5. Delete `generateDateSeries(in:)` and `buildResultSeries(ticker:in:)` (now shared). Delete `cappedDate`, `lookupPrice`, `fallbackPrice` only if nothing else references them after the edit — grep first (`grep -rn "cappedDate\|lookupPrice\|fallbackPrice\|buildResultSeries" Shared/ MoolahTests/`); keep `instrument(for:)`. `instrument(for:)` stays as-is (reads `caches[ticker]?.instrument`).
6. Add the conformance extension (one-extension-per-protocol) in `Shared/StockPriceService.swift`:
   ```swift
   extension StockPriceService: PriceSeriesOrchestrating {
     typealias Cache = StockPriceCache

     func fetchAndMerge(instrumentKey: String, window: ClosedRange<Date>) async throws {
       try await fetchAndMerge(
         ticker: instrumentKey, from: window.lowerBound, to: window.upperBound)
     }
     func quote(for instrumentKey: String) -> Instrument? { caches[instrumentKey]?.instrument }
     func firstTradeFloor(for instrumentKey: String) -> String? { nil }
     func confirmFirstTradeOnBackwardExhaustion(
       instrumentKey: String, lastFetchError: (any Error)?
     ) async throws {}
     func hydrate(instrumentKey: String) async throws {
       try await loadCache(ticker: instrumentKey)
     }
     func belowFloorError(instrumentKey: String, date: String) -> any Error {
       StockPriceError.noPriceAvailable(ticker: instrumentKey, date: date)
     }
     func noPriceError(instrumentKey: String, date: String) -> any Error {
       StockPriceError.noPriceAvailable(ticker: instrumentKey, date: date)
     }
   }
   ```
   Note the two `fetchAndMerge` overloads now coexist (the plug `fetchAndMerge(instrumentKey:window:)` and the existing `fetchAndMerge(ticker:from:to:)`); the plug calls the existing one. Confirm `loadCache(ticker:)` is callable from the extension — if it's `private`, change to no modifier (internal) so the same-type extension can call it.
7. In `Shared/StockPriceService+FetchRange.swift`, delete `fetchToCoverDate` and `coverRangeContiguously`. Keep `boundsKeys(ticker:)` only if still referenced (grep — the shared engine has its own private `boundsKeys(key:)`, so the stock one is likely now dead; delete it if so).

- [ ] **Step 4: Run the stock suites — watch for date-series shifts**

Run: `just test-mac StockPriceServiceTests StockPriceServiceFallbackTests StockPriceServicePersistenceTests 2>&1 | tee .agent-tmp/t4-stock.txt`
Expected: PASS on a UTC-pinned host (the suites pin `timeZone: UTC` and build UTC-anchored ranges, so `Calendar.utc` stepping yields the same day set). `grep -i 'failed\|error:' .agent-tmp/t4-stock.txt` → none.

**If any date-series / `results.count` assertion fails:** that test encoded the host-local stepping bug. Correct the expectation to the UTC-correct day set (do NOT revert the engine to host-local). Record the change in the commit body and flag it for `datetime-review`. Do not "fix" by changing `Calendar.utc` back.

- [ ] **Step 5: Run downstream + full price-service surface**

Run: `just test-mac PriceSourceTests ContiguousFetchPlannerTests SortedDateSeriesTests 2>&1 | tee .agent-tmp/t4-downstream.txt`
Expected: PASS (Sub-project A resolvers + shared lower layers unchanged).

- [ ] **Step 6: Build + format-check**

Run: `just build-mac 2>&1 | tee .agent-tmp/t4-build.txt && just format && just format-check 2>&1 | tee .agent-tmp/t4-fmt.txt`
Expected: build clean, no warnings, format-check exit 0.

- [ ] **Step 7: Run datetime-review on the stock date-stepping change**

Invoke the `datetime-review` agent against `Shared/PriceSeriesOrchestrating.swift` (the `buildResultSeries` `Calendar.utc` walk) and `Shared/StockPriceService.swift`. Apply any findings. This satisfies the spec's "the stock date-series change gets a `datetime-review` pass regardless."

- [ ] **Step 8: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native.instrument-pricing-unification add Shared/StockPriceService.swift Shared/StockPriceService+FetchRange.swift MoolahTests/Shared/StockPriceServiceTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native.instrument-pricing-unification commit -m "refactor(price-series): route StockPriceService through shared engine + UTC fix

price(ticker:on:) / prices(ticker:in:) now delegate to the shared
PriceSeriesOrchestrating defaults. Lands the intentional date-stepping fix:
the carry-forward series now steps with Calendar.utc instead of the host-local
gregorian calendar (a timezoneless-date bug). datetime-review pass applied.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q4LphNRBYdAZSbgHNmmCg6"
```
Then `rm .agent-tmp/t4-*.txt`.

---

## Final verification (after all four tasks)

- [ ] **Full price-service + integration sweep:**
  ```bash
  just test-mac StockPriceServiceTests StockPriceServiceFallbackTests StockPriceServicePersistenceTests CryptoPriceServiceTests CryptoPriceServiceTestsMore CryptoPriceServiceFallbackTests CryptoPriceServiceBoundaryRangeTests CryptoPriceServiceCapTests CryptoPriceServicePersistenceTests CryptoPriceServiceCoalescingTests CryptoPriceServiceAttributionTests CryptoPriceServiceWarmRangeTests CryptoPriceServiceStablecoinTests CryptoPriceServiceMetadataTests CryptoPriceServicePriceLookupTests CryptoPreListingZeroTests PriceSeriesOrchestratingTests PreListingDailyBalanceTests PriceSourceTests ContiguousFetchPlannerTests SortedDateSeriesTests 2>&1 | tee .agent-tmp/final.txt
  ```
  Expected: all green, only the documented stock date assertion (if any) edited.
- [ ] Run `code-review` and `concurrency-review` agents over the new/changed files (`Shared/PriceSeriesOrchestrating.swift`, both services, the new cache conformances). Apply Critical/Important/Minor findings; open a follow-up PR only if a finding is genuinely out of scope.
- [ ] `just format-check` exit 0; `just build-mac` warning-free.
- [ ] Push branch + open PR per the `landing-prs` skill; enable automerge.

---

## Self-Review

**1. Spec coverage:**
- §2.1 shape (default methods on `Actor`-constrained protocol, no snapshot) → Task 2 protocol + extension; per-key mutation enforced in `runWindowLoop`/`buildResultSeries`; concurrent regression test in Task 2 Step 1. ✓
- §2.2 requirements (cache accessors + three plugs + hydrate + error factories) → Task 2 protocol decl; satisfied in Tasks 3/4. ✓
- §2.3 plug definitions (fetch+merge / quote / first-trade) → mapped verbatim in Tasks 3 & 4 plug tables. ✓
- §2.4 tables/hydration stay per-service → `hydrate` plug wraps existing `loadCache`; persistence stays in `fetchAndMerge`. ✓
- §2.5 `generateDateSeries` → `Calendar.utc` → `buildResultSeries` in Task 2; lands for stock in Task 4. ✓
- §2.6 thin wrappers → Tasks 3/4 call-throughs. ✓
- §3 what-stays-per-service (chain, coalescing, quote, first-trade, hydration/persistence, Sub-project A resolution, live/warming) → all retained; explicitly NOT touched. ✓
- §4 behaviour preservation (carry-forward, capping, notify, first-trade gate, re-entrancy, coalescing, guardSteps<250) → reproduced in Task 2 internals; verified by full suites in Tasks 3/4. ✓
- §5 testing (engine tests written first, concurrent two-instrument, quote contract, all listed suites green, stock UTC verify) → Task 2 Step 1 (TDD), Tasks 3/4 Steps 1+4. The "quote(for:) returns listing currency / .USD" focused test is covered by `PriceSourceTests` (kept green) + the `quote` plug bodies; if a reviewer wants an explicit unit test, add it to Task 4 Step 1 — noted. ✓
- §6 boundaries (no schema, FX untouched, public APIs, behaviour-neutral) → Global Constraints + per-task STOP-and-flag gates. ✓

**2. Placeholder scan:** The two spots that read as placeholders are deliberate and bounded: Task 3 Step 1 and Task 4 Step 1 say "use the suite's existing fixture builders / read the file for exact values" because the fixtures (`bhpResponse`, the crypto `makeService` helper) live in the test files and the implementer must mirror them rather than invent divergent fixtures — inventing values would risk a wrong expectation. Every code block that defines new production code (the protocol, the extension, all plug bodies) is complete and real. No "TBD"/"handle edge cases"/"similar to Task N".

**3. Type consistency:** `caches`, `hydrated`, `now`, `timeZone`, `dateFormatter`, `plannerConfig`, `fetchAndMerge(instrumentKey:window:)`, `quote(for:)`, `firstTradeFloor(for:)`, `confirmFirstTradeOnBackwardExhaustion(instrumentKey:lastFetchError:)`, `hydrate(instrumentKey:)`, `belowFloorError(instrumentKey:date:)`, `noPriceError(instrumentKey:date:)`, `price(instrumentKey:on:)`, `prices(instrumentKey:in:)` are spelled identically in the protocol (Task 2), the shared extension (Task 2), and both conformances (Tasks 3, 4). `PriceSeriesCache` fields (`earliestDate`/`latestDate`/`prices`) match the structs (Task 1). `ContiguousFetchPlanner.Config(windowDays:forwardBuffer:)` and `cappedToYesterday(_:now:timeZone:)` match the real signatures read from source. The crypto `hydratedTokenIds`→`hydrated` and stock `hydratedTickers`→`hydrated` renames are called out as the single canonical name (no dual-name aliasing).
