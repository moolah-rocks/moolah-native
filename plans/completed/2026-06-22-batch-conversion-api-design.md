# Batch Currency-Conversion API — Design

**Status:** Design / approved-pending-review
**Issue:** follow-on to #1163 (Analysis slow first open); supersedes the pre-warm band-aid (#1165)
**Date:** 2026-06-22

## Problem

`FullConversionService` is an `actor`. Every `convertResult(amount, to:, on:)` is one
actor hop (plus a task suspension), even on a memo cache hit. History-processing code
converts per row / per day / per instrument in **serial `await` loops**, so a single
Analysis load issues thousands of hops (measured ~25,000 on a populated profile; the
documented #868 burst was ~1,400 in one second). The cost is structural — the per-call
memo (#868) and the concurrent pre-warm (#1165) reduce *recomputation* and overlap the
*network*, but neither removes the serial hops.

A survey found ~14 call sites with this shape. The heavy hitters all process history:

| Site | Loops over | ~conversions/call | Today |
|---|---|---|---|
| `PositionBook.dailyBalance` (daily-balance walk) | day × account/earmark × instrument | 100s–1000s | serial |
| `GRDBAnalysisRepository+IncomeAndExpense` | row × 4 columns | ≤4000 | serial |
| `…+ExpenseBreakdown`, `…+CategoryBalances` | (day,category,instrument) row | ≤1000 | serial |
| `…+DailyBalancesInvestmentValues` / `…+TradesMode` | per-day account×instrument | 10s–100s | serial |
| `…+DailyBalancesForecast.preConvertForecastInstances` | instance × leg | ≤500 | **already concurrent** (TaskGroup) |
| `AccountBalanceCalculator` | account × position, then account | 10s–100s | serial |
| `EarmarkStore+Conversion`, `InvestmentStore+Positions`, `PositionsValuator` | per position | 10s–100s | serial |
| `Domain/Models/TransactionPage.prefetchRates` | unique instrument | 10s | **already concurrent** (TaskGroup) |
| `InsightInputBuilder.scheduledBills` | scheduled txn | 10s–100s | serial |

## Goal

Add one batch primitive that collapses N serial conversion hops into a single `await`,
and adopt it across these call sites. Conversion **results must be unchanged**; only the
call pattern changes.

## A. The API

```swift
// Domain/Services/InstrumentConversionService.swift
struct BatchConversionRequest: Sendable {
  let amount: InstrumentAmount
  let target: Instrument
  let date: Date
}

enum BatchConversionOutcome: Sendable {
  case value(InstrumentAmount)
  case knownZero(target: Instrument)   // mirrors ConversionResult.knownZero
  case failure(any Error)              // per-element — preserves Rule 11 scoping
}

protocol InstrumentConversionService: Sendable {
  // …existing convert / convertAmount / convertResult / invalidateCache /
  //   observeRates / observeErrors…
  func convertResultBatch(_ requests: [BatchConversionRequest]) async throws
    -> [BatchConversionOutcome]
}
```

**Converted amounts, not factors.** Every surveyed call site has a concrete
`(amount, target, date)` and wants a converted amount; none needs a reusable rate. A
factor-map would only save constructing request structs + cheap synchronous multiplies
(the memo already dedups the *rate* computation), while forcing 14 call sites to
re-implement the multiply / `knownZero` / sign rules. So: one API, amounts. Add a factor
API later only if a real caller needs it (YAGNI).

**Per-element outcome, not throw-on-first.** Each request gets its own outcome so callers
keep their per-row / per-day degradation. Only **cancellation** propagates as a thrown
`CancellationError` (cancellation is task-wide, not per-element) — matching the existing
daily-balance and aggregation contracts.

### Default implementation (protocol extension)

Loops `convertResult`, folding each into `.value` / `.knownZero` / `.failure`, but
rethrows `CancellationError` and checks `Task.isCancelled` between elements. Every
conformer inherits this — the single test double uses it, and it is the safety net for
any conformer that does not override.

### `FullConversionService` override (the win)

1. Reduce requests to the set of distinct `(fromId, toId, utc-day)` keys (the existing
   `RateCacheKey`).
2. Resolve those keys: memo hits synchronously; misses concurrently via a bounded
   (≤16 in-flight) throwing task group, populating the memo. Each key resolves to a
   factor, `.knownZero`, or a captured error.
3. Map every request synchronously to its `BatchConversionOutcome` by applying the
   resolved key (same-instrument fast path skips the lookup).

From the caller's view this is a single `await` for the whole batch, with the network
fetches for distinct misses overlapped internally.

## B. Daily-balance walk migration (marquee, PR-A)

Reshape the assembly (`GRDBAnalysisRepository+DailyBalances` + `PositionBook`) into three
phases:

1. **Accumulate (sync).** Walk days applying deltas to the `PositionBook` as today, but
   instead of `await dailyBalance`, emit a flat request list: for each day, each bucket
   (bank / investments / earmark), each `(instrument, cumulative-qty)`, a
   `BatchConversionRequest` tagged with `(dayKey, bucket, ownerId)`.
2. **Convert (one `await`).** A single `convertResultBatch(...)`.
3. **Assemble (sync).** Group outcomes by day; sum per bucket applying the per-earmark
   `max(_, 0)` clamp; build each `DailyBalance`. A day with any `.failure` outcome is
   dropped and logged once (Rule 11). The investment-value and trades-mode folds adopt
   the same shape.

This **deletes the pre-warm** (`+DailyBalancesPrewarm.swift`) and the serial awaits.
`PositionBook.dailyBalance(async)` is replaced by a synchronous summation over resolved
amounts (exact factoring decided in the plan). Existing daily-balance / multi-currency /
investment-value / Rule 11 contract tests are the regression net — results stay identical.

## C. Single test double (PR-B, done first)

Replace all 9 doubles (`StubConversionService`, `FixedConversionService`,
`DateBasedFixedConversionService`, `DateFailingConversionService`,
`FailingConversionService`, `ThrowingConversionService`, `CountingConversionService`,
`ThrowingCountingConversionService`, `RecordingConversionService`) with one configurable
`FakeConversionService`:

- **Behaviour:** a per-call outcome closure `(InstrumentAmount, Instrument, Date) ->
  Result<ConversionResult, Error>` (default: pass-through 1:1). Convenience factories
  cover the common cases — `.passthrough`, `.fixedRates([...])`, `.dateRates([...])`,
  `.failing(onDates:)`, `.throwing`.
- **Recording:** records every call (count + args) so the assertions that
  `Counting`/`ThrowingCounting`/`Recording` make today still work, including
  `invalidateCache` invocations.
- **Rate streams:** controllable `observeRates` / `observeErrors` emission (`emitRate()`,
  `emitError(_:)`).
- Implements `convertResultBatch` (recording the batch) rather than only inheriting the
  default, so batch-era contract tests can assert on it.

Sequenced **first**, as a pure test refactor: introduce `FakeConversionService`, migrate
every test off the 9 doubles, delete them. No production change.

## D. Rollout

1. **#1165** lands (interim pre-warm — removed in PR-A).
2. **PR-B (first):** 9 → 1 `FakeConversionService`. Pure test refactor.
3. **PR-A:** batch API (types + protocol + default impl) + `FullConversionService`
   override + batch unit tests + daily-balance walk migration + delete the pre-warm.
4. **PR-C…N (incremental, one site per PR, highest-volume first):** income/expense →
   expense breakdown → category balances → investment-value / trades-mode folds →
   `AccountBalanceCalculator` → earmark / investment / positions totals → insights
   scheduled bills. Replace the hand-rolled task-groups in `preConvertForecastInstances`
   and `TransactionPage.prefetchRates` with the batch call.

## Error handling

- **Per-element conversion failure** → `.failure(error)` in the result array; callers
  apply their existing Rule 11 handling (log + drop the row/day, continue).
- **Cancellation** → `convertResultBatch` throws `CancellationError`; callers propagate
  (the daily-balance walk already rethrows it). The bounded internal task group cancels
  remaining work on the first cancellation.
- **`knownZero`** (`.unpriced` / `.spam` / before-first-trade, #790) → `.knownZero`,
  contributing zero, never a failure.

## Testing

- `convertResultBatch` unit tests on `FullConversionService`: order preservation,
  distinct-key dedup (one underlying resolution per `(from,to,day)`), per-element
  `.value` / `.knownZero` / `.failure`, cancellation propagation, bounded concurrency.
- Default-impl tests via `FakeConversionService` (loop fold + cancellation rethrow).
- Daily-balance migration: the existing contract suites
  (`GRDBDailyBalancesAssembleTests`, `AnalysisDailyBalancesTests`,
  `GRDBDailyBalancesConversionTests`, multi-currency, investment-value, Rule 11) must
  pass unchanged — they are the proof results did not move.
- Each migration PR: run the **full** suite locally (the assemble contract tests live in
  adjacently-named files and a subset run misses them).

## Non-goals

- No factor/rate-map API (YAGNI; revisit only if a real caller needs raw factors).
- No change to conversion *results*, rounding, sign convention, or conversion-date rules.
- No "render partial then fill" UX (conflicts with the "mark unavailable, never partial"
  rule); out of scope here.
