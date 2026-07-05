# Direct JSON-RPC ERC-20 discovery (with WETH wrap/unwrap and cross-device checkpoint)

**Status:** Design approved, pending spec review
**Date:** 2026-07-05
**Area:** `Shared/CryptoImport/`

## Problem

On-chain transfer discovery for synced wallets currently depends on Alchemy's
`alchemy_getAssetTransfers` (`erc20` category) for all ERC-20 movements. Two
problems with that:

1. **Rate limiting.** Alchemy's free tier rate-limits on *global* traffic, not
   our own usage, so syncs freeze on 429s that are invisible on our dashboard
   (see the "Crypto sync Alchemy throttle" investigation). The only real cure
   today is paying for a plan.
2. **Wrap/unwrap is invisible.** `alchemy_getAssetTransfers`'s `erc20` category
   is an index over ERC-20 `Transfer` event logs. Canonical WETH9 `deposit()`
   and `withdraw()` deliberately emit `Deposit`/`Withdrawal` events — **not**
   `Transfer` — so wrapping and unwrapping WETH never appears as a token
   movement. The ETH side is caught by Blockscout, but the WETH side is lost.

Querying a chain's JSON-RPC endpoint directly (`eth_getLogs` over the `Transfer`
topic) removes the Alchemy dependency and is more reliable; combined with reading
the `Deposit`/`Withdrawal` logs from receipts we already fetch, it also closes
the wrap/unwrap gap.

## Non-goals

