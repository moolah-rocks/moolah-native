# HTTP Timeout + Retry Component Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable HTTP timeout + retry-with-backoff component under `Shared/Networking/` and adopt it in `LiveBlockscoutClient` so a slow Blockscout page no longer aborts the whole account-history sync.

**Architecture:** A `Sendable` `HTTPRetryPolicy` value, a pure generic `withRetry` async executor with injected clock/sleeper/jitter (deterministic tests, no real sleeping), and an `HTTPRetryClassifier` that decides retryability. Blockscout keeps its proactive `RateLimiter` and `AlchemyResponseValidator`; its `send` sets `request.timeoutInterval` and wraps the transport call in `withRetry`, throwing an internal `HTTPRetrySignal` to request a retry for transient transport errors, 5xx-without-Retry-After, and (because Blockscout has no fallback provider) short `Retry-After` waits.

**Tech Stack:** Swift 6, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), `URLSession`, `OSLog`. `xcodegen` (`just generate`), `just` build/test/format targets.

**Scope note (deliberate deferral):** The approved spec lists `URLSession.dataRespectingRateLimit` gaining `retry:`/`idempotent:` so the 6 price/FX/stock clients can inherit retry later. That weaving (retry *before* `FailedRequestCache` muting) is intricate and has **no consumer** until one of those clients adopts it — adding it now is YAGNI and the risky part is unneeded for Blockscout, which is not on the gate/cache path. This plan delivers **the reusable core + Blockscout only**, exactly the spec's "first implementation" scope. The `dataRespectingRateLimit` change is a separate future plan, written when the first of the 6 clients adopts the core.

**Reference:** `plans/2026-05-17-http-timeout-retry-design.md` (approved design).

**Conventions (verified in codebase):**
- Tests live in `MoolahTests/Shared/`; macOS target `MoolahTests_macOS`; run a suite with `just test-mac <SuiteName>`.
- Test style: `import Foundation` / `import Testing` / `@testable import Moolah`, `@Suite("Name") struct …`, `@Test func … async throws`, `#expect(…)`. Fake-clock pattern is a `final class … : @unchecked Sendable` with an `NSLock` (see `MoolahTests/Shared/RateLimitGateTests.swift`).
- New `.swift` files in already-globbed dirs (`Shared/Networking/`, `MoolahTests/Shared/`) are picked up by `just generate`. Run `just generate` before the first build.
- One extension per protocol; thin types; follow `guides/CODE_GUIDE.md`. Run `just format` before every commit; `just format-check` must pass.
- `just` is invoked from the worktree with `just -d <worktree>` only if cwd differs; the executing session's cwd is the worktree root, so plain `just …` is correct.

---

## File Structure

**Create:**
- `Shared/Networking/HTTPRetryPolicy.swift` — `HTTPRetryPolicy`, `HTTPRetryDecision`, `HTTPRetrySignal` (pure value types).
- `Shared/Networking/HTTPRetryClassifier.swift` — `HTTPRetryClassifier` (pure decision function).
- `Shared/Networking/HTTPRetry.swift` — `withRetry` generic async executor.
- `MoolahTests/Shared/HTTPRetryPolicyTests.swift`
- `MoolahTests/Shared/HTTPRetryClassifierTests.swift`
- `MoolahTests/Shared/HTTPRetryTests.swift`
- `MoolahTests/Shared/BlockExplorerClientRetryTests.swift`

**Modify:**
- `Shared/CryptoImport/BlockExplorerClient.swift` — add a `retryPolicy` stored property + init param; rewrite `send(request:stage:)` to set the timeout, wrap in `withRetry`, and classify the response for retry; add a private `classifyBlockscout` helper.

---

## Task 1: `HTTPRetryPolicy`, `HTTPRetryDecision`, `HTTPRetrySignal`

