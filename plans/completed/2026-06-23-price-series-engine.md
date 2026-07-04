# Sub-project B: Shared stock/crypto price-series engine

Date: 2026-06-23
Branch: `price-series-engine` (built on Sub-project A, already merged)
Status: Design spec — implementation not started

## 0. One-paragraph summary

`StockPriceService` and `CryptoPriceService` independently implement the
same daily-price-series orchestration: cap the requested date at yesterday,
hydrate the per-instrument cache from SQL on first touch, check the in-memory
cache, extend the cache contiguously toward the requested date/endpoints with a
bounded `ContiguousFetchPlanner` window loop, carry the last-known close forward
across non-trading days, and write back only the changed delta rows (plus a meta
row) inside one `database.write` with a `notifyRateCacheChange` notify. This spec
extracts that ~85%-identical orchestration into **default methods on an
`Actor`-constrained protocol** (`PriceSeriesOrchestrating`) that both service
actors conform to — the shared code runs `self`-isolated and mutates
`self.caches[key]` per key exactly as the actors do today (no whole-dict
snapshot, so concurrent different-instrument calls never clobber each other).
It is parameterised by **three plugs** (protocol requirements) that capture the
genuine differences: provider fetch, per-instrument quote denomination, and an
optional first-trade floor. The two cache tables stay byte-for-byte as they are
(no schema migration), `ExchangeRateService` is untouched, and both services keep
their existing public APIs so Sub-project A's `PriceSource` resolvers
(`StockPriceSource`, `CryptoPriceSource`) keep working unchanged. The extraction
is neutral on conversion/aggregation results and on the crypto suites; it also
folds in one small intentional correctness fix — the stock carry-forward series'
day-stepping moves from host-local to `Calendar.utc` (crypto's already-correct
choice), fixing a timezoneless-date bug.

---

## 1. Background — what is duplicated, and the three real differences

### 1.1 The shared orchestration shape

Both services already share the lower layers introduced by the
contiguous-extension work (`plans/2026-06-17-contiguous-price-cache-extension-*`):

- `Shared/SortedDateSeries.swift` — the `DateKey`-keyed `exact` / `floor`
  binary-search store both caches hold in `prices`.
- `Shared/ContiguousFetchPlanner.swift` — `nextWindow(earliest:latest:requested:today:config:)`,
  the pure-arithmetic boundary-anchored window planner. **Both** services call it
  with the identical `Config(windowDays: 30, forwardBuffer: 2)`.
- `Shared/PriceCacheCap.swift` — `cappedToYesterday(_:now:timeZone:)`, the
  same cap used by both (and by `ExchangeRateService`).

What is *not* shared, and is duplicated almost line-for-line, is the
orchestration that drives those helpers. The parallel structure:

| Concern | Stock | Crypto |
| --- | --- | --- |
| Single-price entry | `price(ticker:on:)` — `StockPriceService.swift:52` | `price(for:mapping:on:)` — `CryptoPriceService.swift:220` |
| Cap at yesterday | `cappedDate` → `cappedToYesterday` — `StockPriceService.swift:53,141` | `cappedToYesterday(...)` — `CryptoPriceService.swift:225` |
| In-memory exact lookup | `lookupPrice(ticker:dateString:)` — `StockPriceService.swift:57,145` | `lookupPrice(tokenId:dateString:)` — `CryptoPriceService.swift:229,352` |
| Hydrate-on-first-touch | `loadCache(ticker:)` + `hydratedTickers` — `StockPriceService.swift:62,219` | `loadCache(tokenId:)` + `hydratedTokenIds` — `CryptoPriceService+Persistence.swift:17`, `CryptoPriceService.swift:233` |
| Prior-trading-day fallback | `fallbackPrice` (`.floor`) — `StockPriceService.swift:150` | `fallbackPrice` (`.floor`) — `CryptoPriceService.swift:357` |
| Contiguous single-price extend | `fetchToCoverDate` — `StockPriceService+FetchRange.swift:22` | `extendContiguously` — `CryptoPriceService+FetchRange.swift:14` |
| Contiguous range cover | `coverRangeContiguously` — `StockPriceService+FetchRange.swift:78` | `coverRangeContiguously` / `extendOneDirection` — `CryptoPriceService+FetchRange.swift:77,117` |
| `boundsKeys` | `StockPriceService+FetchRange.swift:58` | `CryptoPriceService+FetchRange.swift:234` |
| Carry-forward result series | `buildResultSeries` + `generateDateSeries` — `StockPriceService.swift:157,171` | inline loop + `generateDateSeries` — `CryptoPriceService.swift:321,364` |
| Merge → delta | `mergeReturningDelta(ticker:instrument:newPrices:)` — `StockPriceService+Merge.swift:18` | `mergeReturningDelta(tokenId:symbol:newPrices:)` — `CryptoPriceService+Merge.swift:17` |
| Persist delta + meta + notify | `persistDelta(ticker:deltaRecords:)` — `StockPriceService.swift:279` | `persistDelta(tokenId:deltaRecords:)` — `CryptoPriceService+Persistence.swift:93` |
| Range entry | `prices(ticker:in:)` — `StockPriceService.swift:93` | `prices(for:mapping:in:)` — `CryptoPriceService.swift:288` |

