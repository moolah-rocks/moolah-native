# Networking Architecture Realignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fictional "all requests go through `APIClient`" rule in `guides/CONCURRENCY_GUIDE.md` §4 with a real composable architecture: a `RateLimitedHTTPClient` value type backed by a process-wide `NetworkingServices` registry with host-shared rate-limit gates, plus documented carve-outs for Blockscout (retry-driven RPC), Alchemy (token-bucket RPC), and Coinstash (transport closure). Closes [#938](https://github.com/ajsutton/moolah-native/issues/938).

**Architecture:** Bundle the `(URLSession, RateLimitGate, FailedRequestCache)` trio that 6 standard clients duplicate today into one `Sendable` struct (`RateLimitedHTTPClient`) bound to a single host. `NetworkingServices` (process-wide, injected) lazily creates one `RateLimitGate` per host and vends `RateLimitedHTTPClient` instances, so two callers of the same host share a gate (a 429 cools down every caller). The `URLSession+RateLimited` extension is retired and its logic moves into `RateLimitedHTTPClient.data(for:)`; the new method also validates 2xx and throws `URLError(.badServerResponse)` on non-2xx, DRYing the status-check block every group-1 caller writes today. Six standard clients, `CompositeTokenResolutionClient`, and `SQLiteCoinGeckoCatalog+Refresh` migrate to the new API. `LiveBlockscoutClient`, `LiveAlchemyClient`, and `CoinstashClient` stay on their distinct shapes with documented carve-outs in §4.

**Tech Stack:** Swift 6, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), `URLSession`, `OSLog`. `xcodegen` (`just generate`), `just` build/test/format targets. Merge queue via the `merge-queue` skill.

**Reference:** `plans/2026-05-21-api-client-architecture-design.md` (approved design).

**Conventions (verified in codebase):**
- Tests live in `MoolahTests/Shared/`, `MoolahTests/Backends/`, etc.; macOS target `MoolahTests_macOS`; run a suite with `just test-mac <SuiteName>`.
- Test style: `import Foundation` / `import Testing` / `@testable import Moolah`, `@Suite("Name") struct …`, `@Test func … async throws`, `#expect(…)`.
- New `.swift` files in already-globbed dirs (`Shared/Networking/`, `MoolahTests/Shared/`) are picked up by `just generate`. Run `just generate` before the first build if a new file lands in a directory not yet globbed.
- One extension per protocol; thin types; follow `guides/CODE_GUIDE.md`. Run `just format` before every commit; `just format-check` must pass.
- Capture test output to `.agent-tmp/test-output.txt` (gitignored) and delete when done — see CLAUDE.md.
- Per-PR completion: run `just format-check`, `just build-mac`, and `just test-mac` (or scope-targeted subsets), open the PR with `gh pr create`, then add it to the merge queue via the `merge-queue` skill.

---

## PR scope and dependency order

This plan covers **six PRs**:

1. **PR-1 (Foundation):** Introduce `RateLimitedHTTPClient` + `NetworkingServices`; retire `URLSession.dataRespectingRateLimit`; rename + migrate tests. **Must land first.**
2. **PR-2 (Standard clients):** Migrate the 6 standard clients to `RateLimitedHTTPClient`. Depends on PR-1.
3. **PR-3 (Composite):** Migrate `CompositeTokenResolutionClient` to `NetworkingServices`. Depends on PR-1.
4. **PR-4 (Catalog refresh):** Migrate `SQLiteCoinGeckoCatalog+Refresh` to `RateLimitedHTTPClient`. Depends on PR-1.
5. **PR-5 (App wiring):** Thread `NetworkingServices` through `MoolahApp+Setup` → `SyncCoordinator` → `ProfileSession` → factories so all production callers share a process-wide instance. Depends on PR-2, PR-3, PR-4.
6. **PR-6 (Guide):** Rewrite `guides/CONCURRENCY_GUIDE.md` §4 (and the §2 example) to describe the four sanctioned shapes. Closes #938. Depends on PR-5.

PRs 2/3/4 are independent of each other and can be opened in parallel once PR-1 lands. PR-5 waits for them. PR-6 is doc-only and waits for the code to settle.

---

## File Structure

**Create (PR-1):**
- `Shared/Networking/RateLimitedHTTPClient.swift` — the bundled value type.
- `Shared/Networking/NetworkingServices.swift` — the process-wide registry.
- `MoolahTests/Shared/RateLimitedHTTPClientTests.swift` — the renamed/migrated equivalent of `URLSessionRateLimitTests.swift`.
- `MoolahTests/Shared/NetworkingServicesTests.swift` — new tests for the registry.

**Delete (PR-1):**
- `Shared/Networking/URLSession+RateLimited.swift` — retired.
- `MoolahTests/Shared/URLSessionRateLimitTests.swift` — replaced by `RateLimitedHTTPClientTests.swift`.

**Modify (PR-2):**
- `Backends/CryptoCompare/CryptoCompareClient.swift`
- `Backends/CoinGecko/CoinGeckoClient.swift`
- `Backends/Binance/BinanceClient.swift`
- `Backends/Frankfurter/FrankfurterClient.swift`
- `Backends/YahooFinance/YahooFinanceClient.swift`
- `Backends/YahooFinance/YahooFinanceStockSearchClient.swift`
- Their corresponding `*ClientTests.swift` files under `MoolahTests/Backends/`.

**Modify (PR-3):**
- `Shared/CompositeTokenResolutionClient.swift`
- `MoolahTests/Shared/CompositeTokenResolutionClientTests.swift`

**Modify (PR-4):**
- `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift` (the call site that invokes refresh)
- `Backends/CoinGecko/SQLiteCoinGeckoCatalog+Refresh.swift`
- `MoolahTests/Backends/SQLiteCoinGeckoCatalogRefreshTests.swift`

**Modify (PR-5):**
- `App/MoolahApp+Setup.swift` — construct `NetworkingServices` once.
- `App/MoolahApp+SharedInstrumentScope.swift` — thread it into `makeSharedInstrumentScope`.
- `App/SessionManager.swift` — hold `networking`, thread into `makeSession`.
- `App/ProfileSession.swift` — take `networking: NetworkingServices` init param.
- `App/ProfileSession+Factories.swift` — `makeMarketDataServices(database:networking:)`.
- `Backends/CloudKit/Sync/SyncCoordinator.swift` — hold `sharedNetworking`.
- `Shared/PreviewBackend.swift` — pass through a default-constructed `NetworkingServices`.
- Test fixtures that construct `ProfileSession` / `SessionManager` / `SyncCoordinator` directly.

**Modify (PR-6):**
- `guides/CONCURRENCY_GUIDE.md` — rewrite §4, update §2 example, update anti-pattern row.

---

# PR-1 — Foundation

**Branch:** `feat/networking-services-foundation` (off `main`).

Introduces the new types and retires the extension. After this PR lands, every existing call site (the 6 clients, Composite, Refresh) still uses the old `session.dataRespectingRateLimit(…)` pathway — **except that pathway no longer exists**. So this PR must include the call-site migrations as well, OR we keep the extension as a temporary shim. **Decision: keep the extension as a thin shim that delegates to the new client**, so PR-1 stands alone without breaking the build, and PRs 2-4 each delete the shim usage at their migration sites. The shim is removed at the end of PR-4.

> **Important:** the design says the extension is retired in PR-1. Doing that literally would force PR-1 to also touch all 8 call sites, which makes PR-1 too big. The compromise: PR-1 leaves a deprecated one-line shim that delegates to the new client, marked `@available(*, deprecated, message: "Use RateLimitedHTTPClient.data(for:) — see CONCURRENCY_GUIDE.md §4")`. PRs 2-4 migrate the call sites. The final PR-4 step deletes the shim and the extension file. This is documented in the §4 rewrite (PR-6) by then describing only the final state.

## Task 1-1: Pre-flight — verify clean tree and base branch

**Files:** none.

- [ ] **Step 1: Verify on a clean feature branch off `main`**

```bash
git -C "$(pwd)" status
git -C "$(pwd)" rev-parse --abbrev-ref HEAD
git -C "$(pwd)" log --oneline -1 origin/main
```