**Files:**
- Create: `Shared/Networking/HTTPRetryPolicy.swift`
- Test: `MoolahTests/Shared/HTTPRetryPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/HTTPRetryPolicyTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("HTTPRetryPolicy")
struct HTTPRetryPolicyTests {
  @Test
  func defaultsMatchApprovedDesign() {
    let policy = HTTPRetryPolicy()
    #expect(policy.requestTimeout == 120)
    #expect(policy.maxAttempts == 3)
    #expect(policy.backoffBase == 0.5)
    #expect(policy.backoffCap == 5)
    #expect(policy.totalBudget == 300)
    #expect(policy.honorsRetryAfterInPlace == false)
    #expect(policy.maxRateLimitWait == 60)
  }

  @Test
  func perClientOverridesAreIndependent() {
    let blockscout = HTTPRetryPolicy(honorsRetryAfterInPlace: true)
    #expect(blockscout.honorsRetryAfterInPlace == true)
    #expect(blockscout.requestTimeout == 120)
    #expect(HTTPRetryPolicy().honorsRetryAfterInPlace == false)
  }

  @Test
  func backoffIsExponentialJitteredAndCapped() {
    let policy = HTTPRetryPolicy()
    // Jitter closure of identity yields the deterministic ceiling.
    #expect(policy.backoffCeiling(forAttempt: 1) == 0.5)
    #expect(policy.backoffCeiling(forAttempt: 2) == 1.0)
    #expect(policy.backoffCeiling(forAttempt: 3) == 2.0)
    #expect(policy.backoffCeiling(forAttempt: 10) == 5.0)  // capped
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac HTTPRetryPolicyTests`
Expected: FAIL — `cannot find 'HTTPRetryPolicy' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Shared/Networking/HTTPRetryPolicy.swift`:

```swift
// Shared/Networking/HTTPRetryPolicy.swift
import Foundation

/// Tunable, per-call HTTP retry/timeout policy. A plain value so each client
/// can hold its own and tests can construct variants freely. See
/// `plans/2026-05-17-http-timeout-retry-design.md`.
struct HTTPRetryPolicy: Sendable, Equatable {
  /// Applied via `URLRequest.timeoutInterval`. Default is deliberately long
  /// (Blockscout's public instances are slow — the goal is to *extend* the
  /// effective timeout, not shorten it).
  var requestTimeout: TimeInterval = 120
  /// Total attempts including the first (1 initial + `maxAttempts - 1` retries).
  var maxAttempts: Int = 3
  /// Exponential backoff base; ceiling for attempt `n` is
  /// `min(backoffCap, backoffBase * 2^(n-1))`, then jittered.
  var backoffBase: TimeInterval = 0.5
  var backoffCap: TimeInterval = 5
  /// Hard ceiling across all attempts so a dead provider cannot stall one
  /// request for `maxAttempts * requestTimeout`. Retrying stops when either
  /// `maxAttempts` or `totalBudget` is exhausted, whichever comes first.
  var totalBudget: TimeInterval = 300
  /// When true, a rate-limit response carrying a `Retry-After` no longer than
  /// `maxRateLimitWait` is waited out and the (idempotent) request retried
  /// in-place instead of failing. Default false preserves the fallback-chain
  /// clients' behavior.
  var honorsRetryAfterInPlace: Bool = false
  /// `Retry-After` longer than this is not waited out in-place.
  var maxRateLimitWait: TimeInterval = 60

  /// Pre-jitter backoff ceiling for a 1-based attempt number.
  func backoffCeiling(forAttempt attempt: Int) -> TimeInterval {
    let raw = backoffBase * pow(2, Double(max(0, attempt - 1)))
    return min(backoffCap, raw)
  }
}

/// What `withRetry` should do with a thrown error.
enum HTTPRetryDecision: Sendable, Equatable {
  /// Surface the error to the caller now.
  case doNotRetry
  /// Retry after the policy's jittered exponential backoff.
  case retryAfterBackoff
  /// Retry after a server-specified delay (a vetted `Retry-After`).
  case retryAfter(TimeInterval)
}

/// Internal error an operation throws to ask `withRetry` for a retry. The
/// integration layer (e.g. `LiveBlockscoutClient`) only throws this when it
/// has *decided* a retry is wanted; a terminal error is thrown directly so it
/// propagates unchanged on exhaustion.
struct HTTPRetrySignal: Error, Sendable, Equatable {
  /// `nil` → use policy backoff (e.g. 5xx without `Retry-After`).
  /// non-`nil` → server-requested delay already vetted against the policy.
  let retryAfter: TimeInterval?
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac HTTPRetryPolicyTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Format, lint, commit**

```bash
just generate
just format
just format-check
git add Shared/Networking/HTTPRetryPolicy.swift MoolahTests/Shared/HTTPRetryPolicyTests.swift Moolah.xcodeproj 2>/dev/null; git add Shared/Networking/HTTPRetryPolicy.swift MoolahTests/Shared/HTTPRetryPolicyTests.swift
git commit -m "feat(networking): add HTTPRetryPolicy value type

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

(`Moolah.xcodeproj` is gitignored — the `git add` of it is a no-op safety net; the real adds are the two source files.)

---

## Task 2: `HTTPRetryClassifier`

