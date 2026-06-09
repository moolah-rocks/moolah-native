# Throttle-resilient crypto prices for the Analysis dashboard

**Issue:** [#1075 — Binance throttling not handled automatically](https://github.com/moolah-rocks/moolah-native/issues/1075)
**Date:** 2026-06-08
**Status:** Approved design — ready for implementation plan

## Problem

After the production account was converted to crypto-wallet accounts, the
Analysis dashboard consistently fails to load with a full-screen error such as:

```
Binance network error: cooldown(until: 2026-06-07 17:51:05 +0000)
```

Two things are wrong:

1. **A transient price-fetch failure blanks the entire dashboard.** The
   expense-breakdown and income/expense aggregations *rethrow* the first
   conversion error, so a single throttled Binance request kills the whole
   `loadAll`.
2. **Nothing warms historical crypto prices.** Prices are fetched on demand the
   first time a view needs them. The first Analysis load of a freshly-imported
   multi-year, multi-token wallet fires a burst of provider requests
   (`CoinGecko → CryptoCompare → Binance`, all free-tier rate-limited), trips
   the shared per-host rate-limit gate (cooldown up to 10 minutes), and the
   cooldown cannot be waited out inside a synchronous dashboard load.

The desired behaviour (from the issue): throttling is handled automatically so
**prices simply take longer to arrive rather than causing a complete failure.**

## Root cause

`GRDBAnalysisRepository.loadAll` runs three aggregations in parallel. They have
two different error contracts when a per-row currency conversion fails:

| Aggregation | On a conversion failure | Site |
|---|---|---|
| Daily balances (`walkDays`, `applyInvestmentValues`, trades-mode fold) | Per-day Rule 11 scoping — drops just that day, renders the rest | `+DailyBalances*.swift` |
| Forecast (`generateForecast`) | Per-day Rule 11 scoping (a comment notes this was added to stop "a full-screen WalletSyncError") | `+DailyBalancesForecast.swift:71-90` |
| **Expense breakdown** (`assembleExpenseBreakdown`) | **Rethrows the first error** → fails the whole `loadAll` | `+ExpenseBreakdown.swift:178` |
| **Income/expense** (`assembleIncomeAndExpense`) | **Rethrows the first error** → fails the whole `loadAll` | `+IncomeAndExpense.swift:181` |

When Binance is in cooldown and a **crypto-denominated expense or income leg**
needs a price, `FullConversionService.convertResult → cryptoUsdPrice →
CryptoPriceService.fetchAndExtendCache` throws
`WalletSyncError(provider: .binance, kind: .network(cooldown))`, and the
expense/income assembler rethrows it.

The rethrow was a reasonable "loud signal that the bucket is incomplete" when
conversions were fiat-only (`ExchangeRateService` swallows FX fetch errors). It
became a liability once crypto wallets put a throttle-prone provider on the
per-row conversion path.

### Confirmed wiring facts

- `CryptoPriceService.persistDelta` already calls
  `database.notifyRateCacheChange(.cryptoPrice)` — every price write produces a
  `FullConversionService.observeRates()` tick. Auto-refresh needs no new plumbing
  on the write side.
- `AccountStore` / `EarmarkStore` / `InvestmentStore` already subscribe to
  `conversionService.observeRates()` and recompute on each tick — a proven
  pattern to copy. `AnalysisStore` currently holds only `repository` and does
  **not** subscribe.
- `CryptoPriceService.fetchRange(...)` exists but is **never called**; there is
  no historical price warming anywhere.
- The wallet sequential apply pass completes at
  `SyncedAccountStore+Internals.swift:214` (`walletApplyEngine.apply(...)`
  returns) — the natural trigger point for warming.
- `AnalysisStore` is constructed at `ProfileSession+Factories.swift:347` and
  `AnalysisView.swift:264`.

## Goals

1. The Analysis dashboard always loads; a throttled provider degrades the data,
   never the screen.
2. Missing historical crypto prices are fetched in the background, automatically
   handling throttling/backoff, and the dashboard updates as they arrive.
3. The user gets a subtle, honest signal that prices are still filling in.

## Non-goals

- Reducing on-demand fetch volume beyond what warming already achieves.
- Per-token warming detail in the UI.
- Warming non-crypto instruments (stocks / FX).

## Design

### 1. Graceful degradation (the unblock)

Classify conversion errors:

- **Transient price-availability failure** — `WalletSyncError` with a
  `.network` kind, `RateLimitGateError.cooldown`, `URLError`,
  `CryptoPriceError.noPriceAvailable`.
- **Structural failure** — `ConversionError.unsupportedConversion`, a genuinely
  unmapped non-crypto instrument, etc.

Add a small shared helper `ConversionFailure.isTransient(_:)` (one definition,
reused by both aggregations). In `assembleExpenseBreakdown` and
`assembleIncomeAndExpense`:

- **Transient** → log + skip *that one `(day, instrument)` row's contribution*
  and continue. The bucket still renders, slightly understated, and self-heals
  on auto-refresh once prices arrive. This is the **per-row** (not whole-bucket)
  scoping decision — the most surgical choice and consistent with the per-day
  Rule 11 precedent.
- **Structural** → preserve today's behaviour: record `firstConversionError`
  and rethrow after the walk (the bucket-incomplete loud signal stays for real
  problems).

`CancellationError` continues to rethrow immediately as it does today.

This change alone closes the user-visible bug. Everything below makes the
skipped numbers fill in.

### 2. Throttle-aware background warmer

New `CryptoPriceWarmer` actor in `Shared/`.

**Input:** the synced wallet's `[(CryptoRegistration, holdingRange)]`, where
`holdingRange` is `earliest-transaction-date ... today` per token.

**Per token, serially** (serial processing keeps the request burst small and
lets the shared gate pace everyone), it calls a new
`CryptoPriceService.warmRange(instrument:mapping:in:) async -> WarmOutcome`:

```
enum WarmOutcome {
  case filled                       // gap fetched & persisted
  case cooledDown(until: Date)      // soonest provider cooldown deadline
  case unavailable                  // all providers permanently lack the token
}
```

`warmRange` reuses the existing "only fetch the uncovered extension" logic so
re-warming an already-cached range is cheap and idempotent. Crucially it
surfaces the `RateLimitGateError.cooldown` **deadline** instead of wrapping it
into a `WalletSyncError` string the way `fetchRange` does today.

The warmer's loop:

- `.filled` → move to the next token.
- `.cooledDown(until:)` → sleep until `until` (+ small jitter) via a cancellable
  sleep, then retry the *same* token. Bounded by a per-token cap (max cooldown
  cycles / max wall-clock) so a permanently-429ing host cannot loop forever.
- `.unavailable` → log, leave the gap, move to the next token.

This is the "automatically handle throttling and backoff so prices simply take
longer to arrive" behaviour. The warmer is a **cancellable tracked `Task`**
(torn down on profile teardown / account removal), with `Task.checkCancellation()`
across its cancellable sleeps. The injected clock (`CryptoPriceService` and
`RateLimitGate` already take a `now` closure) keeps it deterministically
testable.

### 3. Trigger

After the sequential apply pass returns at `SyncedAccountStore+Internals.swift:214`,
enumerate the just-synced crypto accounts' tokens and holding ranges and kick
off the warmer as a tracked background task, alongside the existing per-account
sync bookkeeping. Re-syncs re-invoke it; idempotent `warmRange` makes repeat
runs cheap.

### 4. Auto-refresh

Give `AnalysisStore` the `conversionService` (currently it holds only
`repository`) and subscribe to `observeRates()` exactly as
`AccountStore+Observation.swift` does. On a tick it calls a new
`reloadForRateTick()` that:

- **bypasses the `needsLoad` cache guard** in `loadAll` (a rate tick must force a
  recompute even though the window did not change), and
- is **debounced / coalesced** (~500 ms) so a burst of warm writes triggers one
  reload rather than dozens (each reload is a full SQL aggregation + conversion
  pass).

Construction sites (`ProfileSession+Factories.swift:347`, `AnalysisView.swift:264`)
gain the conversion-service argument.

### 5. UX — subtle "Updating prices" indicator

Expose a `priceWarmingInProgress` flag off the warmer and reflect it onto
`SyncedAccountStore` (which already drives sync-progress UI). `AnalysisView`
reads it via the session and shows an unobtrusive header badge / spinner while
warming runs; it clears when the warmer drains. Honest signal that the data is
still filling in, without blocking the chart.

## Testing (TDD — write tests first)

- **Degradation** (`MoolahTests`, contract/store level, `TestBackend`):
  - A crypto-denominated *expense* leg + a crypto *income* leg with a stub price
    client that throws cooldown → `loadAll` returns (does **not** throw); the
    failing rows are omitted, sibling rows render.
  - A *structural* conversion error still rethrows (loud signal preserved).
- **Warmer** (injected clock):
  - Client returns `cooledDown(until:)` then success → cache fills after the
    cooldown deadline; `warmRange` reports `.filled`.
  - Permanently-failing client → warmer hits its per-token cap, reports
    `.unavailable`, leaves the gap, never throws.
  - Cancellation mid-cooldown stops promptly.
  - Already-cached range → `warmRange` is a no-op (idempotence).
- **Auto-refresh** (`AnalysisStore` tests):
  - A rate tick drives a reload that bypasses the `needsLoad` cache guard.
  - A burst of ticks coalesces to a single reload.

## Risks & mitigations

- **Understated buckets look like a bug.** Mitigated by the "Updating prices"
  indicator and the fact that auto-refresh corrects them within seconds of a
  warm write.
- **Reload storms from warm writes.** Mitigated by debouncing rate-tick reloads.
- **Warmer never terminates against a permanently-throttled host.** Mitigated by
  the per-token cooldown-cycle / wall-clock cap → `.unavailable`.
- **Shared gate contention** between warming and on-demand fetches is benign:
  both fail-fast on the same gate, and on-demand fetches become cache hits once
  warming fills the range.

## Rollout

Single feature branch / PR. `Fixes #1075` in the PR body.
