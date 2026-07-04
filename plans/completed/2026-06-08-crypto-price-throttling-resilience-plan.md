# Throttle-resilient crypto prices for the Analysis dashboard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A throttled price provider (Binance cooldown) must degrade the Analysis data, never blank the screen; missing historical crypto prices are warmed in the background respecting backoff; the dashboard auto-refreshes as prices arrive, with a subtle "Updating prices" indicator.

**Architecture:** Three independent layers. (1) The expense/income aggregations stop rethrowing *transient* conversion failures (a shared `ConversionFailureClassifier.isTransient`), degrading per-row like daily-balances already does. (2) A new throttle-aware `CryptoPriceWarmer` actor, kicked off after a wallet sync's apply pass, fills missing historical prices token-by-token, sleeping out `RateLimitGateError.cooldown` deadlines surfaced by a new `CryptoPriceService.warmRange`. (3) `AnalysisStore` subscribes to `conversionService.observeRates()` (the pattern `AccountStore` already uses) and force-reloads as warm writes land; `AnalysisView` shows a small indicator while warming runs.

**Tech Stack:** Swift 6, SwiftUI, GRDB, Swift Concurrency (actors / `@MainActor` stores), Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`). Build/test/format via `just` targets only.

**Design spec:** `plans/2026-06-08-crypto-price-throttling-resilience-design.md`

**Conventions (non-negotiable — from CLAUDE.md / guides):**
- Tests are **Swift Testing**, never XCTest. `@MainActor @Suite` for store tests.
- One extension per protocol; thin views; logic in stores/services.
- Run builds/tests/format only through `just` (`just build-mac`, `just test-mac <Filter>`, `just format`, `just format-check`). Capture test output to `.agent-tmp/`.
- `git -C <path> …`, never `cd && git`.
- After each task: `just format-check` **and** `just build-mac` **and** the task's tests must pass before commit.
- Use `git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-1075-crypto-price-throttling` for all git ops (abbreviated `git -C "$W"` below; `W` = that path).

---

## File Structure

**Create:**
- `Shared/ConversionFailureClassifier.swift` — `isTransient(_:)` classifier (Task 1).
- `Shared/CryptoPriceWarmer.swift` — the throttle-aware background warmer actor (Task 5).
- `Features/Analysis/AnalysisStore+Observation.swift` — rate-tick subscription (Task 8).
- Test files (one per task): see each task.

**Modify:**
- `Backends/GRDB/Repositories/GRDBAnalysisRepository+ExpenseBreakdown.swift` — degrade transient (Task 2).
- `Backends/GRDB/Repositories/GRDBAnalysisRepository+IncomeAndExpense.swift` — degrade transient (Task 3).
- `Shared/CryptoPriceService+FetchRange.swift` — add `warmRange` + `WarmOutcome` (Task 4).
- `Features/Sync/SyncedAccountStore.swift` + `+Internals.swift` — warmer dependency, trigger, progress flag, teardown (Task 6).
- `App/ProfileSession+CryptoSync.swift` — build & inject `CryptoPriceWarmer` (Task 6).
- `Features/Analysis/AnalysisStore.swift` — `conversionService` dep, `loadAll(force:)`, observation lifecycle (Tasks 7, 8).
- `App/ProfileSession+Factories.swift` (line 347) + `App/ProfileSession+SyncCleanup.swift` + `Features/Analysis/Views/AnalysisView.swift` (preview @264, toolbar indicator) — wiring + UX (Tasks 8, 9).

**Phases (each ships independently-valuable, working software):**
- **Phase 1 (Tasks 1–3): the unblock.** Dashboard stops blanking on throttle. *This alone closes the user-visible bug.*
- **Phase 2 (Task 4): `warmRange`.** Cooldown-surfacing fetch primitive.
- **Phase 3 (Task 5): `CryptoPriceWarmer`.** Background fill logic.
- **Phase 4 (Task 6): trigger.** Warmer runs after sync; progress flag.
- **Phase 5 (Tasks 7–8): auto-refresh.** Dashboard updates as prices land.
- **Phase 6 (Task 9): UX indicator.**
- **Phase 7 (Task 10): integration, reviews, PR.**

---

## Phase 1 — Graceful degradation (the unblock)

### Task 1: `ConversionFailureClassifier.isTransient`

**Files:**
- Create: `Shared/ConversionFailureClassifier.swift`
- Test: `MoolahTests/Shared/ConversionFailureClassifierTests.swift`

- [ ] **Step 1: Write the failing test**

`MoolahTests/Shared/ConversionFailureClassifierTests.swift`:
```swift
import Foundation
import Testing

@testable import Moolah

@Suite("ConversionFailureClassifier")
struct ConversionFailureClassifierTests {

  @Test("rate-limit cooldown is transient")
  func cooldownIsTransient() {
    let error = RateLimitGateError.cooldown(until: Date(timeIntervalSince1970: 1))
    #expect(ConversionFailureClassifier.isTransient(error))
  }

  @Test("WalletSyncError .network is transient")
  func networkIsTransient() {
    let error = WalletSyncError(provider: .binance, kind: .network(underlyingDescription: "x"))
    #expect(ConversionFailureClassifier.isTransient(error))
  }

  @Test("WalletSyncError .rateLimited is transient")
  func rateLimitedIsTransient() {
    let error = WalletSyncError(provider: .binance, kind: .rateLimited(retryAfter: nil))
    #expect(ConversionFailureClassifier.isTransient(error))
  }

  @Test("CryptoPriceError .noPriceAvailable is transient")
  func noPriceAvailableIsTransient() {
    let error = CryptoPriceError.noPriceAvailable(tokenId: "1:native", date: "2026-01-01")
    #expect(ConversionFailureClassifier.isTransient(error))
  }

  @Test("URLError is transient")
  func urlErrorIsTransient() {
    #expect(ConversionFailureClassifier.isTransient(URLError(.timedOut)))
  }

  @Test("structural conversion errors are not transient")
  func structuralNotTransient() {
    #expect(!ConversionFailureClassifier.isTransient(
      ConversionError.unsupportedConversion(from: "A", to: "B")))
    #expect(!ConversionFailureClassifier.isTransient(
      ConversionError.noProviderMapping(instrumentId: "1:0xabc")))
    #expect(!ConversionFailureClassifier.isTransient(
      CryptoPriceError.noProviderMapping(tokenId: "1:0xabc", provider: "Binance")))
    #expect(!ConversionFailureClassifier.isTransient(
      WalletSyncError(provider: .binance, kind: .invalidApiKey)))
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `just test-mac ConversionFailureClassifierTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: FAILS to build — `cannot find 'ConversionFailureClassifier' in scope`.

- [ ] **Step 3: Write the minimal implementation**

`Shared/ConversionFailureClassifier.swift`:
```swift
import Foundation