**Files:**
- Create: `Shared/Networking/HTTPRetryClassifier.swift`
- Test: `MoolahTests/Shared/HTTPRetryClassifierTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/HTTPRetryClassifierTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("HTTPRetryClassifier")
struct HTTPRetryClassifierTests {
  @Test
  func transientTransportErrorsRetryWhenIdempotent() {
    for code in [
      URLError.timedOut, .networkConnectionLost, .cannotConnectToHost,
      .dnsLookupFailed, .notConnectedToInternet,
    ] {
      let decision = HTTPRetryClassifier.decision(
        for: URLError(code), idempotent: true)
      #expect(decision == .retryAfterBackoff)
    }
  }

  @Test
  func transientTransportErrorsDoNotRetryWhenNotIdempotent() {
    let decision = HTTPRetryClassifier.decision(
      for: URLError(.timedOut), idempotent: false)
    #expect(decision == .doNotRetry)
  }

  @Test
  func cancellationNeverRetries() {
    #expect(
      HTTPRetryClassifier.decision(for: CancellationError(), idempotent: true)
        == .doNotRetry)
    #expect(
      HTTPRetryClassifier.decision(for: URLError(.cancelled), idempotent: true)
        == .doNotRetry)
  }

  @Test
  func retrySignalWithoutDelayUsesBackoff() {
    #expect(
      HTTPRetryClassifier.decision(
        for: HTTPRetrySignal(retryAfter: nil), idempotent: true)
        == .retryAfterBackoff)
  }

  @Test
  func retrySignalWithDelayHonorsServerDelay() {
    #expect(
      HTTPRetryClassifier.decision(
        for: HTTPRetrySignal(retryAfter: 12), idempotent: true)
        == .retryAfter(12))
  }

  @Test
  func unknownErrorsDoNotRetry() {
    struct Other: Error {}
    #expect(
      HTTPRetryClassifier.decision(for: Other(), idempotent: true)
        == .doNotRetry)
  }

  @Test
  func nonTransientURLErrorDoesNotRetry() {
    #expect(
      HTTPRetryClassifier.decision(
        for: URLError(.badServerResponse), idempotent: true) == .doNotRetry)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac HTTPRetryClassifierTests`
Expected: FAIL — `cannot find 'HTTPRetryClassifier' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Shared/Networking/HTTPRetryClassifier.swift`:

```swift
// Shared/Networking/HTTPRetryClassifier.swift
import Foundation

/// Maps a thrown error to an `HTTPRetryDecision`. Pure and synchronous so it
/// is trivially unit-testable.
enum HTTPRetryClassifier {
  /// `URLError` codes that represent a transient transport failure worth
  /// retrying on an idempotent request.
  private static let retryableTransportCodes: Set<URLError.Code> = [
    .timedOut, .networkConnectionLost, .cannotConnectToHost,
    .dnsLookupFailed, .notConnectedToInternet,
  ]

  static func decision(
    for error: any Error, idempotent: Bool
  ) -> HTTPRetryDecision {
    // Cancellation is user-driven and never a retry, regardless of method.
    if error is CancellationError { return .doNotRetry }
    if let urlError = error as? URLError, urlError.code == .cancelled {
      return .doNotRetry
    }
    // Explicit retry request from the integration layer.
    if let signal = error as? HTTPRetrySignal {
      if let delay = signal.retryAfter { return .retryAfter(delay) }
      return .retryAfterBackoff
    }
    guard idempotent else { return .doNotRetry }
    if let urlError = error as? URLError,
      retryableTransportCodes.contains(urlError.code)
    {
      return .retryAfterBackoff
    }
    return .doNotRetry
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac HTTPRetryClassifierTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Format, lint, commit**

```bash
just format
just format-check
git add Shared/Networking/HTTPRetryClassifier.swift MoolahTests/Shared/HTTPRetryClassifierTests.swift
git commit -m "feat(networking): add HTTPRetryClassifier

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `withRetry` executor

