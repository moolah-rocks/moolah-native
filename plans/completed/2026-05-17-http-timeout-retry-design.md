# HTTP Timeout + Retry Component — Design

**Date:** 2026-05-17
**Status:** Approved (design), pending implementation plan
**Motivation:** Account-history sync fails with "The request timed out" because
every external-provider HTTP call relies on `URLSession.shared`'s ~60s default
request timeout and nothing retries a transient failure. Blockscout's public
instances are slow enough that a single page request can exceed 60s, aborting
the entire sync.

## Goal

A reusable HTTP timeout + retry component that any external-provider client can
adopt to automatically get a configurable per-request timeout and bounded
retry-with-backoff for transient failures. Integrate it into the Blockscout
client first; design it so the 6 clients already on the shared networking layer
can inherit it later with minimal friction.

## Context

The codebase already has a shared networking layer in `Shared/Networking/`:

- `RateLimitGate.swift` — actor; host-wide reactive cooldown on 429/418/503 with
  `Retry-After` or exponential backoff.
- `FailedRequestCache.swift` — actor; per-URL cooldown (fixed 5 min for HTTP
  errors, exponential backoff for transport errors).
- `URLSession+RateLimited.swift` — `dataRespectingRateLimit(for:gate:failureCache:)`
  wraps `data(for:)` with pre-flight gate/cache checks and post-flight
  classification.

Adoption today:

- **Price / FX / stock clients** (CoinGecko, CryptoCompare, Binance,
  Frankfurter, YahooFinance, YahooFinanceStockSearch) — already route through
  `dataRespectingRateLimit`; rely on an orchestrated fallback chain when a
  provider is rate-limited.
- **Wallet-sync clients** (`LiveAlchemyClient`, `LiveBlockscoutClient`) — use
  their own proactive `RateLimiter` actor (Blockscout: 5 req/s, a deliberate
  choice for the unauthenticated public API) and `AlchemyResponseValidator`;
  **not** on the gate/cache path.
- **Coinstash** — custom `Transport` closure, no rate limiting.

Gaps the existing layer does **not** close: no per-request timeout is ever
configured anywhere, and nothing *retries* — the gate/cache only *suppress*
repeats via cooldown.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Component scope | Extend the existing `Shared/Networking` layer; one unified policy; the 6 gate/cache clients inherit retry over time. |
| Retry triggers | Transient transport errors + 5xx without `Retry-After`. 429/418/503+`Retry-After` keep today's throw-cooldown-and-fall-back behavior **by default**. |
| Idempotency | Explicit per-call `idempotent` flag; default derived from HTTP method (GET/HEAD → true, others → false). Read-only POST clients (Alchemy JSON-RPC, Coinstash GraphQL) opt in explicitly later. |
| Policy defaults | `requestTimeout` = **120s** (Blockscout is slow — the point is to *extend* the timeout, not shorten it), 3 attempts, exponential backoff + jitter. |
| Integration approach | **A** — shared retry/timeout core + retry-aware `dataRespectingRateLimit`; Blockscout keeps its proactive `RateLimiter` + `AlchemyResponseValidator`, gains timeout + retry. |
| Blockscout rate-limits | Blockscout must **also** honor reactive `Retry-After` in-place (wait + retry the idempotent GET) because it has no fallback provider — a rate-limit must be waited out, not hard-failed. Enabled via a per-call policy capability that stays **off** for the fallback-chain clients. |

## Architecture & Components

Three new pieces under `Shared/Networking/`, all pure value/function types,
unit-testable with an injected clock (no real sleeping, no simulator).

### `HTTPRetryPolicy` (`Sendable` struct)

Per-call, overridable per client.

- `requestTimeout: TimeInterval = 120` — applied via `URLRequest.timeoutInterval`.
- `maxAttempts: Int = 3` — 1 initial + 2 retries.
- `backoffBase: TimeInterval = 0.5`, `backoffCap: TimeInterval = 5` —
  exponential `backoffBase · 2^(n-1)`, capped at `backoffCap`, with full jitter.
- `totalBudget: TimeInterval = 300` — hard ceiling across all attempts so a
  dead provider cannot stall a single page for `3 × 120s`. Retrying stops when
  **either** `maxAttempts` or `totalBudget` is exhausted, whichever comes first.
- `honorsRetryAfterInPlace: Bool = false` — when true, a `429/418/503` with a
  `Retry-After` ≤ `maxRateLimitWait` is waited out and the (idempotent) request
  retried in-place instead of throwing cooldown. Default false preserves the
  fallback-chain clients' behavior exactly.
- `maxRateLimitWait: TimeInterval = 60` — `Retry-After` longer than this is not
  waited out; the existing throw-cooldown path is used so the caller fails
  cleanly rather than stalling.

### `withRetry(policy:isRetryable:clock:operation:)`

Generic async executor:

- Runs `operation`; on a thrown error consults `isRetryable`.
- If retryable and budget/attempts remain: sleeps the jittered backoff (or the
  capped `Retry-After`), checks `Task.isCancelled` and the elapsed total budget
  between attempts, then retries.
- On exhaustion: rethrows the **last** error unchanged.
- Clock and sleeper are injected (`@Sendable`) so tests advance a fake clock
  and never sleep for real.

### `HTTPRetryClassifier`

Decides whether an error/response is retryable:

- Retryable transport: `URLError` codes `.timedOut`,
  `.networkConnectionLost`, `.cannotConnectToHost`, `.dnsLookupFailed`,
  `.notConnectedToInternet`.
- Retryable HTTP: 5xx **without** a `Retry-After`.
- Only when `idempotent == true`.
- Never retryable: `CancellationError`, `URLError(.cancelled)` — user-driven,
  propagate immediately.

## Integration Points

### `URLSession.dataRespectingRateLimit`

Gains `retry: HTTPRetryPolicy? = nil` and `idempotent: Bool? = nil`
(default derived from the request's HTTP method).

- Retry is woven **inside**, around the raw `self.data(for:)`, **before**
  `FailedRequestCache` muting. This is essential: today the method records a
  transport failure and rethrows on timeout, so a naive retry *wrapped around*
  it would immediately trip the per-URL cooldown on attempt 2. Failure is
  recorded/muted only after retries are exhausted; gate bookkeeping and
  `classify()` run once on the final outcome.
- `retry: nil` ⇒ byte-for-byte today's behavior (backward compatible
  regression guard in tests).
- The 6 price/FX/stock clients adopt `retry:` opt-in, one at a time, later
  (out of scope for the first implementation).

### Blockscout (`LiveBlockscoutClient`) — first adopter

- Keeps its proactive `RateLimiter` (5 req/s) and `AlchemyResponseValidator`.
- Routes the transport call (`send`) through the retry path with policy
  `requestTimeout: 120`, `honorsRetryAfterInPlace: true`,
  `maxRateLimitWait: 60`, `idempotent: true` (all Blockscout calls are GETs).
- Because Blockscout has no fallback provider, a 429/503+`Retry-After`
  within `maxRateLimitWait` is waited out and the page re-fetched; a longer
  `Retry-After` surfaces as the existing error so the sync fails cleanly
  instead of hanging.

## Data Flow (Blockscout page fetch)

```
paginate loop
  → rateLimiter.acquire()                      (proactive 5 req/s, unchanged)
  → withRetry:
      attempt:
        session.data(for:) with timeoutInterval = 120
        ├─ .timedOut / transient transport / 5xx-no-Retry-After
        │     → jittered backoff, budget+cancel check → retry
        ├─ 429/503 + Retry-After ≤ 60s
        │     → sleep Retry-After → retry
        ├─ 429/503 + Retry-After > 60s
        │     → throw (existing cooldown path; sync fails cleanly)
        └─ success / other non-2xx
              → return to AlchemyResponseValidator (validated as today)
      exhaustion → rethrow last error → mapped to WalletSyncError.network
```

## Error Handling

- No new error types. Retries are transparent; on exhaustion the **original**
  error propagates and is mapped by each client's existing validator
  (`WalletSyncError.network` for Blockscout).
- Cancellation propagates immediately, untouched, and never mutes a URL.
- The retry executor logs each retry at `.notice` with attempt number, delay,
  reason, and host. Address/hash stays `.private` per the existing privacy
  table in the Blockscout/Alchemy clients.

## Testing

TDD — test file before implementation, per project rules; follows
`guides/TEST_GUIDE.md`.

- **`HTTPRetryPolicy`** — defaults; per-client override semantics.
- **`withRetry`** — succeeds first try; retries then succeeds; exhausts and
  rethrows the last error; stops at `totalBudget` before `maxAttempts`; stops
  on cancellation mid-backoff; honors capped `Retry-After`; does not retry when
  not idempotent. All with an injected fake clock — zero real sleeping.
- **`HTTPRetryClassifier`** — table test over URLError codes and HTTP status
  codes × `idempotent` flag.
- **`dataRespectingRateLimit` with `retry:`** — a transport failure is retried
  *before* `FailedRequestCache` mutes the URL; gate/cache bookkeeping runs once
  on the final outcome; `retry: nil` path is unchanged (regression guard).
- **Blockscout** — stubbed `URLProtocol`/transport returning timeout-then-success
  proves a page survives a transient timeout; 429 + short `Retry-After` is
  waited out and succeeds; 429 + long `Retry-After` still fails cleanly.

## Out of Scope

- Migrating the 6 price/FX/stock clients onto `retry:` (they inherit it later,
  opt-in, one at a time).
- Migrating Alchemy or Coinstash (read-only POST) onto the component — they can
  opt in later via the explicit `idempotent: true` flag.
- Any change to `RateLimitGate` / `FailedRequestCache` semantics, or to
  Blockscout's proactive 5 req/s rate.
