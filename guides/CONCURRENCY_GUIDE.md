# Moolah Concurrency Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)

---

## 1. Philosophy: Main Thread by Default

> "The best way to handle concurrency is just to not do it."
> — Brent Simmons, NetNewsWire

This project follows NetNewsWire's threading model, now codified by Swift 6.2's default MainActor isolation: **all code runs on the main thread unless there is a specific, justified reason to move it to the background.**

Concurrency is a source of subtle, intermittent bugs. Every background operation is a potential race condition, data corruption, or UI inconsistency. The cost of unnecessary concurrency far exceeds the cost of doing slightly more work on the main thread.

**Core rules:**

1. **Main thread is the default.** All stores, views, and most logic run on `@MainActor`.
2. **Background work is opt-in and justified.** Only pure computation (JSON decoding, image processing, data transformation) and I/O (network, disk) should leave the main thread.
3. **Background work never leaks.** Results always return to the main thread. No component ever receives a callback or notification on a background thread.
4. **Simpler is better.** Sequential main-thread code that takes 5ms is preferable to concurrent code that saves 3ms but adds complexity.

### Key Sources

- [How NetNewsWire Handles Threading](https://inessential.com/2021/03/20/how_netnewswire_handles_threading.html) — Brent Simmons
- [Swift by Sundell Podcast #95](https://www.swiftbysundell.com/podcast/95/) — Brent Simmons interview
- [Swift 6.2 Default Actor Isolation](https://www.avanderlee.com/concurrency/default-actor-isolation-in-swift-6-2/) — SwiftLee
- [Donny Wals on Swift 6.2](https://www.donnywals.com/should-you-opt-in-to-swift-6-2s-main-actor-isolation/)
- [WWDC 2025: Explore Concurrency in SwiftUI](https://developer.apple.com/videos/play/wwdc2025/257/)

---

## 2. Actor Isolation Model

### Stores: `@MainActor @Observable`

All stores own UI-bound state and **must** be `@MainActor`. This is non-negotiable. The `@Observable` macro replaces Combine's `@Published` and integrates with SwiftUI's observation system.

```swift
@MainActor
@Observable
final class AccountStore {
    var accounts: [Account] = []
    var error: String?

    private let repository: AccountRepository

    func load() async {
        do {
            accounts = try await repository.fetchAll()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

**Why `@MainActor` on the class, not individual methods:**
- Ensures all property access is main-thread-safe by default
- Eliminates the risk of forgetting to annotate a new method
- Makes the contract explicit: "this entire type lives on the main thread"

### Domain Models: `Sendable` Value Types

All domain models are `struct` conforming to `Sendable`. They are the data that crosses actor boundaries — passed from repository (which may do background I/O) to store (which is `@MainActor`).

```swift
struct Transaction: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var payee: String
    var amount: InstrumentAmount
    // ...
}
```

**Rules:**
- Domain models must never contain reference types, closures, or mutable shared state
- Domain models must never import SwiftUI, GRDB, or backend modules
- If a model needs computed properties for display, add them as extensions in the appropriate layer

### Repository Protocols: `Sendable`

All repository protocols conform to `Sendable` because they are shared across actors (stored in both `@MainActor` stores and potentially background contexts).

```swift
protocol AccountRepository: Sendable {
    func fetchAll() async throws -> [Account]
    func create(_ account: Account) async throws -> Account
    // ...
}
```

### Remote Implementations: `Sendable` Final Classes

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

### TestBackend: CloudKitBackend with In-Memory GRDB

Tests and previews use `CloudKitBackend` backed by an in-memory GRDB database (via `TestBackend.create()` in tests and `PreviewBackend.create()` in previews). This runs the same production code path but with no persistent storage or CloudKit sync. The `CloudKitBackend` uses `@unchecked Sendable` because it stores a shared `database: any DatabaseWriter` (the GRDB queue) plus immutable repository references. This is acceptable because the `DatabaseWriter` is itself `Sendable` and the queue's serial executor mediates concurrent access (see Carve-out 3 for the repositories it owns).

### False Positives to Avoid

`@unchecked Sendable` is a sharp knife — every use waives a compiler check, so each occurrence must be justified in writing on the type itself and listed here. The carve-outs below are the only places `@unchecked Sendable` is allowed in this codebase. Anything outside this list must be a real `Sendable` (value type, immutable `final class`, or `actor`).

**Carve-out 1 — `CloudKitBackend`.** `Backends/CloudKit/CloudKitBackend.swift` is a `final class` declared `@unchecked Sendable` because every stored property is a `let` — the injected repository references plus the shared `database: any DatabaseWriter` (itself `Sendable` per GRDB's protocol guarantee). None mutate after init. The GRDB repositories it owns are covered by Carve-out 3.

**Carve-out 2 — `SyncCoordinator.PreparedEngine` (one-way ownership transfer).** `Backends/CloudKit/Sync/SyncCoordinator.swift` defines `PreparedEngine` as a `struct` with `@unchecked Sendable` so a `CKSyncEngine` (which CloudKit does not declare `Sendable`) can be constructed on a background `Task` and handed to `@MainActor` via the task's return value. The constraint is **one-way ownership transfer only — no concurrent readers**: the background task constructs the engine, returns the struct, and never touches it again; the receiving `MainActor` then owns the engine for the rest of its life. The `Task.value` happens-before edge is what makes the transfer safe; the `@unchecked` only waives Swift's structural check that `CKSyncEngine` conforms to `Sendable`. Anything that would let two threads observe the same `PreparedEngine.engine` concurrently invalidates this carve-out — keep the struct internal to the prepare/complete-start handoff.

**Carve-out 3 — GRDB repositories (`final class` with immutable post-init state plus optional `@MainActor`-isolated mutable state).** Every repository under `Backends/GRDB/Repositories/` (`GRDBTransactionRepository`, `GRDBAccountRepository`, `GRDBCategoryRepository`, `GRDBEarmarkRepository`, `GRDBEarmarkBudgetItemRepository`, `GRDBInvestmentRepository`, `GRDBTransactionLegRepository`, `GRDBCSVImportProfileRepository`, `GRDBTransferSuggestionRepository`, `GRDBImportRuleRepository`, `GRDBInstrumentRegistryRepository`, `GRDBInsightDismissalRepository`), plus the read-only aggregation sources `GRDBAnalysisRepository` and `GRDBInsightDataSource` (same property shape — immutable `let` storage over a shared `DatabaseWriter` and `Sendable` service existentials), is a `final class` declared `@unchecked Sendable` because:

- All stored properties are `let`, OR
- Any mutable property is explicitly `@MainActor`-isolated (e.g. `subscribers` on `GRDBInstrumentRegistryRepository`) and only touched from `MainActor`-isolated methods.
- The shared `database: any DatabaseWriter` is itself `Sendable` per GRDB's protocol guarantee — the queue's serial executor mediates concurrent access.
- All callback closures are typed `@Sendable` and captured at init.
- `Sendable` protocol existentials stored as `let` (e.g. `any InstrumentMapResolving`, `any InstrumentRegistering`, `any InstrumentConversionService`) are a covered property shape alongside the `@Sendable` closures and `DatabaseWriter`.

`@unchecked` waives only Swift's structural check that a `final class` automatically satisfies `Sendable`; it does not introduce shared mutable state. The justification must be repeated as a doc-comment on the class itself, referencing this carve-out by name. New GRDB repositories follow the same pattern; do **not** invent new carve-outs without updating this section.

**Carve-out 4 — `GateRegistry` (`private` to `NetworkingServices.swift`).** `Shared/Networking/NetworkingServices.swift` defines a `private final class GateRegistry: @unchecked Sendable` whose only mutable state is `[String: RateLimitGate]`, fully guarded by an `NSLock`. The async accessor (`gate(forHost:)`) is internal and used only by tests; the production hot path uses the synchronous accessor. The lock is the synchronisation primitive that makes the type genuinely thread-safe; `@unchecked` waives only Swift's structural check that `final class` automatically conforms to `Sendable`.

**Carve-out 5 — `ScriptCommandBox` (`private` to `NSScriptCommand+ScriptHelpers.swift`, one-way `MainActor` hand-off).** `Automation/AppleScript/Commands/NSScriptCommand+ScriptHelpers.swift` defines a `private final class ScriptCommandBox: @unchecked Sendable` holding a single `let command: NSScriptCommand`. AppleScript handlers run inside `performDefaultImplementation` — an Objective-C override that the compiler treats as **nonisolated** (an override cannot add `@MainActor` over a nonisolated superclass method), so `self` is task-isolated. The handler's real work is async and `@MainActor`, so `runBlockingWithError` uses Cocoa's documented async-command pattern: `suspendExecution()`, run the work in a `@MainActor` `Task`, then `resumeExecution(withResult:)`. That `Task` must hold the command to resume it. The constraint is **one-way ownership transfer only — no concurrent readers**: Cocoa's scripting contract guarantees a suspended command is dormant until resumed, and we only ever resume on the `MainActor`, so the command is touched on exactly one isolation domain. Swift's region-isolation pass can't model that contract (capturing `self` directly trips `sending 'self' risks causing data races`), and the only alternative the compiler would accept — a `DispatchSemaphore` to block until the async work completes — is the forbidden anti-pattern that parks a cooperative-pool thread. The `@unchecked` waives only the structural `Sendable` check on a non-`Sendable` Cocoa type; the box introduces no shared mutable state. The justification is repeated as a doc-comment on the class itself. Anything that would let a second thread observe `ScriptCommandBox.command` invalidates this carve-out — keep the box internal to `runBlockingWithError`.

**Carve-out 6 — `LateBoundCryptoMetadataLookup` (`NSLock`-guarded late-bound box).** `App/LateBoundCryptoMetadataLookup.swift` defines a `final class LateBoundCryptoMetadataLookup: @unchecked Sendable` — a late-bound fallback metadata box used on the preview/legacy path, where the `CryptoPriceService` is constructed before the per-profile instrument registry exists and the registry-backed resolver is rotated in once it's available. Its only mutable state is `resolver: CryptoMetadataLookup?`, fully guarded by an `NSLock`. The lock is **never held across an `await`**: `lookup` copies the bound resolver out under `lock.withLock { … }` and makes the async call only after the lock is released. `bind(_:)` runs synchronously during `ProfileSession` / `makeCloudKitBackend` init, before any concurrent access. The lock is the synchronisation primitive that makes the type genuinely thread-safe; `@unchecked` waives only Swift's structural check that a `final class` automatically conforms to `Sendable`. The justification is repeated as a doc-comment on the class itself.

**Carve-out 7 — `CanonicalInstrumentResolver` (`OSAllocatedUnfairLock`-guarded mutable map).** `Shared/CryptoImport/CanonicalInstrumentResolver.swift` defines a `final class CanonicalInstrumentResolver: @unchecked Sendable` that resolves a retired cross-chain crypto instrument id to its canonical id. Its only mutable state is `dynamicMap: OSAllocatedUnfairLock<[String: String]>` — the registry-derived layer, fully guarded by the lock and read exclusively via `dynamicMap.withLock { $0[id] }`. The lock is **never held across an `await`**: both public methods (`canonicalId(for:)`, `isAlias(_:)`) are synchronous, because the first consumers (`ChainConfig.nativeInstrument`, native transfer/gas legs) read them from non-async contexts. `staticBaseMap` is an immutable `static let` — Swift's once-only initialisation guarantee makes it safe to read from any context without a lock. The lock is the synchronisation primitive that makes the type genuinely thread-safe; `@unchecked` waives only Swift's structural check that a `final class` automatically conforms to `Sendable`, and introduces no unguarded shared mutable state. The justification is repeated as a doc-comment on the class itself.

**Do not use `@unchecked Sendable` in any other production code.** If you need mutable shared state, use an `actor`.

---

## 3. Async Patterns

### Preferred: `async/await`

All asynchronous work uses Swift's structured concurrency. No callbacks, completion handlers, Combine, or GCD.

```swift
// Good: Simple async/await
func load() async {
    do {
        accounts = try await repository.fetchAll()
    } catch {
        error = error.localizedDescription
    }
}
```

### Parallel Fetching: `async let`

When multiple independent async operations can run concurrently, use `async let`:

```swift
func loadAll() async {
    do {
        async let balances = loadDailyBalances()
        async let breakdown = loadExpenseBreakdown()
        async let income = loadIncomeAndExpense()
        _ = try await (balances, breakdown, income)
    } catch {
        error = error.localizedDescription
    }
}
```

**When to use `async let`:**
- Two or more independent network requests that don't depend on each other
- The count is known at compile time (fixed number of operations)

**When to use `TaskGroup`:**
- Dynamic number of concurrent operations (e.g., fetching data for N accounts)
- Need to process results as they arrive

```swift
// Dynamic count — use TaskGroup
let results = try await withThrowingTaskGroup(of: (UUID, [DailyBalance]).self) { group in
    for account in accounts {
        group.addTask {
            let balances = try await repository.fetchDailyBalances(accountId: account.id)
            return (account.id, balances)
        }
    }
    var map: [UUID: [DailyBalance]] = [:]
    for try await (id, balances) in group {
        map[id] = balances
    }
    return map
}
```

### Debouncing: Task Cancellation

For search-as-you-type or autofill, use the Task cancellation pattern:

```swift
@MainActor
@Observable
final class TransactionStore {
    private var suggestionTask: Task<Void, Never>?

    func fetchPayeeSuggestions(prefix: String) {
        suggestionTask?.cancel()
        suggestionTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            guard !Task.isCancelled else { return }
            let results = try? await repository.fetchPayeeSuggestions(prefix: prefix)
            guard !Task.isCancelled else { return }
            self.payeeSuggestions = results ?? []
        }
    }
}
```

**Rules for debouncing:**
- Always cancel the previous task before starting a new one
- Check `Task.isCancelled` after every suspension point (`await`)
- Keep the stored `Task` as a property on the store, not in a view

### Views: `.task` Modifier

Use `.task` for loading data when a view appears. SwiftUI automatically cancels the task when the view disappears.

```swift
List {
    ForEach(store.accounts) { account in
        AccountRow(account: account)
    }
}
.task {
    await store.load()
}
```

Use `.task(id:)` to re-run when a dependency changes:

```swift
.task(id: selectedAccountId) {
    await transactionStore.load(accountId: selectedAccountId)
}
```

**Rules for `.task`:**
- Use for initial data loading and reactive reloading
- Never use `Task { }` in `onAppear` — use `.task` instead (it handles cancellation)
- Keep the body simple: call one store method, or a small number of independent loads

### Views: `Task { }` in Actions

For user-initiated actions (button taps, swipe actions), use `Task { }`:

```swift
Button("Save") {
    Task {
        await store.update(transaction)
        dismiss()
    }
}
```

**Rules:**
- Keep `Task { }` bodies to 1-3 lines
- All logic belongs in the store — the view just dispatches
- Never put error handling, retry logic, or complex orchestration in a `Task { }` block in a view

---

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
    let timed: URLRequest = {
      var request = request
      request.timeoutInterval = retryPolicy.requestTimeout
      return request
    }()
    return try await withRetry(
      policy: retryPolicy,
      classify: { HTTPRetryClassifier.decision(for: $0, idempotent: true) },
      operation: { @Sendable in
        try await self.attempt(request: timed, stage: stage)
      }
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

---

## 5. Optimistic Updates

For mutations that should feel instant, update local state before the server confirms:

```swift
func update(_ account: Account) async throws {
    // 1. Save old state for rollback
    let oldAccounts = accounts

    // 2. Apply optimistic update
    if let index = accounts.firstIndex(where: { $0.id == account.id }) {
        accounts[index] = account
    }

    // 3. Attempt server mutation
    do {
        let updated = try await repository.update(account)
        if let index = accounts.firstIndex(where: { $0.id == updated.id }) {
            accounts[index] = updated
        }
    } catch {
        // 4. Rollback on failure
        accounts = oldAccounts
        throw error
    }
}
```

**Rules:**
- Always save the old state before mutating
- Always rollback on failure
- The server response is authoritative — replace the optimistic value with the server's response
- This pattern belongs in stores, never in views

---

## 6. Reactive Recompute: Guard Against Stale Publishes

A reactive `@MainActor @Observable` store often recomputes published state
(converted balances, running-balance rows, valued positions) in response to
*several independent* async sources — a `repository.observeAll()` snapshot, a
`conversionService.observeRates()` tick, an instrument-registry change, an
account switch. Each recompute reads a snapshot of the store's inputs, `await`s
a conversion / fetch, then publishes.

`@MainActor` serialises the *continuations* but not their *order*, so two
recomputes can be in flight at once (e.g. a background rate-tick pass and an
authoritative data pass) and **whichever resumes last wins** — even if it
computed over stale input. An unconditional publish therefore lets a stale pass
clobber fresher state (a just-added transaction vanishes, the sidebar blanks,
the wrong account's positions show):

```swift
// WRONG — unconditional publish
func recompute() async {
    let input = self.accounts             // snapshot the input
    let result = await convert(input)     // suspends; a fresher snapshot may land here
    self.published = result               // clobbers whatever landed while suspended
}
```

**Rule: capture a generation before the compute; drop the publish if it
advanced.** A monotonic counter, bumped only by the authoritative source, lets a
superseded pass detect that it lost the race and skip its write:

```swift
@ObservationIgnored private(set) var snapshotGeneration: UInt64 = 0
func bumpSnapshotGeneration() { snapshotGeneration &+= 1 }  // authoritative apply / load calls this

func recompute() async {
    let generation = snapshotGeneration   // capture BEFORE reading inputs (no await between)
    let input = self.accounts
    let result = await convert(input)
    guard generation == snapshotGeneration else { return }  // superseded — a fresher pass owns the state
    self.published = result
}
```

- Capture the generation with **no suspension** between the capture and the
  input read, so the two are consistent (both `@MainActor`, both synchronous).
- Bump the counter only from the **authoritative** context change — a new
  `observeAll()` snapshot, an account switch, a filter reset — *not* from the
  background tick that should be dropped. The tick is the loser, not the bumper.
- `@ObservationIgnored` so a bump doesn't re-render every view.

**Retry loops: a dropped pass makes no retry decision.** If the store spawns a
background retry after a conversion failure, a pass that *dropped* its publish
must not also drive retry management. Its (stale) `anyFailed` is meaningless —
treating a stale success as authoritative would cancel the retry a fresher
*failing* pass needs. Return whether the publish happened and gate the retry
decision on it (do **not** mark the publish helper `@discardableResult`, so an
ignored result fails to compile):

```swift
let published = publishSnapshot(result, ifGeneration: generation)
guard published else { return }   // (or `continue`, inside the retry loop)
if !result.anyFailed { conversionTask?.cancel(); conversionTask = nil }
```

This class of bug (issue #1209) was fixed across `AccountStore`, `EarmarkStore`,
`TransactionStore`, and `InvestmentStore`; `AccountGroupStore` and the
instrument-registry refetch path (`applyInstrumentRegistryRefresh`) use the same
guard. Stores that instead **serialise** their recomputes with a single-flight
flag — flipped with no `await` between the check and the set, as in
`AnalysisStore` / `InsightStore` — are already safe, because concurrent
recomputes never coexist.

---

## 7. Pagination

For large data sets, load pages incrementally:

```swift
@MainActor
@Observable
final class TransactionStore {
    var transactions: [Transaction] = []
    var isLoading = false
    var hasMore = true
    private var currentPage = 0
    private let pageSize = 50

    func load() async {
        currentPage = 0
        hasMore = true
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repository.fetch(filter: filter, page: 0, pageSize: pageSize)
            transactions = page.items
            hasMore = page.hasMore
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        currentPage += 1
        do {
            let page = try await repository.fetch(filter: filter, page: currentPage, pageSize: pageSize)
            transactions.append(contentsOf: page.items)
            hasMore = page.hasMore
        } catch {
            currentPage -= 1
            self.error = error.localizedDescription
        }
    }
}
```

**Rules:**
- Guard against concurrent loads (`guard !isLoading`)
- Guard against loading past the end (`guard hasMore`)
- Rollback page counter on failure
- Trigger `loadMore()` from the view when the last item appears (or via a sentinel view)

---

## 8. SwiftUI List Performance

### Never Add `.id()` to ForEach Children

Adding `.id()` modifiers to items inside a `ForEach` **destroys lazy loading**. SwiftUI instantiates all views immediately instead of only visible ones. With large data sets this causes severe performance degradation.

```swift
// BAD: Destroys lazy loading
ForEach(items) { item in
    ItemRow(item: item)
        .id(item.id)  // DO NOT DO THIS
}

// GOOD: Let ForEach handle identity via Identifiable
ForEach(items) { item in
    ItemRow(item: item)
}

// GOOD: Use sentinel views for scroll-to targets
List {
    TopSentinel().id("top").listRowSeparator(.hidden)
    ForEach(items) { item in
        ItemRow(item: item)
    }
}
```

### Use `.task` for Lazy Data Loading

Trigger data loading only when views appear:

```swift
List {
    ForEach(store.transactions) { transaction in
        TransactionRow(transaction: transaction)
    }

    if store.hasMore {
        ProgressView()
            .task {
                await store.loadMore()
            }
    }
}
```

### Debounce Search Input

Never send a network request on every keystroke. Debounce with at least 200ms delay:

```swift
.searchable(text: $searchText)
.task(id: searchText) {
    try? await Task.sleep(nanoseconds: 250_000_000)
    guard !Task.isCancelled else { return }
    await store.search(query: searchText)
}
```

Alternatively, use the Task cancellation pattern in the store (see Section 3).

**Source:** [WWDC 2025: Optimize SwiftUI Performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/)

---

## 9. Anti-Patterns

### Threading & Concurrency

| Anti-Pattern | Why It's Bad | Do This Instead |
|-------------|--------------|-----------------|
| `DispatchQueue.main.async { }` | Bypasses Swift concurrency safety checks | Use `@MainActor` isolation |
| `DispatchQueue.global().async { }` | Unstructured, no cancellation, no priority | Use `Task { }` or `@concurrent` |
| `Task.detached { }` | Loses actor isolation, task-local values, and priority | Use `Task { }` (inherits context) |
| `@unchecked Sendable` on production types | Bypasses compiler safety; hides real threading bugs | Use `actor` or make the type properly `Sendable` |
| `nonisolated(unsafe)` in production code | Compiler escape hatch; allows data races | Only use in tests for `URLProtocol` stubs |
| Callbacks / completion handlers | Harder to reason about, no structured cancellation | Use `async/await` |
| `import Combine` | Legacy reactive framework; use `@Observable` instead | `@Observable` + `async/await` |
| Polling with `Timer` / `DispatchSource` | Resource-heavy, imprecise, complex lifecycle | Use `.task(id:)` or `AsyncStream` |

### Task Management

| Anti-Pattern | Why It's Bad | Do This Instead |
|-------------|--------------|-----------------|
| `Task { }` in `onAppear` | No automatic cancellation on disappear | Use `.task` modifier |
| Storing `Task` in a view `@State` | View identity changes can orphan tasks | Store tasks in the store |
| `Task { }` with complex logic in views | Untestable, violates thin-view principle | Move logic to store methods |
| Ignoring `Task.isCancelled` after `await` | Wasted work, stale data updates | Always check after suspension points |
| Fire-and-forget `Task { }` in stores | No error handling, silent failures | Track the task, handle errors |

### Network

| Anti-Pattern | Why It's Bad | Do This Instead |
|-------------|--------------|-----------------|
| Raw `URLSession.data(for:)` in production code outside the four sanctioned shapes | Scattered network code, inconsistent error handling, no host-shared rate-limit | Route through one of §4's four shapes (`RateLimitedHTTPClient`, `NetworkingServices`, `withRetry` + `HTTPRetryPolicy`, or `RateLimiter`) |
| Not checking HTTP status codes | `URLSession` doesn't throw on 4xx/5xx | Always validate response codes |
| Retry loops without backoff | Can overwhelm the server, drain battery | Use exponential backoff with jitter |
| Creating `URLSession` per request | Resource waste, connection pool fragmentation | Reuse `URLSession.shared` or a single custom session |

### Data & State

| Anti-Pattern | Why It's Bad | Do This Instead |
|-------------|--------------|-----------------|
| Optimistic update without rollback | UI shows stale/incorrect data on failure | Always save old state, rollback on error |
| Loading all pages in a loop at startup | Slow initial load, blocks UI | Use pagination with `loadMore()` |
| Mutating `@Observable` state from background | Runtime crash or undefined behavior | Ensure all state mutation is `@MainActor` |
| Sharing mutable state between stores | Race conditions, unclear ownership | Each store owns its state; communicate via callbacks or reload |
| Publishing a recompute result unconditionally after an `await` | A stale pass that resumes last clobbers fresher published state (#1209) | Capture a generation before the compute; drop the publish if it advanced (§6) |
| A dropped (superseded) recompute still driving retry / cancel decisions | A stale success cancels the retry a fresher failing pass needs | Return whether the publish happened; make no retry decision when it didn't (§6) |

---

## 10. Testing Concurrency

### Store Tests Run on `@MainActor`

All store tests are `@MainActor` because the stores themselves are `@MainActor`:

```swift
@MainActor
final class AccountStoreTests: XCTestCase {
    func testLoad() async throws {
        let (backend, _) = try TestBackend.create()
        let store = AccountStore(repository: backend.accounts)

        await store.load()

        #expect(store.accounts.count == 0)
    }
}
```

### Use `TestBackend`, Not Mocks

Tests use `TestBackend` which creates a `CloudKitBackend` backed by an in-memory GRDB database. This is fast (no I/O), deterministic (no network), and tests real production code paths (not mocked interfaces).

### Remote Backend Tests Use URLProtocol Stubs

For testing the remote layer, use `URLProtocol` subclasses with ephemeral sessions:

```swift
final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else { return }
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
```

`nonisolated(unsafe)` on `requestHandler` is acceptable here because tests run sequentially on `@MainActor`.

---

## 11. Future Considerations

### Swift 6.2 Default MainActor Isolation

When migrating to Xcode 26 / Swift 6.2, enable default MainActor isolation:

```swift
// In project.yml or Package.swift
.target(
    swiftSettings: [
        .defaultIsolation(MainActor.self)
    ]
)
```

This will:
- Make `@MainActor` the default for all types (can remove explicit annotations)
- Require `@concurrent` to opt into background execution
- Change `nonisolated` to mean `nonisolated(nonsending)` (stays on caller's actor)

### Request Deduplication

If profiling shows duplicate concurrent requests (e.g., multiple views loading the same account), implement the `InFlightTaskCoalescer` pattern from Section 4.

### AsyncSequence for Reactive Data

If the app needs real-time updates (WebSocket, server-sent events), use `AsyncStream`:

```swift
let changes = AsyncStream<DatabaseChange> { continuation in
    let observer = database.observe { change in
        continuation.yield(change)
    }
    continuation.onTermination = { _ in observer.cancel() }
}

// Consumed in SwiftUI
.task {
    for await change in changes {
        await handleChange(change)
    }
}
```

### Background URLSession

For large file downloads or uploads that should continue when the app is backgrounded, use `URLSessionConfiguration.background`. This is not currently needed but should be considered for features like data export or backup.

---

## Version History

- **1.1** (2026-07-03): Added §6 "Reactive Recompute: Guard Against Stale Publishes" (the `snapshotGeneration` clobber-guard pattern) and its anti-pattern rows.
- **1.0** (2026-04-09): Initial concurrency guide