**Files:**
- Create: `Shared/Networking/HTTPRetry.swift`
- Test: `MoolahTests/Shared/HTTPRetryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/HTTPRetryTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("withRetry")
struct HTTPRetryTests {
  /// Deterministic clock + sleeper: `sleep` advances the clock instead of
  /// blocking, and records every requested delay.
  final class FakeScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    private(set) var sleeps: [TimeInterval] = []

    func now() -> Date {
      lock.lock(); defer { lock.unlock() }
      return current
    }

    func sleep(_ seconds: TimeInterval) async throws {
      try Task.checkCancellation()
      lock.lock()
      sleeps.append(seconds)
      current = current.addingTimeInterval(seconds)
      lock.unlock()
    }
  }

  @Test
  func succeedsOnFirstTryWithoutSleeping() async throws {
    let sched = FakeScheduler()
    let result = try await withRetry(
      policy: HTTPRetryPolicy(),
      isRetryable: { HTTPRetryClassifier.decision(for: $0, idempotent: true) },
      clock: { sched.now() },
      sleep: { try await sched.sleep($0) },
      jitter: { $0 }
    ) { 42 }
    #expect(result == 42)
    #expect(sched.sleeps.isEmpty)
  }

  @Test
  func retriesTransientThenSucceeds() async throws {
    let sched = FakeScheduler()
    let attempts = Counter()
    let result = try await withRetry(
      policy: HTTPRetryPolicy(),
      isRetryable: { HTTPRetryClassifier.decision(for: $0, idempotent: true) },
      clock: { sched.now() },
      sleep: { try await sched.sleep($0) },
      jitter: { $0 }
    ) {
      if await attempts.next() < 2 { throw URLError(.timedOut) }
      return "ok"
    }
    #expect(result == "ok")
    // Two failures → two backoff sleeps at the deterministic ceilings.
    #expect(sched.sleeps == [0.5, 1.0])
  }

  @Test
  func exhaustsAndRethrowsLastError() async throws {
    let sched = FakeScheduler()
    await #expect(throws: URLError.self) {
      try await withRetry(
        policy: HTTPRetryPolicy(),
        isRetryable: {
          HTTPRetryClassifier.decision(for: $0, idempotent: true)
        },
        clock: { sched.now() },
        sleep: { try await sched.sleep($0) },
        jitter: { $0 }
      ) { throw URLError(.timedOut) }
    }
    // 3 attempts → 2 backoff sleeps.
    #expect(sched.sleeps == [0.5, 1.0])
  }

  @Test
  func nonRetryableErrorIsNotRetried() async throws {
    let sched = FakeScheduler()
    struct Boom: Error, Equatable {}
    await #expect(throws: Boom.self) {
      try await withRetry(
        policy: HTTPRetryPolicy(),
        isRetryable: {
          HTTPRetryClassifier.decision(for: $0, idempotent: true)
        },
        clock: { sched.now() },
        sleep: { try await sched.sleep($0) },
        jitter: { $0 }
      ) { throw Boom() }
    }
    #expect(sched.sleeps.isEmpty)
  }

  @Test
  func honorsServerRetryAfterDelay() async throws {
    let sched = FakeScheduler()
    let attempts = Counter()
    _ = try await withRetry(
      policy: HTTPRetryPolicy(honorsRetryAfterInPlace: true),
      isRetryable: { HTTPRetryClassifier.decision(for: $0, idempotent: true) },
      clock: { sched.now() },
      sleep: { try await sched.sleep($0) },
      jitter: { $0 }
    ) { () async throws -> Int in
      if await attempts.next() < 1 { throw HTTPRetrySignal(retryAfter: 7) }
      return 1
    }
    #expect(sched.sleeps == [7])
  }

  @Test
  func stopsWhenTotalBudgetWouldBeExceeded() async throws {
    let sched = FakeScheduler()
    // backoffBase huge so the first backoff alone exceeds the budget.
    var policy = HTTPRetryPolicy()
    policy.backoffBase = 1000
    policy.backoffCap = 1000
    policy.totalBudget = 10
    await #expect(throws: URLError.self) {
      try await withRetry(
        policy: policy,
        isRetryable: {
          HTTPRetryClassifier.decision(for: $0, idempotent: true)
        },
        clock: { sched.now() },
        sleep: { try await sched.sleep($0) },
        jitter: { $0 }
      ) { throw URLError(.timedOut) }
    }
    // Budget tripped before the first sleep.
    #expect(sched.sleeps.isEmpty)
  }

  @Test
  func stopsOnCancellationMidBackoff() async throws {
    let sched = FakeScheduler()
    let task = Task {
      try await withRetry(
        policy: HTTPRetryPolicy(),
        isRetryable: {
          HTTPRetryClassifier.decision(for: $0, idempotent: true)
        },
        clock: { sched.now() },
        sleep: { _ in
          try Task.checkCancellation()
          throw URLError(.timedOut)
        },
        jitter: { $0 }
      ) { throw URLError(.timedOut) }
    }
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
  }

  /// Minimal async counter so the closures stay `Sendable`.
  actor Counter {
    private var value = 0
    func next() -> Int { defer { value += 1 }; return value }
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac HTTPRetryTests`
Expected: FAIL — `cannot find 'withRetry' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Shared/Networking/HTTPRetry.swift`:

```swift
// Shared/Networking/HTTPRetry.swift
import Foundation
import OSLog

private let retryLogger = Logger(
  subsystem: "com.moolah.app", category: "HTTPRetry")

/// Runs `operation`, retrying per `policy` while `isRetryable` says so.
///
/// - Backoff is the policy's exponential ceiling passed through `jitter`
///   (default: uniform full jitter in `0...ceiling`; tests pass identity).
/// - `clock` / `sleep` are injected so tests advance a fake clock and never
///   block. The default `sleep` is `Task.sleep`, which throws on cancellation.
/// - Stops when `maxAttempts` is reached, when the next delay would exceed
///   `totalBudget`, when the error is not retryable, or on cancellation. On
///   any stop the **last** thrown error propagates unchanged.
func withRetry<T: Sendable>(
  policy: HTTPRetryPolicy,
  isRetryable: @Sendable (any Error) -> HTTPRetryDecision,
  clock: @Sendable () -> Date = { Date() },
  sleep: @Sendable (TimeInterval) async throws -> Void = {
    try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
  },
  jitter: @Sendable (TimeInterval) -> TimeInterval = {
    TimeInterval.random(in: 0...max(0, $0))
  },
  operation: @Sendable () async throws -> T
) async throws -> T {
  let start = clock()
  var attempt = 1
  while true {
    do {
      return try await operation()
    } catch {
      // A cancellation thrown by the operation is terminal.
      try Task.checkCancellation()
      let decision = isRetryable(error)
      let delay: TimeInterval
      switch decision {
      case .doNotRetry:
        throw error
      case .retryAfterBackoff:
        delay = jitter(policy.backoffCeiling(forAttempt: attempt))
      case .retryAfter(let serverDelay):
        delay = max(0, serverDelay)
      }
      guard attempt < policy.maxAttempts else { throw error }
      let elapsed = clock().timeIntervalSince(start)
      guard elapsed + delay <= policy.totalBudget else { throw error }
      retryLogger.notice(
        """
        Retry attempt \(attempt + 1, privacy: .public) of \
        \(policy.maxAttempts, privacy: .public) after \
        \(delay, privacy: .public)s: \
        \(error.localizedDescription, privacy: .public)
        """
      )
      try await sleep(delay)
      attempt += 1
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac HTTPRetryTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Format, lint, commit**

```bash
just format
just format-check
git add Shared/Networking/HTTPRetry.swift MoolahTests/Shared/HTTPRetryTests.swift
git commit -m "feat(networking): add withRetry executor with injected clock/sleeper

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Adopt timeout + retry in `LiveBlockscoutClient`

**Files:**
- Modify: `Shared/CryptoImport/BlockExplorerClient.swift` (the `LiveBlockscoutClient` struct: `init` lines 36–40, `send(request:stage:)` lines 149–170)
- Test: `MoolahTests/Shared/BlockExplorerClientRetryTests.swift`

Background — current code (verbatim, do not keep as-is):

```swift
init(session: URLSession = .shared, rateLimiter: RateLimiter) {
  self.session = session
  self.rateLimiter = rateLimiter
  self.logger = Logger(subsystem: "com.moolah.app", category: "BlockscoutClient")
}

private func send(request: URLRequest, stage: String) async throws -> Data {
  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch let urlError as URLError where urlError.code == .cancelled {
    throw CancellationError()
  } catch {
    logger.error(
      "Blockscout \(stage, privacy: .public) network failure: \(error.localizedDescription, privacy: .public)"
    )
    throw WalletSyncError.network(underlyingDescription: error.localizedDescription)
  }
  do {
    try AlchemyResponseValidator.validate(response: response, stage: stage, logger: logger)
  } catch WalletSyncError.invalidApiKey {
    logger.error(
      "Blockscout \(stage, privacy: .public): HTTP 401/403 (public API expects no auth)")
    throw WalletSyncError.network(underlyingDescription: "HTTP 401/403")
  }
  return data
}
```

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/BlockExplorerClientRetryTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("LiveBlockscoutClient retry")
struct BlockExplorerClientRetryTests {
  /// Per-test scripted responses keyed by call order. Each element is either
  /// a thrown `URLError` or an `(status, body, headers)` response.
  final class Script: @unchecked Sendable {
    enum Step: Sendable {
      case fail(URLError.Code)
      case respond(status: Int, body: Data, headers: [String: String])
    }
    private let lock = NSLock()
    private var steps: [Step]
    private(set) var calls = 0
    init(_ steps: [Step]) { self.steps = steps }
    func next() -> Step {
      lock.lock(); defer { lock.unlock() }
      calls += 1
      precondition(!steps.isEmpty, "StubURLProtocol called more times than scripted")
      return steps.removeFirst()
    }
  }

