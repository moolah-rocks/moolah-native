# Networking Architecture Realignment — Design

**Date:** 2026-05-21
**Status:** Approved (design), pending implementation plan
**Issue:** [#938](https://github.com/ajsutton/moolah-native/issues/938)
**Motivation:** `guides/CONCURRENCY_GUIDE.md` §4 says "All network requests go through `APIClient` — no direct `URLSession` outside the API client." There is no `APIClient` type in the codebase, and 11 HTTP clients each inject their own `URLSession`. The §4 rule is fictional and `concurrency-review` flags it as a pre-existing violation on every networking PR.

## Goal

Realign the codebase with a real, honest architecture that matches §4. Where the existing `Shared/Networking/` toolkit is the right shape, name it and tighten it; where it isn't (Alchemy's token-bucket, Blockscout's in-place retry), document the carve-out instead of pretending it doesn't exist. Then rewrite §4 so the rule matches the code.

## Context — what exists today

`Shared/Networking/` is a composable toolkit, not a centralized client:

- `RateLimitGate` — actor; host-wide reactive cooldown on 429/418/503 (`Retry-After` or exponential backoff).
- `FailedRequestCache` — actor; per-URL cooldown (5 min for HTTP errors, exponential backoff for transport errors).
- `URLSession+RateLimited.swift` — `dataRespectingRateLimit(for:gate:failureCache:)` extension that wraps `data(for:)` with the gate/cache machinery.
- `HTTPRetryPolicy`, `HTTPRetryClassifier`, `withRetry` — bounded retry-with-backoff for clients that need server-error retry in-place.

Adoption across the 11 callers falls into four shapes:

1. **Standard fetch (6 clients)** — `CryptoCompareClient`, `CoinGeckoClient`, `BinanceClient`, `FrankfurterClient`, `YahooFinanceClient`, `YahooFinanceStockSearchClient`. Each injects the same trio `(URLSession, RateLimitGate, FailedRequestCache)` and calls `session.dataRespectingRateLimit(…)`, then checks 2xx and throws `URLError(.badServerResponse)` on non-2xx.
2. **Reference-data fetch (2 callers)** — `CompositeTokenResolutionClient` (4 sites: coin list, exchange info, asset platforms, contract lookup) and `SQLiteCoinGeckoCatalog+Refresh`. Bare `session.data(for:)` with no gate. Three of these sites share hosts with group 1 (`min-api.cryptocompare.com`, `api.coingecko.com`, `api.binance.com`) but have their own gate-less call path, so a 429 from a group 1 client does not cool down these sites.
3. **Retry-driven RPC (1 client)** — `LiveBlockscoutClient`. `URLSession` + `HTTPRetryPolicy`/`withRetry` with an `HTTPRetryClassifier`. Server-error retry happens in-place because Blockscout has no fallback provider. Translates to a `WalletSyncError` vocabulary.
4. **Token-bucket RPC (1 client)** — `LiveAlchemyClient`. `URLSession` + a `RateLimiter` actor (25 req/s for the free tier). Different rate-limit shape from group 1; the gate doesn't model paid-tier req/s.

`CoinstashClient` is a fifth, separate shape: it injects a `Transport` closure rather than a `URLSession`. Out of scope here.

Tests across all four shapes plumb an ephemeral `URLSession` whose `protocolClasses` lists `StubURLProtocol`, so the session-injection seam is load-bearing for test isolation.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Centralize vs strengthen composition | Strengthen composition. The toolkit shape is the honest abstraction; centralizing into one `APIClient` with strategy enums would either flatten genuine variation (per-client error vocab, distinct rate-limit/retry models) or rename the toolkit without changing it. |
| Migration scope | Groups 1 + 2: the 6 standard clients, `CompositeTokenResolutionClient` (4 sites), and `SQLiteCoinGeckoCatalog+Refresh`. Groups 3 and 4 (Blockscout, Alchemy) stay as-is with documented rationale. |
| Gate ownership | One `RateLimitGate` per **host**, shared across every caller of that host. Owned by a **process-wide** `NetworkingServices` instance (not per-profile — remote services don't know about profiles, so a 429 should cool down every profile's caller of that host). |
| `FailedRequestCache` ownership | One cache per process, owned by `NetworkingServices`. The cache is already keyed by absolute URL, so it doesn't need per-host bucketing. |
| Singleton shape | No `static let shared`. `NetworkingServices` is constructed once in `MoolahApp+Setup` and injected like every other dependency — held by `SessionManager` for the app's lifetime. Tests get fresh instances per test. |
| `URLSession.dataRespectingRateLimit` extension | Retire. Its logic moves into `RateLimitedHTTPClient.data(for:)`. The extension on a foreign type was a workaround for not having a value type to host the logic. |
| HTTP status validation | Move out of every caller and into `RateLimitedHTTPClient.data(for:)`. The new method returns `(Data, HTTPURLResponse)` on 2xx and throws `URLError(.badServerResponse)` on non-2xx — matching the exact pattern every group 1 client implements today. |

## Architecture & Components

### `RateLimitedHTTPClient` (new, `Shared/Networking/`)

```swift
/// Composes URLSession + per-host RateLimitGate + (process-shared)
/// FailedRequestCache. Bound to one host at construction time. The
/// gate is keyed by host inside `NetworkingServices` — two callers
/// of the same host share the same gate, so a 429 from one cools
/// the other down.
///
/// Validates 2xx and returns HTTPURLResponse so callers no longer
/// have to repeat the `(200...299).contains(http.statusCode)` check.
struct RateLimitedHTTPClient: Sendable {
  private let session: URLSession
  private let gate: RateLimitGate
  private let failureCache: FailedRequestCache

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
```

`data(for:)` is the only public method. Its behavior is the same set of cases the retired `URLSession+RateLimited` extension covers:

- Cooldown short-circuit (gate or cache) → throws `RateLimitGateError.cooldown` or `FailedRequestCacheError.cooldown`.
- Transport failure (DNS, offline, timeout, hangup, not cancellation) → records to the cache, rethrows.
- 2xx → records success on gate + cache, returns `(Data, HTTPURLResponse)`.
- 429 / 418 → trips the gate, records on cache, throws `RateLimitGateError.cooldown`.
- 503 with `Retry-After` → trips the gate the same way.
- Other non-2xx (4xx, 5xx without `Retry-After`) → records on cache, throws `URLError(.badServerResponse)`. **This last case is a behavior change** — today the extension returns the `(data, response)` and lets the caller throw. Folding the status check in is the DRY-out. The error vocabulary stays `URLError(.badServerResponse)` to match what every caller throws today.
- Cancellation (`CancellationError` or `URLError(.cancelled)`) → propagates without muting the URL.

### `NetworkingServices` (new, `Shared/Networking/`)

```swift
/// Process-wide registry. Owns one RateLimitGate per host (created
/// lazily on first lookup) and one FailedRequestCache for the process.
/// Hands out RateLimitedHTTPClient instances bound to the requested host.
///
/// Constructed once in MoolahApp+Setup and injected through
/// SessionManager → ProfileSession → factories. Tests construct
/// their own instance with an ephemeral URLProtocol-backed session.
final class NetworkingServices: Sendable {
  init(session: URLSession = .shared)

  func client(forHost host: String) -> RateLimitedHTTPClient
}
```

Internals: holds the `URLSession`, a `FailedRequestCache`, and an actor-isolated `[String: RateLimitGate]` for the per-host gate registry. `client(forHost:)` returns a small `Sendable` value bound to the host's gate, so the request hot path doesn't re-traverse the actor — it talks directly to the gate it was given at construction time.

The gate registry is **lazy by host** because we don't statically know which hosts will be touched (CoinGecko has both Pro and free hosts, Yahoo has multiple subdomains). Lazy creation keeps the registry empty for hosts that are never hit. Host keys are normalised to lower-case so `Api.CoinGecko.com` and `api.coingecko.com` share a gate.

**Host-mismatch discipline.** `RateLimitedHTTPClient` does not validate that the request URL's host matches the host it was bound to — the gate would still work (it doesn't care which host it was created for), but the wrong gate would track the wrong host's rate-limit state. The implementation plan can decide whether to add a runtime assertion (debug-only) or rely on caller discipline. The current code has the same footgun and has not produced bugs.