/// Classifies an error thrown by the instrument-conversion path as a
/// *transient* price-availability failure (the rate is temporarily
/// unfetchable — a throttled provider, a network blip, a day not yet
/// warmed) versus a *structural* failure (the conversion can never
/// succeed — an unsupported pair, a permanently unmapped token).
///
/// The Analysis expense/income aggregations degrade per-row on transient
/// failures (skip the row, render the rest, self-heal once prices warm)
/// but preserve the loud rethrow for structural failures. See
/// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 and issue #1075.
enum ConversionFailureClassifier {
  static func isTransient(_ error: any Error) -> Bool {
    switch error {
    case is RateLimitGateError:
      return true
    case let walletSync as WalletSyncError:
      switch walletSync.kind {
      case .network, .rateLimited:
        return true
      case .missingApiKey, .invalidApiKey, .providerMalformedResponse:
        return false
      }
    case let cryptoPrice as CryptoPriceError:
      switch cryptoPrice {
      case .noPriceAvailable, .allProvidersFailed:
        return true
      case .noProviderMapping:
        return false
      }
    case is URLError:
      return true
    default:
      return false
    }
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `just test-mac ConversionFailureClassifierTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: all `@Test`s PASS.

- [ ] **Step 5: format-check, build, commit**

```bash
W=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-1075-crypto-price-throttling
just format && just format-check && just build-mac
git -C "$W" add Shared/ConversionFailureClassifier.swift MoolahTests/Shared/ConversionFailureClassifierTests.swift
git -C "$W" commit -m "feat(analysis): classify transient vs structural conversion failures (#1075)"
```

---

### Task 2: Degrade transient failures in `assembleExpenseBreakdown`

**Files:**
- Modify: `Backends/GRDB/Repositories/GRDBAnalysisRepository+ExpenseBreakdown.swift` (the `catch` block, ~lines 159–166)
- Test: `MoolahTests/Backends/GRDB/GRDBExpenseBreakdownAssembleTests.swift` (extend existing suite)

**Context — the current `catch` (verbatim, do NOT change the `CancellationError` catch above it):**
```swift
      } catch {
        let context = ConversionFailureContext(
          day: row.day, categoryId: row.categoryId, instrumentId: row.instrumentId)
        handlers.handleConversionFailure(error, context)
        if firstConversionError == nil {
          firstConversionError = error
        }
        continue
      }
```

- [ ] **Step 1: Write the failing tests**

First, **confirm the failure-injection seam.** Read `MoolahTests/Support/ThrowingCountingConversionService.swift` and verify its `convertResult(_:to:on:)` surfaces the `outcome` closure's `.failure(error)` (the assemble path calls `convertResult`, via `convertedQuantity`). If `convertResult` currently always returns `.value`, extend it so a `.failure` outcome throws (mirror its `convert(_:from:to:on:)`). Keep `.value` behaviour for `.success`.

Add to `MoolahTests/Backends/GRDB/GRDBExpenseBreakdownAssembleTests.swift` (mirror the existing `handleConversionFailureFiresPerRow` shape; reuse its `makeAggregation()` fixture):
```swift
  @Test("transient conversion failures degrade per-row — no rethrow")
  func transientFailuresDoNotRethrow() async throws {
    let aggregation = makeAggregation()
    let conversionService = ThrowingCountingConversionService { _ in
      .failure(WalletSyncError(provider: .binance, kind: .network(underlyingDescription: "cooldown")))
    }
    let failures = FailureLog()
    let handlers = GRDBAnalysisRepository.ExpenseBreakdownHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in failures.append(0) })

    let result = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      monthEnd: 25,
      handlers: handlers)

    // Every row was transient → all skipped, no throw, empty (or partial) result.
    #expect(result.isEmpty)
    // Handler still fired for every failing row (diagnostics preserved).
    #expect(!failures.snapshot().isEmpty)
  }

  @Test("structural conversion failures still rethrow")
  func structuralFailuresRethrow() async throws {
    let aggregation = makeAggregation()
    let conversionService = ThrowingCountingConversionService { _ in
      .failure(ConversionError.unsupportedConversion(from: "A", to: "B"))
    }
    let handlers = GRDBAnalysisRepository.ExpenseBreakdownHandlers(
      handleUnparseableDay: { _ in }, handleConversionFailure: { _, _ in })

    await #expect(throws: ConversionError.self) {
      _ = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
        aggregation: aggregation,
        profileInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        monthEnd: 25,
        handlers: handlers)
    }
  }
```

- [ ] **Step 2: Run to verify failure**

Run: `just test-mac GRDBExpenseBreakdownAssembleTests 2>&1 | tee .agent-tmp/t2.txt`
Expected: `transientFailuresDoNotRethrow` FAILS (it throws `WalletSyncError` today); `structuralFailuresRethrow` PASSES already.

- [ ] **Step 3: Implement — gate `firstConversionError` on `isTransient`**

Replace the `catch` body shown in Context with:
```swift
      } catch {
        let context = ConversionFailureContext(
          day: row.day, categoryId: row.categoryId, instrumentId: row.instrumentId)
        handlers.handleConversionFailure(error, context)
        // Transient price-availability failures (a throttled provider, a
        // day not yet warmed — issue #1075) degrade per-row: skip this
        // row's contribution and render the rest. Only a *structural*
        // failure preserves the loud rethrow that signals a genuinely
        // incomplete bucket.
        if firstConversionError == nil, !ConversionFailureClassifier.isTransient(error) {
          firstConversionError = error
        }
        continue
      }
```

- [ ] **Step 4: Run to verify pass**

Run: `just test-mac GRDBExpenseBreakdownAssembleTests 2>&1 | tee .agent-tmp/t2.txt`
Expected: both new tests PASS; existing tests (`handleConversionFailureFiresPerRow` uses a non-transient `CallbackError`, so it still rethrows) PASS.

- [ ] **Step 5: format-check, build, commit**
```bash
W=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-1075-crypto-price-throttling
just format && just format-check && just build-mac
git -C "$W" add Backends/GRDB/Repositories/GRDBAnalysisRepository+ExpenseBreakdown.swift \
  MoolahTests/Backends/GRDB/GRDBExpenseBreakdownAssembleTests.swift \
  MoolahTests/Support/ThrowingCountingConversionService.swift
git -C "$W" commit -m "fix(analysis): degrade transient price failures in expense breakdown (#1075)"
```

---

### Task 3: Degrade transient failures in `assembleIncomeAndExpense`

**Files:**
- Modify: `Backends/GRDB/Repositories/GRDBAnalysisRepository+IncomeAndExpense.swift` (the `catch` block, ~lines 161–168)
- Test: `MoolahTests/Backends/GRDB/GRDBIncomeAndExpenseAssembleTests.swift`

This is byte-for-byte parallel to Task 2.

- [ ] **Step 1: Write the failing tests** — add to `GRDBIncomeAndExpenseAssembleTests.swift`, mirroring Task 2's two tests but calling `GRDBAnalysisRepository.assembleIncomeAndExpense(...)` with `IncomeAndExpenseHandlers(handleUnparseableDay:handleConversionFailure:)` and reusing that suite's existing aggregation fixture. Assert transient → no throw; structural (`ConversionError.unsupportedConversion`) → `await #expect(throws: ConversionError.self)`.

- [ ] **Step 2: Run to verify failure**
Run: `just test-mac GRDBIncomeAndExpenseAssembleTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: the transient test FAILS (throws today).

- [ ] **Step 3: Implement** — replace the `catch` body:
```swift
      } catch {
        let context = IncomeAndExpenseFailureContext(
          day: row.day, instrumentId: row.instrumentId)
        handlers.handleConversionFailure(error, context)
        // Issue #1075: transient price failures degrade per-row; only a
        // structural failure preserves the loud rethrow.
        if firstConversionError == nil, !ConversionFailureClassifier.isTransient(error) {
          firstConversionError = error
        }
        continue
      }