  /// `URLProtocol` stub driven by a `Script` shared via a thread-safe box.
  final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var script: Script!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest
    { request }
    override func startLoading() {
      switch Self.script.next() {
      case .fail(let code):
        client?.urlProtocol(self, didFailWithError: URLError(code))
      case .respond(let status, let body, let headers):
        let response = HTTPURLResponse(
          url: request.url!, statusCode: status,
          httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(
          self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
      }
    }
    override func stopLoading() {}
  }

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
  }

  private static let emptyPage = Data(
    #"{"items":[],"next_page_params":null}"#.utf8)

  @Test
  func transientTimeoutIsRetriedThenSucceeds() async throws {
    StubURLProtocol.script = Script([
      .fail(.timedOut),
      .respond(status: 200, body: Self.emptyPage, headers: [:]),
    ])
    let client = LiveBlockscoutClient(
      session: makeSession(),
      rateLimiter: RateLimiter(permitsPerSecond: 1000),
      retryPolicy: HTTPRetryPolicy(),
      sleeper: { _ in })  // no real backoff sleep in tests
    let txs = try await client.nativeTransactions(
      chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    #expect(txs.isEmpty)
    #expect(StubURLProtocol.script.calls == 2)
  }

  @Test
  func longRetryAfterFailsCleanly() async throws {
    StubURLProtocol.script = Script([
      .respond(
        status: 429, body: Data(), headers: ["Retry-After": "999"]),
    ])
    let client = LiveBlockscoutClient(
      session: makeSession(),
      rateLimiter: RateLimiter(permitsPerSecond: 1000),
      retryPolicy: HTTPRetryPolicy(honorsRetryAfterInPlace: true),
      sleeper: { _ in })
    await #expect(throws: WalletSyncError.self) {
      _ = try await client.nativeTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    }
    #expect(StubURLProtocol.script.calls == 1)  // not retried
  }

  @Test
  func shortRetryAfterIsWaitedOutThenSucceeds() async throws {
    StubURLProtocol.script = Script([
      .respond(status: 429, body: Data(), headers: ["Retry-After": "5"]),
      .respond(status: 200, body: Self.emptyPage, headers: [:]),
    ])
    let client = LiveBlockscoutClient(
      session: makeSession(),
      rateLimiter: RateLimiter(permitsPerSecond: 1000),
      retryPolicy: HTTPRetryPolicy(honorsRetryAfterInPlace: true),
      sleeper: { _ in })
    let txs = try await client.nativeTransactions(
      chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    #expect(txs.isEmpty)
    #expect(StubURLProtocol.script.calls == 2)
  }
}
```

> Note: `ChainConfig.ethereum` is the existing Ethereum chain config used elsewhere in the Blockscout tests. If the accessor differs, mirror whatever `BlockExplorerClient`'s existing test/suite uses to build a `ChainConfig` for chain 1 — do not invent a new one.

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac BlockExplorerClientRetryTests`
Expected: FAIL — `extra argument 'retryPolicy' in call` (init does not yet take the new params).

- [ ] **Step 3: Modify `LiveBlockscoutClient`**

In `Shared/CryptoImport/BlockExplorerClient.swift`, add stored properties and extend `init`. Replace the existing `init` (lines 36–40) with:

```swift
private let session: URLSession
private let rateLimiter: RateLimiter
private let retryPolicy: HTTPRetryPolicy
private let sleeper: @Sendable (TimeInterval) async throws -> Void
private let logger: Logger

init(
  session: URLSession = .shared,
  rateLimiter: RateLimiter,
  retryPolicy: HTTPRetryPolicy = HTTPRetryPolicy(
    honorsRetryAfterInPlace: true),
  sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
    try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
  }
) {
  self.session = session
  self.rateLimiter = rateLimiter
  self.retryPolicy = retryPolicy
  self.sleeper = sleeper
  self.logger = Logger(
    subsystem: "com.moolah.app", category: "BlockscoutClient")
}
```

> If `private let session` / `private let rateLimiter` / `private let logger` are already declared as standalone stored properties above the old `init` (they are — lines 32–34), delete those three old declarations so the five-property block above is the single source. Do not duplicate them.

Replace the existing `send(request:stage:)` (lines 149–170) with:

```swift
private func send(request: URLRequest, stage: String) async throws -> Data {
  var timed = request
  timed.timeoutInterval = retryPolicy.requestTimeout
  do {
    return try await withRetry(
      policy: retryPolicy,
      isRetryable: { HTTPRetryClassifier.decision(for: $0, idempotent: true) },
      sleep: sleeper
    ) {
      try await self.attempt(request: timed, stage: stage)
    }
  } catch let urlError as URLError where urlError.code == .cancelled {
    throw CancellationError()
  } catch is CancellationError {
    throw CancellationError()
  } catch let walletError as WalletSyncError {
    throw walletError
  } catch let signal as HTTPRetrySignal {
    let reason =
      signal.retryAfter.map { "Retry-After \($0)s" } ?? "server error"
    logger.error(
      "Blockscout \(stage, privacy: .public) retry exhausted (\(reason, privacy: .public))"
    )
    throw WalletSyncError.network(
      underlyingDescription: "retry exhausted (\(reason))")
  } catch {
    logger.error(
      "Blockscout \(stage, privacy: .public) network failure: \(error.localizedDescription, privacy: .public)"
    )
    throw WalletSyncError.network(
      underlyingDescription: error.localizedDescription)
  }
}

/// One transport attempt. Returns body on 2xx; throws `HTTPRetrySignal` when
/// the response is retryable, or a terminal `WalletSyncError` otherwise. A
/// raw transient `URLError` propagates so the classifier can retry it.
private func attempt(request: URLRequest, stage: String) async throws -> Data {
  let (data, response) = try await session.data(for: request)
  try classifyBlockscout(response: response, stage: stage)
  return data
}

/// Blockscout-specific status classification. Mirrors the old
/// `AlchemyResponseValidator` mapping but converts retryable statuses into
/// `HTTPRetrySignal` so `withRetry` can act on them.
private func classifyBlockscout(
  response: URLResponse, stage: String
) throws {
  guard let http = response as? HTTPURLResponse else {
    throw WalletSyncError.network(underlyingDescription: "No HTTP response")
  }
  let retryAfter = http.retryAfterSeconds(now: Date())
  switch http.statusCode {
  case 200...299:
    return
  case 401, 403:
    logger.error(
      "Blockscout \(stage, privacy: .public): HTTP 401/403 (public API expects no auth)"
    )
    throw WalletSyncError.network(underlyingDescription: "HTTP 401/403")
  case 429, 418:
    if retryPolicy.honorsRetryAfterInPlace, let wait = retryAfter,
      wait <= retryPolicy.maxRateLimitWait
    {
      throw HTTPRetrySignal(retryAfter: wait)
    }
    throw WalletSyncError.rateLimited(
      retryAfter: retryAfter.map { Date().addingTimeInterval($0) })
  case 503:
    if retryPolicy.honorsRetryAfterInPlace, let wait = retryAfter,
      wait <= retryPolicy.maxRateLimitWait
    {
      throw HTTPRetrySignal(retryAfter: wait)
    }
    if retryAfter == nil { throw HTTPRetrySignal(retryAfter: nil) }
    throw WalletSyncError.network(underlyingDescription: "HTTP 503")
  case 500...599:
    throw HTTPRetrySignal(retryAfter: nil)
  default:
    logger.error(
      "Blockscout \(stage, privacy: .public): HTTP \(http.statusCode, privacy: .public)"
    )
    throw WalletSyncError.network(
      underlyingDescription: "HTTP \(http.statusCode)")
  }
}
```

> The old `send` caught `URLError(.cancelled)` *before* anything else. Here, `attempt` lets a raw `URLError` propagate; the outer `do/catch` in `send` still maps `.cancelled` → `CancellationError` first, so cancellation behavior is preserved. A transient `URLError` (e.g. `.timedOut`) is not caught by `attempt`, so the classifier sees it and retries.

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac BlockExplorerClientRetryTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full Blockscout suite for regressions**

Run: `just test-mac BlockExplorerClientTests` (the pre-existing suite — exact name may be `BlockExplorerClientTests` or similar; run whatever the existing Blockscout suite is called).
Expected: PASS — no regressions in existing pagination/decoding tests.

- [ ] **Step 6: Build, format, lint, commit**

```bash
just build-mac
just format
just format-check
git add Shared/CryptoImport/BlockExplorerClient.swift MoolahTests/Shared/BlockExplorerClientRetryTests.swift
git commit -m "feat(crypto): add timeout + retry to Blockscout client

Sets request.timeoutInterval to 120s and wraps the transport in
withRetry, retrying transient transport failures and 5xx, and
waiting out short Retry-After in-place (Blockscout has no fallback
provider). Keeps the proactive RateLimiter unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Verification & review

**Files:** none (verification only)

- [ ] **Step 1: Full macOS networking + crypto regression**

Run: `mkdir -p .agent-tmp && just test-mac HTTPRetryPolicyTests HTTPRetryClassifierTests HTTPRetryTests BlockExplorerClientRetryTests 2>&1 | tee .agent-tmp/retry-tests.txt`
Expected: all suites PASS, 0 failures. Then `grep -i 'failed\|error:' .agent-tmp/retry-tests.txt` shows no test failures; `rm .agent-tmp/retry-tests.txt`.

- [ ] **Step 2: Full build + format gate**

Run: `just build-mac && just format-check`
Expected: build succeeds with zero warnings (project treats warnings as errors); `format-check` exits 0.

- [ ] **Step 3: Compiler-warning sweep**

Use `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`. Expected: no warnings in the new/modified files (preview-macro warnings excluded).

- [ ] **Step 4: Code review**

Invoke the `code-review` agent on `Shared/Networking/HTTPRetryPolicy.swift`, `Shared/Networking/HTTPRetryClassifier.swift`, `Shared/Networking/HTTPRetry.swift`, and the `LiveBlockscoutClient` changes in `Shared/CryptoImport/BlockExplorerClient.swift`. Address every Critical/Important/Minor finding (per project policy: pre-existing-in-another-file is not a skip reason; ask before deferring any).

- [ ] **Step 5: Concurrency review**

Invoke the `concurrency-review` agent on the same four files (new networking code + Blockscout client touch `async`/`Sendable`/closures).

- [ ] **Step 6: Final commit if review changes were made**

```bash
just format && just format-check
git add -A
git commit -m "fix: address code/concurrency review findings

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 7: Push and open PR**

```bash
git -C $(git rev-parse --show-toplevel) push origin feat/http-timeout-retry:feat/http-timeout-retry
gh pr create --title "feat: reusable HTTP timeout + retry; fix Blockscout sync timeout" \
  --body "$(cat <<'EOF'
Adds a reusable `Shared/Networking` timeout + retry component
(`HTTPRetryPolicy`, `HTTPRetryClassifier`, `withRetry`) and adopts it
in `LiveBlockscoutClient`: a 120s request timeout plus bounded
retry-with-backoff for transient transport failures and 5xx, and
in-place waiting for short `Retry-After` (Blockscout has no fallback
provider). Fixes account-history sync aborting with "The request
timed out" on slow Blockscout instances.

Design: `plans/2026-05-17-http-timeout-retry-design.md`.
The 6 price/FX/stock clients and the POST clients (Alchemy/Coinstash)
inherit the core later, opt-in — out of scope here.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Then add the PR to the merge queue per the `merge-queue` skill (project policy: every PR goes through the merge queue, not manual merge).

---

## Self-Review

**Spec coverage:**
- `HTTPRetryPolicy` (timeout/attempts/backoff/budget/Retry-After fields + defaults) → Task 1 ✓
- `withRetry` executor (injected clock/sleeper, budget, cancellation, exhaustion rethrows last) → Task 3 ✓
- `HTTPRetryClassifier` (transient URLError set, 5xx-no-Retry-After via signal, idempotent gate, cancellation never) → Task 2 ✓
- Blockscout adoption: 120s timeout, keep RateLimiter + validator behavior, honor short Retry-After in-place, long Retry-After fails cleanly, transient timeout retried → Task 4 ✓
- Error handling: original error mapped to `WalletSyncError.network`; cancellation untouched → Task 4 `send` catch ladder ✓
- Testing: policy defaults, withRetry matrix with fake clock, classifier table, Blockscout timeout-then-success / short vs long Retry-After → Tasks 1–4 ✓
- Deferred per spec "out of scope": `dataRespectingRateLimit` param + the 6 clients + Alchemy/Coinstash → stated in Scope note, not a gap ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows full code; commands have expected output. The one soft spot (`ChainConfig.ethereum` accessor name and the existing Blockscout suite name) is explicitly flagged with an instruction to mirror the existing test rather than invent — acceptable because the exact symbol is environment-local and the fallback is unambiguous.

**Type consistency:** `HTTPRetryPolicy`, `HTTPRetryDecision`, `HTTPRetrySignal`, `HTTPRetryClassifier.decision(for:idempotent:)`, `withRetry(policy:isRetryable:clock:sleep:jitter:operation:)`, `backoffCeiling(forAttempt:)`, and the `LiveBlockscoutClient` init signature (`session:rateLimiter:retryPolicy:sleeper:`) are used identically across Tasks 1–4. ✓
