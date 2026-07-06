# Resumable, determinate direct-RPC wallet sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended, per this repo's CLAUDE.md) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task follows the repo's TDD + AI-review gate (`guides/AI_WORKFLOW_GUIDE.md`, `guides/AI_REVIEW_GATE_GUIDE.md`): write failing test → make it pass → `just format-check` → run the relevant reviewer agent(s) → fix every finding → commit.

**Goal:** On the direct-RPC (`eth_getLogs`) crypto-sync path, scan in block windows so an interrupted sync resumes mid-scan (checkpoint advances per ~30 s window, even across empty ranges) and the sync button shows a determinate progress bar from the start block to the chain head.

**Architecture:** A new per-account windowed runner drives the direct path: fetch `head` up front, fetch Blockscout native/internal/wrap-unwrap once and partition it by block, then loop fixed block windows — each window scans ERC-20 logs for `[s, e]`, builds over (ERC-20 window ∪ native partition), applies that one account's window through the existing `WalletApplyEngine`, and advances both the local `wallet_sync_state` and synced `wallet_sync_checkpoint` to `e`. The Alchemy-cursor path and exchange sources are untouched (single-shot). Progress is published per chunk to `SyncedAccountStore` and rendered as a determinate `ProgressView(value:)`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, GRDB, Swift Testing (`@Suite`/`@Test`), XCUITest. `just build-mac`, `just test-mac <ExactSuiteName>`, `just format-check`.

## Global Constraints

- **Swift Testing, not XCTest** for unit tests (`import Testing`; `@Suite`/`@Test`/`#expect`). UI-test drivers still import XCTest — see `guides/UI_TEST_GUIDE.md`.
- **`just test-mac <filter>` needs the EXACT `@Suite` struct name** — a substring runs 0 tests and reports green vacuously. Always confirm a non-zero test count. (See memory: "test-mac exact suite filter".)
- **Never run `just test-ui` locally** — gate UI-test changes on the PR's CI job. Build/format/unit tests locally are fine. (See memory: "No local UI tests".)
- **Thin views**: no business logic in SwiftUI view bodies; decisions live in testable helpers (`SyncedAccountHeaderLogic` is the established pattern).
- **`WalletApplyEngine` is the single writer** of `wallet_sync_state` + `wallet_sync_checkpoint`. The windowed runner advances checkpoints only *through* `WalletApplyEngine.apply` — it does not write repositories directly.
- **Money/instrument rules**: never `abs()` trade legs; `InstrumentAmount` arithmetic traps on mismatched instruments. Not central here, but the builder path is shared.
- **AI review gate is mandatory**: run reviewers before each commit and fix every finding (see memory: "Never ignore findings"). Reviewer routing per task is called out below.
- **Reorg window = 32 blocks** (`WalletSyncEngine.subtractingReorgWindow`) — preserved unchanged; resume starts `checkpoint − 32`.
- **`segmentBlockWindow` default = `250_000`** blocks — a tunable constant, a rough ~30 s-of-scanning proxy (scan rate varies by RPC/log density); documented as tunable at its definition.

---

## File / responsibility map

