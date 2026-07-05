# Direct JSON-RPC ERC-20 Discovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pluggable on-chain discovery source that queries a chain's JSON-RPC
endpoint directly (`eth_getLogs`) as an alternative to Alchemy, closes the WETH
wrap/unwrap gap via transaction-receipt logs, and syncs the per-account block
checkpoint across devices.

**Architecture:** Six stacked PRs. PR 1 builds a standalone `LiveJSONRPCClient`
(standard `eth_*` methods, batch-capable). PR 2 renames the `AlchemyClient`
protocol to a provider-neutral `ChainDataClient` seam (no behaviour change). PR 3
adds `DirectRPCChainClient` — `eth_getLogs` ERC-20 discovery with Teku-modelled
adaptive block-range batching and timestamp/metadata back-fill. PR 4 closes the
wrap/unwrap gap by extending the receipt model with logs and adding a
`WrapUnwrapDetector` that runs in **both** provider modes. PR 5 adds the endpoint
list Settings UI, `eth_chainId` auto-detection, and `RoutingChainDataClient`
precedence (custom → Alchemy → publicnode) that finally activates the direct path.
PR 6 makes the block checkpoint CloudKit-synced to stop idle devices re-scanning
from genesis.

**Tech Stack:** Swift, SwiftUI, GRDB (SQLite), CloudKit (CKSyncEngine), Swift
Testing, URLSession/JSON-RPC.

## Global Constraints

- **Design spec:** `plans/2026-07-05-direct-rpc-erc20-discovery-design.md` — authoritative.
- **Worktree:** all work in the `direct-rpc-erc20-discovery` worktree; never edit `main`.
- **Build:** `just build-mac` must pass after each task.
- **Format:** `just format-check` must pass before every commit (`just format` to
  fix). SwiftLint uses the CI-pinned binary (0.63.3) — verify with it, not PATH.
- **Tests:** Swift Testing (`@Test`/`@Suite`), **not** XCTest. Run relevant suites
  with `just test-mac` (long runs stay in the controller, never delegated).
- **AI review gate:** run the routed reviewer(s) before each commit; fix every
  finding and re-review until clean. Routing per task below.
- **CloudKit is additive-only:** never remove/rename/retype a `schema.ckdb` field;
  go through `just generate` / `just check-schema-additive`, never `cktool` directly,
  never hand-edit `Generated/` or `schema-prod-baseline.ckdb`. PR 6 adds a record
  type — no field is removed, so there is **no prod-migration gate**.
- **Money/instrument rules:** synthesized transfers carry exact integer-units values
  as 0x-hex strings (never IEEE-754); never `abs()` a leg or auto-sign by position.
- **The canonical internal model stays `AlchemyTransfer`** (`Shared/CryptoImport/AlchemyTransfer.swift`)
  even for non-Alchemy rows — do not rename it (too invasive). New sources emit
  `AlchemyTransfer` rows with `uniqueId = "<hash>:<category>:<index>"`.
- **Chains:** `ChainConfig.all = [ethereum(1), optimism(10), base(8453)]`.

### Well-known ABI constants (used across PRs 3–4)

Copy these verbatim where referenced:

```swift
// keccak256 event topic0 hashes
let transferTopic   = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" // Transfer(address,address,uint256)
let depositTopic    = "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c" // Deposit(address,uint256)  (WETH9 deposit)
let withdrawalTopic = "0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65" // Withdrawal(address,uint256) (WETH9 withdraw)
// eth_call 4-byte selectors
let decimalsSelector = "0x313ce567" // decimals()
let symbolSelector   = "0x95d89b41" // symbol()
// publicnode defaults
// eth:  https://ethereum-rpc.publicnode.com
// op:   https://optimism-rpc.publicnode.com
// base: https://base-rpc.publicnode.com
```

Address→topic padding: a 20-byte address becomes a 32-byte topic = `"0x"` + 24
zero hex chars + the 40-char lowercased address body. Topic→address: take the last
40 hex chars, prefix `"0x"`, lowercase.

---

# PR 1 — `LiveJSONRPCClient` foundation

Branch: `direct-rpc-erc20-discovery` (this worktree). A self-contained standard
JSON-RPC client. No integration with the sync engine yet — it is exercised only by
its own tests. Ends green + reviewed.

### Task 1: Generalize the JSON-RPC envelope

**Files:**
- Create: `Shared/CryptoImport/JSONRPC/JSONRPCEnvelope.swift`
- Test: `MoolahTests/Shared/CryptoImport/JSONRPCEnvelopeTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct JSONRPCRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
  }
  struct JSONRPCResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    let id: Int
    let result: Result?
    let error: JSONRPCError?
  }
  struct JSONRPCError: Decodable, Sendable, Equatable { let code: Int; let message: String }
  ```
  A batch is `[JSONRPCRequest<Params>]` encoded as a top-level JSON array and
  `[JSONRPCResponse<Result>]` decoded back; responses are correlated by `id`
  (providers may reorder). Provide `enum JSONRPCTransportError: Error { case batchIdMismatch }`.

- [ ] **Step 1: Write failing tests.** A single request encodes to
  `{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}`; a batch of two
  encodes to a JSON array; a response array with `id`s out of order is re-correlated
  to the request order; a `result: null` + `error` object decodes `error` non-nil.
- [ ] **Step 2: Run, expect FAIL** (`just test-mac` filtered to `JSONRPCEnvelopeTests`) —
  types don't exist.
- [ ] **Step 3: Implement** the envelope types above. Use `Int` ids assigned by the
  caller. Provide a `correlate(requests:responses:)` helper returning results in
  request order or throwing `.batchIdMismatch`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Review** `@code-review` + `@concurrency-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): add generic JSON-RPC request/response envelope`.

### Task 2: Hex + address helpers

**Files:**
- Create: `Shared/CryptoImport/JSONRPC/RPCHex.swift`
- Test: `MoolahTests/Shared/CryptoImport/RPCHexTests.swift`

