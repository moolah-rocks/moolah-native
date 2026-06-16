# Stablecoin $1 fallback + per-request CryptoCompare / CoinGecko keys

**Date:** 2026-06-16
**Status:** Design — approved, pending spec review

## Problem

The production net-worth graph and income/expense reports have gaps for
crypto tokens whose only deep-history price source is CryptoCompare.
CryptoCompare's `min-api.cryptocompare.com` now hard-requires an API key
(HTTP 401 "API key required" for keyless requests). `CryptoCompareClient`
sends no key and `RateLimitedHTTPClient` injects none, so every CryptoCompare
fetch fails — `parseHistodayResponse` throws on the `{"Data":{},"Err":{…}}`
error body and nothing is written. The fix (#1136) that routed CoinGecko-only
tokens to CryptoCompare for deep history was written when CryptoCompare was
keyless; CryptoCompare changed the rules underneath it.

Concretely, in the production "Real Profile":

- Tokens with a **Binance** symbol (ETH, BTC, ENS, UNI, OP, TIA, STRK, LDO)
  have full history — Binance klines are keyless and date-anchored.
- Tokens with **no Binance pair** (USDC, USDT, DAI, HEX, SAITABIT) are stuck:
  CoinGecko serves only the last ~365 days and CryptoCompare 401s, so their
  deep tails never fill. A held *priced* token that can't be valued on a day
  drops that day from the graph (per-day Rule 11), blanking the chart.

## Goals

1. **USDC / USDT:** never leave a gap — fall back to a constant **$1.00 USD**
   for any date no real provider can price. USDC and USDT are
   fiat-collateralised, redeemable 1:1, so $1 is accurate to within rounding.
2. **DAI excluded:** DAI is crypto-collateralised (a softer peg that can drift,
   e.g. it fell with USDC during the March 2023 depeg). It keeps **real
   prices**, restored by goal 3 — never a hard $1 peg.
3. **CryptoCompare API key:** let the user enter a CryptoCompare (CoinDesk
   Data) key in Settings so deep history works again for every CryptoCompare
   token (DAI, HEX, and the rest). Takes effect immediately — no restart.
4. **CoinGecko key (add-on):** make the existing CoinGecko key take effect
   immediately too, instead of only at the next session construction.

## Non-goals

- Pegging DAI or any other stablecoin. Only USDC and USDT.
- Making the token-discovery catalog / resolver pick up a new CoinGecko key
  without a restart (see Scope boundary below). This change covers the
  **price-fetch** path, which is what governs backfill.
- Any schema, CloudKit, or migration change. All changes are read-time.

## Background: how the price pipeline fills gaps

`CryptoPriceService` holds an ordered `clients: [CryptoPriceClient]` chain
(currently CoinGecko → CryptoCompare → Binance). Two layers matter:

- **Provider loop** (`fetchRange` / `fetchAndExtendCache` in
  `Shared/CryptoPriceService+FetchRange.swift`): iterates `clients` in order;
  the **first client that returns a non-empty result** for the requested
  (sub-)range persists it and stops. A client that throws
  `CryptoPriceError.noProviderMapping` is skipped silently (a routing
  decision, e.g. USDT has no Binance pair); other throws are recorded as the
  attributed error and the loop continues. The loop is **first-non-empty-wins
  per range**, not per-missing-date.
- **Coverage layer** (`uncoveredSubRanges` / `prices(for:mapping:in:)`): gap
  filling is driven here. The cache tracks each token as a contiguous
  `[earliestDate, latestDate]` window; a requested range outside that window
  produces a backward sub-range (older than `earliest`) and/or a forward
  sub-range (newer than `latest`), and **each uncovered sub-range** is run
  through the provider loop independently.

**Consequence that shapes the design:** a token's deep tail is fetched as its
own backward sub-range. So a provider placed **last** in the chain is consulted
for a sub-range only when every real provider returned empty or threw for that
sub-range. That is exactly "real price if available, else fallback" — without
any change to the loop or coverage logic.

A USDT→$1 fallback precedent already exists at
`ProfileSession+Factories.swift:84-88` (Binance's `usdtRateLookup` returns
`Decimal(1)` when CryptoCompare can't price USDT for quote conversion).

## Design

### 1. `StablecoinPriceClient` — a last-resort $1 provider

A new `CryptoPriceClient` appended **last** in the `priceClients` array, after
CoinGecko, CryptoCompare, and Binance.

```
struct StablecoinPriceClient: CryptoPriceClient, Sendable {
  var syncProvider: SyncProvider { .peggedStablecoin }

  func dailyPrices(for mapping: CryptoProviderMapping,
                   in range: ClosedRange<Date>) async throws -> [String: Decimal]
  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal
  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal]
}
```

Behaviour:

- Parse `mapping.instrumentId` (`"<chainId>:<address>"`) into `chainId` +
  `contractAddress`. A `"<chainId>:native"` id has no address → not a
  stablecoin.
- If `CanonicalTokenRegistry.symbol(chainId:contractAddress:)` is `"USDC"` or
  `"USDT"`, return `1.0` for **every** UTC day in `range` (enumerated with
  `Calendar.utc`, matching the date-key format the cache uses). Otherwise
  `throw CryptoPriceError.noProviderMapping(tokenId:provider:)` so the
  provider loop skips it.
- `currentPrices` returns `1.0` for each canonical USDC/USDT mapping, omits the
  rest.

Because it's last and only answers for USDC/USDT, real providers win whenever
they have data (a genuine USDC depeg day is captured); $1 only fills dates no
real provider could. Filled $1 rows persist through the normal
`mergeReturningDelta` / `persistDelta` path — it behaves like any other
provider, so the graph and reports read it with no special-casing.

**Address source:** reuse `CanonicalTokenRegistry` (already holds exactly the
USDC/USDT canonical addresses per chain plus the reverse `symbol(...)` lookup,
keyed on `(chainId, lowercased address)`). Gated to `{"USDC","USDT"}`. This
keeps the pegged address set current as the vendored token lists regenerate,
and inherits the registry's exact-address trust model — an impersonator at a
different address resolves to `nil` and is **not** pegged.

**`SyncProvider.peggedStablecoin`:** a new case purely for provider attribution
symmetry. The client never throws a real error, so it never becomes an
attributed outage.

### 2. CryptoCompare API key — per-request injection

- **Keychain:** account `"cryptocompare"`, service `KeychainServices.apiKeys`,
  `synchronizable: true` — mirrors `"alchemy"` / `"coingecko"`.
- **Client:** `CryptoCompareClient` gains a `apiKeyProvider: @Sendable () ->
  String?` closure (replacing the keyless `init(http:)`). The URL builders
  `histodayURL` / `priceMultiURL` append `URLQueryItem(name: "api_key",
  value:)` when the resolved key is non-empty, and omit it otherwise (keyless
  requests still 401, but that's no worse than today). Reading per request
  means a freshly entered key works without a restart.
- **Wiring:** in `ProfileSession+CryptoSync.swift`, add a `nonisolated static
  func resolveCryptoCompareApiKey() -> String?` (mirrors
  `resolveAlchemyApiKey`), passed as the provider closure where
  `CryptoCompareClient` is constructed in
  `ProfileSession.makeCryptoPriceService`.

### 3. CoinGecko key — also per-request

Currently the key and the host (`api.coingecko.com` free vs
`pro-api.coingecko.com` pro) are baked at construction, so a newly entered key
needs a restart.

- `CoinGeckoClient` gains the same `apiKeyProvider: @Sendable () -> String?`
  closure and holds **both** host-bound HTTP clients (free + pro). Per request:
  resolve the key; if non-empty, target the pro host with `x_cg_pro_api_key`;
  else the free host (current keyless behaviour).
- Wiring reads the key per request via a `resolveCoinGeckoApiKey()` closure
  from the `"coingecko"` keychain entry.

**Scope boundary (confirmed):** this immediacy applies to the **price-fetch**
clients only. The discovery catalog (`makeCoinGeckoCatalog`,
`makeLookupCatalog`) and `CompositeTokenResolutionClient` continue to read the
CoinGecko key once at session construction; a restart picks up a new key for
those. Bounding the change here keeps it focused on backfill, which is the
reported problem.

### 4. Settings UI

Add a **CryptoCompare** API-key section to `CryptoSettingsView` (likely
`CryptoSettingsView+TokenList.swift`, alongside Alchemy and CoinGecko),
mirroring the existing pattern exactly: a `SecureField` bound to local
`@State`, a Save button that trims and persists then clears the field, a
"Configured ✓ / Remove" state when a key exists, and a footer link to the
CoinDesk Data signup page.

New `CryptoTokenStore` members (mirroring the Alchemy ones):
`cryptocompareKeyStore` field, `saveCryptoCompareApiKey(_:)`,
`hasCryptoCompareApiKey` (computed), `clearCryptoCompareApiKey()`. Errors log
`localizedDescription` only — never the key value.

### 5. Help docs

- **New task article:** `site/help/_src/topics/get-a-cryptocompare-api-key.html`
  + a `toc.json` entry under parent `investments-and-crypto`. Task-type,
  200–600 words, imperative steps, a Result section, HELP_GUIDE / BRAND_GUIDE
  voice (second person, plain-spoken, Australian spelling, no banned marketing
  words). Bold exact UI labels (`**Settings > Crypto Tokens**`), "select" for
  cross-platform.
- **Accuracy:** CryptoCompare is now **CoinDesk Data** (`developers.coindesk.com`
  — the host in the 401 message). The signup / key-creation steps and the free
  tier's limits **must be verified against the live developer portal** when the
  article is written, not transcribed from memory.
- **Light updates:** add the CryptoCompare key to `manage-crypto-tokens.html`
  (which already documents Alchemy + CoinGecko key entry), and note the
  key requirement next to CryptoCompare in
  `supported-crypto-chains-and-providers.html`.

## Testing (TDD — write tests first)

- **`StablecoinPriceClient`** (new unit suite): returns $1 for canonical
  USDC/USDT on mainnet and at least one L2 (Optimism), for a single date and a
  multi-day range (every day present, all `1.0`); throws `noProviderMapping`
  for a non-stablecoin token, for a `:native` id, and for an impersonator
  address that is not the canonical USDC/USDT.
- **Integration via `CryptoPriceService`** (TestBackend, in-memory GRDB): with
  `StablecoinPriceClient` last, a USDT deep range where all real providers
  return empty/throw fills $1 across the range; a range where a real provider
  returns a non-$1 value keeps the real value (peg does **not** override).
- **`CryptoCompareClient`** URL-builder tests: `api_key` appended when the
  provider returns a non-empty key, omitted when nil/empty.
- **`CoinGeckoClient`**: pro host + `x_cg_pro_api_key` when key present, free
  host and no pro param when absent; key resolved per request (a provider that
  flips from empty to non-empty changes the targeted host without
  reconstruction).
- **`CryptoTokenStore`**: save / has / clear the CryptoCompare key (mirror the
  Alchemy store tests), against an injected in-memory `KeychainStore`.
- **`help-review`** agent over the new + edited help articles before merge.

## Risks / notes

- **Interior cache holes:** coverage is tracked as a contiguous
  `[earliest, latest]` window, so an interior hole inside a covered window is
  not re-fetched. The $1 fallback fills contiguous backward/forward sub-ranges
  (no interior holes introduced). This is a pre-existing property, unchanged.
- **Keyless CryptoCompare still 401s.** Users without a key see no regression;
  USDC/USDT are covered by the peg, and other CryptoCompare-only tokens (DAI,
  HEX) stay gapped until a key is entered — exactly today's behaviour for them.
- **Per-request keychain reads** add one keychain lookup per price fetch.
  Fetches are already rate-limited and infrequent; negligible. Matches the
  existing Alchemy per-request pattern.

## Out-of-scope follow-ups

- Making the CoinGecko discovery catalog / resolver pick up a key change
  without a restart.
- Pegging additional fiat-backed stablecoins (PYUSD, GUSD, TUSD, USDS) — easy
  to add to the `{"USDC","USDT"}` gate later if wanted, but not in this change.