- `Shared/CryptoImport/ChainDataClient.swift` — **modify** protocol: add `currentHead`, add `toBlock:` to `getAssetTransfers`. `LiveAlchemyClient` conformance: `currentHead` → `nil`, ignore `toBlock`.
- `Shared/CryptoImport/DirectRPC/DirectRPCChainClient.swift` — **modify**: `currentHead` → `rpc.blockNumber()`; honour `toBlock` (scan `[fromBlock, toBlock ?? head]`).
- `Shared/CryptoImport/DirectRPC/RoutingChainDataClient.swift` — **modify**: forward `currentHead` + windowed `getAssetTransfers` to the resolved client.
- `Shared/CryptoImport/WalletSyncEngine.swift` — **modify**: extract a windowable `buildWindow(...)` primitive + a `fetchNativeContext(...)` primitive from `build`; keep `build` as the single-shot caller of both.
- `Shared/CryptoImport/WindowedWalletSyncRunner.swift` — **create**: the per-account windowed loop (head → native-context → window loop → per-window apply + checkpoint + progress).
- `Features/Sync/WalletSyncProgress.swift` — **create**: `enum WalletSyncProgress`.
- `Features/Sync/SyncedAccountStore.swift` — **modify**: add `progressPerAccount`, a `@MainActor` progress setter, clear on completion.
- `Features/Sync/SyncedAccountStore+Internals.swift` — **modify**: route direct-path crypto accounts to the windowed runner; accumulate `genuinelyNew`; keep single-shot otherwise.
- `Features/Sync/SyncedAccountHeaderView.swift` — **modify**: determinate `ProgressView(value:)` when a fraction is present (via a `SyncedAccountHeaderLogic` helper).
- `Features/Sync/SyncedAccountHeaderLogic.swift` — **modify**: add a pure mapper from `WalletSyncProgress?` → determinate value / indeterminate.
- Tests under `MoolahTests/Shared/CryptoImport/` and `MoolahTests/Features/Sync/`; test doubles in `MoolahTests/Shared/CryptoImport/WalletSyncTestDoubles.swift`.

---

## Task 1: Seam — `currentHead` + windowed `getAssetTransfers` (no behaviour change)

**PR 1.** Purely additive seam change; every existing call site keeps working via a defaulted `toBlock: nil`.

**Files:**
- Modify: `Shared/CryptoImport/ChainDataClient.swift` (protocol + `LiveAlchemyClient` conformance)
- Modify: `Shared/CryptoImport/DirectRPC/DirectRPCChainClient.swift`
- Modify: `Shared/CryptoImport/DirectRPC/RoutingChainDataClient.swift`
- Modify: `MoolahTests/Shared/CryptoImport/WalletSyncTestDoubles.swift` (stubs conform to new protocol)
- Test: `MoolahTests/Shared/CryptoImport/DirectRPCChainClientWindowTests.swift` (create)

**Interfaces:**
- Produces (consumed by Tasks 3–5):
  ```swift
  protocol ChainDataClient: Sendable {
    func currentHead(chain: ChainConfig) async throws -> UInt64?
    func getAssetTransfers(
      chain: ChainConfig, walletAddress: String,
      fromBlock: UInt64, toBlock: UInt64?
    ) async throws -> [AlchemyTransfer]
    func getTransactionReceipt(chain: ChainConfig, hash: String) async throws -> AlchemyTransactionReceipt
  }
  ```
  - `currentHead` → `nil` means "not block-range scannable" (Alchemy). Non-nil is the chain head.
  - `toBlock: nil` means "scan to head" (existing behaviour).

- [ ] **Step 1: Write the failing test** — `DirectRPCChainClientWindowTests` (`@Suite struct DirectRPCChainClientWindowTests`). Use the existing `LiveJSONRPCClient` test seam / stubbed RPC transport already used by the direct-RPC tests (find the current `DirectRPCChainClient` test file and reuse its transport double). Assert:
  - `currentHead(chain:)` returns the stubbed `eth_blockNumber`.
  - `getAssetTransfers(..., fromBlock: 100, toBlock: 200)` issues `eth_getLogs` whose chunk filters never exceed `toBlock = 200` (inspect recorded `RPCLogFilter.toBlock` values; none > `0xC8`) and never fetches `eth_blockNumber` to discover head (bounded call).
  - `getAssetTransfers(..., fromBlock: 100, toBlock: nil)` reproduces today's behaviour (scans to the stubbed head).

- [ ] **Step 2: Run it, confirm failure** — `just test-mac DirectRPCChainClientWindowTests`. Expected: compile failure / FAIL (new protocol members absent).