### Single-host clients — take a `RateLimitedHTTPClient`

```swift
struct CryptoCompareClient: CryptoPriceClient, Sendable {
  private let http: RateLimitedHTTPClient
  init(http: RateLimitedHTTPClient) { self.http = http }

  func dailyPrices(…) async throws -> [String: Decimal] {
    let url = Self.histodayURL(…)
    let (data, _) = try await http.data(for: URLRequest(url: url))
    return try Self.parseHistodayResponse(data)
  }
}
```

Same shape for the other 5 group-1 clients and for `SQLiteCoinGeckoCatalog+Refresh`. Loses 3 lines of constructor boilerplate and 3 lines of status-check boilerplate per request.

### Multi-host caller — takes a `NetworkingServices`

```swift
struct CompositeTokenResolutionClient: TokenResolutionClient, Sendable {
  private let networking: NetworkingServices
  …

  private func fetchCoinListData() async throws -> Data {
    if let preloaded = preloadedCoinList { return preloaded }
    let http = networking.client(forHost: "min-api.cryptocompare.com")
    let (data, _) = try await http.data(for: URLRequest(url: CryptoCompareClient.coinListURL()))
    return data
  }
  // fetchExchangeInfoData → api.binance.com
  // fetchAssetPlatforms   → api.coingecko.com / pro-api.coingecko.com
}
```