**Interfaces:**
- Produces `enum RPCHex` with:
  ```swift
  static func hexQuantity(_ v: UInt64) -> String            // 12 -> "0xc"
  static func parseUInt64(_ s: String) -> UInt64?           // reuse the parse rule in WalletSyncEngine.parseHexUInt64
  static func addressTopic(_ address: String) -> String     // 20-byte addr -> 32-byte 0x… topic (lowercased)
  static func addressFromTopic(_ topic: String) -> String   // last 40 hex chars -> "0x…" lowercased
  static func hexData(_ v: UInt64) -> String                // decimals() encoded value, for constructing rawContract.decimal ("0x12" for 18)
  ```
  Note `HexDecimal.parse`/`parseInt` already exist in `AlchemyTransactionReceipt.swift:84-110`
  for `Decimal`/`Int` — reuse them for value/decimals parsing; `RPCHex` only adds the
  quantity/address/topic string forms not already present.

- [ ] **Step 1: Write failing tests** for each conversion incl. round-trips
  (`addressFromTopic(addressTopic(a)) == a.lowercased()`), odd-length hex, `0x0`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement `RPCHex`.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Review** `@code-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): add JSON-RPC hex and address-topic helpers`.

### Task 3: `LiveJSONRPCClient` transport + `eth_chainId` / `eth_blockNumber`

**Files:**
- Create: `Shared/CryptoImport/JSONRPC/LiveJSONRPCClient.swift`
- Test: `MoolahTests/Shared/CryptoImport/LiveJSONRPCClientTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct LiveJSONRPCClient: Sendable {
    init(endpoint: URL, session: URLSession = .shared, rateLimiter: RateLimiter,
         sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) })
    func chainId() async throws -> Int
    func blockNumber() async throws -> UInt64
    // added incrementally in Tasks 4–5:
    // func getLogs(_ filter: RPCLogFilter) async throws -> [RPCLog]
    // func blockTimestamps(_ blocks: [UInt64]) async throws -> [UInt64: Date]
    // func call(to: String, data: String) async throws -> String
    // func transactionReceipt(hash: String) async throws -> RPCReceipt
  }
  ```
  Mirrors `LiveAlchemyClient` transport (`AlchemyClient.swift:257-333`): `send()` wraps
  `withRetry(policy:classify:sleep:operation:)` with `rateLimiter.acquire()` **inside**
  the retried operation; non-2xx mapped via a small validator. Reuse
  `WalletSyncError` cases (`.network`, `.rateLimited(retryAfter:)`,
  `.providerMalformedResponse(stage:)`). 429/`Retry-After` honoured like Blockscout
  (`honorsRetryAfterInPlace: true`).