The merge logic (`StockPriceService+Merge.swift` vs `CryptoPriceService+Merge.swift`)
is *identical* apart from the record type (`StockPriceRecord` vs `CryptoPriceRecord`)
and the meta-bounds field, and both round-trip `Decimal → Double` via
`NSDecimalNumber(decimal:).doubleValue`. The window loops in
`fetchToCoverDate`/`extendContiguously`/`coverRangeContiguously`/`extendOneDirection`
share the same `guardSteps < 250` bounded structure, the same no-progress break,
and the same `Config(windowDays: 30, forwardBuffer: 2)`.

### 1.2 The three genuine differences (do NOT force-merge these)

1. **Provider-fetch.** Stock has ONE client (`StockPriceClient`,
   `Domain/Repositories/StockPriceClient.swift`) returning a
   `StockPriceResponse` (prices + the discovered listing `instrument`). Crypto
   has a **4-provider fallback chain** (`[CryptoPriceClient]`, ordered
   CoinGecko→CryptoCompare→Binance→DefiLlama in production) implemented in
   `CryptoPriceService+FetchRange.swift:301 fetchRange`, with per-provider
   error classification (`noProviderMapping` skip, `WalletSyncError` key-failure
   skip, `RateLimitGateError.cooldown` for warming, operational-error capture),
   plus per-window request **coalescing** (`fetchWindowCoalesced`,
   `extensionTasks`, `CryptoPriceService.swift:34`). Stock has no coalescing and
   no fallback chain.

2. **Quote / denomination.** A stock's price is denominated in its **listing
   currency**, discovered from the API and stored in `stock_ticker_meta.instrument_id`
   (e.g. `AUD` for `BHP.AX`), reconstructed on load via `Instrument.fiat(code:)`
   (`StockPriceService.swift:244`). The denomination is *per-instrument and
   discovered at fetch time* — `StockPriceService.instrument(for:)` exposes it
   (`StockPriceService.swift:126`), and `StockPriceSource.quote(on:)` returns it
   as `nativeQuote`. A crypto token's price is **always USD** (`crypto_price.price_usd`,
   `CryptoPriceSource` returns `nativeQuote: .USD` unconditionally). Crypto's meta
   `symbol` is display-only and never feeds the quote.

3. **First-trade floor.** Crypto has a confirmed cross-provider first-trade date
   (`CryptoPriceCache.firstTradedOn`, `crypto_token_meta.first_traded_on`) that:
   (a) short-circuits a strictly-earlier request to
   `CryptoPriceError.beforeFirstTrade` (`CryptoPriceService.swift:244`), which the
   `priceLookup` seam maps to `.knownZero` for pre-listing airdrops; and (b) is
   *confirmed and persisted* when a backward window walk exhausts with no error
   (`confirmFirstTradedOnIfExhausted` → `persistFirstTradedOn`,
   `CryptoPriceService+FetchRange.swift:218`, `+Persistence.swift:61`). Stock has
   **no** first-trade concept — a pre-IPO date just falls through to
   `noPriceAvailable`.

These three are real, load-bearing differences. The rest is mechanically
identical and is what we extract.

### 1.3 Why `ExchangeRateService` is out of scope (stated, not redesigned)

`exchange_rate` is keyed `PRIMARY KEY (base, date, quote)` — it stores **many
quote currencies per base per day** in one logical series
(`ProfileSchema+RateCaches.swift:38`). That is a pairwise/multi-quote bridge, not
a single value-per-instrument-per-day series. The shared engine here models one
`Decimal` value per `(instrumentKey, DateKey)`. Forcing FX into it would twist
the engine into knots (its row shape, its meta table, and its multi-quote fetch
have no analogue in the price services). `ExchangeRateService` stays exactly as
it is and is **not** touched by this sub-project.