- **Native / internal ETH stays on Blockscout.** Blockscout is indexed by
  transaction, so it surfaces zero-value / `approve()` / failed txs (#919) and
  OP-stack internal ETH credits (#918) that a log index misses. The direct-RPC
  work replaces only Alchemy's ERC-20 role; the Blockscout path is untouched.
- **No NFT (erc721/erc1155) discovery** — same as today.
- **Polygon** remains unsupported (no first-party Blockscout).

## Current architecture (baseline)

All discovery lives in `Shared/CryptoImport/`. Per-account, read-only:

- `WalletSyncEngine.build(account:chain:)` fetches Blockscout (native +
  internal ETH) and Alchemy (ERC-20), merges into the common `AlchemyTransfer`
  model, then `TransferEventBuilder` groups transfers by tx hash and builds one
  multi-leg `Transaction` per hash (income/expense/trade legs, swap retyping via
  `IntraAccountSwapDetector`, plus a native-token gas leg per outbound `external`
  tx from `eth_getTransactionReceipt`).
- `WalletApplyEngine.apply(...)` (single `@MainActor` writer) does cross-account
  merge → `externalId`-keyed dedup → persist → sync-state update.

Key seams the design relies on:

- **`AlchemyTransfer`** (`AlchemyTransfer.swift`) is the canonical internal model
  for *both* Alchemy and adapted-Blockscout rows. Fields: `hash`, `uniqueId`
  (`<hash>:<category>:<index>` — the `externalId` key), `from`, `to`, `category`
  (`external | internal | erc20 | unknown`), `asset`, `rawContract`
  (`address`, `decimal`, `rawValue`), `metadata.blockTimestamp`, `blockNum`.
- **`externalId` dedup** is the idempotency guarantee (survives the 32-block
  reorg-window re-fetch and cross-device overlap via `CrossDeviceLegDeduper`).
- `fromBlock` for a brand-new wallet is `0` (full genesis scan); on subsequent
  syncs it is `lastSyncedBlockNumber − 32` (reorg window). The checkpoint is
  written in `WalletApplyEngine.updateSyncState` from the highest block seen.
- **A new discovery source only needs to emit `AlchemyTransfer` rows with
  deterministic `uniqueId`s** and merge into the transfer list; the builder,
  dedup, and apply stages then handle it unchanged.

## Design

### 1. Provider seam: `ERC20TransferSource`

Extract the ERC-20 fetch from `WalletSyncEngine` behind a protocol:

```swift
protocol ERC20TransferSource: Sendable {
    func fetchERC20Transfers(
        chain: ChainConfig,
        walletAddress: String,
        fromBlock: UInt64
    ) async throws -> [AlchemyTransfer]
}
```

Two implementations, both emitting the existing `AlchemyTransfer` model:

- **`AlchemyERC20Source`** — thin wrapper over today's `LiveAlchemyClient`
  (`alchemy_getAssetTransfers`, `erc20` category).
- **`DirectRPCERC20Source`** — new; `eth_getLogs`-based (§3).

`WalletSyncEngine.build()` calls the injected `ERC20TransferSource` instead of
Alchemy directly; the merge point (`transfers = blockscout + erc20Source rows`)
is otherwise unchanged.

### 2. New `LiveJSONRPCClient`

A `Sendable` struct over `URLSession`, generalizing the JSON-RPC envelope already
in `AlchemyJSONRPCWireFormat.swift`. Standard methods only:

- `eth_chainId` (endpoint probe / chain identification — §6)
- `eth_blockNumber` (head)
- `eth_getLogs`
- `eth_getBlockByNumber` (timestamps — §4)
- `eth_call` (token metadata — §4)
- `eth_getTransactionReceipt` (gas legs + wrap/unwrap logs — §5)

Supports **batch** JSON-RPC (array of requests) for block-timestamp and
metadata lookups. The endpoint URL is injected per chain (§6). Receipts are
endpoint-agnostic, so this client is also used for gas legs in Alchemy mode
(Alchemy exposes standard `eth_` methods).

### 3. ERC-20 `Transfer` discovery via `eth_getLogs`

Per adaptive block-chunk `[from, to]` (§7), two `eth_getLogs` passes, **no
`address` filter** so all token contracts return at once:

- **Outbound:** `topics = [Transfer, pad32(wallet), null]`
- **Inbound:** `topics = [Transfer, null, pad32(wallet)]`

`Transfer(address indexed from, address indexed to, uint256 value)` →
`topic0 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef`.

Each returned log maps to an `AlchemyTransfer`:

- `hash` = `transactionHash`, `blockNum` = log `blockNumber`
- `from` = topic1, `to` = topic2, `rawContract.address` = log `address`
- `rawContract.rawValue` = log `data` (uint256)
- `category = .erc20`, `uniqueId = <hash>:erc20:<logIndex>`
- `asset` / `rawContract.decimal` resolved in §4

This is the **only** use of `eth_getLogs`. Wrap/unwrap (§5) does not scan logs.

### 4. Filling in what raw logs omit

- **Timestamps.** Logs carry only `blockNumber`. Collect the unique block numbers
  in a chunk and **batch `eth_getBlockByNumber(block, false)`**, then synthesize
  `metadata.blockTimestamp` (ISO-8601) from the block's `timestamp`.
- **Decimals / symbol.** Logs carry only contract + raw value. Resolve via
  **batched `eth_call`** to `decimals()` / `symbol()` (and `name()` if useful),
  reusing / extending the existing token-metadata layer
  (`CryptoTokenDiscoveryService` / `CanonicalTokenRegistry`) as the cache so we
  don't re-query known tokens. `decimals` is required to interpret value; `symbol`
  is best-effort (matches Alchemy behaviour today).

### 5. WETH wrap/unwrap from ETH-movement receipts (no log scan)

Wrap/unwrap is definitionally an ETH movement to/from a WETH contract (1:1), and
we already know every tx where the wallet's ETH moved (Blockscout native +
internal). So we derive the WETH leg from receipts of those specific txs rather
than scanning `Deposit`/`Withdrawal` logs across history.

Wrapped-native contract set: reuse `Domain/Models/WrappedNativeContracts.swift`
(keyed by `(chainId, lowercased address)`).

- **Wrap** (ETH out): a Blockscout native tx whose `to` ∈ wrapped-native
  contracts. Its receipt is **already fetched for the gas leg**, so the
  `Deposit(address indexed dst = wallet, uint wad)` log is read for **zero extra
  requests**. `Deposit` →
  `topic0 = 0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c`.
- **Unwrap** (ETH in): a Blockscout **internal** tx whose `from` ∈ wrapped-native
  contracts. Fetch just those receipts (small, filtered set) and read
  `Withdrawal(address indexed src = wallet, uint wad)`. `Withdrawal` →
  `topic0 = 0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65`.

Each wrap/unwrap log is synthesized as an ordinary `.erc20` `AlchemyTransfer`
(contract = WETH, 18 decimals, `to`/`from` = wallet, `wad` as value,
`uniqueId = <hash>:erc20:<logIndex>`). Because the matching ETH leg of the same
tx already exists (from Blockscout under the same hash), `TransferEventBuilder` +
`IntraAccountSwapDetector` **pair them into an ETH↔WETH trade automatically** —
wrap = ETH-out + WETH-in, unwrap = WETH-out + ETH-in. No builder changes.

**Endpoint-agnostic.** Because it depends only on `eth_getTransactionReceipt`
(standard), this detector runs in **both** Alchemy mode and direct-RPC mode — so
Alchemy users get the wrap/unwrap fix too, at near-zero cost.

**Double-count guard.** Canonical WETH9 `deposit`/`withdraw` emit no `Transfer`,
so there is no overlap. For non-canonical wrapped tokens that mint/burn via a
zero-address `Transfer` *and* a `Deposit`/`Withdrawal`, drop the zero-address
`Transfer` on wrapped-native contracts and keep the Deposit/Withdrawal leg.

### 6. Endpoint configuration and provider precedence

The user supplies a **flat list of JSON-RPC endpoint URLs** in Settings — they do
*not* label which chain each is for. The app **probes each with `eth_chainId`**
and maps the result to a `ChainConfig` in `ChainConfig.all` by `chainId`.

**Per-chain endpoint resolution (in order):**

1. **Custom endpoint** whose probed `chainId` matches the chain (first match in
   the user's list order = preference).
2. **Alchemy** — if a key is present and no custom endpoint covers that chain.
3. **publicnode** default — `ChainConfig` gains a `defaultRPCURL`
   (`ethereum-rpc.publicnode.com`, `optimism-rpc.publicnode.com`,
   `base-rpc.publicnode.com`).

When Alchemy is *not* selected for a chain, ERC-20 discovery uses
`DirectRPCERC20Source` against the resolved endpoint. Gas legs and wrap/unwrap
receipts always route to the resolved endpoint for that chain.

**Settings UI.** A list editor for endpoint URLs. For each entry, a live probe
(`eth_chainId`, plus `eth_blockNumber` for liveness) displays:

- reachable ✓ / ✗ (with error reason on failure), and
- resolved chain — "Ethereum" / "Optimism" / "Base" matched by `chainId`, or
  **"Unknown chain (id N)"** if the id is unrecognised (endpoint accepted but not
  used for any supported chain).

### 7. Adaptive block-range batching (Teku-modelled)

Public endpoints cap `eth_getLogs` by block range (commonly 5k–10k) *or* result
count, and failures are not reported uniformly — an over-large range may surface
as an explicit limit message, an arbitrary JSON-RPC error code, or a plain
**timeout**. The batcher therefore treats **any `eth_getLogs` failure** —
explicit limit, unknown error, or timeout — as "range too large":

- Start from a configurable max range (default **10,000** blocks, matching Teku).
- On failure: **halve** the range and retry the sub-range, down to a floor
  (e.g. 1 block); genuine per-request errors below the floor propagate.
- On sustained success: **grow** the range back toward the max.
- Its own `RateLimiter` + `withRetry` / `HTTPRetryPolicy` (as Blockscout uses),
  honouring 429 / `Retry-After`.

Reference: ConsenSys **Teku**'s `powchain` deposit-log fetching (battle-tested
adaptive range + throttling). The implementer should read the current Teku
`powchain` classes (deposit fetcher / block-range batching / throttling
provider) for the exact shrink/grow algorithm and error handling, and the
[deposit-processing post-incident review](https://github.com/ConsenSys/teku/wiki/Post-Incident-Review---Deposit-Processing-Performance).

Full genesis scan is retained (per decision): a brand-new wallet scans
`[0, head]` in adaptive chunks. Note the UX cost on OP-stack chains (2s blocks →
100M+ blocks) against a rate-limited public endpoint — a first sync can take
minutes. This is one-time per wallet and mitigated by the cross-device
checkpoint (§8).

### 8. Cross-device synced checkpoint

Today `WalletSyncState.lastSyncedBlockNumber` is deliberately **per-device and
un-synced** — a fresh/restored device re-fetches from genesis. That causes an
infrequently-used device (e.g. a phone) to redo a full genesis scan. This design
reverses that:

- Add a **CloudKit-synced checkpoint** per account: the highest synced block.
- **Merge by `max`** across devices — safe because leg dedup is `externalId`-keyed
  (`CrossDeviceLegDeduper`), so any overlap dedups.
- `fromBlock = max(localCheckpoint, syncedCheckpoint) − 32` (keep the reorg
  window as the safety margin).
- Device-local fields (`lastSyncedAt`, `lastError`) stay local; only the block
  number syncs.
- **Eventual-consistency caveat (documented behaviour):** if the synced
  checkpoint arrives before the *transactions* it represents (CloudKit lag), a
  device briefly skips ahead of data it hasn't received — but those transactions
  arrive via normal CloudKit sync and dedup, so the state converges.

This is a CloudKit schema change and routes through the `modifying-cloudkit-schema`
skill and the `sync-review` gate.

## Data flow (direct-RPC mode, one account)

1. `WalletSyncEngine.build`: compute `fromBlock` from
   `max(local, syncedCheckpoint) − 32` (§8).
2. Blockscout: native + internal ETH (unchanged) → `AlchemyTransfer` rows +
   `signedGasTxs`.
3. `DirectRPCERC20Source.fetchERC20Transfers`: adaptive-chunk `eth_getLogs`
   Transfer passes (§3) → ERC-20 `AlchemyTransfer` rows; batch
   `eth_getBlockByNumber` (timestamps) + `eth_call` (metadata) (§4).
4. Wrap/unwrap detector (§5): from Blockscout ETH movements touching
   wrapped-native contracts, read `Deposit`/`Withdrawal` from receipts →
   synthesized WETH `AlchemyTransfer` rows.
5. Merge all rows; `TransferEventBuilder` builds multi-leg transactions
   (gas legs from receipts; wrap/unwrap pair into ETH↔WETH trades) — unchanged.
6. `WalletApplyEngine.apply`: cross-account merge → dedup → persist → update
   local + synced checkpoint (§8) — unchanged except the synced-checkpoint write.

## Error handling

- `eth_getLogs`: any failure → adaptive shrink (§7). 429 / `Retry-After` honoured
  in-place within budget; exhausted budget → `WalletSyncError.rateLimited` up to
  the orchestrator (per-account `lastError`, matching today).
- `eth_chainId` probe failure in Settings → endpoint shown ✗ with reason; not used
  for resolution.
- Missing/failed `decimals()` `eth_call` → skip that token's rows with a logged
  warning (can't interpret value without decimals) rather than guessing.
- Unrecognised chainId from a custom endpoint → surfaced as "Unknown chain",
  excluded from resolution.

## Testing

- **`LiveJSONRPCClient`**: protocol-level fake returning canned log / block /
  receipt / `eth_chainId` / `eth_call` fixtures.
- **ERC-20 discovery**: from/to log passes produce `AlchemyTransfer` rows with
  correct contract/value/decimals and stable `uniqueId`s; dedups idempotently
  across the 32-block reorg re-fetch.
- **Wrap**: a native-out-to-WETH fixture + its receipt `Deposit` log → an
  ETH↔WETH trade; **unwrap**: internal-in-from-WETH + receipt `Withdrawal` →
  the reverse; verified in both Alchemy and direct modes.
- **Double-count guard**: non-canonical wrapped token emitting both mint
  `Transfer` and `Deposit` yields exactly one WETH leg.
- **Adaptive batcher**: a simulated range-cap error and a simulated timeout each
  trigger range-halving and complete; range grows back on success.
- **Endpoint resolution**: precedence (custom → Alchemy → publicnode);
  `eth_chainId` mapping to chain name / "Unknown chain".
- **Cross-device checkpoint**: `max`-merge; a synced checkpoint ahead of local
  advances `fromBlock`; leg dedup covers the overlap.

## Suggested increments (for the implementation plan)

1. `LiveJSONRPCClient` + envelope generalization + `eth_chainId`/`eth_blockNumber`
   /`eth_getBlockByNumber`/`eth_call` (with fakes and tests).
2. `ERC20TransferSource` seam + `AlchemyERC20Source` (pure refactor, no behaviour
   change; Alchemy still the source).
3. `DirectRPCERC20Source`: `eth_getLogs` Transfer passes + timestamp/metadata
   fill-in + adaptive batcher (Teku-modelled).
4. Wrap/unwrap receipt detector (lands the fix in both modes).
5. Endpoint configuration + provider precedence + Settings UI with live probe.
6. Cross-device synced checkpoint (CloudKit schema + `sync-review`).

Each increment is independently shippable behind the existing wiring; step 2 is a
no-op refactor, and the direct source (steps 3–5) only activates when a chain
resolves to a non-Alchemy endpoint.

## Open questions

None outstanding. Decisions captured: full pluggable replacement (both providers
kept); full genesis scan; wrap/unwrap via ETH-movement receipts; custom →
Alchemy → publicnode precedence; auto chain detection via `eth_chainId`;
cross-device synced checkpoint.