- [ ] **Step 1: Write failing tests** using an ephemeral `URLSession` +
  `URLProtocol` stub (copy the harness pattern from the existing Alchemy client
  tests — find with `grep -rn "URLProtocol" MoolahTests/Shared/CryptoImport`). Assert
  `chainId()` decodes `"0x1"` → `1`; `blockNumber()` decodes `"0x10"` → `16`; an HTTP
  429 with `Retry-After: 1` retries then succeeds; a `{"error":{"code":-32000,...}}`
  body throws `.providerMalformedResponse`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the struct, `send()`, `chainId()`, `blockNumber()`, and the
  retry policy (`HTTPRetryPolicy(maxAttempts: 4, backoffBase: 0.5, backoffCap: 8,
  honorsRetryAfterInPlace: true, maxRateLimitWait: 60)`).
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Review** `@code-review` + `@concurrency-review` (Sendable, actor
  hops, retry-inside-limiter). Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): add LiveJSONRPCClient transport with chainId/blockNumber`.

### Task 4: `eth_getBlockByNumber` (batched timestamps) + `eth_call`

**Files:**
- Modify: `Shared/CryptoImport/JSONRPC/LiveJSONRPCClient.swift`
- Create: `Shared/CryptoImport/JSONRPC/RPCWireTypes.swift` (`RPCLog`, `RPCLogFilter`, `RPCReceipt`, `RPCReceiptLog`)
- Test: `MoolahTests/Shared/CryptoImport/LiveJSONRPCClientBatchTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct RPCLog: Decodable, Sendable, Hashable {
    let address: String; let topics: [String]; let data: String
    let blockNumber: String; let transactionHash: String; let logIndex: String
  }
  struct RPCLogFilter: Encodable, Sendable {
    let fromBlock: String; let toBlock: String
    let address: [String]?          // nil = all contracts
    let topics: [String?]           // positional; nil = wildcard
  }
  struct RPCReceiptLog: Decodable, Sendable, Hashable { let address: String; let topics: [String]; let data: String; let logIndex: String }
  struct RPCReceipt: Decodable, Sendable, Hashable {
    let transactionHash: String; let from: String; let gasUsed: String
    let effectiveGasPrice: String; let l1Fee: String?; let logs: [RPCReceiptLog]
  }
  func blockTimestamps(_ blocks: [UInt64]) async throws -> [UInt64: Date]  // one batch request, id-correlated
  func call(to: String, data: String) async throws -> String              // eth_call {to,data} at "latest"
  ```

- [ ] **Step 1: Write failing tests.** `blockTimestamps([16, 17])` issues one batch
  request and maps each block's `"timestamp":"0x…"` to a `Date`
  (`Date(timeIntervalSince1970:)`); `call(to:data:)` returns the `result` hex string;
  a batch response with reordered `id`s still maps correctly.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `blockTimestamps` (batch `eth_getBlockByNumber(block,false)`,
  decode only `timestamp`, correlate by id) and `call`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Review** `@code-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): add batched block-timestamp and eth_call to JSONRPC client`.

### Task 5: `eth_getTransactionReceipt` on the JSON-RPC client

**Files:**
- Modify: `Shared/CryptoImport/JSONRPC/LiveJSONRPCClient.swift`
- Test: extend `LiveJSONRPCClientBatchTests.swift`

**Interfaces:**
- Produces `func transactionReceipt(hash: String) async throws -> RPCReceipt` — decodes
  the standard receipt incl. its `logs` array. Throws `.providerMalformedResponse(stage:
  "getTransactionReceipt")` on `result: null`.

- [ ] **Step 1: Write failing test** decoding a receipt fixture that includes two
  `logs` entries (address/topics/data/logIndex present); assert a `null` result throws.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `transactionReceipt`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Review** `@code-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): add eth_getTransactionReceipt with logs to JSONRPC client`.

---

# PR 2 — Provider-neutral `ChainDataClient` seam (no behaviour change)

Pure rename/refactor. Alchemy remains the only implementation and the only wiring.
`just build-mac` + full touched tests green; behaviour identical.

### Task 6: Rename the `AlchemyClient` protocol to `ChainDataClient`

**Files:**
- Modify: `Shared/CryptoImport/AlchemyClient.swift` (protocol decl L9; `extension LiveAlchemyClient: AlchemyClient` L337)
- Modify every reference: `Shared/CryptoImport/WalletSyncEngine.swift` (L34, L59, L62 param, L172),
  `Shared/CryptoImport/TransferReceiptCoalescer.swift` (L39 param), `TransferEventBuilder+GasOnly.swift` (`alchemy:` params),
  `App/ProfileSession+CryptoSync.swift` (L112 `let alchemy: any AlchemyClient`), and any `BuilderServices` field.
- Modify tests: every stub declared `: AlchemyClient` (grep below).

**Interfaces:**
- Produces: `protocol ChainDataClient: Sendable { func getAssetTransfers(...); func getTransactionReceipt(...) }`
  with identical method signatures. `LiveAlchemyClient: ChainDataClient`. The variable/param
  name `alchemy` may stay for now (renamed in PR 5 wiring) to keep this diff a pure type rename.

- [ ] **Step 1: Inventory references.** `grep -rn "AlchemyClient" Shared App MoolahTests` —
  note every declaration/conformance/param/stub. (The type `LiveAlchemyClient` and the
  model `AlchemyTransfer` are NOT renamed — only the protocol `AlchemyClient`.)
- [ ] **Step 2: Rename the protocol** `AlchemyClient` → `ChainDataClient` in
  `AlchemyClient.swift:9` and the conformance at L337. Update its doc comment to say it
  is the provider-neutral on-chain data seam (Alchemy or direct JSON-RPC).
- [ ] **Step 3: Update every `any AlchemyClient` / `: AlchemyClient`** reference found in
  Step 1 to `ChainDataClient` (production + tests). Leave method names unchanged.
- [ ] **Step 4: Build + test.** `just build-mac`; run the crypto-import suites — expect
  PASS with zero behaviour change.
- [ ] **Step 5: Review** `@code-review`. Fix findings.
- [ ] **Step 6: Commit** `refactor(crypto): rename AlchemyClient protocol to ChainDataClient seam`.

---

# PR 3 — `DirectRPCChainClient` (eth_getLogs ERC-20 discovery)

Adds the direct source and its adaptive batcher. Still not wired as anyone's default
(PR 5 does that) — validated by its own tests.

### Task 7: Adaptive block-range batcher (Teku-modelled)

**Files:**
- Create: `Shared/CryptoImport/DirectRPC/AdaptiveLogRangeBatcher.swift`
- Test: `MoolahTests/Shared/CryptoImport/AdaptiveLogRangeBatcherTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct AdaptiveLogRangeBatcher: Sendable {
    init(maxRange: UInt64 = 10_000, minRange: UInt64 = 1)
    /// Walks [from, to] in chunks, calling `fetch(from,to)` per chunk. On ANY thrown
    /// error (explicit range-limit, unknown provider error, OR timeout) it halves the
    /// current range and retries the sub-range; on a run of successes it grows back
    /// toward maxRange. Errors below minRange propagate. Returns the concatenated results.
    func run<T: Sendable>(from: UInt64, to: UInt64,
                          fetch: @Sendable (UInt64, UInt64) async throws -> [T]) async throws -> [T]
  }
  ```
  Reference: ConsenSys **Teku** `powchain` deposit-log fetching (adaptive range +
  throttling). Treat *every* failure as "range too large" — do NOT try to string-match
  provider error messages (they are inconsistent: message text, `-32xxx` codes, or plain
  timeouts). See the design spec §7 and the
  [Teku deposit post-incident review](https://github.com/ConsenSys/teku/wiki/Post-Incident-Review---Deposit-Processing-Performance).

- [ ] **Step 1: Write failing tests.** With a fake `fetch` that throws whenever
  `(to-from) > 2000`: `run(0, 10_000, fetch)` still completes, covering the whole range
  with no gaps/overlaps (assert on the union of `(from,to)` pairs the fake saw). A fake
  that throws a `URLError(.timedOut)` once at 10k then succeeds at 5k also completes.
  A fake that throws even at `minRange` propagates the error.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the halve-on-failure / grow-on-success loop with the floor.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Review** `@code-review` + `@concurrency-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): add Teku-modelled adaptive log-range batcher`.

### Task 8: `LogTransferMapper` — RPCLog → AlchemyTransfer

**Files:**
- Create: `Shared/CryptoImport/DirectRPC/LogTransferMapper.swift`
- Test: `MoolahTests/Shared/CryptoImport/LogTransferMapperTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum LogTransferMapper {
    /// Maps one ERC-20 Transfer log to an AlchemyTransfer. `decimals`/`symbol` come from
    /// the metadata resolver (Task 9); `timestamp` from the block-timestamp batch (Task 9).
    static func erc20Transfer(from log: RPCLog, decimals: Int, symbol: String?,
                              timestamp: Date) -> AlchemyTransfer
  }
  ```
  Row shape (matching `AlchemyTransfer` exactly, all hex strings): `hash = log.transactionHash`,
  `uniqueId = "\(log.transactionHash):erc20:\(RPCHex.parseUInt64(log.logIndex) ?? 0)"`,
  `from = RPCHex.addressFromTopic(log.topics[1])`, `to = RPCHex.addressFromTopic(log.topics[2])`,
  `category = .erc20`, `asset = symbol`,
  `rawContract = .init(address: log.address.lowercased(), decimal: RPCHex.hexData(UInt64(decimals)), rawValue: log.data)`,
  `metadata = .init(blockTimestamp: ISO8601 of timestamp)`, `blockNum = log.blockNumber`.
  Skip (return nil via a throwing/optional variant) any log with fewer than 3 topics
  (non-standard Transfer).

- [ ] **Step 1: Write failing test.** A canonical USDC Transfer log → an `AlchemyTransfer`
  whose `uniqueId`, `from`, `to`, `rawContract.address`, `rawContract.rawValue`,
  `rawContract.decimalsValue == 6`, and ISO-8601 `blockTimestamp` all match. A 2-topic log
  is skipped.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `LogTransferMapper`. Use a cached `ISO8601DateFormatter` with
  fractional seconds to match Alchemy's `"…Z"` format the rest of the pipeline expects.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Review** `@code-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): map ERC-20 Transfer logs to AlchemyTransfer`.

### Task 9: Token-metadata resolver (`decimals()`/`symbol()`, cached)

**Files:**
- Create: `Shared/CryptoImport/DirectRPC/TokenMetadataResolver.swift`
- Test: `MoolahTests/Shared/CryptoImport/TokenMetadataResolverTests.swift`

**Interfaces:**
- Produces:
  ```swift
  actor TokenMetadataResolver {
    init(rpc: LiveJSONRPCClient)
    struct Metadata: Sendable { let decimals: Int; let symbol: String? }
    /// Resolves once per contract; caches. decimals via eth_call 0x313ce567,
    /// symbol via 0x95d89b41 (best-effort — nil on revert/empty). A contract whose
    /// decimals() reverts is returned as nil so the caller drops its rows (can't scale).
    func metadata(for contract: String) async -> Metadata?
  }
  ```

- [ ] **Step 1: Write failing tests** with a stub `LiveJSONRPCClient` (inject via a small
  `call` closure seam, or subclass the URLProtocol harness): a contract returning
  `decimals()=0x6`, `symbol()=abi("USDC")` → `Metadata(6, "USDC")`; a second call for the
  same contract issues no new `eth_call` (cache hit); a `decimals()` revert → nil.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the actor. Decode `symbol()` ABI (dynamic string: offset,
  length, bytes) with a bytes32-fallback for legacy tokens; `decimals` via `HexDecimal.parseInt`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Review** `@code-review` + `@concurrency-review` (actor cache). Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): add cached ERC-20 token-metadata resolver`.