---

## 2. Design — `PriceSeriesOrchestrating`

### 2.1 Shape decision: shared orchestration as default methods on an `Actor`-constrained protocol

**Decision: the shared orchestration lives in a protocol extension on an
`Actor`-constrained protocol — `protocol PriceSeriesOrchestrating: Actor` — that
both `StockPriceService` and `CryptoPriceService` conform to. The shared
`price(...)` / `prices(...)` and their internals are *default implementations* in
that extension. They run actor-isolated on `self` and mutate `self.caches[key]`
and `self.hydrated` directly, exactly as the two actors do today — per-key, never
a whole-collection snapshot. The "three plugs" become protocol requirements the
two actors satisfy.**

Rationale — this is the only shape that preserves the actors' current
per-key-mutation re-entrancy contract:

- **No whole-dict snapshot ⇒ no concurrent-different-instrument data race.** The
  rejected snapshot/`defer`-writeback design (an earlier draft) copied the entire
  `caches` dict at method entry and restored it at exit. Under the
  batch/daily-balance conversion walk — which calls `price(for:on:)` for many
  tokens *concurrently* — call A snapshots, suspends at an `await`, call B
  snapshots the same pre-A dict, both mutate their own copy, and the last `defer`
  write-back clobbers the other's committed update, **dropping a token's cache
  entry**. The current actors avoid this precisely because they mutate
  `self.caches[key]` per key on the actor, so a re-entrant call observes every
  committed mutation at each suspension point. Default methods on an
  `Actor`-constrained protocol keep that exact behaviour: the shared code is
  `self`-isolated and touches only the single `[key]` it is working on. There is
  no aggregate to snapshot and no `inout` collection to alias.

- **Actor isolation stays clean and unchanged.** The two services remain
  `actor StockPriceService` / `actor CryptoPriceService`. Conformance to
  `PriceSeriesOrchestrating` makes the shared methods run on each actor's own
  isolation; `self.caches` / `self.hydrated` are the actors' existing stored
  properties. No second actor, no second isolation domain, no extra hop.

- **Public APIs are untouched.** The conformance is additive. `price(ticker:on:)`,
  `prices(ticker:in:)`, `instrument(for:)`, `price(for:on:)`,
  `price(for:mapping:on:)`, `prices(for:mapping:in:)`, `registration(for:)`,
  `purgeCache`, `currentPrices`, `prefetchLatest`, and `warmRange` keep their
  exact signatures and actor isolation. The public `price`/`prices` methods become
  thin call-throughs to the protocol-default orchestration (see §2.6). Sub-project
  A's resolvers call the same entry points.

- **Behaviour-neutral by construction.** The window loop, the cap, the
  carry-forward, and the merge are moved *verbatim* into the protocol extension;
  the per-key mutation site is identical to today's. No semantics change, so the
  existing suites pass unchanged.

Rejected alternative 1 — the non-actor `struct` engine driven via
`inout PriceSeriesState`: unsafe, as above (whole-dict snapshot clobbers
concurrent different-instrument updates). Not used.

Rejected alternative 2 — a generic `actor PriceSeriesEngine<Plugs>` that the
services *wrap*: this would force the cache state to live inside the engine
actor, which then has to re-expose `purgeCache`, `firstTradedOn` confirmation,
`extensionTasks` coalescing, and the stock `instrument(for:)` accessor back out
through the wrapping actor — adding a second actor hop on every call and a second
isolation domain to reason about, for no behavioural gain. It also complicates
Sub-project A's resolvers (they'd be one more hop from the data). The
protocol-default approach keeps exactly one actor per service and one isolation
domain.

#### Swift-6 obstacle and the resolution

An `Actor`-constrained protocol **can** declare mutable stored-property
requirements (`var caches: [String: Cache] { get set }`); the actor satisfies
them with its existing stored properties, and any access from a protocol-default
method is actor-isolated because the protocol refines `Actor`. The one thing a
protocol *cannot* do is force the requirement to be backed by stored (rather than
computed) storage — but that is irrelevant here: each actor already has the
stored property, and the default methods only need `get`/`set` access through the
requirement. The associated cache type is an `associatedtype Cache: PriceSeriesCache`
(stock → `StockPriceCache`, crypto → `CryptoPriceCache`). All plug requirements
are ordinary `async`/non-`async` methods on the actor, so they inherit `self`
isolation with no `Sendable`-of-mutable-state hazard. No part of the shared code
escapes a reference to the collection.

