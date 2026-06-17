# Pre-listing crypto valuation: value tokens at $0 before their first trade

**Status:** Design — approved, pending spec review
**Date:** 2026-06-18
**Related:** DefiLlama 12h-oversampling fix (PR #1146), crypto price-cache purge `v7` (PR #1147), [[project_defillama_daily_gap_sep2024]]

## Summary

A held crypto token that has no market price for a given day currently
**throws** from the conversion path, which makes the net-worth graph **drop the
whole day** — every holding disappears, not just the unvaluable one. The
trigger case is an airdropped token received before it became tradable (EIGEN:
received 2024-09-25, first market price anywhere 2024-10-01), but the rule must
be **token-agnostic** and behave sensibly for any current or future token.

This design introduces one general rule: **for a `priced` crypto token, value
any date strictly before the token's confirmed first-trade date at $0
(`.knownZero`)** instead of throwing. Dates on or after first-trade that are
merely uncached keep their current behaviour (backfill, and throw on a genuine
gap). The same rule, applied at the conversion seam, also produces the
ATO-correct acquisition value for free.

## Goals

- A pre-first-trade day values at **$0**, so the net-worth graph renders the
  rest of the portfolio on that day instead of dropping it.
- The rule is **general** — no per-token / per-airdrop special-casing.
- The "before first trade" decision is **safe against a single provider's
  inaccurate start date** — we never zero a date another provider could price.
- A **transient** provider failure (rate limit, network, outage) **never**
  results in a silent $0; it stays "unavailable" and self-heals.
- The airdrop income-receipt leg is valued correctly for ATO purposes as a
  consequence of the same seam (no separate code path).

## Non-goals

- Computing CGT, cost base, or tax reports. Moolah supplies correct values;
  it is not a tax engine.
- Detecting *whether* an airdrop is an "initial allocation" vs an
  "established-token" airdrop. We never need to: the price-on-the-date does the
  work (see ATO mapping below).
- Changing stock or fiat/exchange-rate valuation. Those providers are
  date-anchored and are out of scope.

## Background

### Why the day drops today

Daily-balance, income/expense, investment-value and forecast aggregations
convert each position through `InstrumentConversionService.convertResult`, which
returns `.value` or `.knownZero` (see
`GRDBAnalysisRepository+Conversion.convertedQuantity`). `.knownZero` already
exists for `.unpriced` / `.spam` crypto and folds to `.zero(target)` gracefully
(issue #790). A **`priced`** token whose price is missing instead throws, and
the daily-balances path rethrows — dropping the day (per
`guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11).

### ATO treatment (the reason $0 is correct, not just convenient)

From the ATO "Staking rewards and airdrops" guidance:

- **Initial allocation airdrop** (no trading in the project's tokens prior to
  the airdrop): *no* ordinary income and *no* capital gain at receipt; if issued
  free, **cost base $0**. The ATO states these tokens *"don't have a market
  value at the time of the initial airdrop because they have not previously been
  traded."* (Worked example: Josh / CX — $0 cost base, full proceeds are the
  gain.)
- **Established-token airdrop** (token already trading): money value at receipt
  is ordinary income; cost base = market value at receipt. (Merindah / Coin B.)
- **Paid initial allocation**: cost base = amount paid. (Calista / HXP.)

A single "price-on-the-date, $0 before first trade" rule yields all three
correctly:

| Case | Price on receipt date | Result | ATO example |
|---|---|---|---|
| Initial allocation, free | **$0** (pre-listing) | income $0, cost base $0 | Josh / CX |
| Initial allocation, paid | $0 token price; payment leg = what you paid | cost base = amount paid | Calista / HXP |
| Established-token airdrop | real market price exists | income & cost base = market value | Merindah / Coin B |

## The rule

At the conversion seam, for a `priced` crypto instrument and a target on day `D`:

1. If a cached/fetchable price exists for `D` → use it (unchanged).
2. Else if `D` is **strictly before** the token's **confirmed first-trade date**
   → return `.knownZero` (value $0).
3. Else (`D` ≥ first-trade, or first-trade not yet confirmed) → existing
   behaviour: drive the contiguous backfill; on a genuine post-first-trade gap,
   throw (transient → degrade per row; structural → rethrow).

Placement at the conversion seam (not in the graph) means it propagates
uniformly to net-worth, income/expense, investment values and forecasts, and to
the airdrop income leg.

## Determining the confirmed first-trade date

### Candidate floor

`defillama_support.earliest_date` (already populated by the `/prices/first`
startup probe) is the **candidate**. We trust DefiLlama's floor as
*self-consistent* — i.e. it accurately reflects the earliest DefiLlama tracked
the token. We do **not** second-guess it with an extra `/chart` probe. The only
acknowledged inaccuracy is that DefiLlama may not have tracked the token's
*entire* history, so another provider might have earlier data.

### Cross-check = the existing backward backfill

When a pre-floor date is requested, the contiguous planner
(`ContiguousFetchPlanner` driven by `CryptoPriceService.coverRangeContiguously`
/ `extendContiguously`) already walks backwards, trying **every** provider per
window (DefiLlama clamps below its own floor via the #1145 history-floor clamp,
but Binance / CoinGecko / CryptoCompare are still attempted). Outcomes:

- **A provider returns earlier data** → the walk makes progress, `earliest`
  moves down, those days get real prices. A too-late DefiLlama floor therefore
  **never** zeroes a day another provider can fill.
- **Every provider returns no data** → the walk terminates on "no progress."
  That is the confirmation: nobody prices the token below this point.

### Confirmation gate (structural vs operational)

The backward walk's no-progress termination is only trusted as a first-trade
confirmation when **no _operational_ provider failure occurred** in the
confirming window. Structural unavailability is fine; operational failure is
not:

| Provider outcome | Confirms "no data"? | Classification |
|---|---|---|
| No symbol/mapping for the token | Yes (structural) | `CryptoPriceError.noProviderMapping` |
| Provider unusable — no / invalid API key | Yes (structural) | `WalletSyncError.missingApiKey` / `.invalidApiKey` |
| Clean empty response | Yes (no data) | — |
| Rate-limited / network / 5xx / timeout | **No — blocks** | `RateLimitGateError` / `URLError` / `WalletSyncError.network` / `.rateLimited` |

This is the existing `ConversionFailureClassifier.isTransient` split: a
**transient** failure blocks confirmation ("a provider could have had the token
but we couldn't reach it"); a **structural** one does not ("this provider
genuinely can't contribute"). We confirm — and only then zero below the floor —
when the chain produced no data and threw no *transient* failure.

### Required fix: `fetchRange` flattens errors

`CryptoPriceService.fetchRange` currently wraps **every** provider error —
including a missing API key — into `WalletSyncError(.network …)`, which would
read as transient and wrongly block confirmation forever. Part of this work is
making `fetchRange` (and the `extendContiguously` / `coverRangeContiguously`
no-progress bookkeeping) **preserve** the structural-vs-operational distinction
instead of collapsing it to `.network`, so the confirmation gate can apply
`ConversionFailureClassifier`.

## Components & data flow

1. **`crypto_token_meta.first_traded_on`** (new, nullable ISO `YYYY-MM-DD`):
   the confirmed cross-provider first-trade date. `NULL` = not yet confirmed.
2. **Backfill (`CryptoPriceService` + `+FetchRange`)**: when a backward walk
   terminates on no-progress **with no transient failure**, set
   `first_traded_on = cache.earliestDate` (the earliest any provider served). On
   a transient-failure termination, leave it `NULL` (unknown — try again later).
3. **Price lookup**: when no price is available for `D` and
   `first_traded_on != NULL && D < first_traded_on`, short-circuit to a
   pre-listing signal **before** any network call (fast path; no backfill
   attempt). Expressed as a new `CryptoPriceError.beforeFirstTrade(tokenId:date:)`
   (or equivalent sentinel).
4. **Conversion seam**: map `beforeFirstTrade` → `.knownZero` (a successful
   result, not an error), so `convertedQuantity` folds it to `.zero(target)`.
   `beforeFirstTrade` therefore never reaches `ConversionFailureClassifier`.
5. **Persistence**: `CryptoTokenMetaRecord` gains `firstTradedOn`;
   `loadCache` / `persistDelta` round-trip it.

## Data model / migration

- `ProfileIndexSchema` migration **`v8_crypto_first_traded_on`**:
  `ALTER TABLE crypto_token_meta ADD COLUMN first_traded_on TEXT;`
  (nullable; no default needed — `NULL` means unconfirmed). Bump
  `ProfileIndexSchema.version` to 8 and update `ProfileIndexSchemaV3Tests`'s
  version assertion (the test that caught the v7 bump).
- Follows the existing migration-body-in-sibling-file convention
  (`ProfileIndexSchema+CryptoFirstTradedOn.swift`).

## Edge cases

- **Transient outage** (all providers rate-limited/offline): `first_traded_on`
  stays `NULL`, nothing is zeroed; the day remains "unavailable" and self-heals
  once a provider responds. Never a silent $0.
- **DefiLlama floor too late, another provider earlier**: backward walk fills
  from that provider; `first_traded_on` lands at the true earliest. ✓
- **DefiLlama floor too early**: walk attempts below it, all empty, confirms at
  the real earliest; a couple of wasted attempts, no wrong result.
- **No provider prices the token at all** (`unpriced`): unchanged — already
  `.knownZero` via pricing status; this path is for `priced` tokens only.
- **Established-token airdrop**: a price exists on the receipt date, so step 1
  applies; never reaches the zero branch.
- **Invalidation / re-probe**: a first-trade date should be revisited if the
  token gains a new provider mapping or DefiLlama's support floor changes
  (an earlier source may appear). Re-validated by the existing startup support
  probe; `first_traded_on` is cleared when the candidate floor moves earlier or
  mappings change. (Promote-only spirit: confirmation can move earlier, not
  later, without a re-probe.)

## Testing strategy

- **Conversion seam (unit, `TestBackend`)**: a `priced` token with
  `first_traded_on = F` returns `.knownZero` for `D < F` and the real value for
  `D ≥ F`; an uncached `D ≥ F` with a transient failure rethrows (degrades per
  row), not zeroes.
- **Confirmation gate (unit)**: backward walk that ends clean-empty sets
  `first_traded_on`; a walk that ends on a transient failure does **not**;
  a structural-only failure set (no mapping + no key) still confirms.
- **`fetchRange` classification (unit)**: a missing-API-key failure is
  preserved as structural, a rate-limit as transient (regression for the
  flatten-to-`.network` bug).
- **Migration (unit)**: `v8` adds `first_traded_on`, leaves existing
  `crypto_token_meta` rows intact (nullable), schema-version assertion updated.
- **Scenario (integration)**: EIGEN-shaped token (held from a pre-listing date,
  first price `F`) → graph renders all days; pre-`F` days contribute $0; the
  income-receipt leg before `F` values at $0; post-`F` days value at market.
- **Zone-invariance**: first-trade comparison is UTC-day based (consistent with
  the rest of the rate-cache keying); assert in-process across zones.

## Out of scope / future

- CGT / cost-base reporting.
- Surfacing a UI affordance ("no market price before first trade") on the
  affected days — possible later polish, not required for correctness.

## Risks

- **Wrongly zeroing a real holding** if the confirmation gate misclassifies a
  transient failure as "no data." Mitigated by reusing
  `ConversionFailureClassifier` and the `fetchRange` classification fix; the
  default on any transient/unknown failure is *do not confirm*.
- **Stale `first_traded_on`** freezing out later-arriving earlier history.
  Mitigated by re-validation on mapping/floor change; confirmation may only move
  earlier.
