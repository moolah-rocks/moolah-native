# Crypto account chart — progressive render + batched conversions

**Date:** 2026-07-04
**Status:** Approved (design)
**Area:** `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`, `Shared/PositionsHistoryBuilder.swift`, `Shared/MultiInstrumentPositionsAssembler.swift`, `Shared/Views/Positions/`

## Problem

Opening a crypto account's detail screen (the chart + positions surface above the
transaction list) takes ~16 s on the dev Test Profile's `Crypto - Ethereum
(ajsutton.eth)` account. The equivalent shares surface is near-instant.

### Root cause (confirmed by live profiling)

Two independent failings compound:

1. **The whole surface blocks on the historical chart.**
   `MultiInstrumentPositionsSplitModifier.valuatePositions()` computes the positions
   rows first (fast — batched, current-date prices via `PositionsValuator`), but does
   not assign `positionsInput` until *after* `buildHistoryInput` finishes the slow
   historical series. So the positions table is invisible until the chart is done.

2. **The historical chart converts one (instrument, day) at a time, sequentially.**
   `PositionsHistoryBuilder.emitDailyPoints` calls
   `conversionService.convert(_:from:to:on:)` once per held instrument per day as
   sequential `await`s. For a 3-month default range across ~10 historically-held
   tokens (HEX, ETH, UNI, WETH, USDC, DAI…) that is ~900 serial actor-hops, and each
   cold day drives the rate-limited multi-provider crypto price fetch. Measured:
   79 HEX + 69 ETH + others, ~100–200 ms each.

Shares avoid this because a domestic-currency stock position needs **no** per-day
conversion (listing currency == host → early return), and foreign stocks resolve from
a single reliable provider. Warm re-entry of the crypto account is instant (the series
is memoized), confirming this is a one-time cold cost, not persistent compute.

### Explicitly out of scope

- Pre-warming price caches (considered and rejected — treats the symptom, not the
  sequential/blocking cause).
- The app-launch keychain / CryptoCompare-401 / Analysis-aggregation activity seen in
  profiling — that is startup background work, not on the account-navigation path.

## Design

Two independent changes.

### Part 1 — Progressive render (perceived speed)

Assign `positionsInput` in two stages inside the modifier:

1. As soon as `valuator.valuate` returns, set `positionsInput` with the valued rows and
   `historicalValue: nil`. The positions table renders immediately.
2. Then run cost-basis + history assembly and update `positionsInput` with the series
   (and the cost-basis overlay on the rows).

**Chart loading state.** While the series is still building, the chart region must show
a *loading* indicator distinct from the "no historical activity" empty state. Thread an
explicit loading signal through `PositionsViewInput` (e.g. an `isHistoryLoading` flag or
a `historyState` enum: `.loading` / `.loaded(series)` / `.unavailable`) so `PositionsView`
renders a progress indicator in the chart area only, with the table below fully live.
The existing `historicalValue: HistoricalValueSeries?` + `hasAnyHistoricalActivity` pair
does not distinguish "still loading" from "genuinely none", so a dedicated signal is
required.

Cancellation: the two-stage assignment lives in the same `.task(id:)`; a superseding
task (positions/range/registry change) must not let a stale first-stage assignment
overwrite a fresher one. Re-check `Task.isCancelled` before each assignment, as the
existing code already does before the final assignment.

### Part 2 — Batch the historical value conversions (actual speed)

Restructure `PositionsHistoryBuilder.build` into record-then-batch:

1. **Fold pass (unchanged structure).** Walk day-by-day, folding transactions into the
   running quantity/cost-basis state exactly as today. `emitDailyPoints` no longer
   converts — it **records** each held `(instrument, quantity, cost, day, pointDate)`
   into a pending list, and records which pending entries belong to the same day so the
   aggregate can be assembled later.
2. **Batch pass.** After the loop, build `[BatchConversionRequest]` from the pending
   entries and issue **one** `conversionService.convertResultBatch(_:)` call. This
   resolves distinct `(fromId, toId, utc-day)` cache-miss keys concurrently (≤16 in
   flight) — the same proven path `PositionsValuator` uses.
3. **Assemble pass.** Map outcomes back to `HistoricalValueSeries.Point`s:
   - `.value(amount)` → per-instrument point with that value.
   - `.knownZero` → treat as the existing code treats a zero/known-zero conversion
     (a value of 0 contributes to the day; matches current `convert` semantics for
     `beforeFirstTrade`/known-zero — verify against current behaviour and preserve it).
   - `.failure` → omit that instrument's point for that day (current behaviour: the
     per-instrument series simply skips the day).
   - **Rule 11 preserved:** the aggregate/total point for a day is emitted only if
     *every* contributing instrument's conversion for that day succeeded; any failure
     drops the total point for that day while sibling instruments still chart.

The fold-pass conversions (cost-basis via `TradeEventClassifier` in `apply`, and
contributions in `foldContributions`) stay inline in this first cut — they are
O(transactions), not O(days × tokens). Re-profile after batching; only batch them in a
follow-up if they still dominate.

`convertResultBatch` is a member of the `InstrumentConversionService` existential
(`FullConversionService+Batch.swift`, with a protocol requirement). Confirm the protocol
declares it (so the builder can call it through the existential); if only the concrete
type has it, add the requirement plus a default that loops `convert` for other
conformers (fiat-only test doubles).

### Interaction between Part 1 and Part 2

They are independent and additive. Part 1 makes the table appear immediately regardless
of chart speed; Part 2 makes the chart itself fast. Shipping order is flexible, but both
are needed to fully fix the report: Part 1 alone leaves a slow-but-non-blocking chart;
Part 2 alone still blocks the table on the (now faster) chart.

## Components & boundaries

- **`MultiInstrumentPositionsSplitModifier`** (Part 1): owns the two-stage
  `positionsInput` assignment and the loading signal. No business logic beyond
  sequencing.
- **`PositionsViewInput` / `PositionsView` / `PositionsChart`** (Part 1): carry and
  render the loading state. Pure view/data plumbing.
- **`PositionsHistoryBuilder`** (Part 2): record-then-batch internals. Public `build`
  signature and returned `HistoricalValueSeries` are unchanged — callers and the
  assembler are unaffected.
- **`MultiInstrumentPositionsAssembler.assemble`** (Part 1 seam): today it returns one
  fully-assembled input; the modifier already calls the valuator separately, so the
  first-stage (table-only) input is built in the modifier from the valued rows without
  changing the assembler's contract. Confirm during planning whether the first-stage
  input needs anything the assembler currently adds (e.g. `assetKeys`,
  `hasAnyHistoricalActivity`) and thread those through.

## Testing

- **`PositionsHistoryBuilder` (Part 2):** existing suites assert Rule 11 aggregation,
  per-instrument omission on failure, and cancellation. The batch refactor must produce
  byte-identical `HistoricalValueSeries` output for the same inputs — run the existing
  suite unchanged as the primary guard, and add a case asserting a mixed
  success/failure day drops only the total (not siblings). A fiat-only conversion double
  exercises the non-crypto batch path.
- **Progressive render (Part 1):** a store/view-model-level test that the modifier
  assigns a table-only `positionsInput` (rows present, history loading) before the
  history-bearing one. Assert the loading signal transitions `.loading → .loaded`.
- **Benchmark (optional, recommended):** a `MoolahBenchmarks` case over a synthetic
  many-token multi-year holding, asserting the batched build is materially faster than
  the per-day baseline (guards against regressing to serial awaits).
- **UI verification:** re-run the live repro (dev Test Profile → `Crypto - Ethereum
  (ajsutton.eth)`), confirm the table paints immediately and the chart fills in quickly.

## Review gates (per project workflow)

Route through the AI review gate: `concurrency-review` (builder is `@concurrent`,
task-group batch, two-stage `@MainActor` assignment), `instrument-conversion-review`
(batch outcomes, Rule 11, known-zero/failure mapping), `ui-review` (chart loading
state), and `code-review`. Fix all findings before merge.