### 2.2 The protocol requirements (the cache accessors + three plugs)

`PriceSeriesOrchestrating` declares the state the shared methods read/mutate and
the three plugs. The two cache **structs** are abstracted over the fields the
shared code needs (it does NOT abstract the table — see §2.4):

```swift
protocol PriceSeriesCache: Sendable, Equatable {
  var earliestDate: String { get set }   // "YYYY-MM-DD"
  var latestDate: String { get set }
  var prices: SortedDateSeries<Decimal> { get set }
}

protocol PriceSeriesOrchestrating: Actor {
  associatedtype Cache: PriceSeriesCache

  // — Cache state, mutated per-key by the shared default methods on `self`.
  //   Satisfied by each actor's existing stored properties; no snapshot.
  var caches: [String: Cache] { get set }          // keyed ticker / tokenId
  var hydrated: Set<String> { get set }

  // — Injected clock / zone / formatting (already on both actors).
  var now: @Sendable () -> Date { get }
  var timeZone: TimeZone { get }
  var dateFormatter: ISO8601DateFormatter { get }
  var plannerConfig: ContiguousFetchPlanner.Config { get } // {30, 2} for both

  // — Plug 1: provider fetch + merge + persist for one window (see §2.3).
  func fetchAndMerge(instrumentKey: String, window: ClosedRange<Date>) async throws

  // — Plug 2: per-instrument quote / denomination (see §2.3).
  func quote(for instrumentKey: String) -> Instrument?

  // — Plug 3: optional first-trade floor (see §2.3).
  func firstTradeFloor(for instrumentKey: String) -> String?     // nil for stock
  func confirmFirstTradeOnBackwardExhaustion(
    instrumentKey: String, lastFetchError: (any Error)?) async throws  // no-op for stock

  // — Hydration plug: per-service `loadCache` (different meta shapes; see §2.4).
  func hydrate(instrumentKey: String) async throws

  // — Error factories so the shared code stays free of service-specific errors.
  func belowFloorError(instrumentKey: String, date: String) -> any Error  // crypto → beforeFirstTrade
  func noPriceError(instrumentKey: String, date: String) -> any Error
}
```

(`hydrated` is the existing `hydratedTickers` / `hydratedTokenIds` set, renamed
behind the requirement; the actors keep their own property name and satisfy the
requirement with a computed alias if preferred, or rename the stored property.)

`StockPriceCache` and `CryptoPriceCache` each get a one-line `PriceSeriesCache`
conformance extension (one-extension-per-protocol, per the code guide). The
crypto-only `firstTradedOn` and the stock-only `instrument` / crypto `symbol`
stay on the concrete structs and are reached only through the plugs, not the
`PriceSeriesCache` protocol.

### 2.3 The three plugs (precise definitions)

The plugs are the protocol requirements from §2.2 — `async`/non-`async` methods
on the conforming actor, so each runs `self`-isolated with no
`Sendable`-of-mutable-state hazard. The shared default methods call them; the two
actors implement them by wrapping their existing per-service code.

**Plug 1 — provider fetch + merge.** `func fetchAndMerge(instrumentKey:window:)`.
This is the seam that hides the single-client-vs-fallback-chain difference. It is
given a window `[from, to]` and is responsible for fetching, merging into
`self.caches[instrumentKey]`, and persisting the delta. The shared loop re-reads
`boundsKeys(instrumentKey:)` afterward to decide progress, so the plug returns
nothing — it just mutates the cache on `self`. It throws on a genuine provider
failure.

- Stock's implementation wraps the existing `fetchAndMerge(ticker:from:to:)`
  body (`StockPriceService.swift:193`): one `client.fetchDailyPrices`, skip on
  empty, `mergeReturningDelta`, `persistDelta`. No coalescing.
- Crypto's implementation wraps `fetchWindowCoalesced` →
  `fetchRange` (`CryptoPriceService+FetchRange.swift:257,301`): the
  `extensionTasks` coalescing table + the ordered fallback chain + the error
  classification. `extensionTasks` stays on the `CryptoPriceService` actor and
  is touched only inside this plug.

The shared code calls only `fetchAndMerge` and then re-reads bounds to decide
progress — it never needs to know how many providers were tried. Because the plug
runs on the same actor and mutates `self.caches[instrumentKey]` per key (not a
snapshot), a concurrent call for a *different* instrument is unaffected.

