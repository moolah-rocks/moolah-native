# Contiguous price-cache extension (crypto / stock / FX)

> Design spec. Fixes a data-correctness bug: the historic price/rate caches
> can contain interior date gaps that were **never fetched**, which the
> read path then papers over with a stale prior-day value — silently wrong
> net-worth and income/expense figures.

## Background

Three services cache historic prices/rates, each in its own table pair in
the shared profile-index database (`ProfileIndexSchema+SharedInstrumentRegistry`):

| Service | Price table | Meta table |
|---|---|---|
| `CryptoPriceService` | `crypto_price` | `crypto_token_meta` |
| `StockPriceService` | `stock_price` | `stock_ticker_meta` |
| `ExchangeRateService` | `exchange_rate` | `exchange_rate_meta` |

All three are **near-identical parallel implementations** of the same
pattern: a `SortedDateSeries` of daily values plus a `[earliest_date,
latest_date]` bounds pair in the meta row, an `extensionWindow` /
`fetchToCoverDate` that fetches toward an out-of-range requested date, a
`mergeReturningDelta` that folds fetched rows in, and an `inRangeFallback`
read that returns the prior-trading-day value for an in-range miss.

The caches are **local, derived, un-synced, and rebuildable** — only the
instrument *registry* metadata syncs via CloudKit, never the price rows.

## The bug

The cache tracks coverage as nothing more than the outer `[earliest,
latest]` bounds. Two code paths let those bounds straddle days that were
never actually fetched:

1. **Boundary jump on a partial fill.** `mergeReturningDelta` sets
   `latest = max(existing.latest, returned.max())` (and the symmetric
   `earliest = min(...)`). The forward `extensionWindow` requests an
   **unbounded** range `[latest … requestedDate]`, which can span years.
   When a provider serves only a recent *tail* of that range (e.g.
   CoinGecko's free tier refuses data older than 365 days — verified HTTP
   error `10012`), the merge advances `latest` to the tail's max and the
   un-served middle becomes a permanent hole.
2. **Disconnected island.** The cold-cache branch fetches a free-floating
   30-day window around the requested date, not anchored to the existing
   bounds, stretching `[earliest, latest]` across a span that was never
   queried.

Once `[earliest, latest]` straddles an un-fetched span, `inRangeFallback`
short-circuits every read in that span to the nearest prior value and the
hole is **never re-fetched** — by design, to avoid a network probe per
weekend. The result is a silently stale price, not a blank.

### Evidence (production Real Profile cache)

- **Crypto (24/7 — any gap is spurious):** LDO 14.6% covered (one
  contiguous 1,204-day void: 2023-01-27 → 2026-05-15, recent block exactly
  the 32-day cold window); STRK 5.5%; ZK 6.6%; EIGEN 6.4%.
- **Stocks (ASX, 5/7 — weekend/holiday gaps legitimate):** mostly healthy
  (~68% ≈ trading-days-minus-holidays), but a real spurious hole: VGS.AX
  2026-03-01 → 2026-04-07 (37 days, not a holiday). 6-day gaps are genuine
  Easter closures.
- **FX (5/7):** healthy — no gap exceeds a weekend.

Impact tracks how continuously each market trades; the defect is identical
in all three services.

## The invariant

> A series' cached data is always a single **contiguous** block
> `[earliest, latest]` in which **every day was actually queried**.
> Therefore any absent day inside the block is a genuine no-price day
> (closed market), and the prior-trading-day fallback over it is correct.

The prior-day fallback is **not** the bug and is retained — it is the
*required* behaviour for closed-market days. The fix is to guarantee the
fallback only ever operates over genuine gaps.

## The model (how extension works after the fix)

- **`latest` is the last day with actual data; `earliest` the first.**
- **Forward fill always queries a bounded window anchored at the boundary:**
  `[latest … latest + W]` (default `W ≈ 30` days — large enough to clear a
  weekend/holiday run and be sure the window contains real data, small
  enough that a provider serves it wholesale rather than partially).
- **The boundary advances only to a day that actually returned data.** The
  days between the old boundary and the new one were inside the queried
  window, so their absence is genuine no-price — fallback is correct.
- **Re-querying the boundary every pass is intended, not waste.** Recent
  days whose data was not yet published (or a forward-timezone market's
  not-yet-available day) are picked up on a later pass. We always query
  forward *from the latest day we have*, even if earlier passes returned
  nothing for the days just after it; the gap closes itself once a later
  day returns data, after which the boundary has moved past it and we stop
  re-querying it.
- **Backward fill is symmetric:** bounded windows `[earliest − W … earliest]`
  stepping back toward the requested date.
- **Deep backfill is incremental.** Reaching a far out-of-range date takes
  multiple bounded steps (driven by the existing warming loop). A single
  `price()` call makes bounded forward/backward progress and returns the
  best available value (or triggers background warming) rather than issuing
  one unbounded range request.

Because each window is bounded and anchored at the boundary, a provider that
refuses part of a *huge* range can no longer cause a boundary jump: the
window is small enough to be served wholesale, and any in-window absence is
a genuine no-data day.

### Forward cap and timezone safety

**No artificial forward cap.** A UTC-anchored "today" clamp would be wrong:
end-of-day in Sydney is still "yesterday" in UTC, so a UTC cap would
withhold an ASX close that is already published for ~10 hours.