```

- [ ] **Step 4: Run to verify pass**
Run: `just test-mac GRDBIncomeAndExpenseAssembleTests 2>&1 | tee .agent-tmp/t3.txt` — both new tests PASS, existing PASS.

- [ ] **Step 5: format-check, build, commit**
```bash
W=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-1075-crypto-price-throttling
just format && just format-check && just build-mac
git -C "$W" add Backends/GRDB/Repositories/GRDBAnalysisRepository+IncomeAndExpense.swift \
  MoolahTests/Backends/GRDB/GRDBIncomeAndExpenseAssembleTests.swift
git -C "$W" commit -m "fix(analysis): degrade transient price failures in income/expense (#1075)"
```

> **Checkpoint:** Phase 1 complete. The dashboard no longer blanks on a Binance cooldown — it renders with the prices it has. Remaining phases make the missing prices fill in.

---

## Phase 2 — `CryptoPriceService.warmRange`

### Task 4: `WarmOutcome` + `warmRange` (cooldown-surfacing, idempotent)

**Files:**
- Modify: `Shared/CryptoPriceService+FetchRange.swift` (add `WarmOutcome` enum + `warmRange` + internal `fetchSubRangeWarming`)
- Test: `MoolahTests/Shared/CryptoPriceServiceWarmRangeTests.swift`

**Design.** `warmRange(instrument:mapping:in:)` reuses the cache-extension decision (only fetch the uncovered sub-ranges, same guards as `prices(for:mapping:in:)` lines 243–274) but, unlike `fetchRange`, surfaces the soonest `RateLimitGateError.cooldown` deadline instead of wrapping it into `WalletSyncError`.

```swift
enum WarmOutcome: Equatable {
  case filled        // every uncovered sub-range fetched (or nothing to do)
  case cooledDown(until: Date)  // a provider is rate-limited; retry after this
  case unavailable   // no provider could supply data and no cooldown to wait on
}
```

- [ ] **Step 1: Write the failing tests**

`MoolahTests/Shared/CryptoPriceServiceWarmRangeTests.swift` (mirror `CryptoPriceServiceTests`' `makeService` harness — copy its private `makeService`, `date(_:)`, `dec(_:)`, and the `ethInstrument`/`ethMapping` fixtures from that file or `CryptoPriceServiceCapTests`):
```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoPriceService.warmRange")
struct CryptoPriceServiceWarmRangeTests {

  // (copy makeService / date / dec / ethInstrument / ethMapping from CryptoPriceServiceTests)

  @Test("cooldown is surfaced with its deadline")
  func cooldownSurfaced() async throws {
    let deadline = try date("2026-06-07")
    let client = FixedCryptoPriceClient(
      prices: [:], shouldFail: true,
      failureError: RateLimitGateError.cooldown(until: deadline),
      syncProvider: .binance)
    let service = try makeService(clients: [client], now: { try! self.date("2026-06-01") })
    let from = try date("2026-01-01")
    let to = try date("2026-05-31")

    let outcome = await service.warmRange(
      for: ethInstrument, mapping: ethMapping, in: from...to)

    #expect(outcome == .cooledDown(until: deadline))
  }

  @Test("a fillable range returns .filled and populates the cache")
  func fillableReturnsFilled() async throws {
    let prices = ["1:native": ["2026-01-01": dec("100"), "2026-01-02": dec("110")]]
    let database = try ProfileIndexDatabase.openInMemory()
    let service = try makeService(prices: prices, database: database, now: { try! self.date("2026-02-01") })
    let from = try date("2026-01-01")
    let to = try date("2026-01-02")

    let outcome = await service.warmRange(for: ethInstrument, mapping: ethMapping, in: from...to)
    #expect(outcome == .filled)

    // A fresh reader over the same DB now serves the cached price with no fetch.
    let reader = try makeService(clients: [FixedCryptoPriceClient(prices: [:], shouldFail: true)],
      database: database, now: { try! self.date("2026-02-01") })
    let price = try await reader.price(for: ethInstrument, mapping: ethMapping, on: from)
    #expect(price == dec("100"))
  }

  @Test("an already-cached range is a no-op (no extra fetch)")
  func idempotentNoRefetch() async throws {
    let inner = FixedCryptoPriceClient(
      prices: ["1:native": ["2026-01-01": dec("100"), "2026-01-02": dec("110")]])
    let counting = CountingCryptoPriceClient(wrapping: inner)
    let database = try ProfileIndexDatabase.openInMemory()
    let service = try makeService(clients: [counting], database: database, now: { try! self.date("2026-02-01") })
    let range = try date("2026-01-01")...date("2026-01-02")

    _ = await service.warmRange(for: ethInstrument, mapping: ethMapping, in: range)
    let afterFirst = counting.fetchCount
    let outcome = await service.warmRange(for: ethInstrument, mapping: ethMapping, in: range)

    #expect(outcome == .filled)
    #expect(counting.fetchCount == afterFirst)  // second warm fetched nothing
  }

  @Test("no provider data and no cooldown returns .unavailable")
  func emptyReturnsUnavailable() async throws {
    let client = FixedCryptoPriceClient(prices: [:])  // returns empty dict, no throw
    let service = try makeService(clients: [client], now: { try! self.date("2026-02-01") })
    let outcome = await service.warmRange(
      for: ethInstrument, mapping: ethMapping,
      in: try date("2026-01-01")...date("2026-01-02"))
    #expect(outcome == .unavailable)
  }
}
```

Note: confirm `CountingCryptoPriceClient`'s initializer name (`init(wrapping:)`) and `FixedCryptoPriceClient`'s `failureError:` / `syncProvider:` param labels against the actual support files; adjust labels if they differ.

- [ ] **Step 2: Run to verify failure**
Run: `just test-mac CryptoPriceServiceWarmRangeTests 2>&1 | tee .agent-tmp/t4.txt`
Expected: build failure — `value of type 'CryptoPriceService' has no member 'warmRange'`.

- [ ] **Step 3: Implement `WarmOutcome` + `warmRange` + helper**

Append to `Shared/CryptoPriceService+FetchRange.swift`:
```swift
enum WarmOutcome: Equatable {
  case filled
  case cooledDown(until: Date)
  case unavailable
}

extension CryptoPriceService {
  /// Background-warm a token's prices over `range`, fetching only the
  /// sub-ranges the in-memory/on-disk cache does not already cover.
  /// Unlike `fetchRange`, surfaces a provider `RateLimitGateError.cooldown`
  /// deadline (so the warmer can sleep precisely) instead of wrapping it
  /// into a `WalletSyncError`. Idempotent: an already-covered range fetches
  /// nothing and returns `.filled`. See issue #1075.
  func warmRange(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    in range: ClosedRange<Date>
  ) async -> WarmOutcome {
    let tokenId = instrument.id
    if !hydratedTokenIds.contains(tokenId) {
      try? await loadCache(tokenId: tokenId)
    }
    let subRanges = uncoveredSubRanges(tokenId: tokenId, range: range)
    if subRanges.isEmpty { return .filled }

    var soonestCooldown: Date?
    var filledAny = false
    for sub in subRanges {
      switch await fetchSubRangeWarming(instrument: instrument, mapping: mapping, range: sub) {
      case .filled:
        filledAny = true
      case .cooledDown(let until):
        soonestCooldown = soonestCooldown.map { min($0, until) } ?? until
      case .unavailable:
        continue
      }
    }
    if let soonestCooldown { return .cooledDown(until: soonestCooldown) }
    return filledAny ? .filled : .unavailable
  }