**Plug 2 — per-instrument quote / denomination.** `func quote(for instrumentKey:)`.
Resolves the instrument's quote (denomination) so callers get the right
`nativeQuote`.

- Stock: returns `caches[ticker]?.instrument` — the listing currency discovered
  from the API and stored in `stock_ticker_meta.instrument_id`, reconstructed via
  `Instrument.fiat(code:)`. Backs the read-side accessor `instrument(for:)`
  (`StockPriceService.swift:126`).
- Crypto: returns `.USD` — always.

In practice the quote arrives *with* the fetched data for stocks (the API reports
it on `StockPriceResponse.instrument`) and is recorded during merge exactly as
today; the plug is the explicit read seam so the shared code never embeds the
"always USD" constant — it is told.

**Plug 3 — optional first-trade floor.** Two methods, both no-ops for stock:

```swift
func firstTradeFloor(for instrumentKey: String) -> String?               // nil for stock
func confirmFirstTradeOnBackwardExhaustion(
  instrumentKey: String, lastFetchError: (any Error)?) async throws       // no-op for stock
```

- `firstTradeFloor` — crypto returns `caches[tokenId]?.firstTradedOn`; stock
  returns `nil`. The shared code consults it at exactly the two points the crypto
  path uses it today (`CryptoPriceService.swift:244` pre-fetch short-circuit and
  `CryptoPriceService+FetchRange.swift:190` post-extension). When the requested
  date is strictly below a non-nil floor, the shared code throws
  `belowFloorError(instrumentKey:date:)` — crypto maps that to
  `CryptoPriceError.beforeFirstTrade`; stock supplies a factory that is never
  invoked because its floor is always `nil`.
- `confirmFirstTradeOnBackwardExhaustion` — called from inside the shared window
  loop at the exact `boundsKeys == before && wasBackward` point that exists today.
  Crypto wraps `confirmFirstTradedOnIfExhausted` / `persistFirstTradedOn`; stock
  is a no-op.

### 2.4 Table names and row mapping are passed in (tables stay separate)

The shared orchestration is explicitly **told** its persistence shape; it never
assumes one table. Persistence is fully owned by Plug 1's `fetchAndMerge` (which already
calls the service's own `persistDelta` writing to `stock_price`/`stock_ticker_meta`
or `crypto_price`/`crypto_token_meta` with the correct
`notifyRateCacheChange(.stockPrice)` / `(.cryptoPrice)`), and hydration
(`loadCache`) likewise stays per-service because it reads a different meta shape
(stock has `instrument_id`; crypto has `symbol` + `first_traded_on`). The shared
code calls the `hydrate(instrumentKey:)` plug (§2.2); each actor's
implementation is its existing `loadCache` body, which writes the hydrated
snapshot into `self.caches[instrumentKey]` and inserts into `self.hydrated`.

So **no schema change**: the two table pairs are untouched, the two `loadCache`
bodies are untouched (just invoked through the `hydrate` plug), and the two
`persistDelta` bodies are untouched (invoked inside Plug 1). The shared code owns
only the *orchestration between* them.

### 2.5 The shared default-method surface

The shared orchestration is a protocol extension on `PriceSeriesOrchestrating`.
Every method runs `self`-isolated on the conforming actor and mutates
`self.caches[instrumentKey]` per key:

```swift
extension PriceSeriesOrchestrating {
  // Single price: cap → exact → hydrate-once → exact → floor-check → in-range →
  // extend-contiguously → resolve-after-extension. Mutates self.caches[key].
  func price(instrumentKey: String, on date: Date) async throws -> Decimal { … }

  // Range: hydrate-once → cap upper → cover-range-contiguously(forward, back) →
  // carry-forward result series over the caller-supplied range.
  func prices(instrumentKey: String, in range: ClosedRange<Date>) async throws
              -> [(date: Date, price: Decimal)] { … }

  // The shared internals, moved verbatim from the two services and operating on
  // `self`: cappedDate, lookupPrice/exact, fallbackPrice/floor, inRangeFallback,
  // boundsKeys, the bounded window loops (single + range, fwd-then-back),
  // generateDateSeries, buildResultSeries.
}
```

Everything in that last comment block is the duplicated code from §1.1 lifted
once into the extension, with `caches[key]` reads/writes going through the actor's
own property via the protocol requirement — identical per-key mutation, no
snapshot.