The caps that matter are only those a *provider* imposes. All four current
providers were verified (live future-date probe, 2026-06-17) to **tolerate
requests past today without erroring** — they clamp to the latest available
data or return empty:

| Provider | Asset | Future-date request → |
|---|---|---|
| Binance | crypto | returns `[]` (empty), no error |
| CoinGecko (`market_chart/range`) | crypto | clamps to latest available, no error |
| Frankfurter (`FROM..TO`) | FX | clamps (`end_date` = last real day), no error |
| Yahoo Finance (`v8/finance/chart`) | stocks | clamps to available; meta confirms `Australia/Sydney` AEST `gmtoffset:36000` |

(CryptoCompare's `histoday` requires an API key and was not probed keyless;
its `toTs` is documented to clamp to the latest close, but its future-date
behaviour must be confirmed with a key before relying on it.)

Therefore the forward window requests up to a generous near-future bound
(e.g. `now` plus a small buffer) with **no global clamp**, so a
forward-timezone market's already-published close flows immediately. The
re-query-the-boundary rule covers "not published yet": a day that returns no
data simply does not advance the boundary and is retried next pass — never a
permanent gap.

If a future provider is ever added that *does* error on future dates, the
cap is applied **in that provider's client only** (documented with its
timezone assumption, tolerance, and any retry-with-reduced-max behaviour),
never as a global clamp in the shared core. Date math elsewhere uses
`Calendar.utc` per `guides/DATE_TIME_GUIDE.md`.

## Architecture: extract a shared core

The contiguous-extension logic is extracted into one reusable component
that the three services delegate to, removing the triplication that let the
bug exist in three places. Proposed shape:

- A generic **contiguous-series cache** owning, for one keyed series: the
  `SortedDateSeries<Value>`, the `[earliest, latest]` bounds, the
  in-range/prior-day **read with fallback**, the **bounded-window extension
  planner** (forward/backward, boundary-anchored, future-capped), and the
  **boundary-safe merge** (advance bounds only across the just-queried
  window).
- Each service supplies the parts that genuinely differ: the **provider
  fetch** for a date range (crypto runs its multi-provider fallback chain;
  stock/FX call their single provider) and the **persistence** of the
  returned delta to its own table pair.
- Value type is generic (`Decimal` for all three today) so the core carries
  no asset-specific logic.

The boundary-safe merge replaces the three `*+Merge.swift` min/max
advances; the planner replaces the three `extensionWindow` /
`fetchToCoverDate` implementations and removes the disconnected cold-window
branch (a genuinely new series still bootstraps with a single anchored
window, but one that becomes the series' first contiguous block — there is
no existing boundary to disconnect from).

## Recovery: purge all fetched price/rate data

The existing on-disk caches cannot be trusted — they already contain
un-fetchable gaps. Because the data is local, derived, un-synced, and cheap
to refetch (keyless Binance for crypto deep history; the stock/FX
providers), recovery is a **total purge**, not a targeted repair:

- A one-time migration on the profile-index database deletes all rows from
  `crypto_price`, `crypto_token_meta`, `stock_price`, `stock_ticker_meta`,
  `exchange_rate`, and `exchange_rate_meta`. (Mirrors the precedent set by
  `v7_purge_intraday_cached_prices`; follows the drop/recreate rules in
  `guides/DATABASE_SCHEMA_GUIDE.md`.)
- After the purge every series is empty, so the corrected contiguous
  extension rebuilds it from scratch on demand / via background warming —
  with the invariant holding from the first fetch.

## Error handling

- A provider error or empty response for a window leaves the boundary
  unmoved; the window is retried on a later pass (the desired
  self-healing). No partial state advances the bounds.
- Transient vs structural classification (`ConversionFailureClassifier`)
  is unchanged; a date that no configured provider can supply stays
  out-of-range and surfaces as `noPriceAvailable` (honest unavailable),
  exactly as today — this design does not change which dates are reachable,
  only that reachable dates are fetched contiguously.

## Testing (TDD, against TestBackend / in-memory GRDB)

Shared-core unit tests:

- Forward window is bounded and anchored at `latest`; a tail-only provider
  response does **not** advance the boundary past the un-served span.
- A genuinely-absent day inside a fully-queried window is left as a gap and
  read via prior-day fallback (no boundary corruption, no re-fetch storm).
- Boundary re-query picks up a day that was unavailable on an earlier pass.
- Backward fill steps in bounded windows toward an old requested date.
- No disconnected island is ever persisted.
- Forward window: a forward-timezone market's already-published close
  (e.g. an ASX day that is still "yesterday" in UTC) is fetched, not
  withheld; a day with no data yet leaves the boundary unmoved and is
  retried, never creating a permanent gap. No global UTC cap is applied.

Per-service tests confirm crypto's multi-provider fetch, stock, and FX each
drive the shared core correctly. Migration test: the purge empties all six
tables and a subsequent fetch rebuilds contiguously.

## Out of scope

- Pre-shipping provider mappings (Binance/CoinGecko/CryptoCompare) for known
  tokens — tracked separately as **#1140**. (That fix lets CoinGecko-only
  tokens like RPL reach a deep-history provider; this fix ensures whatever
  *is* reachable is cached contiguously. They are complementary.)
- Reclassifying worthless dust tokens (e.g. HEX, $0 market cap) — noted in
  #1140.
- Any change to the prior-trading-day fallback semantics or to the
  income/expense "unavailable month" rule (#1077).