  /// The sub-ranges of `range` not already covered by the token's cache.
  /// Mirrors the backward/forward extension decision in
  /// `prices(for:mapping:in:)` (and its boundary-day inversion guards).
  private func uncoveredSubRanges(
    tokenId: String, range: ClosedRange<Date>
  ) -> [ClosedRange<Date>] {
    let fetchUpperBound = cappedToYesterday(range.upperBound, now: now, timeZone: timeZone)
    guard range.lowerBound <= fetchUpperBound else { return [] }
    let rangeStart = isoDay(range.lowerBound)
    let fetchEndString = isoDay(fetchUpperBound)
    let gregorian = Calendar(identifier: .gregorian)
    guard let cache = caches[tokenId] else {
      return [range.lowerBound...fetchUpperBound]  // cold cache: whole range
    }
    var result: [ClosedRange<Date>] = []
    if rangeStart < cache.earliestDate,
      let earliest = isoDate(cache.earliestDate),
      let backEnd = gregorian.date(byAdding: .day, value: -1, to: earliest),
      range.lowerBound <= backEnd
    {
      result.append(range.lowerBound...backEnd)
    }
    if fetchEndString > cache.latestDate,
      let forwardStart = isoDate(cache.latestDate),
      forwardStart <= fetchUpperBound
    {
      result.append(forwardStart...fetchUpperBound)
    }
    return result
  }

  /// Run the provider fallback chain for one sub-range, surfacing the
  /// soonest cooldown deadline rather than wrapping it.
  private func fetchSubRangeWarming(
    instrument: Instrument, mapping: CryptoProviderMapping, range: ClosedRange<Date>
  ) async -> WarmOutcome {
    let tokenId = instrument.id
    let symbol = instrument.ticker ?? instrument.name
    var soonestCooldown: Date?
    for client in clients {
      do {
        let fetched = try await client.dailyPrices(for: mapping, in: range)
        if !fetched.isEmpty {
          let delta = mergeReturningDelta(tokenId: tokenId, symbol: symbol, newPrices: fetched)
          if !delta.isEmpty { try await persistDelta(tokenId: tokenId, deltaRecords: delta) }
          return .filled
        }
      } catch let cooldown as RateLimitGateError {
        if case .cooldown(let until) = cooldown {
          soonestCooldown = soonestCooldown.map { min($0, until) } ?? until
        }
        continue
      } catch CryptoPriceError.noProviderMapping {
        continue
      } catch {
        continue
      }
    }
    if let soonestCooldown { return .cooledDown(until: soonestCooldown) }
    return .unavailable
  }
}
```

**Implementation notes for the engineer:**
- `now` and `timeZone` are the service's existing `private let` clock/zone; `cappedToYesterday`, `mergeReturningDelta`, `persistDelta`, `loadCache`, `hydratedTokenIds`, `caches`, `clients` are all in-scope actor internals (same file family).
- Add two tiny private helpers if not already present: `isoDay(_ d: Date) -> String` and `isoDate(_ s: String) -> Date?` using the service's existing `dateFormatter` (`[.withFullDate]`). If the service already exposes equivalents (`dateFormatter.string(from:)` / `dateFormatter.date(from:)`), use those directly and drop the helpers.
- `WalletSyncError` is **not** thrown here by design — that's the whole point of the warm path.

- [ ] **Step 4: Run to verify pass**
Run: `just test-mac CryptoPriceServiceWarmRangeTests 2>&1 | tee .agent-tmp/t4.txt` — all PASS.

- [ ] **Step 5: format-check, build, commit**
```bash
W=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-1075-crypto-price-throttling
just format && just format-check && just build-mac
git -C "$W" add Shared/CryptoPriceService+FetchRange.swift MoolahTests/Shared/CryptoPriceServiceWarmRangeTests.swift
git -C "$W" commit -m "feat(crypto): warmRange surfaces cooldown deadline, idempotent fill (#1075)"
```

---

## Phase 3 — `CryptoPriceWarmer`

### Task 5: The throttle-aware background warmer

**Files:**
- Create: `Shared/CryptoPriceWarmer.swift`
- Test: `MoolahTests/Shared/CryptoPriceWarmerTests.swift`

**Design.** An `actor` that, given a batch of transactions + the synced account ids, computes per-crypto-token holding ranges (earliest leg date on those accounts → `now`), resolves each token's registration, and warms each priced token serially — sleeping out cooldown deadlines, bounded by `maxCooldownCycles`. Clock and sleep are injected for deterministic tests.

```swift
init(
  priceService: CryptoPriceService,
  registrations: @Sendable @escaping () async throws -> [CryptoRegistration],
  now: @Sendable @escaping () -> Date = { Date() },
  sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
  maxCooldownCycles: Int = 3)
```

- [ ] **Step 1: Write the failing tests**

`MoolahTests/Shared/CryptoPriceWarmerTests.swift`:
```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoPriceWarmer")
struct CryptoPriceWarmerTests {

  // Reuse ethInstrument/ethMapping/date/dec helpers (copy from CryptoPriceServiceTests).

  private func cryptoTxn(account: UUID, instrument: Instrument, on date: Date) -> Transaction {
    Transaction(
      date: date, payee: "buy",
      legs: [TransactionLeg(accountId: account, instrument: instrument, quantity: 1, type: .trade)])
  }

  @Test("cooldown then success: warmer sleeps once, then fills")
  func cooldownThenSuccess() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let toggle = ToggleableCryptoPriceClient()
    await toggle.setShouldFail(true, error: RateLimitGateError.cooldown(until: try date("2026-06-07")))
    let service = CryptoPriceService(
      clients: [toggle], database: database, now: { try! self.date("2026-06-08") })

    let registration = CryptoRegistration(instrument: ethInstrument, mapping: ethMapping)
    let sleeps = SleepRecorder()
    let warmer = CryptoPriceWarmer(
      priceService: service,
      registrations: { [registration] },
      now: { try! self.date("2026-06-08") },
      sleep: { duration in
        sleeps.record(duration)
        // After the first cooldown sleep, the provider recovers.
        await toggle.setPrices(["1:native": ["2026-01-01": self.dec("100")]])
        await toggle.setShouldFail(false, error: nil)
      })

    let account = UUID()
    await warmer.warm(
      transactions: [cryptoTxn(account: account, instrument: ethInstrument, on: try date("2026-01-01"))],
      accountIds: [account])