**Date-stepping calendar is standardised on `Calendar.utc` (intentional
correctness fix).** `generateDateSeries` currently differs between the two: stock
steps with `Calendar(identifier: .gregorian)` — i.e. the **host-local** zone
(`StockPriceService.swift:158`); crypto steps with `Calendar.utc`
(`CryptoPriceService.swift:365`). The stock path is a timezoneless-date **bug**:
the range boundaries are UTC-anchored `Date`s and the day labels are formatted
through the shared UTC `dateFormatter`, but the *stepping* uses a local calendar,
so on a UTC-negative host adding a day can drift the emitted day label (the exact
class `guides/DATE_TIME_GUIDE.md` / the timezoneless-date seam,
`reference_timezoneless_date_seam`, warn against). The shared
`generateDateSeries` therefore uses **one `Calendar.utc`** for both services —
crypto's already-correct choice. This is a small, intentional correctness fix
folded into the extraction, not a behaviour regression: with UTC-anchored range
boundaries (as all the suites use) the emitted day set is identical on a UTC
host and now also correct on any other host.

### 2.6 Each service becomes a thin wrapper

`StockPriceService` keeps its stored `client`, `caches` (now satisfying the
`caches` requirement), `hydrated` (its renamed `hydratedTickers`), `database`,
`now`, `timeZone`, `dateFormatter`, `logger`, and its public methods. It declares
`conformance to PriceSeriesOrchestrating` (with `typealias Cache = StockPriceCache`)
and implements the plugs by wrapping its existing per-service code. Its public
entry points become one-liners onto the shared default methods:

```swift
func price(ticker: String, on date: Date) async throws -> Decimal {
  try await price(instrumentKey: ticker, on: date)   // shared default, self-isolated
}
func prices(ticker: String, in range: ClosedRange<Date>) async throws
            -> [(date: Date, price: Decimal)] {
  try await prices(instrumentKey: ticker, in: range)
}
```

There is no snapshot and no `defer` write-back — the shared method runs on the
actor and mutates `self.caches[ticker]` directly, exactly as the original body
did. `instrument(for:)` stays a per-service accessor reading `caches[ticker]?.instrument`
(it is also Plug 2). `CryptoPriceService` conforms identically
(`typealias Cache = CryptoPriceCache`), routing `price(for:mapping:on:)` and
`prices(for:mapping:in:)` onto the shared defaults; `price(for:on:)` /
`registration(for:)` (Sub-project A) stay exactly as they are, calling the thin
`price(for:mapping:on:)`. `purgeCache`, `currentPrices`, `prefetchLatest`,
`warmRange`, `priceLookup` stay per-service (see §3).

---

## 3. What stays per-service (deliberately NOT merged)

- **Provider clients + the crypto fallback chain + coalescing.** `fetchRange`'s
  ordered `[CryptoPriceClient]` walk, its `noProviderMapping` /
  `WalletSyncError` / `RateLimitGateError` / operational-error classification
  (`CryptoPriceService+FetchRange.swift:301`), and the `fetchWindowCoalesced` /
  `extensionTasks` machinery (`:257`, `CryptoPriceService.swift:34`). Stock's
  single-client `fetchAndMerge`. These live behind Plug 1.
- **Quote/denomination resolution.** Stock's `stock_ticker_meta.instrument_id` ⇄
  `Instrument.fiat(code:)` round-trip and `instrument(for:)`; crypto's constant
  `.USD`. Behind Plug 2.
- **First-trade.** `firstTradedOn`, `beforeFirstTrade`,
  `confirmFirstTradedOnIfExhausted`, `persistFirstTradedOn`. Behind Plug 3.
- **Hydration + persistence bodies.** The two `loadCache` and two `persistDelta`
  (+ `persistFirstTradedOn`) bodies — different meta shapes, different table
  names, different notify token. Invoked via the hydrate plug / inside the
  fetcher.
- **Sub-project A's resolution + metadata cache.** `registration(for:)`,
  `metadataCache`, `resolveRegistration`, `priceLookup`,
  `WrappedNativeContracts` wrapped-native redirection
  (`CryptoPriceService.swift:84,117,196`). Entirely above the engine — they
  call `price(for:mapping:on:)`, which the engine now backs, but they are not
  themselves merged.
- **Live / warming paths.** `currentPrices`, `prefetchLatest`
  (`CryptoPriceService+Live.swift`), and `warmRange` /
  `CryptoPriceWarmer` (`CryptoPriceService+Warming.swift`) — crypto-only,
  cooldown-aware, no stock analogue. They reuse the engine's `boundsKeys` /
  planner-loop *shape* but have their own `WarmOutcome` return and
  cooldown-surfacing, so they stay per-service. (Optional, low priority: warming
  could later share the engine's window loop via a `WarmOutcome`-returning
  variant of Plug 1; out of scope for the behaviour-neutral first cut — say so
  rather than twist the engine to fit.)

