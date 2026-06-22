# Instrument Pricing Unification

Status: design approved (2026-06-23). Two sequenced sub-projects; **this spec covers Sub-project A**.

## Background

Profiling the Analysis page cold first-load (Test Profile, dev zone, 2026-06-23) found
first-paint at 2124ms with the main thread, the GRDB serial queue, and the cooperative
pool all pinned (≈100%) inside one stack:

```
FullConversionService.cryptoUsdPrice(for:on:)        Shared/FullConversionService.swift:383
 └ cryptoRegistrations()  ==  { registry.allCryptoRegistrations() }
    └ GRDBInstrumentRegistryRepository.allCryptoRegistrations()
       └ database.read → SELECT … WHERE kind='cryptoToken' (no index on kind)
          → fetchAll + decode every crypto InstrumentRow (incl. the heavy
            encoded_system_fields BLOB) — for the WHOLE registry, on EVERY price lookup.
```

Every crypto USD-price resolution re-reads and re-decodes the entire crypto registration
table. The prior batch-conversion work (`convertResultBatch`) fetches the registry once for
classification, but key *resolution* drops back into `cryptoUsdPrice`, which re-fetches per
key (twice for crypto↔crypto). Cost is O(distinct keys × full-table scan), serialized on one
DB connection, and it grows monotonically as the registry accumulates spam tokens.

### Why crypto is the only offender

The conversion service prices three instrument kinds, but only crypto round-trips the
registry:

| Kind | How its provider metadata is resolved today |
|------|---------------------------------------------|
| Fiat | none needed — `Instrument.id` is the ISO code; `ExchangeRateService.rate(from:to:)` |
| Stock | `StockPriceService` self-resolves listing currency from the ticker via its own cached `stock_ticker_meta` |
| Crypto | **`FullConversionService` scans the entire registry**, `.first(where: id)`, passes the `mapping` into `CryptoPriceService.price(for:mapping:on:)` |

`StockPriceService` already demonstrates the right pattern: the price service takes the
instrument's natural key and self-resolves the rest from its own cached store. Crypto should
work the same way. The `instrument` table has `id TEXT NOT NULL PRIMARY KEY`, so a keyed
lookup is index-backed and cheap.

### Conversion routing must stay direct (no unnecessary USD)

`ExchangeRateService` stores and uses **direct currency pairs** (Frankfurter returns many
quotes against a requested base; `AUD→GBP` is an observed pair, never triangulated). Routing
fiat→fiat through USD would change the numbers and lose observed-rate authority. The unified
model must keep direct pairs and only fall back to USD when no direct path exists.

## Design

### The unifying model

Every instrument gets a pluggable **`PriceSource`** (the `Instrument → metadata` resolver):

- `nativeQuote: Instrument` — the currency the instrument's provider denominates in.
  Fiat: itself. Stock: its listing currency. Crypto: USD.
- `pricePerUnit(on:) async throws -> Decimal` — one unit's price in `nativeQuote`.
  Fiat: `1`. Stock/Crypto: the provider price.
- `pricingStatus(on:)` / classification hook — `.priced` for fiat/stock; crypto reports
  `.priced`/`.unpriced`/`.spam` so the conversion layer can short-circuit to `.knownZero`
  without a provider call.

Conversion collapses to **one** algorithm, replacing the 7-case `computeUnitFactor` switch
and preserving the precision-safe multiplier/divisor form (deferred division so
`fiat→crypto` / `crypto→crypto` keep exact `Decimal` results).

**Common-quote selection.** The single most important invariant is *which* currency the two
operands are priced into (the "common quote"). The current per-case switch makes deliberate,
precision-motivated direction choices; the rule below reproduces every one of them exactly —
in particular it routes `fiat↔crypto`/`fiat↔stock` through the **fiat operand** (never through
USD), preserving the exact-round-trip property (`300000 JPY → ETH` at `1 ETH = 300000 JPY`
returns exactly `1`):

