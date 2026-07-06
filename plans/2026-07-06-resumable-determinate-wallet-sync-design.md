# Resumable, determinate direct-RPC wallet sync — design

**Date:** 2026-07-06
**Status:** Approved (brainstorming), ready for implementation plan
**Builds on:** [Direct-RPC ERC-20 discovery](2026-07-05-direct-rpc-erc20-discovery-design.md) (PR #1245 — `eth_getLogs` source, synced checkpoint, `ChainDataClient` seam)

## Problem

A crypto wallet sync over the direct-RPC path scans `eth_getLogs` across `[fromBlock, head]`. On a large range (e.g. a first-time scan from genesis) this takes a long time, and today it has two shortcomings:

1. **Indeterminate progress.** The sync button shows a plain `ProgressView().controlSize(.small)` driven only by `SyncedAccountStore.inProgressAccountIds: Set<UUID>` — a boolean. The user gets no sense of how far along a long scan is, even though we know the starting block and the chain head.

2. **No partial-progress persistence.** The checkpoint (`wallet_sync_checkpoint.last_synced_block_number`) is written **once**, at the end of apply, to the *max block among found transfers* (`WalletSyncEngine.build` line 140: `maxBlockNumber(in: transfers) ?? priorBlock`). Consequences:
   - An **empty range never advances the checkpoint** — every subsequent cycle re-scans the same empty ranges from `priorBlock − 32`.
   - An **interruption mid-scan** (app quit, network drop) loses *all* progress for that run; the next sync restarts from the old checkpoint and re-fetches everything already scanned.

## Scope

Both improvements apply **only to the direct-RPC (`eth_getLogs`) path**, which runs when a chain resolves to `.direct` — a custom RPC matching the chain, or the publicnode default when no Alchemy key is present (`RPCEndpointResolver.client(for:)`).

The **Alchemy path** (Alchemy key present, no matching custom RPC) uses cursor-based `alchemy_getAssetTransfers` with `toBlock: "latest"` and has no block-window or head concept. It is **unchanged**: single end-of-sync checkpoint, indeterminate progress bar.

**One account = one chain.** `Account.chainId` is a single value; a wallet address on N chains is N separate `Account` rows, each with its own checkpoint. So the single per-account `last_synced_block_number` is well-defined and no multi-chain aggregation is needed.

## Design

### 0. The multi-source reality (why windowing is per-account, not per-scan)

`WalletSyncEngine.build` merges **three** sources before it derives a head or applies anything:

- **Blockscout** native + internal ETH (`BlockExplorerClient.nativeTransactions`/`internalTransactions`) — takes `fromBlock` only, paginates newest-first to latest; **no upper block bound**.
- **Wrap/unwrap synthesis** — derived off the Blockscout native set.
- **Direct-RPC ERC-20** `eth_getLogs` scan (`DirectRPCChainClient.getAssetTransfers`) — the long pole, and the only source with a determinate `[from, head]` block range.

For a resumable checkpoint to be *safe*, every transfer with block ≤ the checkpoint must be durably applied — native included, not just ERC-20 logs. Since Blockscout can't be windowed by an upper bound, the design **fetches Blockscout (native + internal + wrap/unwrap) once up front for `[from, head]`** (same cost as today) and **partitions those transfers by block number into the windows**, applying each window's native partition alongside that window's ERC-20 scan. Only the ERC-20 scan is windowed.

Two more consequences the pipeline forces:

- **Apply becomes per-account-per-window.** Today `WalletApplyEngine.apply(perAccount:)` runs **once per cycle across all accounts**. Mid-scan resumability requires applying (and checkpointing) *within* a scan, so the direct-path account applies its own windows incrementally — `apply(perAccount: [singleAccountInput])` per window. Cross-account transfer pairing is **preserved**: `CrossAccountTransferMerger` already pairs candidates against **already-persisted** legs via `existingLegLookup` (the "prior-cycle pair" path), so a pairing that used to happen in-batch now happens via the persisted-leg lookup on a later window/cycle — same result, idempotent. Transfer-detection and price-warming run **once at cycle end** over the union of each window's `genuinelyNew` survivors (unchanged semantics).
- **The generic `AccountSyncSource` path stays single-shot.** Windowing is specific to the direct-RPC crypto path. Exchanges (Coinstash) and the Alchemy-cursor crypto path keep today's `build(account:) -> WalletSyncBuildResult` → single cross-account apply.

### 1. Block-windowed segment coordinator (direct path)

Replace the single scan-everything-then-apply-once pass (for the direct path only) with a loop over fixed **block windows**:

1. Fetch `head` up front via the new seam capability (direct → `eth_blockNumber`). It is the progress target and, with the existing reorg window, defines `from = max(localState, syncedCheckpoint) − 32` (0 for a fresh account).
2. Fetch Blockscout native + internal + wrap/unwrap **once** for `[from, head]`; partition the resulting transfers by block number into the windows below.
3. Walk `[from, head]` in windows of a constant `segmentBlockWindow` (sized to roughly ~30 s of scanning; a tunable constant — exact block count is approximate because scan rate varies by RPC and log density).
4. For each window `[s, e]` where `e = min(s + segmentBlockWindow − 1, head)`:
   a. Run **both** ERC-20 topic passes (wallet-as-sender, wallet-as-recipient) concurrently over *exactly* `[s, e]`, using the existing `AdaptiveLogRangeBatcher` for chunking within the window. **Await both.**
   b. Build over the window's combined set: the ERC-20 logs from (a) **plus** the pre-fetched native/wrap-unwrap partition whose block ∈ `[s, e]`.
   c. Apply this account's window result via `WalletApplyEngine.apply(perAccount: [input])` and accumulate the returned `genuinelyNew` survivors.
   d. Advance the checkpoint to `e` — **both** the local `wallet_sync_state` and the synced `wallet_sync_checkpoint` (`raiseToMax`, which marks `needs_push`).
   e. Publish progress.
   f. Advance `s = e + 1`.
5. After the last window, run transfer-detection + price-warming once over the accumulated `genuinelyNew`.

**Why the window barrier matters (the "lower of the two topics" guarantee).** Because we await *both* topic passes for a window before applying or checkpointing, the checkpoint can only ever advance to a block that **both** passes have fully covered. It is structurally impossible to checkpoint past the slower topic. This is why block-windowing was chosen over a time-based flush of two independently-racing full-range passes — no cross-pass frontier-min tracking is needed for correctness.

**Checkpoint cadence** ≈ one apply + one CloudKit `needs_push` per window ≈ ~30 s of scanning. Per the product decision, updating the *synced* checkpoint at this cadence is acceptable (a re-scan of ~one window on interruption is fine); it does not need to advance per `eth_getLogs` call, nor wait for the whole sync.

### 2. Correctness invariants

- **Apply-before-advance.** A window's transfers are durably applied *before* its checkpoint moves. An interruption never advances the checkpoint past unsaved transactions, so no transaction is ever permanently skipped.
- **Idempotent replay.** An interruption *between* apply and the checkpoint write causes that one window to be re-scanned and re-applied next run. `WalletApplyEngine` dedups every leg against persisted legs by `(accountId, externalId)` (`survivingLegs`/`legExists`), so re-applying a window drops to a no-op. The plan asserts this for the windowed path.
- **Reorg window preserved.** Resume still starts at `checkpoint − 32` (`WalletSyncEngine.subtractingReorgWindow`). The checkpoint stores the fully-scanned window end; the reorg margin is re-applied on the next scan's `from`.
- **Empty windows advance the checkpoint.** Unlike today, a window with zero transfers still advances the checkpoint to `e`, so empty ranges are scanned once, not every cycle.

### 3. Progress surfaced to the UI

- New model: `WalletSyncProgress` — `enum { case indeterminate; case scanning(fraction: Double) }` (fraction in `0...1`). Lives with the other sync-status models under `Features/Accounts/Models/` or `Features/Sync/`.
- `SyncedAccountStore` gains `progressPerAccount: [UUID: WalletSyncProgress]` (`@Observable`, `@MainActor`), set alongside `inProgressAccountIds`. Cleared/reset on completion or error.
- The coordinator reports `fraction = (pos − from) / (head − from)` where `pos` is the **min** of the two passes' current positions (honest display; may update **per chunk** for a smooth bar, independent of the coarser per-window checkpoint cadence). Reported to the store on the main actor.
- `SyncedAccountHeaderView` (currently the indeterminate `ProgressView` at ~line 343): render `ProgressView(value:)` (determinate) when `progressPerAccount[account.id]` is `.scanning(fraction)`, else the existing indeterminate spinner.
- Cases that stay indeterminate/none: the Alchemy path; the "already caught up / nothing to scan" case (`from > head`); any account before its head is known.
- `AggregatedSyncStatus` (`.syncing(done:total:)` over account counts) is **unchanged** — it is a separate, account-level aggregate.

### 4. Seam changes (`ChainDataClient`)

The segmentation and progress logic lives in a **coordinator above the client**, preserving the existing build-pure / apply-is-sole-writer separation. The client keeps only the windowed scan and head lookup. Required seam additions:

- **Head / capability probe** on `ChainDataClient`: `func currentHead(chain: ChainConfig) async throws -> UInt64?` — direct returns `eth_blockNumber`; Alchemy returns `nil` (→ coordinator falls back to the existing single-shot path). Non-nil is the signal to use the windowed path.
- **Windowed fetch:** `getAssetTransfers` gains an optional upper bound — `getAssetTransfers(chain:walletAddress:fromBlock:toBlock:)` where `toBlock: UInt64?` (nil = latest/head, back-compat). Direct honours `toBlock`; Alchemy ignores it (always `"latest"`).
- `RoutingChainDataClient` forwards both new methods to the per-chain resolved client. `RPCEndpointResolver` is untouched; the coordinator branches on `currentHead != nil`, not on routing internals.

### 5. Testing

Unit tests with a fake `ChainDataClient` (scripted head + per-window transfer fixtures), in-process, no real network, zone-invariant:

- **Empty windows advance the checkpoint** — scan a range with no transfers; assert `last_synced_block_number` advances to `head`, and a second sync starts from `head − 32`, not the original `from`.
- **Interruption resumes mid-scan** — simulate an interruption after window N (e.g. fake throws on window N+1); assert the next sync resumes from window N's end (minus reorg window), not from the original `from`, and that windows ≤ N are not re-fetched beyond the reorg margin.
- **Apply-before-checkpoint ordering** — assert the checkpoint for a window is only observable after that window's transfers are applied (interruption between the two re-applies idempotently, no duplicate transactions, no skipped transactions).
- **Lower-of-two-topics** — a window where one topic pass returns more/later logs than the other still checkpoints only to the window end both covered.
- **Progress fraction** — monotonic non-decreasing, starts near 0, reaches 1.0 at `head`; `.indeterminate` on the Alchemy path and the caught-up case.
- **Alchemy path unchanged** — regression: single checkpoint at end, indeterminate progress, cursor pagination intact.

## Out of scope / non-goals

- Determinate progress on the Alchemy cursor path.
- Cross-device *mid-scan* resume beyond the ~30 s checkpoint cadence (a resuming device re-scans at most ~one window).
- Any change to `AggregatedSyncStatus` semantics.
- Multi-chain-per-account modelling (not how the data is structured).

## Key file references

- Scan loop: `Shared/CryptoImport/DirectRPC/DirectRPCChainClient.swift`, `Shared/CryptoImport/DirectRPC/AdaptiveLogRangeBatcher.swift`
- Build / apply / checkpoint: `Shared/CryptoImport/WalletSyncEngine.swift` (`build`, `resolvePriorBlock`, `subtractingReorgWindow`), `Shared/CryptoImport/WalletApplyEngine.swift` (`updateSyncState`)
- Checkpoint storage: `Backends/GRDB/Repositories/GRDBWalletSyncCheckpointRepository.swift`, `Domain/Repositories/WalletSyncCheckpointRepository.swift`, `Domain/Models/WalletSyncCheckpoint.swift`; local per-device `WalletSyncState` + `GRDBWalletSyncStateRepository`
- Seam + routing: `Shared/CryptoImport/ChainDataClient.swift`, `Shared/CryptoImport/DirectRPC/RoutingChainDataClient.swift`, `Shared/CryptoImport/DirectRPC/RPCEndpointResolver.swift`
- Orchestration + UI: `Features/Sync/SyncedAccountStore.swift`, `Features/Sync/SyncedAccountHeaderView.swift`, `Features/Accounts/Models/AggregatedSyncStatus.swift`, `Features/Accounts/Models/AccountSyncStatus.swift`