- [ ] **Step 3: Implement.**
  - `ChainDataClient` protocol: add `currentHead` and the `toBlock:` parameter (as above).
  - `LiveAlchemyClient`: `func currentHead(chain:) async throws -> UInt64? { nil }`; change its `getAssetTransfers` signature to accept `toBlock: UInt64?` and **ignore** it (its params already hard-code `toBlock: "latest"`).
  - `DirectRPCChainClient`: add `currentHead` → `try await rpc.blockNumber()`. Refactor `getAssetTransfers` so head resolution is `let head = try await toBlock ?? rpc.blockNumber()`; pass `head` as the upper bound to both `fetchLogs(from:fromBlock, to: head, …)` passes (rest unchanged).
  - `RoutingChainDataClient`: forward both new members to the resolved client (mirror the existing `getAssetTransfers` forwarding).
  - Update every existing `getAssetTransfers(...fromBlock:)` call site to `...fromBlock:, toBlock: nil)` (notably `WalletSyncEngine.build` line ~133, `WrapUnwrapDetector`, and all test doubles). Grep: `getAssetTransfers(` to find them all.

- [ ] **Step 4: Run tests, confirm pass** — `just test-mac DirectRPCChainClientWindowTests` (non-zero count) + the existing direct-RPC + wallet-sync suites to prove no regression. `just build-mac`.

- [ ] **Step 5: Reviewers** — `@concurrency-review` (Sendable seam) + `@code-review`. Fix all findings.

- [ ] **Step 6: Commit** — `feat(sync): add currentHead + windowed toBlock to ChainDataClient seam`.

---

## Task 2: `WalletSyncProgress` model + store field

**PR 2 (start).** Small, dependency-free foundation the runner (Task 4) writes and the view (Task 6) reads.

**Files:**
- Create: `Features/Sync/WalletSyncProgress.swift`
- Modify: `Features/Sync/SyncedAccountStore.swift` (observable field + setter)
- Test: `MoolahTests/Features/Sync/SyncedAccountStoreProgressTests.swift` (create)

**Interfaces:**
- Produces:
  ```swift
  enum WalletSyncProgress: Sendable, Equatable {
    case indeterminate
    case scanning(fraction: Double)   // fraction clamped to 0...1
  }
  ```
  On `SyncedAccountStore`:
  ```swift
  private(set) var progressPerAccount: [UUID: WalletSyncProgress] = [:]
  func setSyncProgress(_ progress: WalletSyncProgress?, for accountId: UUID)  // @MainActor
  ```
  `setSyncProgress(nil, …)` removes the entry (clears the bar).

- [ ] **Step 1: Failing test** — `@Suite struct SyncedAccountStoreProgressTests` (`@MainActor`). Build a store via the existing test factory (see how `SyncedAccountStore` is constructed in current sync tests). Assert: default `progressPerAccount` is empty; `setSyncProgress(.scanning(fraction: 0.5), for: id)` then `progressPerAccount[id] == .scanning(fraction: 0.5)`; `.scanning(fraction: 2.0)` is clamped to `1.0`; `setSyncProgress(nil, for: id)` removes it.

- [ ] **Step 2: Run, confirm failure** — `just test-mac SyncedAccountStoreProgressTests`.