    #expect(sleeps.count == 1)
    // Cache now serves the warmed price.
    let reader = CryptoPriceService(clients: [], database: database, now: { try! self.date("2026-06-08") })
    let price = try await reader.price(for: ethInstrument, mapping: ethMapping, on: try date("2026-01-01"))
    #expect(price == dec("100"))
  }

  @Test("permanent failure: warmer gives up after maxCooldownCycles, never throws")
  func permanentCooldownGivesUp() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let client = FixedCryptoPriceClient(
      prices: [:], shouldFail: true,
      failureError: RateLimitGateError.cooldown(until: try date("2026-06-07")))
    let service = CryptoPriceService(clients: [client], database: database, now: { try! self.date("2026-06-08") })
    let sleeps = SleepRecorder()
    let warmer = CryptoPriceWarmer(
      priceService: service,
      registrations: { [CryptoRegistration(instrument: ethInstrument, mapping: ethMapping)] },
      now: { try! self.date("2026-06-08") },
      sleep: { sleeps.record($0) },
      maxCooldownCycles: 3)
    let account = UUID()
    await warmer.warm(
      transactions: [cryptoTxn(account: account, instrument: ethInstrument, on: try date("2026-01-01"))],
      accountIds: [account])
    #expect(sleeps.count == 3)  // tried 3 cooldown cycles then gave up
  }

  @Test("unpriced registrations are skipped")
  func unpricedSkipped() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let counting = CountingCryptoPriceClient(wrapping: FixedCryptoPriceClient(prices: [:]))
    let service = CryptoPriceService(clients: [counting], database: database, now: { try! self.date("2026-06-08") })
    let warmer = CryptoPriceWarmer(
      priceService: service,
      registrations: {
        [CryptoRegistration(instrument: ethInstrument, mapping: ethMapping, pricingStatus: .spam)]
      },
      now: { try! self.date("2026-06-08") },
      sleep: { _ in })
    let account = UUID()
    await warmer.warm(
      transactions: [cryptoTxn(account: account, instrument: ethInstrument, on: try date("2026-01-01"))],
      accountIds: [account])
    #expect(counting.fetchCount == 0)
  }
}
```

Add a tiny `SleepRecorder` test helper (in the test file or `MoolahTests/Support/`):
```swift
final class SleepRecorder: @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock(initialState: [Duration]())
  func record(_ d: Duration) { lock.withLock { $0.append(d) } }
  var count: Int { lock.withLock { $0.count } }
}
```
Confirm `ToggleableCryptoPriceClient` exposes `setShouldFail(_:error:)` / `setPrices(_:)` — recon located it at `MoolahTests/Shared/ConvertCacheInvalidationTests.swift:117`; if its API differs, move it to `MoolahTests/Support/ToggleableCryptoPriceClient.swift` and give it those methods (and a `failureError`).

- [ ] **Step 2: Run to verify failure**
Run: `just test-mac CryptoPriceWarmerTests 2>&1 | tee .agent-tmp/t5.txt`
Expected: build failure — `cannot find 'CryptoPriceWarmer' in scope`.

- [ ] **Step 3: Implement the warmer**

`Shared/CryptoPriceWarmer.swift`:
```swift
import Foundation
import OSLog