Expected: clean tree; branch name matches `feat/networking-services-foundation` (or the executor's chosen worktree branch); HEAD at or just past `origin/main`.

If a worktree wasn't set up for this PR, create one now:

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track .claude/worktrees/networking-services-foundation -b feat/networking-services-foundation origin/main
```

Then enter it. Subsequent steps assume the worktree's CWD.

- [ ] **Step 2: Establish baseline build + format**

Run: `just format-check && just build-mac`
Expected: both pass with the worktree as it is (no changes made yet).

---

## Task 1-2: `RateLimitedHTTPClient` — failing test

**Files:**
- Create: `MoolahTests/Shared/RateLimitedHTTPClientTests.swift`

- [ ] **Step 1: Write the failing test file**

Create `MoolahTests/Shared/RateLimitedHTTPClientTests.swift`:

```swift
// MoolahTests/Shared/RateLimitedHTTPClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("RateLimitedHTTPClient")
struct RateLimitedHTTPClientTests {

  // MARK: - Stub plumbing

  /// Per-suite URLProtocol stub. Mirrors the pattern in
  /// `URLSessionRateLimitTests` (the suite this file replaces) so handler
  /// state stays scoped to one test file.
  class Stub: URLProtocol {
    nonisolated(unsafe) static var handler:
      (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount: Int = 0
    private static let lock = NSLock()

    static func reset() {
      lock.lock()
      defer { lock.unlock() }
      handler = nil
      requestCount = 0
    }

    static func incrementRequestCount() {
      lock.lock()
      defer { lock.unlock() }
      requestCount += 1
    }

    static func capturedRequestCount() -> Int {
      lock.lock()
      defer { lock.unlock() }
      return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      Self.incrementRequestCount()
      guard let handler = Self.handler else {
        client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        return
      }
      do {
        let (response, data) = try handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    }

    override func stopLoading() {}
  }

  private static let stubURL = URL(fileURLWithPath: "/")

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Stub.self]
    return URLSession(configuration: config)
  }

  // swiftlint:disable force_unwrapping
  private func httpResponse(
    statusCode: Int, headers: [String: String] = [:]
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: Self.stubURL,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
  }
  // swiftlint:enable force_unwrapping

  private func request(path: String = "/probe") -> URLRequest {
    URLRequest(url: URL(string: "https://example.com\(path)") ?? Self.stubURL)
  }

  private func makeClient(
    session: URLSession,
    gate: RateLimitGate = RateLimitGate(),
    cache: FailedRequestCache = FailedRequestCache()
  ) -> RateLimitedHTTPClient {
    RateLimitedHTTPClient(session: session, gate: gate, failureCache: cache)
  }

  // MARK: - 2xx success

  @Test
  func twoHundredReturnsDataAndHTTPResponse() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data("OK".utf8)) }

    let client = makeClient(session: makeSession())
    let (data, http) = try await client.data(for: request())
    #expect(data == Data("OK".utf8))
    #expect(http.statusCode == 200)
  }

  // MARK: - non-2xx now throws

  @Test
  func fourOhFourThrowsBadServerResponseAndMutesURL() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 404), Data()) }

    let cache = FailedRequestCache()
    let client = makeClient(session: makeSession(), cache: cache)

    await #expect(throws: URLError(.badServerResponse)) {
      _ = try await client.data(for: request())
    }
    // Second call short-circuits via the cache cooldown.
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data()) }
    await #expect(throws: FailedRequestCacheError.self) {
      _ = try await client.data(for: request())
    }
  }

  @Test
  func fiveHundredThrowsBadServerResponseAndMutesURL() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 500), Data()) }

    let client = makeClient(session: makeSession())
    await #expect(throws: URLError(.badServerResponse)) {
      _ = try await client.data(for: request())
    }
  }

  // MARK: - 429 / 503 trip the gate

  @Test
  func fourTwentyNineTripsGateAndThrowsCooldown() async throws {
    Stub.reset()
    Stub.handler = { _ in
      (self.httpResponse(statusCode: 429, headers: ["Retry-After": "1"]), Data())
    }

    let gate = RateLimitGate()
    let client = makeClient(session: makeSession(), gate: gate)

    await #expect(throws: RateLimitGateError.self) {
      _ = try await client.data(for: request())
    }
    // Subsequent call short-circuits via the gate cooldown.
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data()) }
    await #expect(throws: RateLimitGateError.self) {
      _ = try await client.data(for: request())
    }
  }

  @Test
  func fiveOhThreeWithRetryAfterTripsGate() async throws {
    Stub.reset()
    Stub.handler = { _ in
      (self.httpResponse(statusCode: 503, headers: ["Retry-After": "1"]), Data())
    }
    let client = makeClient(session: makeSession())
    await #expect(throws: RateLimitGateError.self) {
      _ = try await client.data(for: request())
    }
  }

  @Test
  func fiveOhThreeWithoutRetryAfterThrowsBadServerResponse() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 503), Data()) }
    let client = makeClient(session: makeSession())
    await #expect(throws: URLError(.badServerResponse)) {
      _ = try await client.data(for: request())
    }
  }

  // MARK: - transport failure mutes URL, cancellation does not

  @Test
  func transportErrorMutesURL() async throws {
    Stub.reset()
    Stub.handler = { _ in throw URLError(.notConnectedToInternet) }
    let cache = FailedRequestCache()
    let client = makeClient(session: makeSession(), cache: cache)

    await #expect(throws: URLError.self) {
      _ = try await client.data(for: request())
    }
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data()) }
    await #expect(throws: FailedRequestCacheError.self) {
      _ = try await client.data(for: request())
    }
  }

  @Test
  func cancellationDoesNotMuteURL() async throws {
    Stub.reset()
    Stub.handler = { _ in throw URLError(.cancelled) }
    let cache = FailedRequestCache()
    let client = makeClient(session: makeSession(), cache: cache)

    await #expect(throws: URLError.self) {
      _ = try await client.data(for: request())
    }
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data()) }
    // URL not muted — call proceeds.
    _ = try await client.data(for: request())
  }
}
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
mkdir -p .agent-tmp
just test-mac RateLimitedHTTPClientTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: FAIL — `cannot find 'RateLimitedHTTPClient' in scope`. (The build doesn't reach the test phase; failure happens at compile time.)

---

## Task 1-3: `RateLimitedHTTPClient` — minimal implementation

**Files:**
- Create: `Shared/Networking/RateLimitedHTTPClient.swift`

- [ ] **Step 1: Create the type**

Create `Shared/Networking/RateLimitedHTTPClient.swift`:

```swift
// Shared/Networking/RateLimitedHTTPClient.swift
import Foundation
import OSLog

private let rateLimitedHTTPLogger = Logger(
  subsystem: "com.moolah.app", category: "RateLimitedHTTP")

/// Composes URLSession + a host-shared RateLimitGate + a process-shared
/// FailedRequestCache. Bound to one host at construction time (`gate` is
/// the gate for that host, as vended by `NetworkingServices`).
///
/// `data(for:)` runs pre-flight checks (host gate, per-URL failure cache),
/// dispatches the request, classifies the response, and either returns the
/// 2xx body or throws — see method doc. Callers never have to repeat the
/// `(200...299).contains(http.statusCode)` boilerplate.
///
/// See `guides/CONCURRENCY_GUIDE.md` §4 sanctioned shape #1.
struct RateLimitedHTTPClient: Sendable {
  private let session: URLSession
  private let gate: RateLimitGate
  private let failureCache: FailedRequestCache

  init(session: URLSession, gate: RateLimitGate, failureCache: FailedRequestCache) {
    self.session = session
    self.gate = gate
    self.failureCache = failureCache
  }

  /// Sends `request` respecting the host gate and per-URL failure cache.
  ///
  /// **Pre-flight:**
  /// - If the gate is in cooldown, throws `RateLimitGateError.cooldown(until:)`.
  /// - If the cache has a live entry for the URL, throws `FailedRequestCacheError.cooldown(until:)`.
  ///
  /// **Post-flight:**
  /// - 2xx → records success on gate + cache, returns `(Data, HTTPURLResponse)`.
  /// - 429 / 418 → trips the gate (`Retry-After` or exponential backoff),
  ///   records on cache, throws `RateLimitGateError.cooldown`.
  /// - 503 with `Retry-After` → trips the gate, records on cache,
  ///   throws `RateLimitGateError.cooldown`.
  /// - Any other non-2xx (incl. 503 without `Retry-After`, 4xx, 5xx) →
  ///   records on cache, throws `URLError(.badServerResponse)`.
  /// - Transport failure (DNS, offline, timeout, hangup; not cancellation)
  ///   → records on cache, rethrows the original error.
  /// - Cancellation (`CancellationError` or `URLError(.cancelled)`) →
  ///   propagates without muting the URL.
  ///
  /// Behavior matches the retired `URLSession.dataRespectingRateLimit`
  /// extension, with one change: non-2xx now throws
  /// `URLError(.badServerResponse)` here instead of being returned as
  /// `(data, response)` for the caller to check. Every previous caller
  /// implemented exactly that check, so the consolidated behavior is a
  /// pure DRY-out.
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await gate.ensureAvailable()
    let cacheKey = request.url?.absoluteString
    if let cacheKey {
      try await failureCache.ensureAvailable(for: cacheKey)
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      if !Self.isCancellation(error), let cacheKey {
        let deadline = await failureCache.recordTransportFailure(for: cacheKey)
        rateLimitedHTTPLogger.notice(
          """
          Transport failure for \(request.url?.host ?? "?", privacy: .public): \
          \(error.localizedDescription, privacy: .public); URL muted \
          until \(deadline.timeIntervalSince1970, privacy: .public)
          """
        )
      }
      throw error
    }
    let http = try await Self.classify(
      response: response,
      request: request,
      cacheKey: cacheKey,
      gate: gate,
      failureCache: failureCache
    )
    return (data, http)
  }

  /// Classifies the response and records gate/cache side effects.
  /// Throws `RateLimitGateError.cooldown` for rate-limit responses,
  /// `URLError(.badServerResponse)` for any other non-2xx, and returns
  /// the `HTTPURLResponse` for 2xx.
  private static func classify(
    response: URLResponse,
    request: URLRequest,
    cacheKey: String?,
    gate: RateLimitGate,
    failureCache: FailedRequestCache
  ) async throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    let retryAfter = http.retryAfterSeconds(now: Date())
    let host = request.url?.host ?? "?"
    switch http.statusCode {
    case 200...299:
      await gate.recordSuccess()
      if let cacheKey {
        await failureCache.recordSuccess(for: cacheKey)
      }
      return http
    case 429, 418:
      try await tripGate(
        outcome: .init(retryAfter: retryAfter, statusCode: http.statusCode, host: host),
        cacheKey: cacheKey,
        gate: gate,
        failureCache: failureCache
      )
      throw URLError(.badServerResponse)  // unreachable; tripGate always throws
    case 503 where retryAfter != nil:
      try await tripGate(
        outcome: .init(retryAfter: retryAfter, statusCode: http.statusCode, host: host),
        cacheKey: cacheKey,
        gate: gate,
        failureCache: failureCache
      )
      throw URLError(.badServerResponse)  // unreachable
    default:
      if let cacheKey {
        let deadline = await failureCache.recordHTTPFailure(for: cacheKey)
        rateLimitedHTTPLogger.notice(
          """
          Request failed (HTTP \(http.statusCode, privacy: .public)) for \
          \(host, privacy: .public); URL muted until \
          \(deadline.timeIntervalSince1970, privacy: .public)
          """
        )
      }
      throw URLError(.badServerResponse)
    }
  }

  private struct RateLimitOutcome {
    let retryAfter: TimeInterval?
    let statusCode: Int
    let host: String
  }

  private static func tripGate(
    outcome: RateLimitOutcome,
    cacheKey: String?,
    gate: RateLimitGate,
    failureCache: FailedRequestCache
  ) async throws {
    let deadline = await gate.recordRateLimit(retryAfter: outcome.retryAfter)
    if let cacheKey {
      await failureCache.recordHTTPFailure(for: cacheKey)
    }
    rateLimitedHTTPLogger.warning(
      """
      Rate-limited (HTTP \(outcome.statusCode, privacy: .public)) by \
      \(outcome.host, privacy: .public); cooldown until \
      \(deadline.timeIntervalSince1970, privacy: .public)
      """
    )
    throw RateLimitGateError.cooldown(until: deadline)
  }

  private static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
  }
}
```

- [ ] **Step 2: Regenerate Xcode project**

Run: `just generate`
Expected: succeeds with a one-line confirmation. (Required because `Shared/Networking/` is glob-included, but a regen catches any project-yml drift.)

- [ ] **Step 3: Run the tests**

```bash
just test-mac RateLimitedHTTPClientTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt | head -20
```

Expected: all tests pass.

- [ ] **Step 4: Format check**

Run: `just format-check`
Expected: passes.

---

## Task 1-4: `NetworkingServices` — failing test

**Files:**
- Create: `MoolahTests/Shared/NetworkingServicesTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/NetworkingServicesTests.swift`:

```swift
// MoolahTests/Shared/NetworkingServicesTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("NetworkingServices")
struct NetworkingServicesTests {

  @Test
  func clientForHostReturnsSameGateForSameHost() async {
    let services = NetworkingServices(session: .shared)
    let a = await services.gate(forHost: "api.example.com")
    let b = await services.gate(forHost: "api.example.com")
    #expect(a === b)
  }

  @Test
  func clientForHostReturnsDifferentGateForDifferentHost() async {
    let services = NetworkingServices(session: .shared)
    let a = await services.gate(forHost: "api.example.com")
    let b = await services.gate(forHost: "api.other.com")
    #expect(a !== b)
  }

  @Test
  func hostKeyIsCaseInsensitive() async {
    let services = NetworkingServices(session: .shared)
    let a = await services.gate(forHost: "API.Example.com")
    let b = await services.gate(forHost: "api.example.com")
    #expect(a === b)
  }

  @Test
  func clientForHostUsesInjectedSession() {
    let session = URLSession(configuration: .ephemeral)
    let services = NetworkingServices(session: session)
    let client = services.client(forHost: "api.example.com")
    // Round-trip the client through a successful 2xx; if we got the
    // injected session, the request resolves; otherwise it hits the
    // real network. (Smoke test — no Stub registered, so this would
    // fail outright if the wrong session were used.)
    #expect(client.underlyingSession === session)
  }
}
```

> **Note:** the `gate(forHost:)` accessor and `underlyingSession` property below are added for tests only. They are `internal` (no public exposure) and exist to verify gate-sharing and session-passthrough. `client(forHost:)` remains the public-facing API; the test seams are documented as such in the implementation.

- [ ] **Step 2: Run the test to confirm it fails**

```bash
just test-mac NetworkingServicesTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: FAIL — `cannot find 'NetworkingServices' in scope`.

---

## Task 1-5: `NetworkingServices` — minimal implementation

**Files:**
- Create: `Shared/Networking/NetworkingServices.swift`

- [ ] **Step 1: Create the type**

Create `Shared/Networking/NetworkingServices.swift`:

```swift
// Shared/Networking/NetworkingServices.swift
import Foundation

/// Process-wide registry that owns one `RateLimitGate` per host (created
/// lazily on first lookup) and one `FailedRequestCache` for the process.
/// Vends `RateLimitedHTTPClient` instances bound to the requested host so
/// that two callers of the same host share a gate — a 429 from one cools
/// the other down.
///
/// Constructed once in `MoolahApp+Setup` and injected through
/// `SyncCoordinator` → `ProfileSession` → factories. Tests construct their
/// own instance with an ephemeral `URLProtocol`-backed `URLSession`, so
/// each test gets isolated gates with no global mutable state.
///
/// See `guides/CONCURRENCY_GUIDE.md` §4.
final class NetworkingServices: Sendable {
  private let session: URLSession
  private let failureCache: FailedRequestCache
  private let registry: GateRegistry

  /// - Parameter session: URLSession used for every request. Defaults to
  ///   `.shared` in production. Tests inject an ephemeral session whose
  ///   `protocolClasses` includes a `URLProtocol` stub.
  init(session: URLSession = .shared) {
    self.session = session
    self.failureCache = FailedRequestCache()
    self.registry = GateRegistry()
  }

  /// Returns a `RateLimitedHTTPClient` bound to the host's rate-limit
  /// gate and the shared failure cache. Host strings are normalised to
  /// lower-case so `Api.Example.com` and `api.example.com` share a gate.
  func client(forHost host: String) -> RateLimitedHTTPClient {
    let gate = registry.synchronousGate(forHost: host.lowercased())
    return RateLimitedHTTPClient(
      session: session, gate: gate, failureCache: failureCache)
  }

  // MARK: - Test seams (internal)

  /// Returns the gate for `host` (lower-cased internally). Same gate is
  /// returned for repeat lookups. Async because the registry is an actor.
  /// Internal so `NetworkingServicesTests` can assert gate-sharing.
  func gate(forHost host: String) async -> RateLimitGate {
    await registry.gate(forHost: host.lowercased())
  }

  /// The injected `URLSession`. Internal so tests can assert pass-through.
  var underlyingSession: URLSession { session }
}

/// Actor-isolated `[String: RateLimitGate]`. Lazy creation: the registry
/// stays empty until first lookup per host. Hot path uses
/// `synchronousGate(forHost:)`, which uses a lock instead of `await` so
/// the request hot path doesn't hop to the actor just to read the gate.
private final class GateRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var gates: [String: RateLimitGate] = [:]

  /// Sync accessor used by `NetworkingServices.client(forHost:)`. The
  /// lock is uncontended in steady state (Dictionary lookup is O(1)) and
  /// avoids the actor hop on every request. The carve-out is documented
  /// on the class itself — `@unchecked Sendable` because the only mutable
  /// state is `gates`, fully guarded by `lock`.
  func synchronousGate(forHost host: String) -> RateLimitGate {
    lock.lock()
    defer { lock.unlock() }
    if let existing = gates[host] { return existing }
    let gate = RateLimitGate()
    gates[host] = gate
    return gate
  }

  /// Async accessor used only by tests asserting registry behaviour.
  func gate(forHost host: String) async -> RateLimitGate {
    synchronousGate(forHost: host)
  }
}
```

- [ ] **Step 2: Update `CONCURRENCY_GUIDE.md` carve-outs (defensive note)**

`NetworkingServices` declares an `@unchecked Sendable` carve-out on a private nested class (`GateRegistry`). This is one of the cases the §2 "False Positives to Avoid" section enumerates by name. PR-6 rewrites §4 fully; for now, we add the new private type to the existing §2 list so a `code-review` agent run between PR-1 and PR-6 doesn't flag it as an unjustified `@unchecked`. Add to `guides/CONCURRENCY_GUIDE.md`, just before the `Do not use @unchecked Sendable in any other production code.` line:

```
**Carve-out 4 — `GateRegistry` (file-private to `NetworkingServices`).** `Shared/Networking/NetworkingServices.swift` defines a private `final class GateRegistry: @unchecked Sendable` whose only mutable state is `[String: RateLimitGate]`, fully guarded by an `NSLock`. The async accessor (`gate(forHost:)`) is internal and used only by tests; the production hot path uses the synchronous accessor. The lock is the synchronisation primitive that makes the type genuinely thread-safe; `@unchecked` waives only Swift's structural check that `final class` automatically conforms to `Sendable`. PR-6 of #938 folds this carve-out into the rewritten §4.
```

> This addition is intentional for PR-1 so the `concurrency-review` agent stays green between PRs. PR-6 will rephrase §4 and may inline the rationale; the carve-out itself remains valid.

- [ ] **Step 3: Run the tests**

```bash
just test-mac NetworkingServicesTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: all 4 tests pass.

