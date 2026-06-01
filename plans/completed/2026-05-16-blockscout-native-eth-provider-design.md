# Blockscout Native-ETH Provider — Design

**Date:** 2026-05-16
**Issues:** Fixes [#918](https://github.com/ajsutton/moolah-native/issues/918) (contract-internal ETH transfers invisible on OP-stack) and [#919](https://github.com/ajsutton/moolah-native/issues/919) (gas leg dropped for zero-movement signed txs). Composes with in-flight [#921](https://github.com/ajsutton/moolah-native/pull/921) (OP-stack L1 data fee on the receipt-based gas path).

## Problem

The native-ETH balance is reconstructed by summing transaction legs derived from Alchemy `alchemy_getAssetTransfers`, which is a **value-transfer index keyed by Transfer events**, not a transaction index. Two structural gaps follow:

- **#919** — A `:gas` leg is only built for a hash that produced at least one transfer row (`TransferReceiptCoalescer.outboundHashes(in:walletAddress:)` derives the receipt-fetch set from the transfer *groups*). ERC-20 `approve()`, failed/reverted txs, and zero-movement contract calls emit no Transfer, so they never enter a group and never get a gas leg even though the wallet signed them and paid gas. Native balance reads **high**.
- **#918** — On OP-stack chains (Optimism, Base) Alchemy does not index the `internal` transfer category, so ETH that arrives via contract-internal sends is completely absent. Native balance reads **low/wrong**.

Both are the same root cause: native-ETH enumeration comes from a source that cannot see the full transaction set. The fix is to source native-ETH data from a real transaction/internal-transfer index.

## Research summary (why Blockscout)

Full research is in the brainstorming transcript; the conclusions that constrain this design:

- **Alchemy alone cannot enumerate signed txs** across Ethereum + Optimism + Base. `getAssetTransfers` is value-based; the Portfolio "Transactions by Wallet" endpoint excludes Optimism and is deprecating; `getTransactionReceipts`-by-block requires an unbounded full-chain scan; Trace API is Ethereum-only; the Debug API (`callTracer`) is Growth/Enterprise tier (paid).
- **Etherscan V2** paywalled Optimism/Base in Nov 2025 (paid — ruled out by the no-paid-providers constraint).
- **Balance-bisection** (binary-search the block range for native-balance changes) provably degenerates to a near-full block scan for any wallet syncing after a gap (native balance is non-monotone) and still falls back to per-block *net* figures — i.e. plug legs, which are explicitly rejected.
- **Blockscout public API** is the only **free, no-API-key** source that returns real per-tx data — every signed tx (incl. failed/zero-value/`approve()`) and contract-internal ETH transfers — across Ethereum, Optimism, and Base, via per-chain public instances with an identical schema.

Accepted dependency risk: Blockscout public instances are a free community service with no SLA and ~5 req/s rate limiting. There is no free alternative; the alternative is leaving #918/#919 unfixed on OP-stack.

## Decisions (locked with product owner)

1. **Integration shape** — Blockscout normalizes into the existing `AlchemyTransfer`-shaped pipeline; Alchemy is retained for ERC-20 transfers, token discovery/metadata, and `eth_getTransactionReceipt` (gas amount, including #921's L1-fee logic). Everything downstream — `TransferEventBuilder` legs, cross-account merge, dedup, leg-sum balance — is reused unchanged.
2. **Source split** — Alchemy `getAssetTransfers` results are **filtered to `.erc20` only** in the engine. Blockscout is the sole source of native (`.external`) and internal (`.internal`) ETH. No double-counting.
3. **Polygon removed** — `.polygon` is deleted from `ChainConfig` entirely in this PR. There is no first-party Blockscout instance for Polygon comparable to eth/optimism/base, and the project is not committing to a paid or third-party Polygon explorer. Existing Polygon crypto accounts fall through the **existing** `ChainConfig.config(for:) == nil → buildOne returns .skipped` path (logged "unknown chainId"); no crash, the account simply stops syncing.
4. **Blockscout-unreachable behaviour** — A Blockscout fetch failure is **a sync error for that account** (no Alchemy-only fallback). It propagates as a `WalletSyncError` out of `WalletSyncEngine.build`, caught by the existing `CryptoSyncStore` `buildOne → persistError` path and surfaced exactly like an Alchemy failure today.
5. **No plug legs** — Every emitted leg is a real transaction, internal transfer, or gas payment with a real amount, date, and counterparty.

## Architecture

### Component overview

```
WalletSyncEngine.build(account:chain:)
├── BlockExplorerClient (NEW)
│   ├── nativeTransactions(chain:walletAddress:fromBlock:)  → [BlockscoutNativeTx]
│   └── internalTransactions(chain:walletAddress:fromBlock:) → [BlockscoutInternalTx]
│        └── BlockscoutTransferAdapter (NEW, pure)
│             ├── native value rows  → [AlchemyTransfer category:.external]
│             ├── internal ETH rows  → [AlchemyTransfer category:.internal]
│             └── signed-tx set      → [SignedGasTx(hash, blockTimestamp)]
├── AlchemyClient.getAssetTransfers(...)  → filter to .erc20 only
│
└── TransferEventBuilder.build(transfers: native⊕erc20,
                               signedGasTxs:,            (NEW param)
                               account:, services:, importOrigin:)
        ├── existing per-group path → transfer legs + gas leg (unchanged)
        └── gas-only path (NEW) → BuiltTransaction with only a gas leg
              for each signed hash with no transfer group
```

### 1. `BlockExplorerClient` protocol + `LiveBlockscoutClient`

New file(s) under `Shared/CryptoImport/`. Mirrors the `AlchemyClient` shape and invariants exactly so it is a familiar, reviewable seam:

- `Sendable` protocol; `LiveBlockscoutClient` is a `Sendable` struct with no mutable state.
- Per-request URL built from `chain.blockscoutAPIBaseURL`; **no API key**.
- Shared `RateLimiter` actor sized for the public instance (`permitsPerSecond: 5`), separate from Alchemy's 25.
- `os_signpost` `.begin`/`.end` around each method under `Signposts.cryptoSync`, chain id `.public`, address `.private`.
- Error containment identical to `LiveAlchemyClient`: network failure → `WalletSyncError.network`; non-2xx → `AlchemyResponseValidator`-equivalent validation → typed errors; malformed JSON → `WalletSyncError.providerMalformedResponse(stage:)`; `URLError.cancelled` / cooperative cancellation re-thrown as `CancellationError`.

Methods:

- `func nativeTransactions(chain:walletAddress:fromBlock:) async throws -> [BlockscoutNativeTx]`
  - `GET {base}/api/v2/addresses/{address}/transactions`
  - Paginated via Blockscout's `next_page_params` (cursor object echoed back as query params). Results are newest-first; stop paginating once a page's entries are all `block_number < fromBlock`.
- `func internalTransactions(chain:walletAddress:fromBlock:) async throws -> [BlockscoutInternalTx]`
  - `GET {base}/api/v2/addresses/{address}/internal-transactions`
  - Same pagination / early-stop rule.

Wire structs (`Decodable`, file-scope `CodingKeys` per project idiom):

- `BlockscoutNativeTx` — `hash`, `blockNumber`, `timestamp` (ISO-8601), `from` (address), `to` (address?, `nil` for contract-creation), `value` (wei, decimal string), `status`/`result` (success vs `error`/reverted), and any gas fields present (not relied on for the amount — gas amount still comes from the Alchemy receipt; see §4).
- `BlockscoutInternalTx` — parent `transactionHash`, `blockNumber`, `timestamp`, `from`, `to`, `value` (wei), `index` (Blockscout's stable per-parent ordinal — required for a deterministic `externalId`), `success`.

Decode policy is **lenient per row**: a row that fails to decode is logged (`.notice`) and skipped, matching `TransferEventBuilder`'s per-row policy, so one malformed row never fails the account.

### 2. `ChainConfig` changes

- Add `blockscoutAPIBaseURL: URL` to `ChainConfig` (non-optional — every supported chain has one):
  - Ethereum (1): `https://eth.blockscout.com`
  - Optimism (10): `https://optimism.blockscout.com`
  - Base (8453): `https://base.blockscout.com`
- **Remove** the `.polygon` static and its entry in `ChainConfig.all`. Update `ChainConfig.all` to `[.ethereum, .optimism, .base]`.
- The exact public host strings are pinned by a `ChainConfigTests` invariant (alongside the existing per-chain invariants, e.g. #921's `chargesL1DataFee`). The plan must also update / remove any `.polygon`-referencing fixtures, seeds, and the per-chain invariant test rows.

### 3. `BlockscoutTransferAdapter`

New pure, `Sendable`, fully unit-tested type under `Shared/CryptoImport/`. Input: `[BlockscoutNativeTx]`, `[BlockscoutInternalTx]`, lowercased `walletAddress`, `ChainConfig`. Output: `BlockscoutAdaptResult { transfers: [AlchemyTransfer]; signedGasTxs: [SignedGasTx] }`.

Mapping rules:

- **Native value tx** where the wallet is `from` or `to` and `value != 0` → one `AlchemyTransfer`:
  - `category: .external`, `hash`, `uniqueId = "<hash>:external:0"` (Alchemy's exact `<hash>:<category>:<index>` format so cross-account merge / dedup / `externalId` logic is unchanged),
  - `from`, `to`, `rawContract(address: nil, decimal: nil, rawValue: "0x" + hex(weiValue))` — native ⇒ builder substitutes `chain.nativeInstrument.decimals`,
  - `metadata.blockTimestamp = ISO-8601(timestamp)`, `blockNum = "0x" + hex(blockNumber)` (so `WalletSyncEngine.maxBlockNumber` head-block math is reused unchanged).
- **Internal ETH tx** where the wallet is `from` or `to` and `value != 0` → one `AlchemyTransfer`:
  - `category: .internal`, `hash = parent transactionHash`, `uniqueId = "<parentHash>:internal:<index>"` using Blockscout's `index` (deterministic across re-syncs ⇒ idempotent on the partial unique index when one parent tx has multiple internal moves).
  - Other fields analogous to the native mapping.
- **Signed-tx set** — every `BlockscoutNativeTx` with `from == walletAddress` (regardless of value, status, or whether it produced a transfer row) contributes `SignedGasTx(hash, blockTimestamp)`. This is the authoritative gas-paying set and is what fixes #919: `approve()`, failed, and zero-movement txs are all `from == wallet` here even though they emit no transfer row.
- Zero-value / failed signed txs produce **no** transfer row (so no spurious 0-ETH leg) — they exist only in `signedGasTxs`.
- Address comparisons lowercase both sides (Blockscout returns checksummed addresses; the builder already lowercases `walletAddress`).

### 4. `TransferEventBuilder` / `TransferReceiptCoalescer` change (#919)

`TransferEventBuilder.build(...)` gains a `signedGasTxs: [SignedGasTx]` parameter (threaded from the engine).

- **Receipt-fetch set** = `outboundHashes(in: groups, walletAddress:)` ∪ `signedGasTxs.map(\.hash)`. The Blockscout signed set is authoritative for "wallet paid gas"; the existing `outboundHashes` heuristic is retained as belt-and-braces for any signed hash outside Blockscout's pagination window that a transfer still surfaced. The union is deduplicated; `fetchReceipts` is otherwise unchanged.
- **Gas-only path** — partition: `groupedHashes` = hashes that have a transfer group; `gasOnlyHashes` = `signedGasTxs` hashes − `groupedHashes`. The existing per-group loop handles grouped hashes unchanged (including its existing single gas-leg append, so **no duplicate gas leg**). A new loop iterates `gasOnlyHashes`: for each, if a receipt is present and `makeGasLeg` returns a leg, emit a `BuiltTransaction` whose **only** leg is that gas leg, dated to the `SignedGasTx.blockTimestamp` (the gas-only hash has no transfer metadata to fall back on; the timestamp comes from Blockscout via `signedGasTxs`).
- `makeGasLeg` and the `receipt.from == walletAddress` guard are **reused verbatim** — Blockscout's `from == wallet` filter guarantees `receipt.from == wallet`, so the guard holds and #921's L1-fee summation (gated by `chargesL1DataFee`) is included with zero changes to the gas-amount computation. This design is layered strictly on top of #921; it must not modify `makeGasLeg`'s fee math.

### 5. `WalletSyncEngine.build` wiring

Inject `blockExplorer: any BlockExplorerClient` alongside `alchemy`. Revised flow:

1. Validate account (unchanged). Compute `fromBlock` with the existing 32-block reorg margin (unchanged).
2. `blockExplorer.nativeTransactions(...)` and `blockExplorer.internalTransactions(...)` → `BlockscoutTransferAdapter.adapt(...)` → native/internal `[AlchemyTransfer]` + `[SignedGasTx]`. Any failure here throws `WalletSyncError` and propagates (decision 4 — sync error for the account, no fallback).
3. `alchemy.getAssetTransfers(...)`, then **filter to `category == .erc20`** (decision 2). (ERC-20-only request optimisation — adding a category parameter to the `AlchemyClient` protocol — is explicitly out of scope; filtering in the engine avoids churning every test stub.)
4. Merge native/internal (Blockscout) ⊕ erc20 (Alchemy) into one `[AlchemyTransfer]`. Head block = `maxBlockNumber` over the merged set (Blockscout `blockNum` participates via the existing parser).
5. `TransferEventBuilder.build(transfers:merged, signedGasTxs:, account:, services:, importOrigin:)`.
6. The existing "builder dropped all transfers" wire-regression warning still applies to the merged set.

`BuilderServices` keeps `alchemy` (the builder still uses the Alchemy receipt fetch for gas). `signedGasTxs` is passed as an explicit `build(...)` argument, not through `BuilderServices`, because it is per-account data, not a service.

### 6. App wiring (`ProfileSession+CryptoSync.swift`)

Construct `LiveBlockscoutClient(rateLimiter: RateLimiter(permitsPerSecond: 5))` and inject it into `WalletSyncEngine`. No keychain/API-key plumbing (public service). `CryptoSyncStore` / `buildOne` are unchanged — they already map a thrown `WalletSyncError` to `persistError` (decision 4 needs no new code there).

### 7. Idempotency, dedup, merge, reorg

- Reuses the existing `(account_id, external_id)` partial unique index. `externalId`s: native `<hash>:external:0`, internal `<hash>:internal:<index>`, gas `<hash>:gas` (`gasLegExternalId` unchanged). Re-syncs dedup via the existing `legExists` path with no change.
- Cross-account transfer merge is unaffected — Blockscout-originated rows carry Alchemy-format `uniqueId`s, so opposite-sign / same-`externalId` pairing across accounts works identically. Gas legs remain unmerged as today.
- The 32-block reorg margin is applied by the engine (unchanged); Blockscout pagination early-stops at `block_number < fromBlock`.

## Testing

Following `guides/TEST_GUIDE.md` (Swift Testing; one-extension-per-protocol; TDD — tests before implementation):

- **`RecordingBlockExplorerClientStub`** test double mirroring `RecordingAlchemyClientStub` (scriptable per-method responses; recorded calls for assertions; conforming via a dedicated extension).
- **Wire-format decoding tests** with captured fixtures: a native value tx, a contract-internal ETH credit, an ERC-20 `approve()` (zero-value) tx, a failed/reverted tx, a multi-page `next_page_params` response, a malformed row (logged + skipped).
- **Adapter tests**: native/internal → expected `AlchemyTransfer`s (sign, counterparty, `uniqueId`, `blockNum`, timestamp); OP-stack internal credit surfaces (#918); `approve()`/failed → present in `signedGasTxs`, absent from `transfers` (#919); multiple internal moves in one parent → distinct `:internal:<index>` ids; checksummed-address matching.
- **Builder tests**: gas-only hash → `BuiltTransaction` with exactly one gas leg, dated to the signed-tx timestamp, with #921's L1 fee included on OP-stack and excluded on L1; receipt-set union (`outboundHashes` ∪ signed); no duplicate gas leg when a hash has both transfers and is in the signed set; gas-only hash whose receipt fails → no transaction (existing per-hash containment), account not failed.
- **Engine tests**: Alchemy result filtered to `.erc20` only (native/internal from Blockscout, no double-count); Blockscout failure → `WalletSyncError` propagates (no fallback) and `buildOne` persists an error row; head-block math over merged Blockscout + Alchemy set.
- **`ChainConfig` tests**: `.polygon` removed from `all`; `blockscoutAPIBaseURL` invariant per remaining chain; `config(for: 137) == nil`.
- **Live Blockscout client tests** (opt-in / network-gated, mirroring the `LiveAlchemyClient*Tests` pattern): real public endpoints decode into the wire structs for each chain.
- **Store / contract level**: a fixture account with an OP-stack internal credit and an `approve()` tx yields a native balance equal to the expected real total (closes #918 + #919 end-to-end), asserted against `TestBackend`.

## Out of scope

- #920 (OP-stack L1 data fee) — handled by in-flight #921 via the Alchemy receipt path, reused unchanged here.
- ERC-20 sourcing from Blockscout — Alchemy retains ERC-20 transfers + token discovery/metadata.
- An `erc20`-only request parameter on `AlchemyClient` — filtered in the engine instead to avoid churning every stub.
- Historical-balance backfill correctness beyond what real per-tx legs provide; no reconciliation/plug leg is introduced.
- A migration/notice for existing Polygon accounts — they degrade to the existing "unknown chainId → skipped" behaviour; any richer messaging is a separate concern.

## Risks

- **Blockscout availability / rate limits.** No SLA; ~5 req/s. Mitigation: per-account error containment (decision 4) means an outage degrades to a normal, retried sync error rather than data loss or a crash. The 5 req/s limiter plus block-windowed pagination keeps a normal incremental sync within budget; a first full backfill of a very active wallet is the heaviest case and is bounded by `fromBlock`.
- **Blockscout schema drift.** Mitigated by lenient per-row decode + opt-in live tests that exercise the real endpoints.
- **#921 interaction.** This design is strictly additive on top of #921's `makeGasLeg`. If #921's API (e.g. the `l2ExecutionFeeWei` rename) is still in flight at implementation time, the plan rebases onto #921's merged form and must not re-implement L1-fee math.
