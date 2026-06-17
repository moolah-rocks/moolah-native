# DefiLlama as primary crypto price provider — design

Date: 2026-06-17
Related: [#1140](https://github.com/moolah-rocks/moolah-native/issues/1140)
(self-refreshing provider token-list caches + re-detection)

## Problem

Crypto token pricing is brittle: coverage is pieced together from CoinGecko,
CryptoCompare, and Binance, each with its own gaps.

- **CryptoCompare** now requires a key and the free tier is ~100 calls/month —
  effectively unusable as a live source.
- **CoinGecko free** hard-refuses historical data older than 365 days
  (`error 10012`), so tokens registered with only a `coingecko_id` cannot
  backfill pre-365-day history. Users hold crypto with records going back well
  before that, so monthly Income & Expense renders affected months as "—" (one
  un-priceable `.priced` leg blanks the whole month, strict Rule 11 / #1077).

#1140 addresses the CoinGecko-horizon symptom by *routing around* it: cache all
three providers' token lists and run a startup re-detection pass that finds an
alternate provider symbol (e.g. a keyless Binance `RPLUSDT` pair) so deep
history can come from Binance instead of CoinGecko.

This design adds a more fundamental source. **DefiLlama's coins API
(`coins.llama.fi`) is keyless, free, looks up arbitrary tokens by
`{chain}:{contract_address}`, and serves deep daily history** — verified live
2026-06-17 against the production "Real Profile" token set:

- Coverage: 27 / 34 non-spam tokens, including **every token in #1140's gap
  table** (RPL → 2018-07, ILV → 2021-03, IMX → 2021-11, STRK → 2024-02,
  AVAIL → 2024-07, HEX → 2019-12) — by contract address, no symbol discovery.
- BTC history to 2013, ETH to 2015, USDT to 2015, WETH/USDC to 2018.
- The 7 misses are native MATIC (a stale `coingecko_id`, fixable) and 4
  micro-caps (DFLY/FAM/MDGB/OPT) that no current provider prices either.

DefiLlama as the first provider in the chain closes the deep-history gap
directly, by the contract address we already store — without needing to
discover an alternate symbol per token.

## Goals

1. Add `DefiLlamaClient` as a keyless `CryptoPriceClient`, **first** in the
   price-client chain, keyed on the contract address already in `instrumentId`.
2. Determine and refresh whether DefiLlama supports a given token *without* a
   downloadable token list, re-validated on the same startup rhythm as #1140's
   reconciliation (so support is not locked in at first registration forever).
3. Be a polite network citizen despite no documented hard rate limit.

## Non-goals

- Changing #1140's CoinGecko / CryptoCompare / Binance catalogs or its
  merge-only mapping reconciliation. This design is **strictly additive and
  lands after #1140's PR1+PR2 merge** (Path B).
- Using DefiLlama for token *resolution* (symbol/name/decimals) or
  instrument-picker search — the list-based providers keep that role; DefiLlama
  only prices and self-probes for support.
- Replacing any existing provider. CoinGecko/CryptoCompare/Binance/Stablecoin
  remain as fallbacks for the long-tail tokens DefiLlama lacks.
- Reclassifying any token to `.unpriced` / `.spam`.

## Architecture

### Why DefiLlama is a clean drop-in

The existing `CryptoPriceClient` protocol (`dailyPrice(for:on:)`,
`dailyPrices(for:in:)`, `currentPrices(for:)`, all USD) maps 1:1 onto verified
keyless DefiLlama endpoints, and the cache / merge / persist / contiguous-window
machinery in `CryptoPriceService` is provider-agnostic (it operates on
`[ISODate: Decimal]` deltas). No protocol change is required.

| Protocol method | DefiLlama endpoint |
|---|---|
| `dailyPrices(for:in:)` | `/chart/{coin}?start=&span=&period=1d` |
| `dailyPrice(for:on:)` | `/prices/historical/{ts}/{coin}` |
| `currentPrices(for:)` | `/prices/current/{coins}` (native multi-coin batch) |

### `DefiLlamaClient: CryptoPriceClient`

- **`syncProvider`**: a new `SyncProvider.defiLlama` case (display name "DefiLlama").
- **Coin-id derivation** (no network lookup):
  - ERC-20 `instrumentId == "{chainId}:0x…"` → `"{defillamaChain}:{address}"`
    via a static `chainId → DefiLlama chain-name` table
    (`1→ethereum, 10→optimism, 137→polygon, 8453→base, 534352→scroll, …`).
    **Always the contract address for ERC-20s.**
  - Native `instrumentId == "{chainId}:native"` → `"coingecko:{coingeckoId}"`
    from the mapping; BTC → `coingecko:bitcoin`.
  - A token whose chain is absent from the table, or a native token with no
    `coingeckoId`, derives no id → the client throws `noProviderMapping` and the
    chain falls through (same contract as CoinGecko on a missing id).
- **`dailyPrices`**: GET `/chart`, day-bucket the near-day timestamps keeping the
  last point per calendar day (the existing `parseMarketChartResponse` pattern),
  applying the confidence gate below.
- **`currentPrices`**: GET `/prices/current` with comma-separated coin ids,
  remap response back to `instrumentId`.
- **Confidence gate (threshold 0.2):** drop any individual price point whose
  `confidence < 0.2`. Rationale: DefiLlama exposing low confidence does not mean
  CoinGecko's value for the same token is better — CoinGecko simply does not
  report uncertainty. Keep low-confidence DefiLlama data; only 0.2 guards against
  genuinely broken / zero-liquidity reads. A fully-gated response is treated as
  empty, so the chain falls through.
- **Rate limiting:** the client uses `networking.client(forHost: "coins.llama.fi")`,
  i.e. a `RateLimitedHTTPClient` with a polite configured limit, giving the same
  shared, 429-aware per-host cooldown every other provider gets. Batched probes
  (below) keep request volume low.

### Support probe cache (the new state)

DefiLlama has no enumerable token list, so "does it support token T?" is a
**validation result with freshness**, not an identifier. The id is always
derivable; only support is unknown. This is recorded in a **local-only**
SQLite cache, keyed by `instrumentId`:

```sql
CREATE TABLE defillama_support (
  instrument_id TEXT NOT NULL PRIMARY KEY,
  supported     INTEGER NOT NULL CHECK (supported IN (0, 1)),
  earliest_date TEXT,            -- ISO YYYY-MM-DD, NULL when unsupported
  last_checked  TEXT NOT NULL    -- ISO 8601
) STRICT;
```

- Lives under the existing InstrumentRegistry support directory, **local-only,
  drop-and-recreate retention** (network-derived cache — the same retention
  model as #1140's catalogs and `SQLiteCoinGeckoCatalog`; never the profile DB).
- It is a per-token memoization built **bottom-up by probing our registered
  tokens**, not a downloaded list. It therefore does **not** reuse #1140's
  `RefreshableCatalogStore` (which models a top-down list download); it may reuse
  the low-level `CatalogSQLite` raw-SQLite helpers if #1140 PR1 exposes them, to
  avoid duplicating the open/exec/bind plumbing.
- `earliest_date` (from `/prices/first`) gives the contiguous-window backfill a
  real **history floor**, so `extendContiguously` / `coverRangeContiguously`
  stop at first-liquidity instead of probing dead pre-history windows.

### Startup probe (the re-validation)

A best-effort pass run at session startup, alongside
`registerBuiltInPresetsIfMissing` / #1140's `reconcileProviderMappings`:

1. Select registered crypto tokens whose support row is **missing, older than
   24h, or `supported = 0`**. Re-probing `supported = 0` is what stops DefiLlama
   support from being locked in at first check — a token that gains DEX
   liquidity later is re-detected on a subsequent launch.
2. **Batch-probe** the selected tokens via `/prices/first` with comma-separated
   coin ids (one or few requests for the whole set).
3. Write `{supported, earliest_date, last_checked}`: a returned point →
   `supported = 1` + its earliest date; absent from the response →
   `supported = 0`, `earliest_date = NULL`.
4. Best-effort and cancellation-aware; mirrors the preset seeder.

### Price-chain integration

Chain order becomes `[defiLlama, coinGecko, cryptoCompare, binance, stablecoin]`.

`DefiLlamaClient` consults the support cache to avoid wasted round-trips:

- token cached `supported = 0` **and** fresh (`last_checked` within 24h) →
  throw `noProviderMapping` immediately (no network), chain falls through;
- otherwise call the API, and **opportunistically update** the cache from the
  live outcome (non-empty after the confidence gate → `supported = 1` + observed
  floor; empty → `supported = 0`). This keeps support fresh between startups
  without a dedicated pass.

The orchestrator (`CryptoPriceService.fetchRange` / `currentPrices`) is
unchanged: it already tolerates per-provider failures and falls through.

## Data flow

```
app launch (ProfileSession)
  ├─ registerBuiltInPresetsIfMissing()              (existing)
  ├─ reconcileProviderMappings(using: catalogs)     (#1140 PR2)
  └─ probeDefiLlamaSupport()                         (new; batched /prices/first,
        └─ per token: write {supported, earliest_date, last_checked}    24h gate)

price fetch (existing orchestration, new client first)
  └─ CryptoPriceService.fetchRange / currentPrices
        └─ DefiLlamaClient
             ├─ cached unsupported & fresh → throw → fall through (no network)
             └─ else GET /chart|/current → confidence-gate 0.2
                   → update support cache → return or throw → fall through
```

## Error handling

- **Unsupported / empty / fully-gated / undrivable id** → throw
  `noProviderMapping` or return empty → existing chain falls through. No
  orchestrator behaviour change.
- **DefiLlama outage / network error** → client throws → chain falls through;
  today's provider stack still serves.
- **Startup probe network failure** → log, leave rows untouched, retry next
  launch (same graceful-degradation contract as the catalogs).
- **Support-cache schema-version mismatch** → drop and recreate the single file.
- No API key, so no key-management or 401 path.

## Testing

- **`DefiLlamaClient`** (via `StubURLProtocol` fixtures): id derivation
  (ERC-20 / native / BTC / unknown chain / native-without-coingecko-id),
  `/chart` day-bucketing, confidence gate at 0.2 (kept vs dropped vs
  fully-gated→empty), `currentPrices` multi-coin batch + remap.
- **Support cache**: write/read, 24h staleness gate, drop-and-recreate on schema
  bump, re-probe of `supported = 0` rows.
- **Startup probe**: batched `/prices/first` updates rows; graceful degradation
  on network error (rows untouched); idempotent (second run within 24h no-ops).
- **Chain integration** (against `CloudKitBackend` + in-memory GRDB): a
  cached-unsupported-and-fresh token short-circuits with **no** network call; a
  supported token resolves from DefiLlama first; a deep-history token (e.g. RPL
  back to 2018) backfills past the CoinGecko 365-day wall.

## Known constraints / decisions

- DefiLlama publishes no hard rate limit for keyless `coins.llama.fi`; politeness
  comes from the per-host `RateLimitedHTTPClient` plus batched probes. An
  optional paid `pro-api.llama.fi` tier exists but is not used.
- DefiLlama history for an ERC-20 starts at first DEX liquidity, not contract
  deployment — strictly better than today (it is the only source giving deep
  history at all); `earliest_date` records the real floor per token.
- Confidence threshold **0.2** (deliberately low — see rationale above).
- Staleness TTL **24h**; support cache **local-only, not synced**.
- Chain order **DefiLlama-first**.
- Orthogonal follow-up surfaced by the coverage check (out of scope here): the
  stored `coingecko_id = "matic-network"` is stale (rebranded to POL);
  `coingecko:polygon-ecosystem-token` works. Worth a separate fix.

## Decisions log

- Add DefiLlama as primary price source (keyless, by contract address, deepest
  history); retire reliance on CryptoCompare and CoinGecko-free for history.
- DefiLlama support tracked in a local probe cache refreshed at startup (chosen
  over storing it on the synced mapping, and over try-first-with-no-state).
- Probe captures `earliest_date` as well as a support flag (chosen over a flag
  only) for the backfill history floor.
- Own cache table, not folded into #1140's list-based catalog engine (different
  shape: bottom-up per-token memoization vs top-down list download).
- Confidence gate lowered to 0.2 from an initial 0.5.
- Ships after #1140 (Path B); strictly additive.