### Task 10: `DirectRPCChainClient` conforming to `ChainDataClient`

**Files:**
- Create: `Shared/CryptoImport/DirectRPC/DirectRPCChainClient.swift`
- Test: `MoolahTests/Shared/CryptoImport/DirectRPCChainClientTests.swift`

**Interfaces:**
- Consumes: `LiveJSONRPCClient`, `AdaptiveLogRangeBatcher`, `LogTransferMapper`,
  `TokenMetadataResolver`, the ABI constants.
- Produces:
  ```swift
  struct DirectRPCChainClient: ChainDataClient {
    init(rpc: LiveJSONRPCClient, batcher: AdaptiveLogRangeBatcher = .init(),
         metadata: TokenMetadataResolver)
    func getAssetTransfers(chain:walletAddress:fromBlock:) async throws -> [AlchemyTransfer]
    func getTransactionReceipt(chain:hash:) async throws -> AlchemyTransactionReceipt
  }
  ```
  `getAssetTransfers`: `head = try await rpc.blockNumber()`; two `eth_getLogs` passes over
  `[fromBlock, head]` via the batcher — outbound `topics=[transferTopic, addressTopic(wallet), nil]`,
  inbound `topics=[transferTopic, nil, addressTopic(wallet)]`, `address: nil` (all tokens).
  De-dup logs by `(transactionHash, logIndex)` (a self-send appears in both passes). Batch
  `rpc.blockTimestamps(uniqueBlocks)`; resolve metadata per unique contract; map via
  `LogTransferMapper`; drop rows whose metadata is nil. **Wrapped-native guard:** skip any
  Transfer log whose `from` or `to` is the zero address when
  `WrappedNativeContracts.nativePricingInstrumentId(chainId: chain.chainId, contractAddress: log.address) != nil`
  (those mint/burn legs are covered by PR 4's Deposit/Withdrawal to avoid double counting).
  `getTransactionReceipt`: `rpc.transactionReceipt(hash:)` → map `RPCReceipt` to
  `AlchemyTransactionReceipt` (incl. `logs`, added in PR 4 Task 12; until then map the gas
  fields only).

- [ ] **Step 1: Write failing test** with a URLProtocol harness scripting: `eth_blockNumber`,
  two `eth_getLogs` pages (one inbound USDC, one outbound USDC), `eth_getBlockByNumber` batch,
  and `decimals()`/`symbol()` `eth_call`s. Assert the returned `[AlchemyTransfer]` has the two
  ERC-20 rows with correct direction/value and no duplicates; assert a WETH `from==0x0` mint
  log is skipped.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `DirectRPCChainClient`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Review** `@code-review` + `@concurrency-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): add DirectRPCChainClient eth_getLogs ERC-20 discovery`.

---

# PR 4 — WETH wrap/unwrap via receipt logs (ships in both modes)

Closes the gap for **Alchemy users too** (only needs `eth_getTransactionReceipt`).
Wired into `WalletSyncEngine.build` this PR.

### Task 11: Extend the receipt model with `logs`

**Files:**
- Modify: `Shared/CryptoImport/AlchemyTransactionReceipt.swift` (struct L16; init L61-73)
- Modify: `Shared/CryptoImport/AlchemyJSONRPCWireFormat.swift` (`AlchemyTransactionReceiptPayload` L178; `toReceipt` L188-208)
- Test: `MoolahTests/Shared/CryptoImport/AlchemyTransactionReceiptTests.swift` (or the existing receipt-decode suite — grep `AlchemyTransactionReceipt` under MoolahTests)

**Interfaces:**
- Produces:
  ```swift
  struct ReceiptLog: Sendable, Hashable { let address: String; let topics: [String]; let data: String; let logIndex: Int }
  // on AlchemyTransactionReceipt: add `let logs: [ReceiptLog]` and default it to [] in the
  // memberwise init so every existing caller compiles unchanged.
  ```
  `AlchemyTransactionReceiptPayload` gains `let logs: [ReceiptLogPayload]?` (decode-optional —
  absent ⇒ `[]`); `toReceipt` maps them (parse `logIndex` hex via `HexDecimal.parseInt`).

- [ ] **Step 1: Write failing test** decoding a receipt JSON with two logs → `receipt.logs.count == 2`
  with parsed `logIndex`; a receipt JSON with no `logs` key → `receipt.logs == []`; existing
  gas-field assertions still pass.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the `logs` field (default `[]` in init L61-73) + payload decode + `toReceipt` mapping.
- [ ] **Step 4: Build + test.** `just build-mac` (confirm gas-leg call sites in
  `TransferReceiptCoalescer` still compile); run receipt suites — PASS.
- [ ] **Step 5: Review** `@code-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): decode transaction-receipt logs`.

### Task 12: `WrapUnwrapDetector`

**Files:**
- Create: `Shared/CryptoImport/WrapUnwrapDetector.swift`
- Test: `MoolahTests/Shared/CryptoImport/WrapUnwrapDetectorTests.swift`

**Interfaces:**
- Consumes: `BlockscoutAdaptResult.transfers` (the `.external`/`.internal` native rows,
  with on-chain `from`/`to` preserved — see `BlockscoutTransferAdapter.swift:44-91`),
  `any ChainDataClient` (for receipts), `WrappedNativeContracts.nativePricingInstrumentId`,
  the `depositTopic`/`withdrawalTopic` constants.
- Produces:
  ```swift
  struct WrapUnwrapDetector: Sendable {
    init(chainClient: any ChainDataClient)
    /// Scans native ETH movements touching a wrapped-native contract, fetches those
    /// (few) receipts, and synthesizes the missing WETH .erc20 leg from Deposit/Withdrawal.
    func detect(nativeTransfers: [AlchemyTransfer], chain: ChainConfig,
                walletAddress: String) async throws -> [AlchemyTransfer]
  }
  ```
  Wrap candidate: `.external` transfer, `from == wallet`, and
  `nativePricingInstrumentId(chainId: chain.chainId, contractAddress: transfer.to) != nil`.
  Unwrap candidate: `.internal` transfer, `to == wallet`, and
  `nativePricingInstrumentId(chainId: chain.chainId, contractAddress: transfer.from) != nil`.
  For each candidate hash, fetch the receipt; find the `Deposit` log (topic0 == depositTopic,
  `addressFromTopic(topics[1]) == wallet`) for a wrap, or `Withdrawal` (withdrawalTopic,
  `topics[1] == wallet`) for an unwrap, on the wrapped-native contract. Synthesize an
  `AlchemyTransfer`: `category = .erc20`, `rawContract.address = <WETH contract>`,
  `rawContract.decimal = "0x12"` (18), `rawValue = <log.data (wad)>`,
  `uniqueId = "\(hash):erc20:\(log.logIndex)"`, `blockNum`/`blockTimestamp` copied from the
  native transfer. Wrap ⇒ `to = wallet` (WETH in); unwrap ⇒ `from = wallet` (WETH out).
  De-dup receipts per hash (one fetch even if multiple candidate legs share a hash).

- [ ] **Step 1: Write failing tests** with a stub `ChainDataClient` returning canned
  receipts: (a) a wrap — native `.external` wallet→WETH + a `Deposit(dst=wallet)` receipt log
  → one synthesized WETH-in `.erc20` row with the wad value and `<hash>:erc20:<idx>` id;
  (b) an unwrap — `.internal` WETH→wallet + `Withdrawal(src=wallet)` → one WETH-out row;
  (c) a native send to a non-WETH address → no rows, no receipt fetch.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `WrapUnwrapDetector`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Review** `@code-review` + `@concurrency-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): detect WETH wrap/unwrap from receipt logs`.

### Task 13: Wire the detector into `WalletSyncEngine.build`

**Files:**
- Modify: `Shared/CryptoImport/WalletSyncEngine.swift` (init L58-70 add dependency; `build` L109-116)
- Modify: `App/ProfileSession+CryptoSync.swift` (`makeWalletSyncEngine` L156-177 to construct + inject the detector)
- Test: `MoolahTests/Shared/CryptoImport/WalletSyncEngineTests.swift` (grep for the existing suite)

**Interfaces:**
- Consumes: `WrapUnwrapDetector`.
- Produces: `WalletSyncEngine.build` appends `wrapUnwrap` rows to `transfers` before the head-block/builder steps:
  ```swift
  // after L110 `let adapted = …`
  let wrapUnwrap = try await wrapUnwrapDetector.detect(
    nativeTransfers: adapted.transfers, chain: chain, walletAddress: walletAddress)
  // L116 becomes:
  let transfers = adapted.transfers + wrapUnwrap
    + alchemyAll.filter { $0.category == .erc20 }
  ```
  Add `private let wrapUnwrapDetector: WrapUnwrapDetector` + init param (default-construct
  from the same `chainClient` at the wiring site). The paired ETH↔WETH `trade` falls out of the
  existing `TransferEventBuilder` + `IntraAccountSwapDetector` (same hash).

- [ ] **Step 1: Write failing test.** Drive `build(account:chain:)` with a stub Blockscout
  returning a wrap (native wallet→WETH) + stub receipt with a `Deposit`; assert the resulting
  `WalletSyncBuildResult.candidates` contains a single transaction pairing the ETH-out and
  WETH-in legs (a trade). (Reuse the engine test harness; add a stub `ChainDataClient` that
  serves the receipt.)
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the init param + `build` change + wiring in `makeWalletSyncEngine`.
- [ ] **Step 4: Build + full crypto-import suite.** `just build-mac`; `just test-mac` for the
  CryptoImport suites — PASS.
- [ ] **Step 5: Review** `@code-review` + `@concurrency-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): surface WETH wrap/unwrap in wallet sync`.

---

# PR 5 — Endpoint config, chain auto-detection, and precedence routing

Activates the direct path: custom → Alchemy → publicnode, per chain.

### Task 14: `defaultRPCURL` on `ChainConfig`

**Files:**
- Modify: `Shared/CryptoImport/ChainConfig.swift` (struct + the `.ethereum/.optimism/.base` factories in `.all`)
- Test: `MoolahTests/Shared/CryptoImport/ChainConfigTests.swift` (or add to the existing config suite)

**Interfaces:**
- Produces: `let defaultRPCURL: URL` on `ChainConfig`, set to the publicnode URL per chain
  (eth/op/base as in the constants block). Update all `ChainConfig(...)` initializers incl. tests.

- [ ] **Step 1: Write failing test** asserting `ChainConfig.config(for: 1)?.defaultRPCURL.host == "ethereum-rpc.publicnode.com"` (and op/base).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the field + factory values; fix any now-broken `ChainConfig(...)` call sites (grep).
- [ ] **Step 4: Build + test — PASS.**
- [ ] **Step 5: Review** `@code-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): add default publicnode RPC URL per chain`.

### Task 15: `CryptoRPCEndpointsStore` (persist the endpoint list)

**Files:**
- Create: `Features/Settings/CryptoRPCEndpointsStore.swift`
- Test: `MoolahTests/Features/Settings/CryptoRPCEndpointsStoreTests.swift`

**Interfaces:**
- Consumes: `KeychainStore` (`saveString`/`restoreString`, `KeychainServices.apiKeys`).
- Produces:
  ```swift
  struct CryptoRPCEndpointsStore: Sendable {
    init(store: KeychainStore = KeychainStore(service: KeychainServices.apiKeys,
                                              account: "rpc-endpoints", synchronizable: true))
    func load() -> [String]              // JSON-decoded; [] on empty/missing/corrupt
    func save(_ endpoints: [String]) throws
  }
  ```
  A custom RPC URL can embed an API key, so it is stored in the Keychain (synchronizable —
  the list follows the user across devices), JSON-encoded. Mirrors the key-store shape in
  `CryptoTokenStore+APIKeys.swift`.

- [ ] **Step 1: Write failing tests** (inject a fake `KeychainStore` seam or use an in-memory
  double): save→load round-trips a 2-URL list; empty store → `[]`; corrupt JSON → `[]` (no throw on load).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the store.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Review** `@code-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(settings): persist a synced list of custom RPC endpoints`.

### Task 16: `RPCEndpointResolver` (probe + precedence)

**Files:**
- Create: `Shared/CryptoImport/DirectRPC/RPCEndpointResolver.swift`
- Test: `MoolahTests/Shared/CryptoImport/RPCEndpointResolverTests.swift`

**Interfaces:**
- Produces:
  ```swift
  actor RPCEndpointResolver {
    init(customEndpoints: [String], alchemyKeyPresent: @Sendable () -> Bool,
         makeRPC: @Sendable (URL) -> LiveJSONRPCClient)
    struct Probe: Sendable, Equatable { let url: String; let reachable: Bool; let chainId: Int? }
    /// For Settings: probe every custom endpoint's eth_chainId (cached).
    func probeAll() async -> [Probe]
    /// For routing: which client serves this chain? custom(matching chainId) → Alchemy → publicnode.
    func client(for chain: ChainConfig) async -> ResolvedClient
    enum ResolvedClient: Sendable { case direct(LiveJSONRPCClient); case alchemy }
  }
  ```
  `client(for:)`: probe custom endpoints (cached); the first whose `chainId == chain.chainId`
  ⇒ `.direct(makeRPC(url))`; else if `alchemyKeyPresent()` ⇒ `.alchemy`; else
  `.direct(makeRPC(chain.defaultRPCURL))`.

- [ ] **Step 1: Write failing tests** with a fake `makeRPC` returning stub clients keyed by
  URL→chainId: a custom OP endpoint routes chain 10 to `.direct` but chain 1 to `.alchemy`
  (key present) / publicnode (no key); an unreachable custom endpoint is `reachable:false,
  chainId:nil` in `probeAll` and ignored by `client(for:)`; probing happens once (cache).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the resolver + probe cache.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Review** `@code-review` + `@concurrency-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): add RPC endpoint resolver with custom→Alchemy→publicnode precedence`.

### Task 17: `RoutingChainDataClient` + wiring

**Files:**
- Create: `Shared/CryptoImport/DirectRPC/RoutingChainDataClient.swift`
- Modify: `App/ProfileSession+CryptoSync.swift` (`makeCryptoSyncWiring` L111-124; `makeWalletSyncEngine` L156-177) — replace the single `LiveAlchemyClient` with the routing client
- Test: `MoolahTests/Shared/CryptoImport/RoutingChainDataClientTests.swift`

**Interfaces:**
- Consumes: `RPCEndpointResolver`, `LiveAlchemyClient`, `DirectRPCChainClient`, `TokenMetadataResolver`.
- Produces:
  ```swift
  struct RoutingChainDataClient: ChainDataClient {
    init(resolver: RPCEndpointResolver, makeAlchemy: @Sendable () -> any ChainDataClient,
         makeDirect: @Sendable (LiveJSONRPCClient) -> any ChainDataClient)
    func getAssetTransfers(chain:walletAddress:fromBlock:) async throws -> [AlchemyTransfer]
    func getTransactionReceipt(chain:hash:) async throws -> AlchemyTransactionReceipt
  }
  ```
  Both methods `await resolver.client(for: chain)` and dispatch to the Alchemy or direct client.
  Wire in `makeCryptoSyncWiring`: build the resolver from
  `CryptoRPCEndpointsStore().load()` + `{ resolveAlchemyApiKey() != nil }`, construct the
  `RoutingChainDataClient`, and inject it everywhere the old `alchemy` client went (engine +
  gas-leg coalescer + wrap/unwrap detector). Rename the local `alchemy` → `chainClient` here.

- [ ] **Step 1: Write failing test** with a fake resolver: chain 1 → `.alchemy` dispatches to
  the Alchemy stub; chain 10 → `.direct` dispatches to the direct stub; receipts follow the
  same routing.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `RoutingChainDataClient` + rewire `makeCryptoSyncWiring` /
  `makeWalletSyncEngine`. Each per-chain `DirectRPCChainClient` shares one
  `TokenMetadataResolver` per endpoint.
- [ ] **Step 4: Build + full CryptoImport + a manual smoke.** `just build-mac`; `just test-mac`
  CryptoImport suites — PASS. With no custom endpoint + Alchemy key, behaviour is unchanged
  (routes to Alchemy).
- [ ] **Step 5: Review** `@code-review` + `@concurrency-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(crypto): route on-chain fetches by custom→Alchemy→publicnode precedence`.

### Task 18: Settings section — endpoint list + live status

**Files:**
- Modify: `Features/Settings/CryptoSettingsView.swift` (add a fifth `Section` in `body` L40-56; new `@ViewBuilder private var rpcEndpointsSection`; `@State` for the input + probe results)
- Modify: `Features/Settings/CryptoTokenStore.swift` (expose `CryptoRPCEndpointsStore` + a `probeEndpoints()` action calling `RPCEndpointResolver.probeAll`)
- Test: `MoolahUITests_macOS/…` per the writing-ui-tests skill (identifiers on the add-field, list rows, and status labels), plus a store-level test for load/save/probe.

**Interfaces:**
- Consumes: `CryptoRPCEndpointsStore`, `RPCEndpointResolver.Probe`.
- Produces: a Settings section listing endpoint URLs (add via `TextField` + "Add", delete via
  swipe/`Remove`), each row showing a status badge — reachable ✓/✗ and the resolved chain
  name (Ethereum/Optimism/Base) or "Unknown chain (id N)". Mirror the `alchemyStatusBadge`
  precedence `@ViewBuilder` pattern (`CryptoSettingsView.swift:139-156`): `Label(text,
  systemImage:)` colored red/green/secondary. Editing the list re-probes and (on save)
  rebuilds the crypto-sync wiring so routing picks up the change.

- [ ] **Step 1: Add identifiers + store plumbing.** Follow the `writing-ui-tests` skill: add
  `.accessibilityIdentifier` to the URL field, each row, and each status label; expose
  `store.rpcEndpoints`, `store.addRPCEndpoint(_:)`, `store.removeRPCEndpoint(_:)`,
  `store.probeEndpoints()` on `CryptoTokenStore`.
- [ ] **Step 2: Write the failing UI test** (macOS): add an endpoint, assert the row appears
  and a status label resolves to a chain name; remove it, assert it disappears. Run — expect FAIL.
- [ ] **Step 3: Implement** `rpcEndpointsSection` + the store actions + wiring-rebuild hook.
- [ ] **Step 4: Iterate the view via `RenderPreview`/#Preview** (per `reviewing-ui-with-preview`);
  then run the UI test — PASS. (If the UI host is wedged, gate on the PR's CI UI-Test job.)
- [ ] **Step 5: Review** `@ui-review` + `@ui-test-review` + `@code-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(settings): add custom RPC endpoints section with live chain detection`.

---

# PR 6 — Cross-device synced block checkpoint

Stops an idle device re-scanning from genesis. **Behavioural reversal:**
`WalletSyncState` is deliberately per-device today (`WalletSyncState.swift:3-8`); this PR
adds a *separate* CloudKit-synced checkpoint record and merges it by `max`, keeping the
32-block reorg window and relying on `externalId` dedup for overlap.

### Task 19: Add the `WalletCheckpointRecord` synced type

**Files:**
- Modify: `CloudKit/schema.ckdb` (add a `WalletSyncCheckpointRecord` block — system fields + `___recordID REFERENCE QUERYABLE` + `lastSyncedBlockNumber INT64 QUERYABLE SORTABLE` + the three standard grants)
- Create: `Domain/Models/WalletSyncCheckpoint.swift` (`struct WalletSyncCheckpoint: Codable, Sendable, Identifiable, Hashable { let id: UUID; var lastSyncedBlockNumber: UInt64 }`)
- Create: `Backends/GRDB/Records/WalletSyncCheckpointRow.swift` (+ `+Mapping.swift`) — local mirror table, `UInt64`↔`Int64` like `WalletSyncStateRow+Mapping.swift:39,49`
- Create: `Backends/GRDB/Sync/WalletSyncCheckpointRow+CloudKit.swift` (`CloudKitRecordConvertible` adapter mirroring `AccountRow+CloudKit.swift:17-78`)
- Modify: `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift` (register in `RecordTypeRegistry.allTypes` L137-150; add to the `IdentifiableRecord`/`ValueTypeSystemFieldsReadable` lists L35-47/L60-73)
- Modify: register a GRDB migration for the mirror table (follow the existing `WalletSyncStateRow` migration; grep the migrator registration)
- Test: `MoolahTests/Backends/CloudKit/RoundTripTests.swift` (add a checkpoint round-trip)

**Interfaces:**
- Produces: `static let recordType = "WalletSyncCheckpointRecord"`; the row conforms to
  `FetchableRecord`/`PersistableRecord` and `CloudKitRecordConvertible`. `just generate`
  emits `WalletSyncCheckpointRecordCloudKitFields`.

- [ ] **Step 1: Edit `schema.ckdb`** adding the record block; run `just generate` and
  `just check-schema-additive` (expect additive-OK).
- [ ] **Step 2: Write the failing round-trip test** (domain→CKRecord→domain preserves id +
  block number). Run — FAIL (types missing).
- [ ] **Step 3: Implement** the model, GRDB row + mapping + migration, the `+CloudKit` adapter,
  and the registry registrations.
- [ ] **Step 4: Build + test.** `just build-mac`; run `RoundTripTests` + a migration test — PASS.
- [ ] **Step 5: Review** `@sync-review` + `@database-schema-review` + `@database-code-review` + `@code-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(sync): add cross-device wallet sync checkpoint record`.

### Task 20: Read/write the synced checkpoint in the sync engine

**Files:**
- Create: `Domain/Repositories/WalletSyncCheckpointRepository.swift` (+ `Backends/GRDB/Repositories/GRDBWalletSyncCheckpointRepository.swift`) — `load(accountId:)`/`save(_:)`, mirroring `GRDBWalletSyncStateRepository.swift`
- Modify: `Shared/CryptoImport/WalletSyncEngine.swift` (`build` L100-102 — combine checkpoints)
- Modify: `Shared/CryptoImport/WalletApplyEngine.swift` (`updateSyncState` L240-250 — also write the synced checkpoint by `max`)
- Modify: `App/ProfileSession+CryptoSync.swift` (inject the new repo into engine + apply)
- Test: `MoolahTests/Shared/CryptoImport/WalletSyncCheckpointTests.swift`

**Interfaces:**
- Consumes: `WalletSyncCheckpointRepository`.
- Produces: `build`'s `fromBlock` uses the higher of local + synced checkpoints:
  ```swift
  // replace L100-102
  let localState = try await walletSyncState.load(accountId: account.id)
  let syncedBlock = (try? await checkpoints.load(accountId: account.id))?.lastSyncedBlockNumber ?? 0
  let priorBlock = max(localState?.lastSyncedBlockNumber ?? 0, syncedBlock)
  let fromBlock = priorBlock == 0 ? 0 : Self.subtractingReorgWindow(priorBlock)
  ```
  `updateSyncState` additionally writes `WalletSyncCheckpoint(id: account.id,
  lastSyncedBlockNumber: max(existingSynced, input.headBlockNumber))` so a device never
  lowers the shared checkpoint. Add a doc comment recording the eventual-consistency caveat
  (a checkpoint may arrive before its transactions; they converge via CloudKit + `externalId` dedup).

- [ ] **Step 1: Write failing tests.** (a) `build` with local=0 but synced=1000 fetches from
  `968` (1000−32), not 0; (b) `updateSyncState` with an existing synced=2000 and head=1500
  keeps the synced checkpoint at 2000 (`max`), and at head=2500 raises it to 2500.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the repo, the `build` combine, and the `updateSyncState` max-write; inject in wiring.
- [ ] **Step 4: Build + full CryptoImport suite — PASS.**
- [ ] **Step 5: Review** `@sync-review` + `@database-code-review` + `@concurrency-review` + `@code-review`. Fix findings.
- [ ] **Step 6: Commit** `feat(sync): advance wallet sync fromBlock using the synced checkpoint`.

---

## Self-Review

**Spec coverage:**
- Provider seam → PR 2 (Task 6). ✅
- `LiveJSONRPCClient` (standard methods, batch) → PR 1 (Tasks 1–5). ✅
- `eth_getLogs` Transfer discovery + timestamp/metadata fill → PR 3 (Tasks 8–10). ✅
- Adaptive Teku-modelled batcher → PR 3 (Task 7). ✅
- Wrap/unwrap via ETH-movement receipts, both modes, double-count guard → PR 4 (Tasks 11–13)
  + the zero-address wrapped-native skip in Task 10. ✅
- Endpoint list Settings + `eth_chainId` auto-detect + "Unknown chain" → PR 5 (Tasks 16, 18). ✅
- Precedence custom→Alchemy→publicnode + `defaultRPCURL` → PR 5 (Tasks 14, 16, 17). ✅
- Full genesis scan retained → PR 3 (Task 10 scans `[fromBlock, head]`; `fromBlock=0` for new wallets is unchanged). ✅
- Cross-device synced checkpoint (max-merge, reorg window kept, caveat) → PR 6 (Tasks 19–20). ✅

**Placeholder scan:** no TBD/TODO; each task names concrete files, real anchors, interface
signatures, and test assertions. Novel logic (envelope, hex/topics, batcher, mapper, detector,
resolver, routing, checkpoint) carries code or exact shapes.

**Type consistency:** `ChainDataClient` (PR 2) is the seam name used consistently in PRs 3–6;
`AlchemyTransfer` and `AlchemyTransactionReceipt` are extended, not renamed; `RPCReceipt`/
`ReceiptLog` vs `AlchemyTransactionReceipt.logs` are distinct by design (wire vs domain) and
mapped in Task 10/Task 11.

## Execution Handoff

Recommended: **subagent-driven-development** — dispatch a fresh subagent per task, review
between tasks. Long `just test-mac` runs stay in the controller (never delegated). Land each
PR via the `landing-prs` skill; PRs 2–6 stack on their predecessor (retarget to `main` as each
parent merges). Given the CloudKit schema change, PR 6 must not be squashed with earlier PRs.