```
factor(source → target, on date) -> UnitFactor(multiplier, divisor):
  precondition target.kind != .stock           // any →stock is unsupported (unchanged)
  if source == target                          → (1, 1)
  if source.kind == .fiat && target.kind == .fiat
                                               → (rate(source → target), 1)   // direct Frankfurter pair
  common = target.kind == .fiat ? target
         : source.kind == .fiat ? source
         : USD                                  // both non-fiat → USD
  return ( priceIn(source, common, date),       // multiplier
           priceIn(target, common, date) )      // divisor  (division deferred)

priceIn(instrument, common, date) -> Decimal:   // value of 1 unit of `instrument` in `common`
  if instrument == common                      → 1
  if instrument.kind == .fiat                  → rate(instrument → common)     // direct pair
  // stock / crypto: price in nativeQuote, then FX to `common`
  ps = source.pricePerUnit(date)                // stock: listing-ccy price; crypto: USD price
  qs = instrument.nativeQuote                    // stock: listing currency;   crypto: USD
  return qs == common ? ps : ps · rate(qs → common)
```

`rate(a → b)` is `ExchangeRateService.rate`, which already encapsulates direct-pair lookup
with its own carry-forward fallback — so the fiat bridge needs no special USD handling here.
USD appears **only** as `common` when *both* operands are non-fiat.

Verification against the seven current cases (all reproduce exactly, including FX direction):

| Case | current `computeUnitFactor` | generic `(multiplier, divisor)` |
|---|---|---|
| fiat→fiat | `rate(s→t)` | `(rate(s→t), 1)` ✓ |
| stock→fiat | `price·rate(listing→fiat)` | `(price·rate(listing→fiat), 1)` ✓ |
| crypto→fiat | `cryptoUsd·rate(USD→fiat)` | `(cryptoUsd·rate(USD→fiat), 1)` ✓ |
| fiat→crypto | `1 / (cryptoUsd(t)·rate(USD→source))` | `(1, cryptoUsd(t)·rate(USD→source))` ✓ |
| crypto→crypto | `cryptoUsd(s) / cryptoUsd(t)` | `(cryptoUsd(s), cryptoUsd(t))` ✓ |
| stock→crypto | `stockUsd(s) / cryptoUsd(t)` | `(price·rate(listing→USD), cryptoUsd(t))` ✓ |
| *→stock | unsupported | precondition throws unsupported ✓ |

Crypto "always goes through USD" falls out of `nativeQuote = USD` (so `fiat↔crypto` bridges
through the fiat side, and `crypto↔crypto` through USD), not a hardcoded rule. A future
provider offering AUD crypto prices changes only that resolver's `nativeQuote`.

### Crypto self-resolution (the bottleneck fix)

`CryptoPriceService.price(for:on:)` **drops its `mapping:` parameter**. Internally it resolves
`mapping` + `pricingStatus` from the instrument id through a small in-memory metadata cache,
hydrated on miss via the **indexed `cryptoRegistration(byId:)` point lookup** and evicted by
the existing `purgeCache`/`invalidateCache` lifecycle (mirroring how `StockPriceService`
caches listing currency). Wrapped-native resolution (WETH→ETH via
`WrappedNativeContracts.nativePricingInstrumentId`, an exact `(chainId, contractAddress)`
trust-list lookup — never by symbol) moves inside this metadata step.

`FullConversionService` **drops the `cryptoRegistrations` closure entirely**. No conversion
code path calls `allCryptoRegistrations()` anymore. `allCryptoRegistrations()` remains for its
genuine all-rows callers (spam scan, UI lists).

Net effect: registry cost per batch goes from "full-table scan per key" to "one indexed
point-query per *distinct* token, then cached" — scaling with the working set, not the
registry size.

### Behavior preservation

- **`pricingStatus` → `knownZero`.** `convertResultDecision` asks the *source's* `PriceSource`
  for its status; `.unpriced`/`.spam` → `.knownZero` with no provider call; `beforeFirstTrade`
  still → `.knownZero`. Fiat/stock are always `.priced`. Same outcomes, sourced through the
  resolver instead of a scanned array.
- **Batch path shape unchanged.** `convertResultBatch` keeps classify → distinct keys →
  bounded (≤16) task group → ordered map, and the `(quantity·multiplier)/divisor` math.
  Classification/resolution route through `PriceSource`; crypto metadata is the cached
  point-lookup.