- [ ] **Step 3: Implement** — create the enum (clamp in a factory or in the setter); add the field + `setSyncProgress` to `SyncedAccountStore` (mirror `setGlobalError`'s shim pattern; keep `private(set)` so views only observe).

- [ ] **Step 4: Run, confirm pass** (non-zero count) + `just build-mac`.

- [ ] **Step 5: Reviewers** — `@code-review`. Fix findings.

- [ ] **Step 6: Commit** — `feat(sync): add WalletSyncProgress + progressPerAccount to SyncedAccountStore`.

---

## Task 3: Extract windowable primitives from `WalletSyncEngine.build`

**PR 2.** Refactor-only, behaviour-preserving: split `build` into (a) native-context fetch and (b) a windowable candidate builder, so both the single-shot path and the runner reuse the same composition. No caller behaviour changes yet.

**Files:**
- Modify: `Shared/CryptoImport/WalletSyncEngine.swift`
- Test: `MoolahTests/Shared/CryptoImport/WalletSyncEngineWindowBuildTests.swift` (create)

**Interfaces:**
- Produces (consumed by Task 4):
  ```swift
  /// The Blockscout native + internal + wrap/unwrap set for [fromBlock, head],
  /// fetched once; the runner partitions `nativeRows` by block per window.
  struct WalletSyncNativeContext: Sendable {
    let nativeRows: [AlchemyTransfer]      // adapted native + internal + wrap/unwrap rows
    let signedGasTxs: [SignedGasTx]        // (existing adapted.signedGasTxs type)
    let prefetchedReceipts: [String: AlchemyTransactionReceipt]  // wrapUnwrap.receipts type
  }

  extension WalletSyncEngine {
    func fetchNativeContext(
      account: Account, chain: ChainConfig, walletAddress: String, fromBlock: UInt64
    ) async throws -> WalletSyncNativeContext

    /// Builds candidates for ONE window: ERC-20 logs for [from, to] merged with
    /// the caller-supplied native rows whose block ∈ [from, to]. `headForRecord`
    /// is the block the apply pass will checkpoint to (the window end `e`).
    func buildWindow(
      account: Account, chain: ChainConfig, walletAddress: String,
      from: UInt64, to: UInt64,
      nativeRowsInWindow: [AlchemyTransfer],
      signedGasTxs: [SignedGasTx],
      prefetchedReceipts: [String: AlchemyTransactionReceipt],
      headForRecord: UInt64
    ) async throws -> WalletSyncBuildResult
  }
  ```
  (Confirm the exact element types for `signedGasTxs` / `prefetchedReceipts` from `BlockscoutAdaptResult` and `WrapUnwrapResult` when implementing; the names above are the plan's contract.)

- [ ] **Step 1: Failing test** — `@Suite struct WalletSyncEngineWindowBuildTests`. Using the existing wallet-sync test doubles (stub `ChainDataClient`, stub `BlockExplorerClient`, in-memory repos), assert:
  - `fetchNativeContext` returns the adapted native rows for a scripted Blockscout response.
  - `buildWindow(from:100,to:200,nativeRowsInWindow:[…],headForRecord:200)` returns a `WalletSyncBuildResult` whose `headBlockNumber == 200` (the window end, NOT the max transfer block) and whose candidates include both an ERC-20 log the stub returns for `[100,200]` and a supplied native row.
  - `buildWindow` calls the ERC-20 client with `toBlock: 200` (assert via a recording stub).

- [ ] **Step 2: Run, confirm failure** — `just test-mac WalletSyncEngineWindowBuildTests`.

- [ ] **Step 3: Implement** — extract from `build`:
  - `fetchNativeContext`: the Blockscout fetch (`fetchBlockscout`) + `wrapUnwrapDetector.detect`, returning the adapted native rows (`adapted.transfers + wrapUnwrap.rows`), `adapted.signedGasTxs`, and `wrapUnwrap.receipts`.
  - `buildWindow`: fetch ERC-20 via `alchemy.getAssetTransfers(chain:walletAddress:fromBlock:from, toBlock:to)`, filter `.erc20`, merge with `nativeRowsInWindow`, run `TransferEventBuilder.build(...)` exactly as `build` does, and return `WalletSyncBuildResult(candidates: built, headBlockNumber: headForRecord)`.
  - Reimplement `build` in terms of these two (single window `[fromBlock, head]`, `headForRecord = maxBlockNumber(in: merged) ?? priorBlock` to preserve today's exact single-shot semantics). Keep the "builder dropped all transfers" warning.

- [ ] **Step 4: Run, confirm pass** — `WalletSyncEngineWindowBuildTests` (non-zero) + the full existing `WalletSyncEngine` suite (unchanged behaviour) + `just build-mac`.

- [ ] **Step 5: Reviewers** — `@code-review` + `@concurrency-review`. Fix findings.

- [ ] **Step 6: Commit** — `refactor(sync): extract fetchNativeContext + buildWindow from WalletSyncEngine.build`.

---

## Task 4: `WindowedWalletSyncRunner` — window loop + per-window apply + checkpoint + progress

**PR 3 (core).** The heart of the feature. A per-account runner that interleaves scan → apply → checkpoint per window and publishes progress. It uses `WalletApplyEngine` as the sole writer (checkpoint advances via `AccountInput.headBlockNumber = e`).

**Files:**
- Create: `Shared/CryptoImport/WindowedWalletSyncRunner.swift`
- Create: `Shared/CryptoImport/WalletSyncWindowMath.swift` (pure window/partition helpers — split out for isolated testing)
- Test: `MoolahTests/Shared/CryptoImport/WalletSyncWindowMathTests.swift`
- Test: `MoolahTests/Shared/CryptoImport/WindowedWalletSyncRunnerTests.swift`

**Interfaces:**
- Consumes: Task 1 (`currentHead`, windowed `getAssetTransfers`), Task 2 (`WalletSyncProgress`), Task 3 (`fetchNativeContext`, `buildWindow`).
- Produces (consumed by Task 5):
  ```swift
  struct WalletSyncWindow: Sendable, Equatable { let from: UInt64; let to: UInt64 }

  enum WalletSyncWindowMath {
    /// Inclusive windows covering [from, head] in <= size steps. Empty when from > head.
    static func windows(from: UInt64, head: UInt64, size: UInt64) -> [WalletSyncWindow]
    /// Rows whose parsed blockNum ∈ [window.from, window.to].
    static func partition(_ rows: [AlchemyTransfer], into window: WalletSyncWindow) -> [AlchemyTransfer]
    /// (pos - from) / (head - from), clamped 0...1; 1.0 when head == from.
    static func fraction(pos: UInt64, from: UInt64, head: UInt64) -> Double
  }

  @MainActor
  final class WindowedWalletSyncRunner {
    struct RunResult: Sendable { let genuinelyNew: [Transaction]; let didWindowedScan: Bool }
    /// Returns .didWindowedScan == false when currentHead is nil (caller falls back to single-shot).
    func run(
      account: Account, chain: ChainConfig,
      progress: @MainActor (WalletSyncProgress) -> Void
    ) async throws -> RunResult
  }
  ```
  Constructor injects: the `WalletSyncEngine` (for `fetchNativeContext`/`buildWindow`), the `ChainDataClient` (for `currentHead`), the `WalletApplyEngine`, the `WalletSyncCheckpointRepository`/`WalletSyncStateRepository` reads used to compute `fromBlock`, and `segmentBlockWindow`.

- [ ] **Step 1: Failing tests for `WalletSyncWindowMath`** — `@Suite struct WalletSyncWindowMathTests`: `windows(from:100,head:100,size:250_000) == [Window(100,100)]`; `windows(from:0,head:600_000,size:250_000)` == `[(0,249_999),(250_000,499_999),(500_000,600_000)]`; `windows(from:10,head:5,…) == []`; `partition` keeps only in-range blocks and drops unparseable `blockNum`; `fraction(pos:150,from:100,head:200)==0.5`, `fraction(pos:100,from:100,head:100)==1.0`, clamps.

- [ ] **Step 2: Run, confirm failure** — `just test-mac WalletSyncWindowMathTests`.

- [ ] **Step 3: Implement `WalletSyncWindowMath`** (pure functions).

- [ ] **Step 4: Run, confirm pass** — `WalletSyncWindowMathTests` (non-zero).

- [ ] **Step 5: Failing tests for `WindowedWalletSyncRunner`** — `@Suite struct WindowedWalletSyncRunnerTests` (`@MainActor`), using stub `ChainDataClient` (scripted `currentHead` + per-window ERC-20 rows), stub `BlockExplorerClient`, in-memory `TransactionRepository` + checkpoint/state repos, and a real `WalletApplyEngine`. Assert:
  - **Empty windows advance the checkpoint:** head=600_000, no transfers anywhere → after `run`, `walletSyncCheckpoints.load(id).lastSyncedBlockNumber == 600_000` and local state == 600_000. (Today it would stay at the prior value.)
  - **Checkpoint advances per window:** inject a failure on the 3rd window's ERC-20 fetch → `run` throws, but the checkpoint equals the 2nd window's `e` (progress persisted), not the original `from`.
  - **Resume:** a second `run` (failure cleared) starts its first ERC-20 fetch at `secondCheckpoint − 32` (assert the recorded `fromBlock` on the stub), i.e. it does not re-scan window 1 from the top.
  - **Apply-before-checkpoint / idempotent replay:** a window whose transfers were applied, then re-run, produces no duplicate transactions (dedup by `(accountId, externalId)`); the checkpoint is only observable at/after the window's transactions are persisted.
  - **Progress:** the `progress` closure receives monotonic non-decreasing `.scanning(fraction:)` values, starting near 0 and ending at `1.0`.
  - **Alchemy fallback:** when `currentHead` returns `nil`, `run` returns `didWindowedScan == false` and does not apply/checkpoint (caller handles single-shot).
  - **Lower-of-two-topics:** a window where the inbound topic pass returns a later-block log than outbound still checkpoints to the window end `e` both passes covered (never beyond `e`).

- [ ] **Step 6: Run, confirm failure** — `just test-mac WindowedWalletSyncRunnerTests`.

- [ ] **Step 7: Implement `WindowedWalletSyncRunner.run`:**
  1. `guard let head = try await chainClient.currentHead(chain:) else { return RunResult(genuinelyNew: [], didWindowedScan: false) }`.
  2. Compute `from` = `subtractingReorgWindow(max(local, synced))` (reuse `WalletSyncEngine.resolvePriorBlock` logic — expose it or replicate via the repos).
  3. `guard from <= head else { publish .scanning(1.0); return didWindowedScan:true, genuinelyNew:[] }` (already caught up).
  4. `let ctx = try await engine.fetchNativeContext(account:chain:walletAddress:fromBlock:from)`.
  5. `for window in WalletSyncWindowMath.windows(from:from, head:head, size: segmentBlockWindow)`:
     - `try Task.checkCancellation()`
     - `let native = WalletSyncWindowMath.partition(ctx.nativeRows, into: window)`
     - `let result = try await engine.buildWindow(account:chain:walletAddress:from:window.from, to:window.to, nativeRowsInWindow:native, signedGasTxs:ctx.signedGasTxs, prefetchedReceipts:ctx.prefetchedReceipts, headForRecord: window.to)`
     - `let input = WalletApplyEngine.AccountInput(account:account, headBlockNumber: window.to, candidates: result.candidates)`
     - `let persisted = try await applyEngine.apply(perAccount: [input])` — this persists AND advances local + synced checkpoint to `window.to` (empty windows still advance, because `headBlockNumber == window.to`).
     - accumulate `persisted` into `genuinelyNew`
     - `progress(.scanning(fraction: WalletSyncWindowMath.fraction(pos: window.to, from: from, head: head)))`
     - (optional finer progress: publish per chunk from within `buildWindow` in a later polish; window-granularity is the required baseline.)
  6. `return RunResult(genuinelyNew: genuinelyNew, didWindowedScan: true)`.
  - **Cancellation/interruption note:** a thrown error (network, cancellation) after window `k` leaves checkpoints at window `k`'s `e` — exactly the resume point. Do NOT swallow; rethrow so the caller records `lastError`.

- [ ] **Step 8: Run, confirm pass** — both new suites (non-zero) + `just build-mac`.

- [ ] **Step 9: Reviewers** — `@concurrency-review` (MainActor apply loop, cancellation), `@code-review`, `@database-code-review` (checkpoint writes via apply), `@sync-review` (checkpoint/`needs_push` cadence, eventual-consistency notes). Fix every finding.

- [ ] **Step 10: Commit** — `feat(sync): windowed direct-RPC sync runner with per-window checkpoint + progress`.

---

## Task 5: Route direct-path crypto accounts through the runner in `SyncedAccountStore`

**PR 3.** Wire the runner into the orchestrator: crypto accounts try the windowed runner; `didWindowedScan == false` (Alchemy) and all other sources fall back to today's build→apply. Detection + price-warming run once over accumulated `genuinelyNew`.

**Files:**
- Modify: `Features/Sync/SyncedAccountStore+Internals.swift`
- Modify: `Features/Sync/SyncedAccountStore.swift` (hold the runner; clear progress in `defer`)
- Modify: profile wiring where `SyncedAccountStore`/`WalletApplyEngine` are constructed (`ProfileSession.makeCryptoSyncWiring` — grep for the construction site) to inject the runner.
- Test: `MoolahTests/Features/Sync/SyncedAccountStoreWindowedSyncTests.swift` (create)

**Interfaces:**
- Consumes: Task 4 (`WindowedWalletSyncRunner`), Task 2 (`setSyncProgress`).
- Behaviour contract:
  - For each in-flight crypto account, call `runner.run(account:chain:) { progress in self.setSyncProgress(progress, for: account.id) }`.
  - If `didWindowedScan`, that account is fully synced (built+applied+checkpointed inside the runner); collect its `genuinelyNew`. Skip it in the single-shot build+apply pass.
  - Non-crypto sources and crypto accounts that returned `didWindowedScan == false` go through the **existing** `runParallelBuilds` → `runApplyPass` path unchanged.
  - After both, run `runTransferDetection` + `startPriceWarming` over the **union** of windowed `genuinelyNew` and single-shot `genuinelyNew`.
  - `defer { for id in inputs { setSyncProgress(nil, for: id) } }` clears bars on completion/error (alongside the existing `inProgressAccountIds` clear).

- [ ] **Step 1: Failing test** — `@Suite struct SyncedAccountStoreWindowedSyncTests` (`@MainActor`). Wire a store with a runner backed by stub clients. Assert:
  - Syncing a direct-path crypto account advances its checkpoint per window and ends at head (delegates to runner) — assert via the checkpoint repo.
  - During the scan, `progressPerAccount[id]` is `.scanning(...)`; after completion it is cleared (nil).
  - An Alchemy-path crypto account (stub `currentHead` → nil) still syncs via the single-shot path (assert a transaction persisted) and shows no `.scanning` progress.
  - A cross-account transfer between two direct-path accounts is still paired into one merged transaction across their windows (via the persisted-leg lookup) — regression for the apply-restructuring.
  - Detection runs once over the combined `genuinelyNew` (assert the detection coordinator recorded a single invocation with the union).

- [ ] **Step 2: Run, confirm failure** — `just test-mac SyncedAccountStoreWindowedSyncTests`.

- [ ] **Step 3: Implement** the routing in `syncAccounts`/`+Internals`: split `inputs` into windowed-eligible crypto vs the rest; run the runner (respect `maxConcurrentBuilds` — the runner is `@MainActor` and applies serially, so run runners sequentially or in a bounded task group that awaits each `run`); merge `genuinelyNew`; keep the existing path for the rest; single detection + warming; clear progress in `defer`.

- [ ] **Step 4: Run, confirm pass** — new suite (non-zero) + the full existing `SyncedAccountStore` suites (no regression) + `just build-mac`.

- [ ] **Step 5: Reviewers** — `@concurrency-review` (orchestration, task hygiene, cancellation), `@code-review`, `@sync-review`. Fix every finding.

- [ ] **Step 6: Commit** — `feat(sync): route direct-RPC crypto accounts through the windowed runner`.

---

## Task 6: Determinate progress bar in the sync button

**PR 4.** Thin-view change: render `ProgressView(value:)` when a fraction is present.

**Files:**
- Modify: `Features/Sync/SyncedAccountHeaderLogic.swift` (pure mapper)
- Modify: `Features/Sync/SyncedAccountHeaderView.swift` (consume it)
- Test: `MoolahTests/Features/Sync/SyncedAccountHeaderLogicTests.swift` (extend existing suite if present, else create)

**Interfaces:**
- Consumes: Task 2 (`WalletSyncProgress`, `progressPerAccount`).
- Produces:
  ```swift
  enum SyncButtonProgress: Equatable { case none; case indeterminate; case determinate(Double) }
  extension SyncedAccountHeaderLogic {
    static func syncButtonProgress(
      isSyncing: Bool, progress: WalletSyncProgress?
    ) -> SyncButtonProgress
  }
  ```
  Mapping: not syncing → `.none`; syncing + `.scanning(f)` → `.determinate(f)`; syncing + (`.indeterminate` | nil) → `.indeterminate`.

- [ ] **Step 1: Failing test** — assert the four mappings of `syncButtonProgress(isSyncing:progress:)`.

- [ ] **Step 2: Run, confirm failure** — `just test-mac SyncedAccountHeaderLogicTests`.

- [ ] **Step 3: Implement** the mapper; in `SyncedAccountHeaderView.syncButton`, replace the `if isSyncing { ProgressView().controlSize(.small) }` branch with a switch on `SyncedAccountHeaderLogic.syncButtonProgress(isSyncing: isSyncing, progress: syncStore.progressPerAccount[account.id])`: `.determinate(f)` → `ProgressView(value: f).controlSize(.small).progressViewStyle(.linear).frame(width: …)`; `.indeterminate` → today's spinner; `.none` → the `Label`. Keep the accessibility label; add the percentage to it when determinate (e.g. "Syncing 42%").

- [ ] **Step 4: Run, confirm pass** — logic suite (non-zero) + `just build-mac`. Optionally eyeball via `#Preview` + `mcp__xcode__RenderPreview` (see memory: "Iterate UI via #Preview") — do NOT relaunch the app.

- [ ] **Step 5: Reviewers** — `@ui-review` (determinate control sizing, accessibility, HIG), `@code-review` (thin-view discipline). Fix every finding.

- [ ] **Step 6: Commit** — `feat(sync): determinate progress bar for direct-RPC wallet sync`.

---

## Task 7: End-to-end regression + documentation sweep

**PR 4 (finish).**

**Files:**
- Modify: any doc that describes the checkpoint-advances-only-on-transfers behaviour (grep the `WalletSyncEngine` / `WalletApplyEngine` doc comments and `plans/2026-07-05-direct-rpc-erc20-discovery-*` for now-outdated "watermark advances to max transfer block" statements) so the empty-window-advances semantics are recorded.
- Test: reuse Task 4/5 suites; add one integration test that runs a full multi-window scan with a mid-scan throw and asserts the second run completes to head with no duplicate transactions.

- [ ] **Step 1: Add the integration regression test** (interruption → resume → completeness, no duplicates, checkpoint == head).
- [ ] **Step 2: Run it, confirm it fails/passes as written** — `just test-mac <SuiteName>`.
- [ ] **Step 3: Update stale doc comments** so they match empty-window checkpoint advancement.
- [ ] **Step 4: Full local gate** — `just build-mac` + `just format-check` + the full crypto-sync unit suites green.
- [ ] **Step 5: Reviewers** — `@code-review` + `@sync-review` on the final diff. Fix findings.
- [ ] **Step 6: Commit** — `test(sync): interruption-resume regression + doc updates for windowed sync`.

---

## Self-review (plan vs spec)

- **Spec §0 (multi-source, per-account apply, generic path stays single-shot)** → Tasks 3 (extract native context + buildWindow), 4 (per-window `apply(perAccount:[input])`), 5 (route only direct-path crypto; Alchemy/exchange single-shot). ✔
- **Spec §1 (window loop, Blockscout up-front + partition, checkpoint per window incl. empty)** → Task 4 steps 5/7 + Task 3. ✔
- **Spec §2 (apply-before-advance, idempotent replay, reorg window, empty advances)** → Task 4 step 5 assertions + Task 7 integration. ✔
- **Spec §3 (WalletSyncProgress, progressPerAccount, determinate view, Aggregated unchanged)** → Tasks 2 + 6. ✔
- **Spec §4 (currentHead + toBlock seam, Routing forwards, Resolver untouched)** → Task 1. ✔
- **Spec §5 (tests: empty advances, resume, apply-order, lower-of-two, progress monotonic, Alchemy unchanged)** → Task 4 step 5 + Task 5 step 1 + Task 7. ✔
- **Placeholder scan:** the only deferred detail is the exact element types for `signedGasTxs`/`prefetchedReceipts` (Task 3), explicitly flagged to confirm from `BlockscoutAdaptResult`/`WrapUnwrapResult` at implementation — a lookup, not a design gap. `segmentBlockWindow` has a concrete default (250_000). No TBDs.
- **Type consistency:** `currentHead`, `getAssetTransfers(…toBlock:)`, `WalletSyncProgress`, `setSyncProgress`, `fetchNativeContext`/`buildWindow`, `WalletSyncWindowMath`, `WindowedWalletSyncRunner.run`/`RunResult`, `syncButtonProgress` are used with identical signatures across the tasks that produce and consume them. ✔