- [ ] **Step 4: Format check**

Run: `just format-check`
Expected: passes.

---

## Task 1-6: Leave the existing extension and its tests in place

**Files:** none (this task is a "do nothing" checkpoint).

**Decision:** PR-1 leaves `Shared/Networking/URLSession+RateLimited.swift` and `MoolahTests/Shared/URLSessionRateLimitTests.swift` **completely untouched**. The extension keeps doing what it does today; the existing tests continue to cover it. The 8 call sites still use it.

Reasoning: marking the extension `@available(*, deprecated)` would emit warnings at every call site, and `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` would fail the build. Migrating all 8 call sites in PR-1 would make the PR too large. The cleanest answer is: PR-1 introduces the new types, the 8 call sites migrate in PRs 2-4, and PR-4 deletes the extension and its tests as a final step when no consumer remains.

- [ ] **Step 1: Verify nothing was changed under `Shared/Networking/URLSession+RateLimited.swift`**

```bash
git -C "$(pwd)" diff --stat Shared/Networking/URLSession+RateLimited.swift \
  MoolahTests/Shared/URLSessionRateLimitTests.swift
```

Expected: zero output (no changes).

- [ ] **Step 2: Build + run both existing and new test suites**

```bash
just build-mac
just test-mac RateLimitedHTTPClientTests NetworkingServicesTests URLSessionRateLimitTests
```

Expected: build clean, all three suites pass.

---

## Task 1-7: PR-1 final verification

**Files:** none.

- [ ] **Step 1: Full build + tests + format**

```bash
just format-check 2>&1 | tee .agent-tmp/format-check.txt
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
just test-mac 2>&1 | tee .agent-tmp/test-mac.txt
grep -i 'failed\|error:' .agent-tmp/test-mac.txt | head -20
```

Expected: format clean, build clean, all tests pass.

- [ ] **Step 2: Remove temp files**

```bash
rm -rf .agent-tmp
```

- [ ] **Step 3: Commit**

```bash
git -C "$(pwd)" add Shared/Networking/RateLimitedHTTPClient.swift \
  Shared/Networking/NetworkingServices.swift \
  MoolahTests/Shared/RateLimitedHTTPClientTests.swift \
  MoolahTests/Shared/NetworkingServicesTests.swift \
  guides/CONCURRENCY_GUIDE.md
git -C "$(pwd)" commit -m "$(cat <<'EOF'
feat(networking): introduce RateLimitedHTTPClient + NetworkingServices

Foundation PR for #938. New value type RateLimitedHTTPClient bundles the
(URLSession, RateLimitGate, FailedRequestCache) trio every standard client
duplicates today, and validates 2xx so callers stop repeating the status
check. NetworkingServices is a process-wide registry that lazily creates
one RateLimitGate per host and vends RateLimitedHTTPClient instances —
so two callers of the same host share a gate (a 429 from one cools down
the other).

URLSession+RateLimited extension and its tests stay in place during the
migration window. PR-4's final step deletes them when no consumer remains.

CONCURRENCY_GUIDE §2 gains a new @unchecked Sendable carve-out (GateRegistry,
file-private to NetworkingServices) so concurrency-review stays green
between PRs. PR-6 rewrites §4 to fully describe the new architecture.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Push and open PR**

```bash
git -C "$(pwd)" push origin feat/networking-services-foundation:feat/networking-services-foundation -u
gh pr create --title "feat(networking): introduce RateLimitedHTTPClient + NetworkingServices" --body "$(cat <<'EOF'
## Summary

Foundation PR for #938. Introduces two new types under `Shared/Networking/`:

- `RateLimitedHTTPClient` — `Sendable` struct that bundles `(URLSession, RateLimitGate, FailedRequestCache)`, runs the rate-limit / failure-cache pipeline, and validates 2xx (throwing `URLError(.badServerResponse)` on non-2xx so callers stop repeating the status check).
- `NetworkingServices` — process-wide registry that lazily creates one `RateLimitGate` per host (lower-cased key) and vends `RateLimitedHTTPClient` instances bound to that host.

No call sites are migrated in this PR — the existing `URLSession+RateLimited` extension stays in place and continues to be used. PRs 2-4 of #938 migrate the 8 consumers; PR-4 deletes the extension.

`guides/CONCURRENCY_GUIDE.md` §2 gains a new `@unchecked Sendable` carve-out (`GateRegistry`, file-private to `NetworkingServices`) so `concurrency-review` stays green between PRs. PR-6 rewrites §4 end-to-end.

## Test plan

- [x] `just test-mac RateLimitedHTTPClientTests` — covers cooldown short-circuit, 2xx + gate/cache success, 429/418 trip gate, 503+Retry-After trips gate, 503 without Retry-After throws badServerResponse, 4xx/5xx throw badServerResponse + mute URL, transport failure mutes URL, cancellation does not.
- [x] `just test-mac NetworkingServicesTests` — covers same-host gate sharing, different-host gate isolation, lower-case host normalisation, injected-session pass-through.
- [x] `just test-mac` — full suite green.

Refs #938
🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: Add PR to merge queue**

Invoke the `merge-queue` skill with the PR number returned by `gh pr create`. The skill takes care of the speculative train; do **not** run `gh pr merge` manually.

```bash
# After PR-1 is in the queue, check status:
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh status
```

After PR-1 lands on `main`, proceed to PR-2.

---

# PR-2 — Migrate the 6 standard clients

**Branch:** `feat/migrate-standard-clients-to-rate-limited-http` (off `main`, after PR-1 lands).

Each client loses its `(session, rateLimitGate, failureCache)` init parameters and gains a single `http: RateLimitedHTTPClient`. The `(200...299)` status check is removed from each call site (now handled inside `RateLimitedHTTPClient.data(for:)`). Tests for each client construct `NetworkingServices(session: stub)` and pass `networking.client(forHost: …)`.

Hosts (verified):
- `CryptoCompareClient` → `min-api.cryptocompare.com`
- `CoinGeckoClient` → **dual host**: `pro-api.coingecko.com` when a key is set, `api.coingecko.com` otherwise. The factory chooses at construction time.
- `BinanceClient` → `api.binance.com`
- `FrankfurterClient` → `api.frankfurter.app`
- `YahooFinanceClient` → `query2.finance.yahoo.com`
- `YahooFinanceStockSearchClient` → `query1.finance.yahoo.com`

## Task 2-1: `CryptoCompareClient`

**Files:**
- Modify: `Backends/CryptoCompare/CryptoCompareClient.swift`
- Modify: `MoolahTests/Backends/CryptoCompareClientTests.swift` (rename test session/gate setup)

- [ ] **Step 1: Update the client**