`Composite` resolves its client per request because its three reference-data endpoints live on three different hosts. The cost of this lookup (a struct construction backed by a `Dictionary` read inside an actor) is irrelevant against the cost of the HTTPS round-trip that follows.

After this migration, a CryptoCompare 429 on the price-fetch path **does** cool down `Composite.fetchCoinListData()` (same host) and vice versa — closing the gap that motivated picking group 2 into scope.

### Factory wiring (`App/`, `ProfileSession+Factories.swift`)

```swift
// MoolahApp+Setup.makeSessionManager (called once at app launch)
let networking = NetworkingServices()
let sessionManager = SessionManager(
  containerManager: setup.manager,
  profileIndexRepository: setup.manager.profileIndexRepository,
  syncCoordinator: coordinator,
  networking: networking)   // ← new required parameter

// ProfileSession+Factories.makeMarketDataServices
static func makeMarketDataServices(
  database: any DatabaseWriter,
  networking: NetworkingServices    // ← new required parameter
) -> MarketDataServices {
  let yahooClient = YahooFinanceClient(
    http: networking.client(forHost: "query1.finance.yahoo.com"))
  …
}
```

`NetworkingServices` flows: `MoolahApp+Setup` → `SessionManager` → `ProfileSession.init` → `ProfileSession+Factories`. Every client construction site becomes "ask the registry for a host-bound client" instead of "default-construct a gate and cache here."

### Untouched callers (with documented carve-outs)

- **`LiveBlockscoutClient`** — keeps `URLSession` + `HTTPRetryPolicy`/`withRetry`. Carve-out: server-error retry happens in-place because Blockscout has no fallback provider, which doesn't match the gate model. Constructor gains a `// see guides/CONCURRENCY_GUIDE.md §4 shape 3` reference.
- **`LiveAlchemyClient`** — keeps `URLSession` + `RateLimiter`. Carve-out: paid-tier 25 req/s throttling needs a token-bucket model, not host-wide 429 cooldown. Same reference comment.
- **`CoinstashClient`** — keeps its `Transport` closure shape. Out of scope (different test-injection seam).

## Test impact

The session-injection seam stays at the boundary, just one level up:

```swift
// Today
let session = URLSession(configuration: { … StubURLProtocol … })
let client = CryptoCompareClient(session: session)

// After
let session = URLSession(configuration: { … StubURLProtocol … })
let networking = NetworkingServices(session: session)
let client = CryptoCompareClient(
  http: networking.client(forHost: "min-api.cryptocompare.com"))
```

Each test gets its own `NetworkingServices` instance → its own gate registry and failure cache → fully isolated, no global mutable state across tests.

`MoolahTests/Shared/URLSessionRateLimitTests.swift` is renamed to `MoolahTests/Shared/RateLimitedHTTPClientTests.swift` and asserts the same set of cases against the new entry point (cooldown short-circuit on gate, cooldown short-circuit on cache, 2xx happy path with gate + cache success recording, 429 trips gate, 503 + `Retry-After` trips gate, transport failure records to cache, **non-2xx now throws `URLError(.badServerResponse)`** instead of returning the response, cancellation propagates without muting the URL). `FailedRequestCacheTests` and `RateLimitGateTests` are unchanged — they test the actors directly and don't go through the new client.

`SessionManager` and `ProfileSession` test fixtures (currently in `MoolahTests/App/ProfileSessionTests.swift` and similar) gain a `networking` parameter; existing fixtures pass a default-constructed `NetworkingServices(session: .ephemeralStub())`. Production code paths require it (no `nil` default).

## Documentation impact — `guides/CONCURRENCY_GUIDE.md` §4

§4 is rewritten end-to-end. The new shape:

1. **Sanctioned shape #1 — standard fetch.** Inject `RateLimitedHTTPClient`, one client per host. Status validation, host-shared rate-limit gate, per-URL failure cache, all handled by the type. Tests construct via `NetworkingServices(session: stub)`. Used by 6 single-host clients + `SQLiteCoinGeckoCatalog+Refresh`.
2. **Sanctioned shape #2 — multi-host caller.** Inject `NetworkingServices`; resolve `client(forHost:)` per request. Used when a single component bridges hosts (`CompositeTokenResolutionClient`).
3. **Sanctioned shape #3 — retry-driven RPC.** Inject `URLSession` + `HTTPRetryPolicy`; compose with `withRetry(policy:classify:)` and a provider-specific `HTTPRetryClassifier`. Rationale: server-error retry in-place doesn't fit the gate model. Used by Blockscout.
4. **Sanctioned shape #4 — token-bucket RPC.** Inject `URLSession` + a `RateLimiter` actor. Rationale: paid-tier req/s throttling is shaped differently from 429-driven host cooldown. Used by Alchemy.

The anti-pattern row (today line 518) becomes: "raw `URLSession.shared.data(for:)` in production code outside the four sanctioned shapes — route through one of them." The `concurrency-review` agent's check changes from "look for `URLSession` outside `APIClient` (which doesn't exist)" to "look for `URLSession.data(for:)` in production code outside one of the four shapes."

`§2`'s example block (lines 96-105) — the `RemoteAccountRepository` over `APIClient` — is replaced with one of the four real shapes (probably shape 1, since it's the most common). The `Sendable` carve-outs table is unaffected.

## Implementation order

Each row is a separate PR. The first must land before the rest (it introduces the types); 2-4 can land in any order; 5 is the wiring step; 6 closes #938 and is just docs.

1. **Introduce the types.** Add `RateLimitedHTTPClient` and `NetworkingServices` under `Shared/Networking/`. Move the logic from `URLSession+RateLimited` into `RateLimitedHTTPClient.data(for:)`. Retire the extension. Move the extension tests to `RateLimitedHTTPClientTests` and assert the new non-2xx throw behavior. No call-site migrations yet — the new types are introduced ahead of consumers so the migration PRs can be small.
2. **Migrate the 6 standard clients.** `CryptoCompareClient`, `CoinGeckoClient`, `BinanceClient`, `FrankfurterClient`, `YahooFinanceClient`, `YahooFinanceStockSearchClient`. Each loses its `(session, rateLimitGate, failureCache)` constructor and gains a `http: RateLimitedHTTPClient` one. Each test file updates to construct `NetworkingServices(session: stub)` and pass `networking.client(forHost: …)`. One bundled PR per the user's preference for refactors-in-this-area; reviewable per-file in the diff.
3. **Migrate `CompositeTokenResolutionClient`.** Constructor takes `NetworkingServices`. Four call sites in the body switch to `networking.client(forHost: …).data(for: …)`. Tests in `CompositeTokenResolutionClientTests.swift` get a `NetworkingServices` instance backed by `StubURLProtocol`.
4. **Migrate `SQLiteCoinGeckoCatalog+Refresh`.** `refresh(session:…)` → `refresh(http:…)`. Single host (CoinGecko), so a `RateLimitedHTTPClient` is fine; the call site that invokes refresh asks for the CoinGecko host at construction time.
5. **Wire `NetworkingServices` into the app.** Add the `networking: NetworkingServices` parameter to `SessionManager.init`, `ProfileSession.init`, and each factory under `ProfileSession+Factories`. Construct the singleton in `MoolahApp+Setup.makeSessionManager`. Default `NetworkingServices(session: .shared)`; tests inject their own.
6. **Rewrite `guides/CONCURRENCY_GUIDE.md` §4.** Replace the §4 body with the four sanctioned shapes. Update the `§2` `RemoteAccountRepository` example. Update the anti-pattern table row for "URLSession outside APIClient" → "URLSession outside the four sanctioned shapes." Add carve-out notes pointing at Blockscout and Alchemy as shapes 3 and 4. Closes #938.

Each PR is independently buildable on top of `main`. PRs 2-4 each compile against PR 1; PR 5 compiles against 1-4; PR 6 is text-only.

## Non-goals

- **No new retry behavior in `RateLimitedHTTPClient`.** The shape stays equivalent to today's `dataRespectingRateLimit`. Adding `withRetry` to the standard fetch path is a separate decision tracked in `2026-05-17-http-timeout-retry-design.md` and is not what #938 is asking for.
- **No change to `LiveAlchemyClient` or `LiveBlockscoutClient`.** Their custom shapes are sanctioned by the new §4, not migrated.
- **No change to `CoinstashClient`'s `Transport` closure pattern.** Different test-injection seam; out of scope.
- **No process-wide `static let shared`.** The architecture deliberately threads `NetworkingServices` through DI instead of relying on a global; the singleton is by instance lifetime, not by static reference.