/// Background-fills historical crypto prices for a freshly-synced wallet,
/// automatically handling provider throttling: when a token's
/// `warmRange` reports a `RateLimitGateError.cooldown`, the warmer sleeps
/// until the deadline and retries that token, bounded by
/// `maxCooldownCycles`. Tokens are processed serially so the shared
/// per-host rate-limit gate is not re-burst. See issue #1075.
actor CryptoPriceWarmer {
  private let priceService: CryptoPriceService
  private let registrations: @Sendable () async throws -> [CryptoRegistration]
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void
  private let maxCooldownCycles: Int
  private let logger = Logger(subsystem: "com.moolah.app", category: "CryptoPriceWarmer")

  init(
    priceService: CryptoPriceService,
    registrations: @Sendable @escaping () async throws -> [CryptoRegistration],
    now: @Sendable @escaping () -> Date = { Date() },
    sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    maxCooldownCycles: Int = 3
  ) {
    self.priceService = priceService
    self.registrations = registrations
    self.now = now
    self.sleep = sleep
    self.maxCooldownCycles = max(1, maxCooldownCycles)
  }

  /// Warm every priced crypto token appearing on `accountIds`' legs in
  /// `transactions`, over `[earliest leg date … now]` per token. Errors
  /// are swallowed (best-effort, background) — cancellation propagates.
  func warm(transactions: [Transaction], accountIds: Set<UUID>) async {
    let ranges = holdingRanges(transactions: transactions, accountIds: accountIds)
    guard !ranges.isEmpty else { return }
    let registrationsById: [String: CryptoRegistration]
    do {
      registrationsById = Dictionary(
        (try await registrations()).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    } catch {
      logger.warning("warm: registration lookup failed: \(error.localizedDescription, privacy: .public)")
      return
    }
    for (instrumentId, range) in ranges {
      guard !Task.isCancelled else { return }
      guard let registration = registrationsById[instrumentId],
        registration.pricingStatus == .priced
      else { continue }
      await warmToken(registration: registration, range: range)
    }
  }

  private func warmToken(registration: CryptoRegistration, range: ClosedRange<Date>) async {
    var cycles = 0
    while !Task.isCancelled {
      let outcome = await priceService.warmRange(
        for: registration.instrument, mapping: registration.mapping, in: range)
      switch outcome {
      case .filled, .unavailable:
        return
      case .cooledDown(let until):
        cycles += 1
        if cycles >= maxCooldownCycles {
          logger.notice(
            "warm: giving up on \(registration.id, privacy: .public) after \(cycles) cooldown cycles")
          return
        }
        let seconds = max(0, until.timeIntervalSince(now()))
        do {
          try await sleep(.seconds(seconds))
        } catch {
          return  // cancelled
        }
      }
    }
  }

  /// Earliest leg date per crypto instrument across `accountIds`' legs,
  /// paired with `now` as the upper bound.
  private func holdingRanges(
    transactions: [Transaction], accountIds: Set<UUID>
  ) -> [String: ClosedRange<Date>] {
    var earliest: [String: Date] = [:]
    var instruments: [String: Instrument] = [:]
    for txn in transactions {
      for leg in txn.legs where leg.instrument.kind == .cryptoToken {
        guard let accountId = leg.accountId, accountIds.contains(accountId) else { continue }
        let id = leg.instrument.id
        instruments[id] = leg.instrument
        earliest[id] = min(earliest[id] ?? txn.date, txn.date)
      }
    }
    let upper = now()
    var ranges: [String: ClosedRange<Date>] = [:]
    for (id, start) in earliest where start <= upper {
      ranges[id] = start...upper
    }
    return ranges
  }
}
```

**Notes:** `TransactionLeg.accountId` is `UUID?`; `Instrument.kind == .cryptoToken` identifies crypto legs. `CryptoPriceService` is an `actor`; `warmRange` is `await`ed. The `sleep(.seconds(0))` for an already-expired deadline returns immediately.

- [ ] **Step 4: Run to verify pass**
Run: `just test-mac CryptoPriceWarmerTests 2>&1 | tee .agent-tmp/t5.txt` — all PASS.

- [ ] **Step 5: format-check, build, commit**
```bash
W=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-1075-crypto-price-throttling
just format && just format-check && just build-mac
git -C "$W" add Shared/CryptoPriceWarmer.swift MoolahTests/Shared/CryptoPriceWarmerTests.swift \
  MoolahTests/Support/ToggleableCryptoPriceClient.swift MoolahTests/Support/SleepRecorder.swift
git -C "$W" commit -m "feat(crypto): throttle-aware background CryptoPriceWarmer (#1075)"
```

---

## Phase 4 — Trigger after wallet sync

### Task 6: Wire the warmer into `SyncedAccountStore`

**Files:**
- Modify: `Features/Sync/SyncedAccountStore.swift` (add dep, flag, task handle, teardown)
- Modify: `Features/Sync/SyncedAccountStore+Internals.swift` (post-apply call)
- Modify: `App/ProfileSession+CryptoSync.swift` (build & inject `CryptoPriceWarmer`)
- Test: `MoolahTests/Features/SyncedAccountStorePriceWarmingTests.swift`

- [ ] **Step 1: Write the failing test**

`MoolahTests/Features/SyncedAccountStorePriceWarmingTests.swift` — drive `syncAccounts` and assert the injected warmer was called with the synced account's new crypto transactions, and that `priceWarmingInProgress` toggles. Use the store's existing test construction pattern (grep `SyncedAccountStore(` in `MoolahTests/` for the established fixture; mirror it, adding the new `priceWarmer:` arg). Use a spy:
```swift
final class SpyPriceWarmer: PriceWarming, @unchecked Sendable {
  let lock = OSAllocatedUnfairLock(initialState: (txns: [Transaction](), called: false))
  func warm(transactions: [Transaction], accountIds: Set<UUID>) async {
    lock.withLock { $0 = (transactions, true) }
  }
}
```
Assert: after `await store.syncAccounts([cryptoAccount])` (with a source that yields ≥1 new crypto txn), `spy` was called with a non-empty `transactions`, and `store.priceWarmingInProgress == false` once the warm task completes (await it via a test seam mirroring `waitForPendingInitialSyncs`).

- [ ] **Step 2: Run to verify failure**
Run: `just test-mac SyncedAccountStorePriceWarmingTests 2>&1 | tee .agent-tmp/t6.txt`
Expected: build failure (`priceWarmer` arg / `priceWarmingInProgress` / `PriceWarming` not found).

- [ ] **Step 3: Implement**

(a) Add a tiny protocol so the store depends on an abstraction (testable) — `Shared/CryptoPriceWarmer.swift`:
```swift
protocol PriceWarming: Sendable {
  func warm(transactions: [Transaction], accountIds: Set<UUID>) async
}
extension CryptoPriceWarmer: PriceWarming {}
```

(b) `SyncedAccountStore.swift` — add stored property, init param, flag, task handle:
```swift
  private(set) var priceWarmingInProgress = false
  private let priceWarmer: (any PriceWarming)?
  private var priceWarmingTask: Task<Void, Never>?
```
Add `priceWarmer: (any PriceWarming)? = nil` to `init` (last param, defaulted so existing call sites/tests compile) and `self.priceWarmer = priceWarmer`.

Add a test seam mirroring `waitForPendingInitialSyncs`:
```swift
  func waitForPriceWarming() async { await priceWarmingTask?.value }
```

Add cancellation to `cancelTimer()`:
```swift
    priceWarmingTask?.cancel()
    priceWarmingTask = nil
```

(c) Add the kick-off method (in `+Internals.swift`):
```swift
  /// Best-effort background price warm for the just-synced accounts'
  /// crypto tokens. Replaces any in-flight warm (the newest sync's
  /// survivor set supersedes). See issue #1075.
  func startPriceWarming(genuinelyNew: [Transaction], accountIds: Set<UUID>) {
    guard let priceWarmer, !genuinelyNew.isEmpty, !accountIds.isEmpty else { return }
    priceWarmingTask?.cancel()
    priceWarmingInProgress = true
    priceWarmingTask = Task { [weak self] in
      await priceWarmer.warm(transactions: genuinelyNew, accountIds: accountIds)
      self?.priceWarmingInProgress = false
    }
  }
```

(d) Call it from `syncAccounts(_:)` immediately after `runTransferDetection(...)`:
```swift
    startPriceWarming(genuinelyNew: genuinelyNew, accountIds: Set(inputs.map(\.id)))
```

(e) `App/ProfileSession+CryptoSync.swift` `makeCryptoSyncWiring` — build the warmer and pass it (everything is in scope: `cryptoPriceService`, `registry`):
```swift
    let priceWarmer = CryptoPriceWarmer(
      priceService: cryptoPriceService,
      registrations: { try await registry.allCryptoRegistrations() })
    let store = SyncedAccountStore(
      sources: [WalletSyncSource(engine: walletSyncEngine), coinstashSource],
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts,
      transferDetection: transferDetection,
      priceWarmer: priceWarmer)
```

- [ ] **Step 4: Run to verify pass**
Run: `just test-mac SyncedAccountStorePriceWarmingTests 2>&1 | tee .agent-tmp/t6.txt` — PASS.
Also run the existing sync suite to confirm no regression: `just test-mac SyncedAccountStore 2>&1 | tee .agent-tmp/t6b.txt`.

- [ ] **Step 5: format-check, build, commit**
```bash
W=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-1075-crypto-price-throttling
just format && just format-check && just build-mac
git -C "$W" add Shared/CryptoPriceWarmer.swift Features/Sync/SyncedAccountStore.swift \
  Features/Sync/SyncedAccountStore+Internals.swift App/ProfileSession+CryptoSync.swift \
  MoolahTests/Features/SyncedAccountStorePriceWarmingTests.swift
git -C "$W" commit -m "feat(sync): warm crypto prices in background after wallet apply (#1075)"
```

---

## Phase 5 — Auto-refresh

### Task 7: `AnalysisStore` gains `conversionService` + `loadAll(force:)` + `reloadForRateTick`

**Files:**
- Modify: `Features/Analysis/AnalysisStore.swift`
- Test: `MoolahTests/Features/AnalysisStoreRateTickTests.swift` (the reload-bypass + coalescing parts; the subscription itself is Task 8)

**Design.** `loadAll` keeps its `needsLoad` cache guard; add `func loadAll(force: Bool = false)` where `force == true` skips that guard. `reloadForRateTick()` calls `loadAll(force: true)` with **in-flight coalescing**: if a reload is already running, mark a pending re-run and reload exactly once more when it finishes (collapses warm-write bursts deterministically, no timers).

- [ ] **Step 1: Write the failing tests**

`MoolahTests/Features/AnalysisStoreRateTickTests.swift`:
```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — rate-tick reload")
@MainActor
struct AnalysisStoreRateTickTests {

  private func makeDefaults() throws -> UserDefaults {
    let name = "com.moolah.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("reloadForRateTick reloads even when the window is unchanged")
  func rateTickBypassesCacheGuard() async throws {
    let repository = CountingAnalysisRepository()  // counts loadAll calls; returns canned data
    let store = AnalysisStore(
      repository: repository,
      conversionService: StubConversionService(),  // observeRates: empty stream for this test
      defaults: try makeDefaults())
    await store.loadAll()                    // initial load → count 1, cache populated
    let afterInitial = repository.loadAllCount
    await store.reloadForRateTick()          // same window → would early-return without force
    #expect(repository.loadAllCount == afterInitial + 1)
  }

  @Test("a burst of rate ticks during a reload coalesces to one extra reload")
  func burstCoalesces() async throws {
    let repository = GatedCountingAnalysisRepository()  // first loadAll blocks until released
    let store = AnalysisStore(
      repository: repository, conversionService: StubConversionService(),
      defaults: try makeDefaults())
    async let first: Void = store.reloadForRateTick()
    await repository.waitUntilFetchStarted()
    // Three more ticks arrive while the first reload is in flight.
    async let t2: Void = store.reloadForRateTick()
    async let t3: Void = store.reloadForRateTick()
    async let t4: Void = store.reloadForRateTick()
    await repository.releaseAll()
    _ = await (first, t2, t3, t4)
    // 1 in-flight reload + at most 1 coalesced re-run.
    #expect(repository.loadAllCount <= 2)
    #expect(repository.loadAllCount >= 1)
  }
}
```
Add `CountingAnalysisRepository` / `GatedCountingAnalysisRepository` / `StubConversionService` to `MoolahTests/Support/` (model the gated one on `GatedAnalysisRepository`; `StubConversionService` returns an empty `observeRates()`/`observeErrors()` for now — it gains a controllable tick stream in Task 8).

- [ ] **Step 2: Run to verify failure**
Run: `just test-mac AnalysisStoreRateTickTests 2>&1 | tee .agent-tmp/t7.txt`
Expected: build failure (`conversionService:` arg / `reloadForRateTick` not found).

- [ ] **Step 3: Implement**

In `AnalysisStore.swift`:
- Add `let conversionService: any InstrumentConversionService` (non-`private`, so the Task-8 `+Observation` extension can read it — mirror `AccountStore.swift:36`).
- Add `conversionService:` to `init` (before `defaults:`), assign it.
- Add coalescing state: `private var rateTickReloadInFlight = false` and `private var rateTickReloadPending = false`.
- Refactor `loadAll()` to `loadAll(force: Bool = false)`; change the guard line `guard needsLoad else { return }` to `guard force || needsLoad else { return }`. (When `force`, also treat it as a recompute even if `hasCachedData` — the rest of the body is unchanged; the existing `growing` logic still holds because `requestedLoadMonths` equals `cachedLoadMonths` on a forced same-window reload, so it won't clear the chart.)
- Add:
```swift
  /// Force a reload in response to a price-cache rate tick (a background
  /// warm landed new crypto prices). Coalesces bursts: if a reload is
  /// already running, run exactly one more when it finishes. See #1075.
  func reloadForRateTick() async {
    if rateTickReloadInFlight {
      rateTickReloadPending = true
      return
    }
    rateTickReloadInFlight = true
    defer { rateTickReloadInFlight = false }
    repeat {
      rateTickReloadPending = false
      await loadAll(force: true)
    } while rateTickReloadPending
  }
```

- [ ] **Step 4: Run to verify pass**
Run: `just test-mac AnalysisStoreRateTickTests 2>&1 | tee .agent-tmp/t7.txt` — PASS.
Run existing `just test-mac AnalysisStore 2>&1 | tee .agent-tmp/t7b.txt` to confirm no regression (note: every `AnalysisStore(...)` construction in tests now needs the `conversionService:` arg — update those fixtures to pass `StubConversionService()`).

- [ ] **Step 5: format-check, build, commit**
```bash
W=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-1075-crypto-price-throttling
just format && just format-check && just build-mac
git -C "$W" add Features/Analysis/AnalysisStore.swift MoolahTests/Features/AnalysisStoreRateTickTests.swift \
  MoolahTests/Support/CountingAnalysisRepository.swift MoolahTests/Support/GatedCountingAnalysisRepository.swift \
  MoolahTests/Support/StubConversionService.swift MoolahTests/Features/*AnalysisStore*Tests.swift
git -C "$W" commit -m "feat(analysis): forced rate-tick reload with in-flight coalescing (#1075)"
```

---

### Task 8: `AnalysisStore+Observation` — subscribe to rate ticks

**Files:**
- Create: `Features/Analysis/AnalysisStore+Observation.swift`
- Modify: `Features/Analysis/AnalysisStore.swift` (spawn/cancel the observation task)
- Modify: `App/ProfileSession+Factories.swift:347` and `App/ProfileSession+SyncCleanup.swift` and `Features/Analysis/Views/AnalysisView.swift:264` (wiring)
- Test: extend `MoolahTests/Features/AnalysisStoreRateTickTests.swift`

- [ ] **Step 1: Write the failing test**

Give `StubConversionService` a controllable tick stream (`AsyncStream<Void>.makeStream()`), exposing `func emitRate()`. Add:
```swift
  @Test("a rate-cache tick triggers a forced reload (initial tick ignored)")
  func rateTickDrivesReload() async throws {
    let repository = CountingAnalysisRepository()
    let conversion = StubConversionService()  // emits an initial tick on subscribe
    let store = AnalysisStore(
      repository: repository, conversionService: conversion, defaults: try makeDefaults())
    await store.startObservingForTesting()   // or rely on init-spawned task + a settle hook
    await store.loadAll()
    let baseline = repository.loadAllCount
    conversion.emitRate()                     // a warm write landed
    await store.settleObservationForTesting() // await the triggered reload
    #expect(repository.loadAllCount == baseline + 1)
  }
```
Use the deterministic emission-tick pattern from `AccountStore` (`testObservationTickStream` / `MoolahTests/Support/TestableStoreObservation.swift`) so the test can await the reload rather than poll. Mirror that seam on `AnalysisStore`.

- [ ] **Step 2: Run to verify failure**
Run: `just test-mac AnalysisStoreRateTickTests 2>&1 | tee .agent-tmp/t8.txt`
Expected: build failure (observation seam absent).

- [ ] **Step 3: Implement**

`Features/Analysis/AnalysisStore+Observation.swift` (mirror `AccountStore+Observation.swift`, skipping the **initial** tick so subscription doesn't double-load on top of the view's `.task`):
```swift
import Foundation

extension AnalysisStore {
  /// Subscribe to the conversion service's rate-tick stream. The first
  /// emission is the on-subscribe tick (see `observeRates()` contract) —
  /// skip it so we don't double-load alongside the view's initial
  /// `.task { loadAll() }`. Subsequent ticks (background price warms,
  /// remote sync rate writes) force a coalesced reload. See #1075.
  func observe() async {
    let rateStream = conversionService.observeRates()
    let rateErrors = conversionService.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        var sawInitial = false
        for await _ in rateStream {
          if !sawInitial { sawInitial = true; continue }
          await self.reloadForRateTick()
        }
      }
      group.addTask { [self] in
        for await error in rateErrors { await self.surfaceObservationError(error) }
      }
    }
  }

  func surfaceObservationError(_ error: any Error) {
    // Rate-observation errors are non-fatal to the chart; log, don't blank.
    logger.error("AnalysisStore rate observation error: \(error.localizedDescription, privacy: .public)")
  }
}
```
In `AnalysisStore.swift`:
- `private var observationTask: Task<Void, Never>?`
- At the end of `init`: `observationTask = Task { await self.observe() }`
- `func stopObserving() { observationTask?.cancel() }`
- `deinit { MainActor.assumeIsolated { observationTask?.cancel() } }`
- Add the test seam(s) (`startObservingForTesting` / `settleObservationForTesting`) mirroring `AccountStore`'s `testObservationTick*` plumbing, or expose `awaitObservationTermination()`.

Wiring:
- `App/ProfileSession+Factories.swift:347` → `let analysis = AnalysisStore(repository: backend.analysis, conversionService: backend.conversionService)`
- `App/ProfileSession+SyncCleanup.swift` (`cleanupSync`) → add `analysisStore?.stopObserving()` next to the other stores' `stopObserving()` calls (grep that file for `stopObserving` and follow the pattern; thread the `analysis` store reference if not already retained).
- `Features/Analysis/Views/AnalysisView.swift:264` (`#Preview`) → `AnalysisStore(repository: backend.analysis, conversionService: backend.conversionService)`.

- [ ] **Step 4: Run to verify pass**
Run: `just test-mac AnalysisStoreRateTickTests 2>&1 | tee .agent-tmp/t8.txt` — PASS.

- [ ] **Step 5: format-check, build, commit**
```bash
W=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-1075-crypto-price-throttling
just format && just format-check && just build-mac
git -C "$W" add Features/Analysis/AnalysisStore.swift Features/Analysis/AnalysisStore+Observation.swift \
  App/ProfileSession+Factories.swift App/ProfileSession+SyncCleanup.swift \
  Features/Analysis/Views/AnalysisView.swift MoolahTests/Features/AnalysisStoreRateTickTests.swift \
  MoolahTests/Support/StubConversionService.swift
git -C "$W" commit -m "feat(analysis): auto-refresh dashboard on price-cache rate ticks (#1075)"
```

---

## Phase 6 — UX indicator

### Task 9: "Updating prices" indicator in `AnalysisView`

**Files:**
- Modify: `Features/Analysis/Views/AnalysisView.swift` (toolbar)

The view already holds `@Environment(ProfileSession.self) private var session`; read `session.cryptoSyncStore?.priceWarmingInProgress`.

- [ ] **Step 1: Add the indicator** — insert a `ToolbarItem` in the existing `.toolbar { … }` block (before the Filters item):
```swift
      if session.cryptoSyncStore?.priceWarmingInProgress == true {
        ToolbarItem(placement: .automatic) {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Updating prices").font(.caption).foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Updating prices")
        }
      }
```
(Mirrors the established `ProgressView().controlSize(.small)` + explicit `.accessibilityLabel` idiom from `SyncedAccountHeaderView.swift`.)

- [ ] **Step 2: Verify it builds**
Run: `just build-mac 2>&1 | tee .agent-tmp/t9.txt` — no warnings/errors (warnings are errors here).

- [ ] **Step 3: Visually verify** via `#Preview` / `mcp__xcode__RenderPreview` per the `reviewing-ui-with-preview` skill — set a preview where `priceWarmingInProgress == true` and confirm the indicator renders unobtrusively, then run `@ui-review` on the change.

- [ ] **Step 4: format-check, build, commit**
```bash
W=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-1075-crypto-price-throttling
just format && just format-check && just build-mac
git -C "$W" add Features/Analysis/Views/AnalysisView.swift
git -C "$W" commit -m "feat(analysis): subtle 'Updating prices' indicator while warming (#1075)"
```

---

## Phase 7 — Integration, reviews, PR

### Task 10: Full verification + review agents + PR

- [ ] **Step 1: Full format-check + build**
```bash
just format && just format-check && just build-mac
```
Expected: clean (no SwiftLint violations, no warnings).

- [ ] **Step 2: Full test suite (mac)**
```bash
mkdir -p .agent-tmp
just test-mac 2>&1 | tee .agent-tmp/full-mac.txt
grep -i 'failed\|error:' .agent-tmp/full-mac.txt || echo "no failures"
```
Expected: 0 failures. Investigate any `AnalysisStore(...)` / `SyncedAccountStore(...)` construction sites in tests that now need the new args.

- [ ] **Step 3: iOS build** (the app targets iOS 26+ too)
```bash
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
```

- [ ] **Step 4: Review agents** (apply ALL findings — Critical/Important/Minor — per project policy):
  - `@code-review` (naming, thin-view, optional discipline, `TODO(#N)` format)
  - `@concurrency-review` (the new `actor CryptoPriceWarmer`, the `@MainActor` `SyncedAccountStore` task handle, `AnalysisStore` observation task + `deinit` `MainActor.assumeIsolated`, `Sendable` of `PriceWarming` / closures)
  - `@instrument-conversion-review` (degradation still honours Rule 11; `warmRange` conversion-date correctness)
  - `@datetime-review` (`holdingRanges` / `warmRange` day math — `cappedToYesterday`, ISO `[.withFullDate]`, UTC vs local boundaries)
  - `@ui-review` (Task 9 indicator)
  - `@database-code-review` (the `persistDelta` path is reused, but confirm no new unsafe SQL)

- [ ] **Step 5: Push branch + open PR**
```bash
W=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-1075-crypto-price-throttling
git -C "$W" push origin worktree-fix-1075-crypto-price-throttling:fix-1075-crypto-price-throttling
gh pr create --repo moolah-rocks/moolah-native \
  --title "Throttle-resilient crypto prices for the Analysis dashboard" \
  --body "$(cat <<'BODY'
Fixes #1075.

The Analysis dashboard blanked with `Binance network error: cooldown(...)` whenever a crypto-denominated income/expense leg needed a price during a provider cooldown. Root cause: the expense/income aggregations rethrew the first conversion error (unlike daily-balances/forecast, which scope per-day).

This PR:
- **Graceful degradation** — expense/income aggregations skip *transient* price failures per-row (new `ConversionFailureClassifier`) and render the rest; structural failures keep the loud rethrow.
- **Throttle-aware warmer** — a new `CryptoPriceWarmer` actor, kicked off after each wallet-sync apply pass, fills missing historical prices token-by-token over each token's holding period, sleeping out `RateLimitGateError.cooldown` deadlines surfaced by the new `CryptoPriceService.warmRange`.
- **Auto-refresh** — `AnalysisStore` now subscribes to `conversionService.observeRates()` and force-reloads (coalesced) as warm writes land.
- **UX** — a subtle "Updating prices" indicator while warming runs.

Design: `plans/2026-06-08-crypto-price-throttling-resilience-design.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

- [ ] **Step 6: Land via merge queue** per the `landing-prs` skill once CI is green.

---

## Self-Review (run before executing)

**Spec coverage:** ✅ Degradation (Tasks 1–3) ↔ spec §1; warmer + cooldown handling (Tasks 4–5) ↔ §2; trigger (Task 6) ↔ §3; auto-refresh (Tasks 7–8) ↔ §4; indicator (Task 9) ↔ §5; tests interleaved per task ↔ §6. Non-goals respected (no stock/FX warming, no per-token UI detail).

**Type consistency:** `WarmOutcome { .filled / .cooledDown(until:) / .unavailable }` used identically across Tasks 4–5. `CryptoPriceWarmer.warm(transactions:accountIds:)` signature matches the `PriceWarming` protocol and the Task-6 spy. `reloadForRateTick()` / `loadAll(force:)` consistent across Tasks 7–8. `priceWarmingInProgress` defined in Task 6, read in Task 9.

**Known soft spots the executor must verify against live code (not placeholders — verification steps):**
- Task 2/3: confirm `ThrowingCountingConversionService.convertResult` surfaces `.failure` (extend if it only routes `convert`).
- Task 4: confirm `FixedCryptoPriceClient` has `failureError:`/`syncProvider:` labels and `CountingCryptoPriceClient` has `init(wrapping:)`; confirm the service's ISO day formatter helper names.
- Task 5: confirm/relocate `ToggleableCryptoPriceClient` with `setShouldFail(_:error:)`/`setPrices(_:)`.
- Task 6: grep the existing `SyncedAccountStore(` test fixture and extend it with the defaulted `priceWarmer:` arg; confirm `cleanupSync` calls `cancelTimer()` (teardown path for the warm task).
- Task 7/8: every existing `AnalysisStore(...)` construction (prod + tests + preview) must add `conversionService:`.