Display-symbol storage (`crypto_token_meta.symbol`) stays on the crypto cache and
meta; it is display-only and never enters the engine.

---

## 4. Behaviour preservation & risks

- **Carry-forward semantics.** `buildResultSeries` / the crypto inline loop are
  identical: walk the generated daily series, emit the exact close where present,
  else carry `lastKnownPrice` forward, emit nothing before the first known close.
  Moved verbatim. The one intentional change is `generateDateSeries` standardising
  on `Calendar.utc` (§2.5), which **fixes** the stock path's host-local stepping
  bug — the emitted day labels still come from the shared UTC `dateFormatter`, so
  over the UTC-anchored ranges the suites use the day set is identical on a UTC
  host and now correct on any host.
- **Date-capping.** `cappedToYesterday(_:now:timeZone:)` is called at the same
  points (single-price entry; range fetch upper bound). The shared code reads
  `now`/`timeZone` from the actor via the protocol requirements; tests pinning a
  `YYYY-MM-DD` label still pass an explicit zone.
- **`notifyRateCacheChange` + `WITHOUT ROWID` caveat.** Unchanged — persistence
  stays inside the per-service `persistDelta` / `persistFirstTradedOn` / `purgeCache`,
  each of which already calls `notifyRateCacheChange(.stockPrice)` /
  `(.cryptoPrice)` inside its `database.write`. The engine never writes SQL, so
  it cannot regress the `ValueObservation` notify contract
  (`ProfileSchema+RateCaches.swift:16-26`, `guides/DATABASE_CODE_GUIDE.md` §2).
- **First-trade gate.** The two floor consult points and the backward-exhaustion
  confirm-and-persist are reproduced exactly via Plug 3; the
  `beforeFirstTrade` → `.knownZero` mapping stays in `priceLookup`
  (`CryptoPriceService+PriceLookup.swift:40`), above the engine. Stock's floor is
  always nil so its loop is structurally identical to today's `fetchToCoverDate`.
- **Sub-project A `metadataCache` / `registration(for:)`.** Untouched; sits above
  `price(for:mapping:on:)`. `purgeCache`'s dual wrapped-native eviction
  (`CryptoPriceService.swift:117-161`) is unchanged.
- **Re-entrancy / concurrent different-instrument calls (the load-bearing
  correctness point).** The shared default methods mutate `self.caches[key]` per
  key on the actor — there is **no** whole-`caches` snapshot and no `inout`
  collection. So a concurrent `price(for:on:)` for token B (as the batch /
  daily-balance conversion walk issues constantly) cannot clobber token A's
  committed cache update: each call only ever writes its own `[key]` entry, and a
  re-entrant call observes every committed mutation at each suspension point —
  byte-for-byte the current actors' behaviour. This is the whole reason the
  protocol-default-on-`Actor` shape was chosen over the rejected snapshot design
  (§2.1). The `CryptoPriceServiceCoalescingTests` and the
  concurrent-conversion paths remain the proof.
- **Coalescing.** Crypto's `extensionTasks` coalescing stays on the
  `CryptoPriceService` actor inside Plug 1; the shared code drives one window at a
  time per instrument exactly as the loops do today, so the "one window fetch at a
  time per token" precondition (`fetchWindowCoalesced` doc,
  `CryptoPriceService+FetchRange.swift:255`) holds.
- **`guardSteps < 250`** bound and the warning log are preserved in the shared
  window loop.

---

## 5. Testing — the neutrality proof

The neutrality claim is: **conversion / aggregation results unchanged, crypto
suites unchanged, and stock date-series handling becomes UTC-correct.** The one
intentional change is the stock `generateDateSeries` host-local → `Calendar.utc`
fix (§2.5). The existing suites under `MoolahTests/Shared/` are the proof:

- Stock: `StockPriceServiceTests`, `StockPriceServiceFallbackTests`,
  `StockPriceServicePersistenceTests`.