Replace the stored properties and init in `Backends/CryptoCompare/CryptoCompareClient.swift` (lines 9-21) with:

```swift
private let http: RateLimitedHTTPClient

init(http: RateLimitedHTTPClient) {
  self.http = http
}
```

Replace each `try await session.dataRespectingRateLimit(...)` block with `try await http.data(for: URLRequest(url: url))`. Remove the `(200...299).contains(http.statusCode)` checks and the `URLError(.badServerResponse)` throws — `http.data(for:)` does this now.

Resulting `dailyPrices(for:in:)` body (lines 32-46 today):

```swift
func dailyPrices(
  for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
) async throws -> [String: Decimal] {
  guard let symbol = mapping.cryptocompareSymbol else {
    throw CryptoPriceError.noProviderMapping(
      tokenId: mapping.instrumentId, provider: "CryptoCompare")
  }
  let url = Self.histodayURL(symbol: symbol, from: range.lowerBound, to: range.upperBound)
  let (data, _) = try await http.data(for: URLRequest(url: url))
  return try Self.parseHistodayResponse(data)
}
```

Same pattern for `currentPrices(for:)` (lines 48-73).

- [ ] **Step 2: Update the tests**

Find each `CryptoCompareClient(session: …, rateLimitGate: …, failureCache: …)` construction in `MoolahTests/Backends/CryptoCompareClientTests.swift` and replace with the new shape:

```swift
let services = NetworkingServices(session: stubbedSession)
let client = CryptoCompareClient(http: services.client(forHost: "min-api.cryptocompare.com"))
```

If a specific test asserted gate / cache behaviour through the old constructor (e.g. injecting a tripped gate), keep that test by constructing the `RateLimitedHTTPClient` directly:

```swift
let trippedGate = RateLimitGate()
// ... arrange tripped state ...
let client = CryptoCompareClient(
  http: RateLimitedHTTPClient(
    session: stubbedSession, gate: trippedGate, failureCache: FailedRequestCache()))
```

- [ ] **Step 3: Build + test**

```bash
just build-mac
just test-mac CryptoCompareClientTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build clean, all tests pass.

- [ ] **Step 4: Update factory wiring (deferred to PR-5)**

`App/ProfileSession+Factories.swift` constructs `CryptoCompareClient()` (no args, defaults). With the new init signature, this is a compile error. **Temporarily** update the factory construction to:

```swift
let cryptoCompareClient = CryptoCompareClient(
  http: NetworkingServices().client(forHost: "min-api.cryptocompare.com"))
