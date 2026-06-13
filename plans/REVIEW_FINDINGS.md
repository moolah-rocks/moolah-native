# Reviewer findings applied to the plan (#1101)

Three reviewer agents (instrument-conversion-review, concurrency-review, code-review) reviewed
`plans/2026-06-13-cross-chain-asset-aggregation-plan.md`. Consensus findings, all applied to the revised plan:

## Critical / Important (applied)

1. **Architectural seam (concurrency + code-review, Critical).** `BackendProvider` does not expose the
   instrument registry; `InvestmentStore`/`MultiInstrumentPositionsSplitModifier` have no registry handle.
   Features cannot import `Backends/`. → New **Task 9**: add `instrumentRegistry: (any InstrumentRegistryRepository)?`
   to `BackendProvider` (default-nil extension; `CloudKitBackend` returns its existing `instrumentRegistry`).
   Inject into `InvestmentStore.init`; the modifier reads it via `@Environment(BackendProvider.self)`.

2. **`reduce` seed type mismatch (code-review, Important).** Non-optional seed with a closure returning
   `InstrumentAmount?` will not compile. → Rewrote `merge` to use an explicit `hostCurrency` seed and a
   `for`-loop with `break` for nil-propagation.

3. **`hostInstrument` guessing → explicit `hostCurrency` (instrument-conversion + code-review, Important).**
   The fallback seeded `.zero` in a per-chain crypto instrument (latent `InstrumentAmount` trap). → `fold`
   now takes `hostCurrency: Instrument` threaded from `PositionsViewInput.hostCurrency`; `hostInstrument` deleted.

4. **Dead `chainIds` var (instrument-conversion, Important — build break under warnings-as-errors).** → Now
   used to derive `chainId`: `chainIds.count == 1 ? chainIds.first : nil`.

5. **`try?` swallows registry errors (all three, Critical/Important).** → Logged `do/catch` with
   `CancellationError` re-throw in the store; `do/catch` + cancel-guard in the modifier.

6. **Missing cancellation guard after new await (concurrency, Important).** → Added `Task.isCancelled`
   handling on the registry fetch path.

7. **DRY: duplicated `quantityFormatted`/`quantityCaption` + `Instrument.fiat(code:)` reconstruction
   (code-review, Important).** → Extracted `QuantityFormatting` shared utility; `AssetHolding` carries
   `currencyCode: String?`; both `ValuedPosition` and `AssetHolding` delegate. No throw-away `Instrument`.

8. **`PositionSelection.init(holding:)` matches memberwise init (code-review, Important).** → Replaced with
   `AssetHolding.positionSelection` computed property; `PositionSelection` stays a plain data carrier.

9. **`chartSnapshot()` has THREE `selectedInstrument` sites (code-review, Important).** → Plan now enumerates
   all three (title, baseline, baselineName).

10. **Cost-basis-vs-value semantics undertested (instrument-conversion, Important).** Decision: `costBasis`
    is independent of `value` — a row may have a known cost basis while `value` is unavailable (mirrors
    per-row `ValuedPosition`). → Added explicit test.

11. **`series(forInstrumentIds:)` different-length-series coverage (code-review, Important).** → Added test
    where one contributor has more dates than the other (asserts intersection).

12. **`PositionRow` accessibility for multi-chain (code-review, Important).** → `accessibilityLabel` says
    "across N chains".

## Minor (applied)
- `assetKeys(from:)` uses `reduce(into:)` (SwiftLint `reduce_into`).
- `// MARK: - Sortable accessors` moved onto the extension, not inside the struct body.
- Split `fallsBackToCryptocompareThenBinance` into two `@Test`s.
- Renamed `mergesEthAcrossChainsWithIssueNumbers` → `mergesEthAcrossChains`.
- Comment in `merge` noting the same-`decimals` (same-unit) assumption for the quantity sum.

## Withdrawn by reviewer
- instrument-conversion Finding 5 (series intersection anchor-on-first) — confirmed correct; no change.

This file is a working note; delete before opening the PR.