- Crypto core: `CryptoPriceServiceTests`, `CryptoPriceServiceTestsMore`,
  `CryptoPriceServiceFallbackTests`, `CryptoPriceServiceBoundaryRangeTests`,
  `CryptoPriceServiceCapTests`, `CryptoPriceServicePersistenceTests`,
  `CryptoPriceServiceCoalescingTests` (re-entrancy/coalescing),
  `CryptoPriceServiceAttributionTests` (provider error attribution),
  `CryptoPriceServiceWarmRangeTests` (warming loop),
  `CryptoPriceServiceStablecoinTests`, `CryptoPriceServiceMetadataTests` (A),
  `CryptoPriceServicePriceLookupTests` (A's `priceLookup`/`knownZero`),
  `CryptoPreListingZeroTests` (first-trade → zero).
- Shared lower layers (must remain green, unchanged):
  `ContiguousFetchPlannerTests`, `SortedDateSeriesTests`.
- Integration downstream of the services:
  `MoolahTests/Backends/GRDB/PreListingDailyBalanceTests` (first-trade floor end
  to end), and `PriceSourceTests` (Sub-project A resolvers over the services).

**Stock date-series change.** Per `reference_pre_existing_date_flaky_tests`, the
price-service test harnesses were UTC-seam-fixed in #1051; verified here — the
stock suites pin the service's `timeZone` to `UTC`
(`StockPriceServiceTests.swift:21`, `StockPriceServiceFallbackTests.swift:42`) and
build range boundaries from a UTC-anchored `[.withFullDate]` parser
(`StockPriceServiceTests.swift:25`). So on the (UTC-pinned) CI host the
`generateDateSeries` → `Calendar.utc` change produces the **same** day set the
stock `results.count` assertions already encode — no expectation change is
expected. **Verify, don't assume:** run the stock suites; if any expected date
series shifts, that test was encoding the zone-fragile local behaviour — update it
to the correct UTC expectation (do NOT preserve the old behaviour) and flag the
change for the `datetime-review` agent. The stock date-series change gets a
`datetime-review` pass regardless, since it touches day-stepping.

New engine-level tests (write first, TDD):

- `PriceSeriesOrchestratingTests` — exercise the shared default methods on a
  minimal test actor conforming to `PriceSeriesOrchestrating` (a fake `Cache`, a
  fake fetcher plug mutating `self.caches[key]`, a fake clock) and assert the
  orchestration in isolation: cap-at-yesterday, hydrate-once, exact/floor lookup,
  bounded window loop no-progress break, carry-forward series over `Calendar.utc`,
  and the Plug-3 floor short-circuit + backward-exhaustion confirm hook firing at
  the right point. Crucially include a **concurrent two-instrument** test: two
  overlapping `price(...)` calls for different keys each suspending in the fetcher
  plug, asserting neither drops the other's cache entry — the regression test for
  the snapshot race the design avoids. Reusable by a future third instrument type.
- A focused test that Plug 2's `quote(for:)` returns the listing currency for a
  stock and `.USD` for crypto, asserting the `nativeQuote` contract both resolvers
  depend on (kept green via `PriceSourceTests`).

TDD order per `guides/TEST_GUIDE.md`: write `PriceSeriesOrchestratingTests`
against the new protocol first, then implement the shared extension, then make
each service conform and route its public methods onto the defaults one at a
time, running its suite green before the next.

---

## 6. Boundaries (hard constraints, restated)

- **No schema migration.** `stock_price` / `stock_ticker_meta` and
  `crypto_price` / `crypto_token_meta` stay exactly as defined in
  `Backends/GRDB/ProfileSchema+RateCaches.swift` (and the `WITHOUT ROWID` /
  `*_meta` ROWID split from later migrations). `StockPriceRecord` /
  `CryptoPriceRecord` unchanged.
- **`ExchangeRateService` untouched.** Out of scope (§1.3); it remains the
  pairwise fiat bridge.
- **Public APIs unchanged.** Both services keep every method signature and actor
  isolation; Sub-project A's `StockPriceSource` / `CryptoPriceSource` and
  `priceLookup` / `registration(for:)` keep working with no edits.
- **Behaviour-neutral on results.** Conversion / aggregation results and the
  crypto suites are unchanged; the one intentional change — stock
  `generateDateSeries` host-local → `Calendar.utc` — is a timezoneless-date
  correctness fix that gets a `datetime-review` pass (§5). It is expected to be a
  no-op on the UTC-pinned stock suites; any expected date series it does shift was
  encoding the zone-fragile local behaviour and is corrected, not preserved.
- **Conventions:** Swift 6 actors + `Sendable` (`guides/CONCURRENCY_GUIDE.md`);
  Swift Testing, not XCTest; one-extension-per-protocol; spec lives in `plans/`.