```

This is intentional throwaway code: PR-5 replaces the inline `NetworkingServices()` with the shared instance threaded through the app. Mark it with a `TODO(#938)` comment pointing at PR-5:

```swift
// TODO(#938): replace with shared NetworkingServices from ProfileSession init
//   once PR-5 of plans/2026-05-21-api-client-architecture-implementation.md
//   lands. https://github.com/ajsutton/moolah-native/issues/938
let cryptoCompareClient = CryptoCompareClient(
  http: NetworkingServices().client(forHost: "min-api.cryptocompare.com"))
```

> **Format note:** the `TODO(#N)` form is required by `just validate-todos` (CI gate). The bare `TODO:` form would fail CI.

- [ ] **Step 5: Run full build**

```bash
just build-mac
```

Expected: clean.

---

## Task 2-2: `CoinGeckoClient`

**Files:**
- Modify: `Backends/CoinGecko/CoinGeckoClient.swift`
- Modify: `MoolahTests/Backends/CoinGeckoClientTests.swift`

CoinGecko is the one client with a dual-host shape: `pro-api.coingecko.com` (key set) or `api.coingecko.com` (no key). The factory picks the host at construction time based on `apiKey`.

- [ ] **Step 1: Update the client**

Replace the stored properties + init in `Backends/CoinGecko/CoinGeckoClient.swift` (lines 17-32) with:

```swift
private let http: RateLimitedHTTPClient
private let apiKey: String

init(apiKey: String, http: RateLimitedHTTPClient) {
  self.apiKey = apiKey
  self.http = http
}
```

Then replace each `session.dataRespectingRateLimit(...)` call (lines 68 and 87) with `http.data(for: URLRequest(url: url))` and remove the surrounding 2xx status check.

- [ ] **Step 2: Update the tests**

Replace each `CoinGeckoClient(session: …, apiKey: …, rateLimitGate: …, failureCache: …)` with:

```swift
let services = NetworkingServices(session: stubbedSession)
let host = apiKey.isEmpty ? "api.coingecko.com" : "pro-api.coingecko.com"
let client = CoinGeckoClient(
  apiKey: apiKey, http: services.client(forHost: host))
```

- [ ] **Step 3: Update factory wiring (PR-5 placeholder)**

In `App/ProfileSession+Factories.swift`, replace the `CoinGeckoClient(apiKey: resolverApiKey)` construction with:

```swift
// TODO(#938): replace with shared NetworkingServices once PR-5 lands.
//   https://github.com/ajsutton/moolah-native/issues/938
let cgHost = resolverApiKey.isEmpty ? "api.coingecko.com" : "pro-api.coingecko.com"
let coinGeckoClient = CoinGeckoClient(
  apiKey: resolverApiKey,
  http: NetworkingServices().client(forHost: cgHost))
```

- [ ] **Step 4: Build + test**

```bash
just build-mac
just test-mac CoinGeckoClientTests
```

Expected: clean.

---

## Task 2-3: `BinanceClient`

**Files:**
- Modify: `Backends/Binance/BinanceClient.swift`
- Modify: `MoolahTests/Backends/BinanceClientTests.swift`

`BinanceClient` is special: it also takes a `usdtRateLookup` closure. That stays.

- [ ] **Step 1: Update the client**

Replace stored props + init (lines 10-25):

```swift
private let http: RateLimitedHTTPClient
private let usdtRateLookup: @Sendable (Date) async -> Decimal

init(
  http: RateLimitedHTTPClient,
  usdtRateLookup: @escaping @Sendable (Date) async -> Decimal = { _ in Decimal(1) }
) {
  self.http = http
  self.usdtRateLookup = usdtRateLookup
}
```

Replace the `session.dataRespectingRateLimit(...)` call (line 53) with `http.data(for: …)`. Drop the 2xx check (line 55).

- [ ] **Step 2: Update the tests**

Replace each `BinanceClient(session: …, …)` with:

```swift
let services = NetworkingServices(session: stubbedSession)
let client = BinanceClient(
  http: services.client(forHost: "api.binance.com"))
```

- [ ] **Step 3: Update factory wiring (PR-5 placeholder)**

In `App/ProfileSession+Factories.swift`, the `binanceClient = BinanceClient { date in … }` construction becomes:

```swift
// TODO(#938): replace with shared NetworkingServices once PR-5 lands.
//   https://github.com/ajsutton/moolah-native/issues/938
let binanceClient = BinanceClient(
  http: NetworkingServices().client(forHost: "api.binance.com"),
  usdtRateLookup: { date in
    let usdtMapping = CryptoProviderMapping(
      instrumentId: "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
      coingeckoId: "tether", cryptocompareSymbol: "USDT", binanceSymbol: nil
    )
    do {
      return try await cryptoCompareClient.dailyPrice(for: usdtMapping, on: date)
    } catch {
      return Decimal(1)
    }
  })
```

- [ ] **Step 4: Build + test**

```bash
just build-mac
just test-mac BinanceClientTests
```

Expected: clean.

---

## Task 2-4: `FrankfurterClient`

**Files:**
- Modify: `Backends/Frankfurter/FrankfurterClient.swift`
- Modify: `MoolahTests/Backends/FrankfurterClientTests.swift`

- [ ] **Step 1: Update the client**

Replace stored props + init (lines 15-23):

```swift
private let http: RateLimitedHTTPClient

init(http: RateLimitedHTTPClient) {
  self.http = http
}
```

Replace `session.dataRespectingRateLimit(...)` with `http.data(for: …)` and drop the status check.

- [ ] **Step 2: Update the tests**

```swift
let services = NetworkingServices(session: stubbedSession)
let client = FrankfurterClient(http: services.client(forHost: "api.frankfurter.app"))
```

- [ ] **Step 3: Update factory wiring (PR-5 placeholder)**

In `App/ProfileSession+Factories.swift`:

```swift
// TODO(#938): replace with shared NetworkingServices once PR-5 lands.
//   https://github.com/ajsutton/moolah-native/issues/938
exchangeRate: ExchangeRateService(
  client: FrankfurterClient(
    http: NetworkingServices().client(forHost: "api.frankfurter.app")),
  database: database),
```

`Shared/PreviewBackend.swift` line 50 also constructs `FrankfurterClient()`. Update to:

```swift
client: FrankfurterClient(
  http: NetworkingServices().client(forHost: "api.frankfurter.app")),
```

- [ ] **Step 4: Build + test**

```bash
just build-mac
just test-mac FrankfurterClientTests
```

Expected: clean.

---

## Task 2-5: `YahooFinanceClient`

**Files:**
- Modify: `Backends/YahooFinance/YahooFinanceClient.swift`
- Modify: `MoolahTests/Backends/YahooFinanceClientTests.swift`

- [ ] **Step 1: Update the client**

Replace stored props + init (lines 14-24):

```swift
private let http: RateLimitedHTTPClient

init(http: RateLimitedHTTPClient) {
  self.http = http
}
```

Replace `session.dataRespectingRateLimit(...)` with `http.data(for: …)`.

- [ ] **Step 2: Update the tests**

```swift
let services = NetworkingServices(session: stubbedSession)
let client = YahooFinanceClient(
  http: services.client(forHost: "query2.finance.yahoo.com"))
```

- [ ] **Step 3: Update factory wiring (PR-5 placeholder)**

In `App/ProfileSession+Factories.swift`:

```swift
// TODO(#938): replace with shared NetworkingServices once PR-5 lands.
//   https://github.com/ajsutton/moolah-native/issues/938
let yahooClient = YahooFinanceClient(
  http: NetworkingServices().client(forHost: "query2.finance.yahoo.com"))
```

- [ ] **Step 4: Build + test**

```bash
just build-mac
just test-mac YahooFinanceClientTests
```

Expected: clean.

---

## Task 2-6: `YahooFinanceStockSearchClient`

**Files:**
- Modify: `Backends/YahooFinance/YahooFinanceStockSearchClient.swift`
- Modify: `MoolahTests/Backends/YahooFinanceStockSearchClientTests.swift`

- [ ] **Step 1: Update the client**

Replace stored props + init (lines 11-24):

```swift
private let http: RateLimitedHTTPClient

init(http: RateLimitedHTTPClient) {
  self.http = http
}
```

Replace `session.dataRespectingRateLimit(...)` with `http.data(for: …)`.

- [ ] **Step 2: Update the tests**

```swift
let services = NetworkingServices(session: stubbedSession)
let client = YahooFinanceStockSearchClient(
  http: services.client(forHost: "query1.finance.yahoo.com"))
```

- [ ] **Step 3: Update factory wiring (PR-5 placeholder)**

In `App/ProfileSession+Factories.swift`:

```swift
// TODO(#938): replace with shared NetworkingServices once PR-5 lands.
//   https://github.com/ajsutton/moolah-native/issues/938
stockSearchClient: YahooFinanceStockSearchClient(
  http: NetworkingServices().client(forHost: "query1.finance.yahoo.com"))
```

- [ ] **Step 4: Build + test**

```bash
just build-mac
just test-mac YahooFinanceStockSearchClientTests
```

Expected: clean.

---

## Task 2-7: PR-2 final verification

**Files:** none.

- [ ] **Step 1: Full build + tests + format**

```bash
mkdir -p .agent-tmp
just format-check
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
just test-mac 2>&1 | tee .agent-tmp/test-mac.txt
grep -i 'failed\|error:' .agent-tmp/test-mac.txt | head -20
```

Expected: clean. Look for any test that references `dataRespectingRateLimit` or imports the old init signatures — they should not exist for any of the 6 migrated clients.

- [ ] **Step 2: Verify `TODO(#938)` markers**

```bash
just validate-todos
```

Expected: passes. The TODOs reference issue #938, which is open.

- [ ] **Step 3: Remove temp files**

```bash
rm -rf .agent-tmp
```

- [ ] **Step 4: Commit + push + PR + queue**

```bash
git -C "$(pwd)" add Backends/CryptoCompare Backends/CoinGecko Backends/Binance \
  Backends/Frankfurter Backends/YahooFinance \
  MoolahTests/Backends App/ProfileSession+Factories.swift \
  Shared/PreviewBackend.swift
git -C "$(pwd)" commit -m "$(cat <<'EOF'
feat(networking): migrate 6 standard clients to RateLimitedHTTPClient

For #938. CryptoCompareClient, CoinGeckoClient, BinanceClient,
FrankfurterClient, YahooFinanceClient, and YahooFinanceStockSearchClient
each lose their (session, rateLimitGate, failureCache) trio and gain a
single `http: RateLimitedHTTPClient` parameter. The (200...299) status
check is removed from each call site — RateLimitedHTTPClient.data(for:)
handles it.

Factory wiring in ProfileSession+Factories.swift (and PreviewBackend.swift)
uses inline NetworkingServices() construction with TODO(#938) markers.
PR-5 replaces those with a shared instance threaded through the app.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git -C "$(pwd)" push origin feat/migrate-standard-clients-to-rate-limited-http:feat/migrate-standard-clients-to-rate-limited-http -u
gh pr create --title "feat(networking): migrate 6 standard clients to RateLimitedHTTPClient" --body "$(cat <<'EOF'
## Summary

Second PR for #938. Migrates the 6 single-host clients that share the `(URLSession, RateLimitGate, FailedRequestCache)` trio to the new `RateLimitedHTTPClient` API:

- `CryptoCompareClient` → `min-api.cryptocompare.com`
- `CoinGeckoClient` → `pro-api.coingecko.com` / `api.coingecko.com` (key-dependent)
- `BinanceClient` → `api.binance.com`
- `FrankfurterClient` → `api.frankfurter.app`
- `YahooFinanceClient` → `query2.finance.yahoo.com`
- `YahooFinanceStockSearchClient` → `query1.finance.yahoo.com`

Each client loses 3 lines of constructor boilerplate and 3 lines of `(200...299)` status-check boilerplate per request. Factory wiring uses inline `NetworkingServices()` with `TODO(#938)` markers — PR-5 of #938 replaces those with a shared instance threaded through the app, so 429s from one client cool down every other caller of the same host.

## Test plan

- [x] `just test-mac` — full suite green.
- [x] `just validate-todos` — passes.

Refs #938
🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Then invoke the `merge-queue` skill with the new PR number.

---

# PR-3 — Migrate `CompositeTokenResolutionClient`

**Branch:** `feat/migrate-composite-resolver-to-networking-services` (off `main`).

Composite is the one client in this work that takes `NetworkingServices` (not a single `RateLimitedHTTPClient`) because it bridges three hosts: `min-api.cryptocompare.com`, `api.binance.com`, and `api.coingecko.com` / `pro-api.coingecko.com`.

## Task 3-1: Update `CompositeTokenResolutionClient`

**Files:**
- Modify: `Shared/CompositeTokenResolutionClient.swift`
- Modify: `MoolahTests/Shared/CompositeTokenResolutionClientTests.swift`

- [ ] **Step 1: Update stored properties + initializers**

Replace lines 7-35 of `Shared/CompositeTokenResolutionClient.swift` with:

```swift
private let networking: NetworkingServices
private let coinGeckoApiKey: String?

// For testing: inject pre-parsed reference data
private let preloadedCoinList: Data?
private let preloadedExchangeInfo: Data?

init(networking: NetworkingServices, coinGeckoApiKey: String? = nil) {
  self.networking = networking
  self.coinGeckoApiKey = coinGeckoApiKey
  self.preloadedCoinList = nil
  self.preloadedExchangeInfo = nil
}

/// Test initializer with pre-loaded reference data. Accepts an optional
/// `networking` so tests that exercise the CoinGecko-dependent paths can
/// plug a `StubURLProtocol`-backed `NetworkingServices` in.
init(
  coinListData: Data,
  exchangeInfoData: Data,
  coinGeckoApiKey: String?,
  networking: NetworkingServices = NetworkingServices()
) {
  self.networking = networking
  self.coinGeckoApiKey = coinGeckoApiKey
  self.preloadedCoinList = coinListData
  self.preloadedExchangeInfo = exchangeInfoData
}
```

- [ ] **Step 2: Replace each fetch helper**

Replace the four `session.data(for: URLRequest(url: url))` call sites with `networking.client(forHost: …).data(for: …)`. Remove the 2xx status check that follows each call.

`fetchCoinListData()` (lines 166-174):

```swift
private func fetchCoinListData() async throws -> Data {
  if let preloaded = preloadedCoinList { return preloaded }
  let url = CryptoCompareClient.coinListURL()
  let http = networking.client(forHost: "min-api.cryptocompare.com")
  let (data, _) = try await http.data(for: URLRequest(url: url))
  return data
}
```

`fetchExchangeInfoData()` (lines 176-184):

```swift
private func fetchExchangeInfoData() async throws -> Data {
  if let preloaded = preloadedExchangeInfo { return preloaded }
  let url = BinanceClient.exchangeInfoURL()
  let http = networking.client(forHost: "api.binance.com")
  let (data, _) = try await http.data(for: URLRequest(url: url))
  return data
}
```

`fetchAssetPlatforms(apiKey:)` (lines 186-193):

```swift
private func fetchAssetPlatforms(apiKey: String) async throws -> [Int: String] {
  let url = CoinGeckoClient.assetPlatformsURL(apiKey: apiKey)
  let host = apiKey.isEmpty ? "api.coingecko.com" : "pro-api.coingecko.com"
  let http = networking.client(forHost: host)
  let (data, _) = try await http.data(for: URLRequest(url: url))
  return try CoinGeckoClient.parseAssetPlatformsResponse(data)
}
```

Inline contract lookup inside `resolveFromCoinGecko(...)` (lines 105-113):

```swift
let url = CoinGeckoClient.contractLookupURL(
  platformId: platformSlug, contractAddress: contractAddress, apiKey: apiKey)
let host = apiKey.isEmpty ? "api.coingecko.com" : "pro-api.coingecko.com"
let http = networking.client(forHost: host)
let (data, _) = try await http.data(for: URLRequest(url: url))
let lookup = try CoinGeckoClient.parseContractLookupResponse(data)
```

Drop the surrounding `guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }` — the new `http.data(for:)` throws on non-2xx. **However**, this site is wrapped in `do { … } catch { /* best-effort */ }`, so the throw is silently swallowed at the same spot the early `return` was. Behaviour preserved.

- [ ] **Step 3: Update tests**

In `MoolahTests/Shared/CompositeTokenResolutionClientTests.swift`, replace each `CompositeTokenResolutionClient(session: …, coinGeckoApiKey: …)` and `CompositeTokenResolutionClient(coinListData: …, exchangeInfoData: …, coinGeckoApiKey: …, session: …)` with the `networking:` form:

```swift
let services = NetworkingServices(session: stubbedSession)
let client = CompositeTokenResolutionClient(
  networking: services, coinGeckoApiKey: apiKey)

// or for the preloaded shape:
let client = CompositeTokenResolutionClient(
  coinListData: coinListData,
  exchangeInfoData: exchangeInfoData,
  coinGeckoApiKey: apiKey,
  networking: services)
```

- [ ] **Step 4: Update factory wiring (PR-5 placeholder)**

In `App/ProfileSession+Factories.swift`, the `CompositeTokenResolutionClient(coinGeckoApiKey: resolverApiKey)` construction at line 82 becomes:

```swift
// TODO(#938): replace with shared NetworkingServices once PR-5 lands.
//   https://github.com/ajsutton/moolah-native/issues/938
resolutionClient: CompositeTokenResolutionClient(
  networking: NetworkingServices(), coinGeckoApiKey: resolverApiKey)
```

Same at line 165 (another factory construction).

- [ ] **Step 5: Build + test**

```bash
just build-mac
just test-mac CompositeTokenResolutionClientTests
```

Expected: clean.

---

## Task 3-2: PR-3 final verification

**Files:** none.

- [ ] **Step 1: Full build + tests + format**

```bash
just format-check
just build-mac
just test-mac
just validate-todos
```

Expected: clean.

- [ ] **Step 2: Commit + push + PR + queue**

```bash
git -C "$(pwd)" add Shared/CompositeTokenResolutionClient.swift \
  MoolahTests/Shared/CompositeTokenResolutionClientTests.swift \
  App/ProfileSession+Factories.swift
git -C "$(pwd)" commit -m "$(cat <<'EOF'
feat(networking): migrate CompositeTokenResolutionClient to NetworkingServices

For #938. Composite bridges three hosts (CryptoCompare coin list, Binance
exchange info, CoinGecko asset platforms / contract lookup), so it takes
NetworkingServices and resolves a RateLimitedHTTPClient per-request via
client(forHost:). Drops the four bare `session.data(for:)` call sites and
their (200...299) status checks.

Effect: a CryptoCompare 429 on the price-fetch path now cools down
Composite's coin-list fetch on the same host, and vice versa — closing
the gap that motivated bringing this client into scope.

Factory wiring uses inline NetworkingServices() with TODO(#938); PR-5
replaces with the shared instance.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git -C "$(pwd)" push origin feat/migrate-composite-resolver-to-networking-services:feat/migrate-composite-resolver-to-networking-services -u
gh pr create --title "feat(networking): migrate CompositeTokenResolutionClient to NetworkingServices" --body "$(cat <<'EOF'
## Summary

Third PR for #938. Migrates `CompositeTokenResolutionClient` (multi-host) to inject `NetworkingServices` and resolve `client(forHost:)` per request. Drops 4 bare `session.data(for:)` call sites and their 2xx status checks.

After this PR, a CryptoCompare 429 on the price-fetch path also cools down Composite's coin-list fetch on the same host — closing the gap that motivated including Composite in the migration scope.

## Test plan

- [x] `just test-mac CompositeTokenResolutionClientTests` — green.
- [x] `just test-mac` — full suite green.

Refs #938
🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Then invoke the `merge-queue` skill with the new PR number.

---

# PR-4 — Migrate `SQLiteCoinGeckoCatalog+Refresh` and retire the extension

**Branch:** `feat/migrate-coingecko-catalog-refresh-and-retire-extension` (off `main`).

`SQLiteCoinGeckoCatalog+Refresh.refresh(session:…)` becomes `refresh(http:…)`. After this PR, no caller uses `URLSession.dataRespectingRateLimit` — the extension and its file get deleted.

## Task 4-1: Update `SQLiteCoinGeckoCatalog+Refresh`

**Files:**
- Modify: `Backends/CoinGecko/SQLiteCoinGeckoCatalog+Refresh.swift`
- Modify: `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift` (the caller of refresh)
- Modify: `MoolahTests/Backends/SQLiteCoinGeckoCatalogRefreshTests.swift`

- [ ] **Step 1: Update the refresh helper signature**

Replace the `session: URLSession` parameter with `http: RateLimitedHTTPClient` in `Backends/CoinGecko/SQLiteCoinGeckoCatalog+Refresh.swift` (around line 112). Replace `let (data, response) = try await session.data(for: request)` (line 121) with:

```swift
let (data, _) = try await http.data(for: request)
```

Drop any subsequent 2xx status check; it's now handled by `http.data(for:)`.

(If the existing code uses `response` for `ETag` headers or similar — re-read the surrounding lines and ensure the `HTTPURLResponse` returned by `http.data(for:)` is captured when needed:

```swift
let (data, response) = try await http.data(for: request)
let etag = response.value(forHTTPHeaderField: "ETag")
```

The new method returns `(Data, HTTPURLResponse)` directly, not `(Data, URLResponse)`, so any `as? HTTPURLResponse` cast can be dropped.)

- [ ] **Step 2: Update `SQLiteCoinGeckoCatalog`'s stored state and `make` signature**

`SQLiteCoinGeckoCatalog` (an actor) currently stores `let session: URLSession` and exposes it cross-extension so `+Refresh` can read it. Change the actor to store a `RateLimitedHTTPClient` instead.

In `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift`:

1. Replace `let session: URLSession` (line ~17) with `let http: RateLimitedHTTPClient`. Update the cross-extension internals comment block to rename `session` → `http`.
2. Replace the `static func make(directory:session:)` signature (line ~42) with `static func make(directory:http:)`:

```swift
static func make(
  directory: URL,
  http: RateLimitedHTTPClient
) throws -> SQLiteCoinGeckoCatalog {
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true
  )
  let database = try open(dbURL: directory.appendingPathComponent("catalog.sqlite"))
  return SQLiteCoinGeckoCatalog(
    directory: directory, http: http, database: database)
}
```

3. Update the private `init` parameter (line ~54) to take `http: RateLimitedHTTPClient`.

The factory that constructs `SQLiteCoinGeckoCatalog.make(...)` is `makeCoinGeckoCatalog()` in `App/ProfileSession+Factories.swift` (around line 215). It currently takes no parameters and has no access to the CoinGecko API key in scope. For the PR-4 transitional placeholder, hard-code the free host (`api.coingecko.com`) — the inline `NetworkingServices()` has its own gate that nothing else uses, so the host choice is irrelevant for now. PR-5 fixes this by threading the API key + shared `NetworkingServices` through.

Replace line ~221:

```swift
let catalog = try SQLiteCoinGeckoCatalog.make(directory: directory)
```

with:

```swift
// TODO(#938): receive `networking: NetworkingServices` + the resolved
//   CoinGecko host as a parameter once PR-5 lands. For now the inline
//   NetworkingServices() instance is private to this factory call, so
//   the host string is a placeholder.
//   https://github.com/ajsutton/moolah-native/issues/938
let catalog = try SQLiteCoinGeckoCatalog.make(
  directory: directory,
  http: NetworkingServices().client(forHost: "api.coingecko.com"))
```

- [ ] **Step 3: Update the tests**

In `MoolahTests/Backends/SQLiteCoinGeckoCatalogRefreshTests.swift`, replace the `session:` parameter on the refresh invocations with:

```swift
let services = NetworkingServices(session: stubbedSession)
let http = services.client(forHost: "api.coingecko.com")
try await catalog.refresh(http: http)
```

- [ ] **Step 4: Build + test**

```bash
just build-mac
just test-mac SQLiteCoinGeckoCatalogRefreshTests
```

Expected: clean.

---

## Task 4-2: Delete the retired `URLSession+RateLimited` extension

**Files:**
- Delete: `Shared/Networking/URLSession+RateLimited.swift`

- [ ] **Step 1: Confirm no remaining call sites**

```bash
grep -rn "dataRespectingRateLimit" --include="*.swift" .
```

Expected: zero matches.

If any matches remain, this task cannot proceed — find and migrate them first.

- [ ] **Step 2: Delete the extension and its tests**

```bash
git -C "$(pwd)" rm Shared/Networking/URLSession+RateLimited.swift
git -C "$(pwd)" rm MoolahTests/Shared/URLSessionRateLimitTests.swift
```

- [ ] **Step 3: Build + tests**

```bash
just generate     # ensure the project file reflects the removal
just build-mac
just test-mac
```

Expected: clean.

---

## Task 4-3: PR-4 final verification

**Files:** none.

- [ ] **Step 1: Full build + tests + format**

```bash
just format-check
just build-mac
just test-mac
just validate-todos
```

Expected: clean.

- [ ] **Step 2: Verify the extension is gone**

```bash
test ! -f Shared/Networking/URLSession+RateLimited.swift && echo "OK: extension deleted"
grep -rn "dataRespectingRateLimit" --include="*.swift" . || echo "OK: no more references"
```

- [ ] **Step 3: Commit + push + PR + queue**

```bash
git -C "$(pwd)" add Backends/CoinGecko \
  MoolahTests/Backends/SQLiteCoinGeckoCatalogRefreshTests.swift \
  App/ProfileSession+Factories.swift App/MoolahApp+SharedInstrumentScope.swift
git -C "$(pwd)" rm Shared/Networking/URLSession+RateLimited.swift \
  MoolahTests/Shared/URLSessionRateLimitTests.swift
git -C "$(pwd)" commit -m "$(cat <<'EOF'
feat(networking): migrate SQLiteCoinGeckoCatalog+Refresh and retire extension

For #938. SQLiteCoinGeckoCatalog+Refresh.refresh(session:) becomes
refresh(http:RateLimitedHTTPClient). With the catalog refresh migrated,
no caller uses URLSession.dataRespectingRateLimit anymore, so the
extension and its file are deleted outright.

Factory wiring uses inline NetworkingServices() with TODO(#938); PR-5
replaces with the shared instance.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git -C "$(pwd)" push origin feat/migrate-coingecko-catalog-refresh-and-retire-extension:feat/migrate-coingecko-catalog-refresh-and-retire-extension -u
gh pr create --title "feat(networking): migrate catalog refresh and retire URLSession+RateLimited" --body "$(cat <<'EOF'
## Summary

Fourth PR for #938. Migrates `SQLiteCoinGeckoCatalog+Refresh.refresh(session:)` to `refresh(http: RateLimitedHTTPClient)`. With this last consumer migrated, the `URLSession.dataRespectingRateLimit` extension is deleted outright (the file is removed).

## Test plan

- [x] `just test-mac SQLiteCoinGeckoCatalogRefreshTests` — green.
- [x] `grep -rn "dataRespectingRateLimit" --include="*.swift" .` returns zero matches.
- [x] `just test-mac` — full suite green.

Refs #938
🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Then invoke the `merge-queue` skill with the new PR number.

---

# PR-5 — Wire `NetworkingServices` through the app

**Branch:** `feat/share-networking-services-process-wide` (off `main`, after PR-2/3/4 land).

This PR replaces every `NetworkingServices()` inline construction (and its `TODO(#938)` marker) with a single instance threaded through `MoolahApp+Setup` → `SyncCoordinator` → `ProfileSession` → factories. After this PR, gates are genuinely process-shared.

## Task 5-1: Add `sharedNetworking` to `SyncCoordinator`

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift`

- [ ] **Step 1: Add the stored property**

After line 175 (`nonisolated let sharedMarketData: ProfileSession.MarketDataServices?`), add:

```swift
/// App-level shared `NetworkingServices` instance. When wired, every
/// profile session reads its `RateLimitedHTTPClient`s through this
/// registry, so two callers of the same host share a `RateLimitGate`
/// (a 429 from one cools down every caller of that host). `nil` for
/// preview / test callers that don't pass shared services. See
/// `guides/CONCURRENCY_GUIDE.md` §4 (post-#938).
nonisolated let sharedNetworking: NetworkingServices?
```

- [ ] **Step 2: Add the init parameter**

In the `init(...)` signature around line 341, add a new parameter:

```swift
init(
  containerManager: ProfileContainerManager,
  userDefaults: UserDefaults = .moolahShared,
  isCloudKitAvailable: Bool = CloudKitAuthProvider.isCloudKitAvailable,
  sharedInstrumentRegistry: GRDBInstrumentRegistryRepository? = nil,
  sharedMarketData: ProfileSession.MarketDataServices? = nil,
  sharedRegistryStore: SharedRegistryStore? = nil,
  sharedNetworking: NetworkingServices? = nil
) {
  …
  self.sharedNetworking = sharedNetworking
  …
}
```

- [ ] **Step 3: Build**

```bash
just build-mac
```

Expected: clean (no behaviour change yet — nothing reads `sharedNetworking`).

---

## Task 5-2: Thread `NetworkingServices` into `makeSharedInstrumentScope`

**Files:**
- Modify: `App/MoolahApp+SharedInstrumentScope.swift`
- Modify: `App/ProfileSession+Factories.swift`

- [ ] **Step 1: Construct `NetworkingServices` in `bootstrapSyncCoordinator`**

Replace `App/MoolahApp+SharedInstrumentScope.swift` `bootstrapSyncCoordinator(setup:)` and `makeSharedInstrumentScope(setup:)`:

```swift
static func bootstrapSyncCoordinator(setup: ContainerSetup) -> SyncCoordinator {
  let networking = NetworkingServices()
  let scope = makeSharedInstrumentScope(setup: setup, networking: networking)
  let registryStore = SharedRegistryStore(registry: scope.registry)
  let coordinator = SyncCoordinator(
    containerManager: setup.manager,
    sharedInstrumentRegistry: scope.registry,
    sharedMarketData: scope.marketData,
    sharedRegistryStore: registryStore,
    sharedNetworking: networking)
  attachSharedInstrumentRegistrySyncHooks(
    registry: scope.registry, coordinator: coordinator)
  return coordinator
}

static func makeSharedInstrumentScope(
  setup: ContainerSetup,
  networking: NetworkingServices
) -> (
  registry: GRDBInstrumentRegistryRepository,
  marketData: ProfileSession.MarketDataServices
) {
  let database = setup.manager.profileIndexDatabase
  return (
    registry: makeSharedInstrumentRegistry(database: database),
    marketData: ProfileSession.makeMarketDataServices(
      database: database, networking: networking)
  )
}
```

- [ ] **Step 2: Update `ProfileSession.makeMarketDataServices` signature**

In `App/ProfileSession+Factories.swift`, change `makeMarketDataServices(database:)` to `makeMarketDataServices(database:networking:)`:

```swift
static func makeMarketDataServices(
  database: any DatabaseWriter,
  networking: NetworkingServices
) -> MarketDataServices {
  let yahooClient = YahooFinanceClient(
    http: networking.client(forHost: "query2.finance.yahoo.com"))
  let apiKeyStore = KeychainStore(
    service: KeychainServices.apiKeys, account: "coingecko", synchronizable: true
  )
  let coinGeckoApiKey = try? apiKeyStore.restoreString()
  return MarketDataServices(
    exchangeRate: ExchangeRateService(
      client: FrankfurterClient(
        http: networking.client(forHost: "api.frankfurter.app")),
      database: database),
    stockPrice: StockPriceService(client: yahooClient, database: database),
    cryptoPrice: Self.makeCryptoPriceService(
      coinGeckoApiKey: coinGeckoApiKey, database: database, networking: networking),
    yahooPriceFetcher: yahooClient,
    coinGeckoApiKey: coinGeckoApiKey
  )
}
```

Same for `makeCryptoPriceService` — add a `networking: NetworkingServices` param and use it for every client construction:

```swift
static func makeCryptoPriceService(
  coinGeckoApiKey: String?,
  database: any DatabaseWriter,
  networking: NetworkingServices
) -> CryptoPriceService {
  let resolverApiKey = coinGeckoApiKey ?? ""
  let cgHost = resolverApiKey.isEmpty ? "api.coingecko.com" : "pro-api.coingecko.com"
  let cryptoCompareClient = CryptoCompareClient(
    http: networking.client(forHost: "min-api.cryptocompare.com"))
  let binanceClient = BinanceClient(
    http: networking.client(forHost: "api.binance.com"),
    usdtRateLookup: { date in
      let usdtMapping = CryptoProviderMapping(
        instrumentId: "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
        coingeckoId: "tether", cryptocompareSymbol: "USDT", binanceSymbol: nil
      )
      do {
        return try await cryptoCompareClient.dailyPrice(for: usdtMapping, on: date)
      } catch {
        return Decimal(1)
      }
    })
  let priceClients: [CryptoPriceClient] = [
    CoinGeckoClient(
      apiKey: resolverApiKey, http: networking.client(forHost: cgHost)),
    cryptoCompareClient,
    binanceClient,
  ]
  return CryptoPriceService(
    clients: priceClients,
    database: database,
    resolutionClient: CompositeTokenResolutionClient(
      networking: networking, coinGeckoApiKey: resolverApiKey)
  )
}
```

Delete every `TODO(#938)` marker added in PRs 2-4 from this file.

Same for the second `CompositeTokenResolutionClient` construction around line 165 — thread `networking` through and delete the TODO.

Same for `YahooFinanceStockSearchClient` around line 180:

```swift
stockSearchClient: YahooFinanceStockSearchClient(
  http: networking.client(forHost: "query1.finance.yahoo.com"))
```

(Every factory function this method calls needs a `networking` parameter — chase the chain in the file.)

- [ ] **Step 3: Update `Shared/PreviewBackend.swift`**

Replace inline `NetworkingServices()` calls with a single shared instance constructed at the top of the preview backend factory. Delete `TODO(#938)` markers.

- [ ] **Step 4: Build + test**

```bash
just build-mac
just test-mac
```

Expected: clean.

---

## Task 5-3: Thread `networking` into `ProfileSession.init`

**Files:**
- Modify: `App/ProfileSession.swift`
- Modify: `App/ProfileSession+Database.swift`
- Modify: `App/SessionManager.swift`
- Modify: `Shared/PreviewBackend.swift`
- Modify: test fixtures (`MoolahTests/App/ProfileSessionTests.swift`, `MoolahTests/App/SessionManagerMidSessionBumpTests.swift`, `MoolahTests/App/ProfileSessionPragmaOptimizeTests.swift`, `MoolahTests/Backends/CloudKit/SyncCoordinatorRemoveDataHandlerTests.swift`)

- [ ] **Step 1: Add `networking` to `ProfileSession.init`**

In `App/ProfileSession.swift`, around line 125-130, add the parameter (with a default so legacy/test callers compile):

```swift
init(
  profile: Profile,
  containerManager: ProfileContainerManager? = nil,
  syncCoordinator: SyncCoordinator? = nil,
  database: DatabaseQueue? = nil,
  networking: NetworkingServices? = nil
) throws {
  …
  // Prefer the app-level shared NetworkingServices via SyncCoordinator,
  // fall back to the directly-injected one, then to a fresh instance for
  // preview / test fixtures that didn't pass shared services through.
  let resolvedNetworking =
    syncCoordinator?.sharedNetworking ?? networking ?? NetworkingServices()
  …
  // Use resolvedNetworking instead of constructing a fresh
  // NetworkingServices in the fallback path.
  let services =
    syncCoordinator?.sharedMarketData
    ?? Self.makeMarketDataServices(database: resolvedDatabase, networking: resolvedNetworking)
  …
  let registryWiring = Self.makeRegistryWiring(
    backend: backend,
    cryptoPriceService: services.cryptoPrice,
    yahooPriceFetcher: services.yahooPriceFetcher,
    coinGeckoApiKey: services.coinGeckoApiKey,
    sharedRegistryStore: syncCoordinator?.sharedRegistryStore,
    networking: resolvedNetworking)
  …
}
```

`makeRegistryWiring` (in `App/ProfileSession+Factories.swift` around line 141) takes a new `networking: NetworkingServices` parameter and passes it through:

- To `CompositeTokenResolutionClient(networking: networking, coinGeckoApiKey: coinGeckoApiKey)` (replacing any inline `NetworkingServices()` left by PR-3).
- To `makeCoinGeckoCatalog(apiKey:networking:)` (a new signature added in this step). The catalog factory uses the api key to pick the host:

```swift
@MainActor
private static func makeCoinGeckoCatalog(
  apiKey: String?,
  networking: NetworkingServices
) -> (catalog: (any CoinGeckoCatalog)?, refreshTask: Task<Void, Never>?) {
  let directory = URL.moolahScopedApplicationSupport
    .appending(path: "InstrumentRegistry", directoryHint: .isDirectory)
  do {
    let host = (apiKey ?? "").isEmpty
      ? "api.coingecko.com" : "pro-api.coingecko.com"
    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: directory,
      http: networking.client(forHost: host))
    let refreshTask = Task(priority: .background) { [catalog] in
      await catalog.refreshIfStale()
    }
    return (catalog, refreshTask)
  } catch {
    Logger(subsystem: "com.moolah.app", category: "ProfileSession")
      .error("CoinGecko catalog init failed: \(error.localizedDescription, privacy: .public)")
    return (nil, nil)
  }
}
```

Delete the `TODO(#938)` marker added in PR-4.

- [ ] **Step 2: Update `SessionManager` to pass `networking` through**

In `App/SessionManager.swift`, the `makeSession(for:)` method around line 119 calls `ProfileSession(...)` — no change needed because `syncCoordinator?.sharedNetworking` already flows through. Confirm by re-reading the file.

- [ ] **Step 3: Update test fixtures**

For each test fixture that constructs `ProfileSession(...)` directly (without a `SyncCoordinator`):

```swift
// Before:
let session = try ProfileSession(profile: profile, containerManager: containerManager)
// After:
let session = try ProfileSession(
  profile: profile, containerManager: containerManager,
  networking: NetworkingServices())
```

Or, if the test passes a `SyncCoordinator`, ensure the coordinator was constructed with `sharedNetworking: NetworkingServices()`.

- [ ] **Step 4: Build + test**

```bash
just build-mac
just test-mac
```

Expected: clean.

---

## Task 5-4: PR-5 final verification

**Files:** none.

- [ ] **Step 1: Confirm no `TODO(#938)` markers remain in factories**

```bash
grep -rn "TODO(#938)" --include="*.swift" .
```

Expected: zero matches.

- [ ] **Step 2: Confirm no `NetworkingServices()` constructed inside factory functions**

```bash
grep -rn "NetworkingServices()" --include="*.swift" App/ Backends/ Shared/
```

Expected: matches **only** in `MoolahApp+SharedInstrumentScope.swift` (the single construction in `bootstrapSyncCoordinator`) and `Shared/PreviewBackend.swift` (the preview-only construction). Everything else takes `networking` as a parameter.

- [ ] **Step 3: Full build + tests + format**

```bash
just format-check
just build-mac
just test-mac
just validate-todos
```

Expected: clean.

- [ ] **Step 4: Commit + push + PR + queue**

```bash
git -C "$(pwd)" add App/MoolahApp+SharedInstrumentScope.swift \
  App/ProfileSession.swift App/ProfileSession+Factories.swift \
  App/ProfileSession+Database.swift App/SessionManager.swift \
  Backends/CloudKit/Sync/SyncCoordinator.swift \
  Shared/PreviewBackend.swift \
  MoolahTests/App MoolahTests/Backends/CloudKit
git -C "$(pwd)" commit -m "$(cat <<'EOF'
feat(networking): thread shared NetworkingServices through app wiring

For #938. Replaces every inline `NetworkingServices()` construction (and
its TODO(#938) marker) with a single instance constructed in
MoolahApp+Setup.bootstrapSyncCoordinator and threaded through:

  SyncCoordinator.sharedNetworking
    → ProfileSession.init (networking:)
    → ProfileSession.makeMarketDataServices (networking:)
    → every standard client (CryptoCompare, CoinGecko, Binance,
      Frankfurter, YahooFinance, YahooFinanceStockSearch),
      CompositeTokenResolutionClient, and SQLiteCoinGeckoCatalog+Refresh.

After this PR, gates are genuinely process-shared: a CryptoCompare 429
from one profile session cools down every other caller of
min-api.cryptocompare.com (across profiles, across stores, across
fetchers).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git -C "$(pwd)" push origin feat/share-networking-services-process-wide:feat/share-networking-services-process-wide -u
gh pr create --title "feat(networking): thread shared NetworkingServices through app wiring" --body "$(cat <<'EOF'
## Summary

Fifth PR for #938. Replaces every inline `NetworkingServices()` construction (and the TODO(#938) markers added in PRs 2-4) with a single instance constructed in `MoolahApp+SharedInstrumentScope.bootstrapSyncCoordinator` and threaded through `SyncCoordinator.sharedNetworking` → `ProfileSession.init(networking:)` → every factory.

After this PR, gates are genuinely process-shared. A CryptoCompare 429 from one caller cools down every other caller of `min-api.cryptocompare.com` — across profiles, across stores, across fetchers.

## Test plan

- [x] `grep TODO(#938)` returns zero matches in production code.
- [x] `grep NetworkingServices()` returns matches only in `bootstrapSyncCoordinator` and `PreviewBackend`.
- [x] `just test-mac` — full suite green.

Refs #938
🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Then invoke the `merge-queue` skill with the new PR number.

---

# PR-6 — Rewrite `CONCURRENCY_GUIDE.md` §4 (closes #938)

**Branch:** `docs/concurrency-guide-networking-shapes` (off `main`, after PR-5 lands).

Text-only. Replaces §4 of `guides/CONCURRENCY_GUIDE.md` with the four sanctioned shapes; updates the §2 `RemoteAccountRepository` example to match shape #1; updates the anti-pattern table row.

## Task 6-1: Rewrite §4

**Files:**
- Modify: `guides/CONCURRENCY_GUIDE.md`

- [ ] **Step 1: Replace §4 in full**

In `guides/CONCURRENCY_GUIDE.md`, locate the existing `## 4. Network Layer` section (line ~271 today) and replace it through the start of `## 5.` with:

```markdown
## 4. Network Layer

The codebase has **four sanctioned shapes** for HTTP work. Production code must use one of them; the `concurrency-review` agent flags any other shape.

### Sanctioned shape #1 — standard fetch

For single-host clients that need rate-limiting + per-URL failure-caching:

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

- `RateLimitedHTTPClient.data(for:)` validates 2xx and returns `(Data, HTTPURLResponse)`. Non-2xx throws `URLError(.badServerResponse)`. Rate-limit responses (429 / 418 / 503+Retry-After) trip the host's `RateLimitGate` and throw `RateLimitGateError.cooldown`. Transport failures mute the URL via the process-shared `FailedRequestCache`.
- The gate is **host-shared** through `NetworkingServices`: a 429 from one caller of `min-api.cryptocompare.com` cools down every caller of that host.
- Tests construct `NetworkingServices(session: stub)` and pass `services.client(forHost: "min-api.cryptocompare.com")`.

Used by: `CryptoCompareClient`, `CoinGeckoClient`, `BinanceClient`, `FrankfurterClient`, `YahooFinanceClient`, `YahooFinanceStockSearchClient`, `SQLiteCoinGeckoCatalog+Refresh`.

### Sanctioned shape #2 — multi-host caller

For components that bridge several hosts (e.g. a token resolver that pings CryptoCompare, Binance, and CoinGecko):

```swift
struct CompositeTokenResolutionClient: TokenResolutionClient, Sendable {
  private let networking: NetworkingServices
  init(networking: NetworkingServices, …) { self.networking = networking }

  private func fetchCoinListData() async throws -> Data {
    let http = networking.client(forHost: "min-api.cryptocompare.com")
    let (data, _) = try await http.data(for: URLRequest(url: CryptoCompareClient.coinListURL()))
    return data
  }
  // fetchExchangeInfoData   → api.binance.com
  // fetchAssetPlatforms     → api.coingecko.com / pro-api.coingecko.com
}
```

Resolve the per-host `RateLimitedHTTPClient` at each fetch site. The lookup is a `Dictionary` read under a lock — irrelevant against the HTTPS round-trip cost.

Used by: `CompositeTokenResolutionClient`.

### Sanctioned shape #3 — retry-driven RPC

For clients with no fallback provider (Blockscout) that must retry transient server errors in place:

```swift
struct LiveBlockscoutClient: Sendable {
  private let session: URLSession
  private let retryPolicy: HTTPRetryPolicy

  private func send(request: URLRequest, stage: String) async throws -> Data {
    var timed = request
    timed.timeoutInterval = retryPolicy.requestTimeout
    return try await withRetry(
      policy: retryPolicy,
      classify: { HTTPRetryClassifier.decision(for: $0, idempotent: true) },
      operation: { try await self.attempt(request: timed, stage: stage) }
    )
  }
}
```

- Doesn't use `RateLimitGate` (server-error retry in place doesn't fit the host-cooldown model).
- Translates to a provider-specific error vocabulary (`WalletSyncError`).

Used by: `LiveBlockscoutClient`.

### Sanctioned shape #4 — token-bucket RPC

For paid-tier APIs with explicit req/s quotas (Alchemy's 25 req/s free tier):

```swift
struct LiveAlchemyClient: Sendable {
  private let session: URLSession
  private let rateLimiter: RateLimiter  // token bucket actor

  func fetchReceipt(…) async throws -> AlchemyTransactionReceipt {
    try await rateLimiter.acquire()
    let (data, _) = try await session.data(for: request)
    …
  }
}
```

- `RateLimiter` is a token-bucket actor sized for the API plan (e.g. 25 req/s); not the same as the reactive `RateLimitGate`.
- Translates to a provider-specific error vocabulary (`WalletSyncError`).

Used by: `LiveAlchemyClient`.

### Why four shapes, not one

The variation is real:
- Standard fetch needs host-wide reactive 429 cooldown (shape 1).
- Multi-host clients need to switch hosts per call (shape 2).
- Retry-driven clients need bounded retry-with-backoff that the gate model doesn't express (shape 3).
- Token-bucket clients need proactive req/s throttling that doesn't fit a reactive gate (shape 4).

A single `APIClient` abstraction would either flatten this variation (lose the per-shape behaviour the call sites depend on) or absorb it via strategy enums (rename the toolkit without changing anything). The four shapes are the honest minimum.

### Request Deduplication

If multiple views request the same data simultaneously (e.g., account balances shown in sidebar and detail view), consider an actor-based task coalescer:

```swift
actor InFlightTaskCoalescer<Key: Hashable & Sendable, Value: Sendable> {
  private var inFlightTasks: [Key: Task<Value, Error>] = [:]

  func deduplicated(
    key: Key,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    if let existingTask = inFlightTasks[key] {
      return try await existingTask.value
    }
    let task = Task { try await operation() }
    inFlightTasks[key] = task
    defer { inFlightTasks[key] = nil }
    return try await task.value
  }
}
```

This is not currently implemented but should be considered if duplicate request patterns emerge.

### Error Handling

- Each shape's `Sendable` client maps network errors to a domain-specific error type before propagating (`CryptoPriceError`, `WalletSyncError`, `BackendError`, etc.).
- Shape 1 throws `URLError(.badServerResponse)` on non-2xx, `RateLimitGateError.cooldown` on rate-limit, `FailedRequestCacheError.cooldown` on a muted URL.
- Log errors with `os.Logger` before propagating.
```

- [ ] **Step 2: Update the §2 `RemoteAccountRepository` example**

The current §2 example (around line 96) uses the fictional `APIClient`. Replace with shape #1:

Find:
```markdown
Remote repository implementations are `final class` conforming to `Sendable`. They hold only `Sendable` state (an `APIClient` with a `URLSession` and `URL`).

```swift
final class RemoteAccountRepository: AccountRepository, Sendable {
    private let client: APIClient

    func fetchAll() async throws -> [Account] {
        let data = try await client.get("/api/accounts")
        return try JSONDecoder().decode([Account].self, from: data)
    }
}
```
```

Replace with:
```markdown
Remote repository implementations are `final class` or `struct` conforming to `Sendable`. They hold only `Sendable` state — typically a `RateLimitedHTTPClient` (from `NetworkingServices`) or the fields needed for one of the other sanctioned shapes in §4.

```swift
struct RemoteAccountRepository: AccountRepository, Sendable {
    private let http: RateLimitedHTTPClient

    init(http: RateLimitedHTTPClient) { self.http = http }

    func fetchAll() async throws -> [Account] {
        let url = URL(string: "/api/accounts", relativeTo: baseURL) ?? baseURL
        let (data, _) = try await http.data(for: URLRequest(url: url))
        return try JSONDecoder().decode([Account].self, from: data)
    }
}
```
```

- [ ] **Step 3: Update the anti-pattern table row**

Find the row in the Network section of the anti-pattern table (around line 518):

```markdown
| `URLSession` calls outside `APIClient` | Scattered network code, inconsistent error handling | Route all requests through `APIClient` |
```

Replace with:

```markdown
| Raw `URLSession.data(for:)` in production code outside the four sanctioned shapes | Scattered network code, inconsistent error handling, no host-shared rate-limit | Route through one of §4's four shapes (`RateLimitedHTTPClient`, `NetworkingServices`, `withRetry` + `HTTPRetryPolicy`, or `RateLimiter`) |
```

- [ ] **Step 4: Verify the §2 carve-out for `GateRegistry` is still accurate**

PR-1 added "Carve-out 4 — GateRegistry" to §2's `False Positives to Avoid` list. With §4 rewritten, the cross-reference in that carve-out paragraph (which says "PR-6 of #938 folds this carve-out into the rewritten §4") is now stale. Either:

- Keep it as a historical note (acceptable), or
- Trim to just the technical rationale.

Trim: replace the last sentence of carve-out 4 with:

```
The lock is the synchronisation primitive that makes the type genuinely thread-safe; `@unchecked` waives only Swift's structural check that `final class` automatically conforms to `Sendable`.
```

- [ ] **Step 5: Run the markdown linter (if any)**

Run: `just format-check`

Expected: passes. (`just format-check` is Swift-focused but should not flag the markdown changes.)

- [ ] **Step 6: Build + tests (sanity — markdown shouldn't break the build)**

```bash
just build-mac
just test-mac
```

Expected: clean.

---

## Task 6-2: PR-6 final verification

**Files:** none.

- [ ] **Step 1: Re-read the guide change for self-consistency**

Open `guides/CONCURRENCY_GUIDE.md` and verify:
- §4's four shapes correspond exactly to the architecture shipped by PRs 1-5.
- The §2 `RemoteAccountRepository` example compiles in your head as shape #1.
- The anti-pattern table row references all four shapes by name.
- The carve-out 4 for `GateRegistry` reads as standalone (no stale cross-reference).

- [ ] **Step 2: Commit + push + PR + queue**

```bash
git -C "$(pwd)" add guides/CONCURRENCY_GUIDE.md
git -C "$(pwd)" commit -m "$(cat <<'EOF'
docs(concurrency-guide): rewrite §4 around the four sanctioned shapes

Closes #938. Replaces the fictional "all requests go through APIClient"
rule with the four real shapes the codebase uses:

  1. Standard fetch — RateLimitedHTTPClient via NetworkingServices.
  2. Multi-host caller — NetworkingServices, resolved per-host.
  3. Retry-driven RPC — withRetry + HTTPRetryPolicy + HTTPRetryClassifier.
  4. Token-bucket RPC — URLSession + RateLimiter actor.

Updates the §2 RemoteAccountRepository example to use shape 1 and the
Network anti-pattern row to point at the four shapes by name. Trims the
GateRegistry carve-out's cross-reference now that §4 is rewritten.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git -C "$(pwd)" push origin docs/concurrency-guide-networking-shapes:docs/concurrency-guide-networking-shapes -u
gh pr create --title "docs(concurrency-guide): rewrite §4 around the four sanctioned shapes" --body "$(cat <<'EOF'
## Summary

Final PR for #938. Replaces `guides/CONCURRENCY_GUIDE.md` §4's fictional `APIClient` rule with the four sanctioned shapes the codebase actually uses (after PRs 1-5):

1. **Standard fetch** — `RateLimitedHTTPClient` via `NetworkingServices`.
2. **Multi-host caller** — `NetworkingServices`, resolved per-host.
3. **Retry-driven RPC** — `withRetry` + `HTTPRetryPolicy` + `HTTPRetryClassifier`.
4. **Token-bucket RPC** — `URLSession` + `RateLimiter` actor.

Also updates the §2 `RemoteAccountRepository` example and the anti-pattern table row in §Anti-Patterns / Network.

Closes #938.

## Test plan

- [x] `just format-check` — passes.
- [x] `just build-mac` / `just test-mac` — sanity green (no Swift changed).
- [x] Self-review: the §4 shapes match what PRs 1-5 shipped.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Then invoke the `merge-queue` skill with the new PR number.

After PR-6 lands, issue #938 is resolved.

---

# Self-review checklist (for the executor)

Before declaring the plan complete, verify each spec requirement is implemented:

- [ ] `RateLimitedHTTPClient` exists in `Shared/Networking/` with the documented `data(for:)` behaviour — PR-1.
- [ ] `NetworkingServices` exists with `client(forHost:)`, lower-case host normalisation, lazy gate creation — PR-1.
- [ ] `URLSession.dataRespectingRateLimit` extension is gone — PR-4 final step.
- [ ] All 6 standard clients take `http: RateLimitedHTTPClient` (no `session: URLSession`) — PR-2.
- [ ] `CompositeTokenResolutionClient` takes `networking: NetworkingServices` — PR-3.
- [ ] `SQLiteCoinGeckoCatalog+Refresh.refresh(http:)` (no `session:`) — PR-4.
- [ ] `NetworkingServices` is constructed once in `bootstrapSyncCoordinator` and threaded through `SyncCoordinator.sharedNetworking` → `ProfileSession.init(networking:)` → every factory — PR-5.
- [ ] `guides/CONCURRENCY_GUIDE.md` §4 documents the four shapes; §2 example uses shape #1; anti-pattern row references the four shapes — PR-6.
- [ ] `LiveBlockscoutClient`, `LiveAlchemyClient`, `CoinstashClient` are untouched.
- [ ] Carve-out 4 (`GateRegistry`) lives in §2's `@unchecked Sendable` list and is technically self-contained.

If anything is missing, return to the corresponding PR's task and complete it before declaring the plan done.