- **`invalidateCache(for:)`** still evicts memoised `rateCache` entries mentioning the
  instrument and purges the crypto price cache, and now also evicts the cached metadata for
  that id. Wrapped-native eviction (WETH when ETH changes) preserved.
- **`observeRates`/`observeErrors`** untouched. `ConversionError.noProviderMapping` still
  thrown for a crypto instrument with no registration.

### Boundaries / what is NOT in Sub-project A

- No storage changes. The three cache tables and `ExchangeRateService` are untouched.
- `StockPriceService` / `CryptoPriceService` internal orchestration is not yet merged — that
  is Sub-project B. A only changes `CryptoPriceService`'s public `price(for:…)` surface to
  self-resolve mapping/status, plus the `FullConversionService` composition layer.

## Components (Sub-project A)

1. `PriceSource` protocol + a resolver registry dispatched by `Instrument.kind`
   (FiatPriceSource / StockPriceSource / CryptoPriceSource). Likely new files under `Shared/`.
2. `CryptoPriceService` metadata cache + `price(for:on:)` signature change + a keyed metadata
   lookup plug (closure `(String) async throws -> CryptoRegistration?` backed by
   `cryptoRegistration(byId:)`), with eviction wired into `purgeCache`/invalidation.
3. `FullConversionService`: generic `factor` algorithm replacing `computeUnitFactor`'s switch;
   `convertCryptoToFiat`/`cryptoUsdPrice` removed/rewritten; `cryptoRegistrations` closure
   removed from the initialiser and all construction sites (1 prod wiring + preview + ~14 test
   sites — adapt with a keyed-lookup helper).
4. Wiring update in `ProfileSession+CloudKitBackendBuild.swift` (inject the keyed metadata plug
   into `CryptoPriceService` instead of the all-rows closure into `FullConversionService`).

## Error handling

- Provider failures throw (Rule 11) and surface as `.failure` in the batch; `beforeFirstTrade`
  and `.unpriced`/`.spam` map to `.knownZero`. No partial sums; mark-unavailable preserved.
- Cancellation remains task-wide in the batch group (rethrown, never a per-element `.failure`).

## Testing

- **Behaviour-neutrality** is proven by the existing conversion contract suites:
  `FullConversionServiceConvertResultTests`, `…BatchTests`, `…CachingTests`,
  `InstrumentConversionServiceCryptoTests`, `InstrumentConversionServiceStockTests`,
  `WrappedNativeConversionTests`, `FullConversionErrorPropagationTests`,
  `ConvertCacheInvalidationTests`. These must pass unchanged (TestBackend / FakeConversionService).
- **New tests:** crypto metadata cache hydrates-on-miss and evicts on `invalidateCache`;
  pricing performs a keyed point-lookup and never calls `allCryptoRegistrations()` in the
  conversion path (assert via a recording registry double / call counter); the generic `factor`
  algorithm's direct-vs-USD routing for each kind pair (AUD→GBP direct, stock→fiat via listing,
  crypto→fiat via USD, crypto↔crypto, fiat↔crypto, stock↔crypto).
- **Re-profile** the app after merge to confirm `allCryptoRegistrations` no longer dominates
  and first-paint improves vs the 2124ms baseline.

## Sub-project B (future spec)

Extract the ~85%-identical `StockPriceService`/`CryptoPriceService` orchestration
(cap-to-yesterday → in-memory check → hydrate-from-SQL → windowed network fetch →
carry-forward → write-back; already sharing `SortedDateSeries`, `ContiguousFetchPlanner`,
`cappedToYesterday`) into one generic engine, parameterized by: provider-fetch plug
(single Yahoo vs the 4-provider crypto chain), per-instrument quote (listing vs USD), and an
optional first-trade floor (crypto only). The two cache tables are **kept** (no schema
migration). Pure internal refactor behind A's `PriceSource` resolvers. `ExchangeRateService`
stays separate — pairwise/multi-quote-per-row; it is the fiat bridge, not a per-instrument
series.
