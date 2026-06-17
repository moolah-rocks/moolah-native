# Self-refreshing provider token-list caches + re-detection — design

Issue: [#1140](https://github.com/moolah-rocks/moolah-native/issues/1140)
Date: 2026-06-17 (revised — supersedes the bundled-catalog / vendoring approach)

## Problem

Several real, actively-traded tokens are registered with **only** a
`coingecko_id` and no `cryptocompare_symbol` / `binance_symbol`. CoinGecko's
free tier hard-refuses historical data older than 365 days (`error 10012`), so
those tokens cannot backfill pre-365-day history and the monthly Income &
Expense table renders the affected months as "—" (one un-priceable `.priced`
leg blanks the whole month, strict Rule 11 / #1077).

Confirmed gaps (CoinGecko-only today; a keyless Binance pair exists):

| Token | Provider available elsewhere |
|---|---|
| RPL (Rocket Pool) | Binance `RPLUSDT` (keyless), verified `2024-07-12` close `$16.14` |
| ILV (Illuvium) | Binance `ILVUSDT` (keyless) |
| IMX (Immutable X) | Binance `IMXUSDT` (keyless) |
| STRK (Starknet) | Binance `STRKUSDT` (keyless) |
| AVAIL | CryptoCompare only (no Binance pair) |
| HEX | CoinGecko-only ($0 mkt cap) — probed, not reclassified |

**Two root causes, both addressed here:**

1. **Provider ids are resolved once, at registration time, and never
   revisited.** `CompositeTokenResolutionClient` runs CryptoCompare + CoinGecko
   + Binance resolution when a token is first registered. A token registered
   before a provider listed it (or before resolution reached that provider)
   stays partially mapped forever. There is no re-detection.
2. **Only CoinGecko's token list is cached.** `SQLiteCoinGeckoCatalog` keeps a
   self-refreshing on-disk cache (`catalog.sqlite`, 24h, ETag). CryptoCompare's
   `/data/all/coinlist` and Binance's `/api/v3/exchangeInfo` are **re-downloaded
   in full on every single token resolution** and then discarded — expensive,
   not reusable, and impossible to reconcile against later.

## Goals

1. **Generalize the self-refreshing token-list cache** so all three providers
   (CoinGecko, CryptoCompare, Binance) share one well-tested SQLite caching
   engine — different URL + parse + schema only (DRY; the user's explicit ask).
2. **Cache CryptoCompare and Binance token lists** on disk like CoinGecko's,
   and route `CompositeTokenResolutionClient` through the caches instead of
   ad-hoc per-resolution downloads (a refactor with no change to the resolution
   *result*).
3. **Re-detect expanded provider support**: a startup reconciliation pass
   re-resolves each already-registered crypto token against the (cached) lists
   and **merge-only** upgrades its provider mapping — fixing #1140 and keeping
   mappings fresh as the caches refresh, with no app update or vendoring step.

## Non-goals

- Vendoring scripts, a bundled static Swift catalog, or a weekly CI auto-PR
  (the earlier approach — fully dropped in favour of runtime caches).
- Reclassifying HEX (or any token) to `.unpriced` / `.spam`.
- Changing the existing 8 `builtInPresets` (offline seeding for native BTC/ETH/
  MATIC + OP/UNI/ENS, #791) — they stay as-is.
- Changing the resolution *algorithm* in PR1 (same inputs → same mapping); only
  the data source moves from live to cached.

## Delivery: two stacked PRs

- **PR1 — Refactor + new caches (no bug-behaviour change).** Extract the shared
  caching engine, refactor CoinGecko onto it, add CryptoCompare + Binance
  caches, route resolution through the caches. Pure refactor + new capability;
  the #1140 symptom is untouched.
- **PR2 (stacked on PR1) — Re-detection.** The startup reconciliation pass that
  re-resolves registered tokens from the caches and merge-only upgrades them.
  This is the change that closes #1140.

---

## Architecture

### Shared caching engine (PR1)

A provider-agnostic, SQLite-backed, self-refreshing cache extracted from the
proven `SQLiteCoinGeckoCatalog` machinery. Three collaborating pieces:

**(a) `CatalogSQLite` — shared raw-SQLite helpers.** The `exec` / `prepare` /
`bind` / `step` / `readText` / `scalarInt` / `rollback` / `errorMessage`
statics currently in `SQLiteCoinGeckoCatalog+SQLite.swift`, lifted to a
provider-neutral namespace so all three caches share one implementation.

**(b) `RefreshableCatalogStore` — file lifecycle + refresh orchestration.**
Owns one `<dir>/<name>.sqlite`:
- Open / bootstrap from a supplied `(schemaVersion, schemaDDL)`; on a
  `meta.schema_version` mismatch, **drop the file and recreate clean** (the
  retention policy the schema guide permits for network-derived caches).
- WAL + extended result codes.
- A generic `refreshIfStale` driven by a descriptor: a 24h `maxAge` staleness
  gate; for each configured endpoint an ETag conditional GET
  (`fetchConditional`, reused verbatim — `.ok(Data, etag)` / `.notModified`);
  collect outcomes; hand them to the provider's `apply(database:outcomes:)` for
  an atomic table replace; persist `last_fetched` + per-endpoint etags. Network
  failure logs and leaves `last_fetched` untouched so the next launch retries
  (existing graceful-degradation contract preserved).

**(c) `ProviderCatalog` descriptor** (the per-provider strategy): supplies
`name`, `schemaVersion`, `schemaDDL`, the endpoint URL builder(s) + etag meta
keys, and `apply(database:outcomes:)` (parse wire → rows → replace tables).
Each concrete cache also exposes its own typed query methods over the store.

### The three caches (PR1)

| Cache | Endpoint(s) | Tables | Query surface |
|---|---|---|---|
| `CoinGeckoTokenCache` (refactor of `SQLiteCoinGeckoCatalog`) | `/coins/list?include_platform=true` + `/asset_platforms` | `coin`, `coin_platform`, `platform`, `coin_fts` | `search` (FTS), `localContractMatch` |
| `CryptoCompareTokenCache` (new) | `/data/all/coinlist` | `cc_coin(symbol, contract_address?)` | `symbol(forContract:)`, `nativeSymbols()`, `allSymbols()` |
| `BinanceTokenCache` (new) | `/api/v3/exchangeInfo` | `binance_pair(symbol)` (USDT/TRADING) | `hasUsdtPair(base:)` / `usdtPairs()` |

All conform to a small `RefreshableCatalog` protocol (`refreshIfStale()`), and
keep `STRICT` tables per the schema guide (FTS5 excepted). Each lives at its own
`<name>.sqlite` under the existing InstrumentRegistry support directory, so a
single provider's schema bump drops only that provider's file.

CryptoCompare's cache must hold a key to refresh (`/data/all/coinlist` is
401-without-key, verified). When unkeyed or rate-limited, `refreshIfStale`
degrades to the stale snapshot exactly like CoinGecko's already does — no
exception path.

### Resolution rewire (PR1)

`CompositeTokenResolutionClient.fetchCoinListData()` /
`fetchExchangeInfoData()` stop doing ad-hoc full downloads and instead read
from `CryptoCompareTokenCache` / `BinanceTokenCache`. To preserve today's
correctness on a cold cache, each cache does a **fetch-on-miss**: if it has no
snapshot yet it performs the same one-shot download it does today, stores it,
and serves — so the first resolution is no slower than now and every subsequent
one is free. The resolution algorithm (local-first, contract-gated Binance
attribution per #790, by-symbol post-confirm) is **unchanged**; only the bytes'
origin changes. The preloaded-`Data` test seams remain for unit tests.

### Re-detection reconciliation (PR2)

A new repository method run at session startup alongside
`registerBuiltInPresetsIfMissing`:

```swift
func reconcileProviderMappings(using catalogs: ProviderCatalogLookups) async
```

`resolver.resolve()` cannot be reused directly: its local-first path
**early-returns** on a cached CoinGecko contract match
(`CompositeTokenResolutionClient.swift:63-71`) and never reaches the Binance /
CryptoCompare steps — exactly the providers re-detection needs to fill. Instead,
reconciliation reads the caches directly through the **same per-provider
attribution helpers** the resolution client uses (extracted in PR1 so there is
one spam-safe implementation, not two):

For each registered crypto instrument (`allCryptoRegistrations()`, ≥1 mapping
field ⇒ its identity was already contract-confirmed at registration, so
attributing a Binance pair by its ticker is safe re #790):
- `binanceSymbol` (if nil): `BinanceTokenCache.hasUsdtPair(base: ticker)` →
  `"\(ticker)USDT"`.
- `cryptocompareSymbol` (if nil): ERC-20 → `CryptoCompareTokenCache.symbol(forContract:)`;
  native → `nativeSymbols()` membership; else by-symbol post-confirm against
  `allSymbols()`.
- `coingeckoId` (if nil): `CoinGeckoTokenCache.localContractMatch`.

Then **merge-only** combine with the stored mapping
(`CryptoProviderMapping.merging`, never downgrades) and write **only** when
something changed (no sync churn). Best-effort, cancellation-aware, mirroring
the preset seeder. Result: an RPL registered coingecko-only gains `binanceSymbol`
(and `cryptocompareSymbol` once the CC cache is keyed) on the next launch, and
stays current as the caches refresh.

`ProviderCatalogLookups` is a small Sendable bundle of the three caches' query
seams, so reconciliation is unit-testable with in-memory stubs.

## Data flow

```
app launch (ProfileSession)
  ├─ each cache.refreshIfStale()  (background; 24h ETag conditional GET)
  ├─ registerBuiltInPresetsIfMissing()              (existing, unchanged)
  └─ reconcileProviderMappings(using: catalogs)     (PR2)
        └─ per registered token: cache attribution → merge-only upgrade

token registration (existing)
  └─ CompositeTokenResolutionClient.resolve()
        └─ reads CryptoCompare / Binance / CoinGecko caches (fetch-on-miss)

price fetch (existing, unchanged)
  └─ mapping now carries binanceSymbol → keyless Binance deep history
```

## Error handling

- **Cache refresh**: network failure → logged, `last_fetched` untouched, stale
  snapshot served (existing CoinGecko contract). CC unkeyed/rate-limited → same.
- **Cache fetch-on-miss**: a failed cold fetch behaves like today's failed live
  fetch (resolution degrades for that provider), never crashes.
- **Reconciliation**: per-token failures logged and skipped; cancellation
  returns immediately; merge-only never downgrades a stored column.
- **Schema-version mismatch**: drop-and-recreate the single provider's file.

## Testing

- **Shared engine**: open/bootstrap, schema-version-mismatch drop-and-recreate,
  WAL, ETag 200/304 paths, maxAge staleness gate, graceful degradation on
  network error (last_fetched preserved). Reuse the `StubURLProtocol` +
  temp-directory patterns from `SQLiteCoinGeckoCatalogRefreshTests`.
- **CoinGecko refactor**: the existing `SQLiteCoinGeckoCatalog*Tests` must keep
  passing (behaviour-preserving refactor — the regression guard).
- **CryptoCompareTokenCache / BinanceTokenCache**: parse + store + query
  (contract→symbol, native symbols, USDT pairs), fetch-on-miss, refresh ETag.
- **Resolution rewire**: existing `CompositeTokenResolutionClientTests` pass
  with cache-backed sources; add a test that a warm cache serves without a
  second network hit.
- **Reconciliation (PR2)**: against `CloudKitBackend` + in-memory GRDB —
  partial mapping upgraded; fuller stored mapping untouched (no downgrade, no
  write); token absent from caches untouched; idempotent (second run no-op).

## Relationship to the existing infrastructure

`SQLiteCoinGeckoCatalog` is the template this generalizes — it already does
file lifecycle, 24h ETag refresh, drop-and-recreate, offline contract lookup,
and FTS search with raw SQLite on an actor (deliberately not GRDB: it is a
network-derived cache whose retention policy is drop-and-recreate, which the
profile DB forbids — see `DATABASE_SCHEMA_GUIDE.md`). The refactor lifts its
reusable machinery into the shared engine and adds two siblings; it does not
change its retention model, file location convention, or actor isolation.

## Known constraints

- The supplied CryptoCompare key is free-tier (~100 calls/month) and was over
  its monthly cap at design time. The cache needs only **one bulk call per 24h**
  (vs today's call-per-resolution), so caching *reduces* CC usage dramatically.
  Until the cap resets the CC cache serves stale/empty and `cryptocompareSymbol`
  fills in on a later refresh — merge-only reconciliation never regresses.

## Decisions log

- Full pivot to runtime self-refreshing caches; vendoring/CI/bundled-catalog
  dropped.
- Generalize all three providers (CoinGecko refactor + CryptoCompare + Binance)
  onto one shared caching engine.
- Re-detection reads the caches via the shared per-provider attribution helpers
  extracted from the resolution client (its `resolve()` early-returns on a local
  match and can't be reused wholesale), so the spam-safe attribution is shared,
  not duplicated.
- Cold-cache correctness via fetch-on-miss (first resolution no slower than
  today; thereafter free).
- Ship as two stacked PRs: refactor first, re-detection second.
- HEX: not reclassified.
