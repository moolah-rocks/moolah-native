# Blockscout Native-ETH Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Source native-ETH transactions and contract-internal ETH transfers from Blockscout's public API alongside Alchemy (which keeps ERC-20 + receipts), fixing #918 (invisible internal transfers on OP-stack) and #919 (gas leg dropped for zero-movement signed txs).

**Architecture:** A new `BlockExplorerClient`/`LiveBlockscoutClient` (no API key) fetches a wallet's signed txs + internal txs. A pure `BlockscoutTransferAdapter` normalizes them into the existing `AlchemyTransfer` model plus an authoritative `[SignedGasTx]` set. `WalletSyncEngine` merges Blockscout native rows with Alchemy ERC-20-only rows; `TransferEventBuilder` gains a gas-only-hash path so every signed tx gets a gas leg. Polygon is removed from `ChainConfig`. Builds strictly on top of in-flight #921's `makeGasLeg` (no fee-math changes).

**Tech Stack:** Swift 6, Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`), `URLProtocol` stub harness, `just` build/test/format targets, xcodegen (directory-based sources — new files auto-included, run `just generate`).

**Spec:** `plans/2026-05-16-blockscout-native-eth-provider-design.md`

**Conventions (non-negotiable, from CLAUDE.md + guides):**
- TDD: write the failing test first, watch it fail, then implement.
- One protocol conformance per `extension`; file-scope `CodingKeys`; `// path/Name.swift` first-line comment; namespace `enum` anchor matching filename when a file holds loose top-level types (SwiftLint `file_name`).
- All currency/amount math preserves sign; never `abs()`.
- Run `just format` before every commit; `just generate` after adding files / before building; capture test output to `.agent-tmp/`.
- Never edit `.swiftlint-baseline.yml`. Fix violations by restructuring.
- `git -C <worktree> …` (never `cd && git`); `just -d <worktree> --justfile <worktree>/justfile <target>` (never `cd && just`).
- Worktree path: `/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-blockscout-native-eth` (branch `worktree-fix-blockscout-native-eth`). All commands run against it.

For brevity below, `WT` = the worktree path above. `just` invocations: `just -d "$WT" --justfile "$WT/justfile" <target>`.

---

## Task 1: Remove `.polygon` from `ChainConfig`; add `blockscoutAPIBaseURL`

**Files:**
- Modify: `Shared/CryptoImport/ChainConfig.swift`
- Modify (test, first): `MoolahTests/Shared/CryptoImport/ChainConfigTests.swift`
- Modify (compile-fix): every file referencing `ChainConfig.polygon` (enumerated in Step 5)

- [ ] **Step 1: Rewrite `ChainConfigTests.swift` for the new shape (failing test)**

Replace the bodies that reference Polygon and add the Blockscout invariant. Apply these exact edits:

Replace `baseConfigIsCorrect()` to also assert the new field, and replace `polygonConfigIsCorrect`, `allChainsAreUnique`, `lookupByIdReturnsMatchingConfig`, `nativeInstrumentsUseCorrectFactoryFormat`, `internalTransferSupportMatchesDesignDoc` as follows:

```swift
  @Test
  func ethereumConfigIsCorrect() {
    let config = ChainConfig.ethereum
    #expect(config.chainId == 1)
    #expect(config.alchemyNetworkSlug == "eth-mainnet")
    #expect(config.supportsInternalTransfers == true)
    #expect(config.displayName == "Ethereum")
    #expect(config.blockExplorerBaseURL.absoluteString == "https://etherscan.io")
    #expect(config.blockscoutAPIBaseURL.absoluteString == "https://eth.blockscout.com")
    #expect(config.nativeInstrument.ticker == "ETH")
    #expect(config.nativeInstrument.chainId == 1)
    #expect(config.nativeInstrument.contractAddress == nil)
    #expect(config.nativeInstrument.decimals == 18)
  }

  @Test
  func optimismConfigIsCorrect() {
    let config = ChainConfig.optimism
    #expect(config.chainId == 10)
    #expect(config.alchemyNetworkSlug == "opt-mainnet")
    #expect(config.supportsInternalTransfers == false)
    #expect(config.displayName == "OP Mainnet")
    #expect(config.blockExplorerBaseURL.absoluteString == "https://optimistic.etherscan.io")
    #expect(config.blockscoutAPIBaseURL.absoluteString == "https://optimism.blockscout.com")
    #expect(config.nativeInstrument.ticker == "ETH")
    #expect(config.nativeInstrument.chainId == 10)
  }

  @Test
  func baseConfigIsCorrect() {
    let config = ChainConfig.base
    #expect(config.chainId == 8453)
    #expect(config.alchemyNetworkSlug == "base-mainnet")
    #expect(config.supportsInternalTransfers == false)
    #expect(config.displayName == "Base")
    #expect(config.blockExplorerBaseURL.absoluteString == "https://basescan.org")
    #expect(config.blockscoutAPIBaseURL.absoluteString == "https://base.blockscout.com")
    #expect(config.nativeInstrument.ticker == "ETH")
    #expect(config.nativeInstrument.chainId == 8453)
  }

  @Test
  func allChainsAreUniqueAndPolygonRemoved() {
    let chainIds = ChainConfig.all.map(\.chainId)
    #expect(Set(chainIds).count == chainIds.count)
    #expect(chainIds == [1, 10, 8453])
  }

  @Test
  func lookupByIdReturnsMatchingConfig() {
    #expect(ChainConfig.config(for: 1) == .ethereum)
    #expect(ChainConfig.config(for: 10) == .optimism)
    #expect(ChainConfig.config(for: 8453) == .base)
  }

  @Test
  func lookupByIdReturnsNilForUnsupportedChain() {
    #expect(ChainConfig.config(for: 0) == nil)
    #expect(ChainConfig.config(for: 137) == nil)  // Polygon — removed (no public Blockscout)
    #expect(ChainConfig.config(for: 42_161) == nil)  // Arbitrum, not yet supported
    #expect(ChainConfig.config(for: 999_999) == nil)
  }

  @Test
  func nativeInstrumentsUseCorrectFactoryFormat() {
    #expect(ChainConfig.ethereum.nativeInstrument.id == "1:native")
    #expect(ChainConfig.optimism.nativeInstrument.id == "10:native")
    #expect(ChainConfig.base.nativeInstrument.id == "8453:native")
  }

  @Test
  func internalTransferSupportMatchesDesignDoc() {
    let supports = Dictionary(
      uniqueKeysWithValues: ChainConfig.all.map { ($0.chainId, $0.supportsInternalTransfers) }
    )
    #expect(supports[1] == true)
    #expect(supports[10] == false)
    #expect(supports[8453] == false)
    #expect(supports[137] == nil)  // Polygon removed
  }
```

Delete the old `polygonConfigIsCorrect()` test entirely.

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac ChainConfigTests 2>&1 | tee "$WT/.agent-tmp/t1.txt"`
Expected: FAIL — `ChainConfig has no member 'blockscoutAPIBaseURL'` and `.polygon` still present.

- [ ] **Step 3: Add `blockscoutAPIBaseURL`, remove `.polygon`**

In `Shared/CryptoImport/ChainConfig.swift`:

Add the stored property after `blockExplorerBaseURL` (line 29):

```swift
  /// Blockscout public-instance API base URL (no trailing slash), e.g.
  /// `https://eth.blockscout.com`. Used by `LiveBlockscoutClient` for the
  /// `/api/v2/addresses/{address}/transactions` and
  /// `/internal-transactions` endpoints. Every supported chain has a
  /// first-party public Blockscout instance; Polygon does not, which is
  /// why it is not a supported chain.
  let blockscoutAPIBaseURL: URL
```

Change `ChainConfig.all` (line 36-38) to:

```swift
  static let all: [ChainConfig] = [
    .ethereum, .optimism, .base,
  ]
```

Add `blockscoutAPIBaseURL:` to each of `.ethereum`, `.optimism`, `.base` initialisers:

- `.ethereum`: add `blockscoutAPIBaseURL: requireURL("https://eth.blockscout.com"),` after the `blockExplorerBaseURL:` line.
- `.optimism`: add `blockscoutAPIBaseURL: requireURL("https://optimism.blockscout.com"),`.
- `.base`: add `blockscoutAPIBaseURL: requireURL("https://base.blockscout.com"),`.

Delete the entire `static let polygon = ChainConfig(...)` block (lines 83-93) and its doc comment.

- [ ] **Step 4: Run ChainConfigTests to verify pass**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac ChainConfigTests 2>&1 | tee "$WT/.agent-tmp/t1.txt"`
Expected: PASS.

- [ ] **Step 5: Fix every `ChainConfig.polygon` reference, then full build**

Find call sites: `grep -rn "ChainConfig.polygon\|\.polygon\b" --include="*.swift" "$WT/Shared" "$WT/App" "$WT/Features" "$WT/MoolahTests" | grep -v "polygonscan"`

Known production references to fix:
- `Shared/CryptoImport/TransferEventBuilder+NativeRegistration.swift` — if it enumerates `ChainConfig.all` it needs no change; if it references `.polygon` directly, remove that reference.
- `App/ProfileSession.swift` — remove any `.polygon` usage (e.g. a chain-picker list); if it iterates `ChainConfig.all` no change needed.

Known test references (these construct `ChainConfig.polygon` or pass chainId 137 *via ChainConfig*): inspect each and either switch to `.ethereum`/`.base` or delete the Polygon-specific case:
- `MoolahTests/Shared/CryptoImport/BlockExplorerLinkTests.swift`
- `MoolahTests/Shared/CryptoImport/SwapDetectorPreservationTests.swift`
- `MoolahTests/Shared/CryptoImport/CrossAccountTransferMergerTests.swift`
- `MoolahTests/Shared/CryptoImport/IntraAccountSwapDetectorTests.swift`
- `MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryCoalescerTests.swift`
- `MoolahTests/Shared/CryptoImport/LiveAlchemyClientRequestTests.swift`
- `MoolahTests/Features/Crypto/CryptoAccountCreationStoreTests.swift`

For each: if the test asserts Polygon-specific behaviour that no longer exists, delete that single `@Test`; otherwise replace `ChainConfig.polygon` with `ChainConfig.base` (also OP-stack-like: `supportsInternalTransfers == false`) or `.ethereum` as fits the assertion. Do **not** change tests that use raw `Instrument.crypto(chainId: 137, …)` or CoinGecko `"matic"` unrelated to `ChainConfig` (those exercise instrument/catalog code, not chain config) — verify by reading the file; only `ChainConfig.polygon` / `ChainConfig.config(for: 137)` expectations change.

Run: `just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t1-build.txt"`
Expected: build succeeds with zero warnings.

- [ ] **Step 6: Format, generate, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" generate
git -C "$WT" add -A
git -C "$WT" commit -m "refactor(crypto): remove Polygon from ChainConfig; add blockscoutAPIBaseURL

Polygon has no first-party public Blockscout instance and the project
does not commit to a paid explorer. Existing Polygon accounts fall
through the existing unknown-chainId skip path. Adds the Blockscout
API base URL per supported chain (eth/optimism/base). Refs #918, #919.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Blockscout wire-format structs + decoding tests

**Files:**
- Create: `Shared/CryptoImport/BlockscoutWireFormat.swift`
- Create (test, first): `MoolahTests/Shared/CryptoImport/BlockscoutWireFormatDecodingTests.swift`
- Create (fixtures): `MoolahTests/Support/Fixtures/blockscout-*.json` (verify the fixture directory by checking where Alchemy fixtures live: `grep -rl "eth-simple-eth-send" "$WT/MoolahTests" --include=*.json -l` → put new fixtures alongside).

Blockscout `/api/v2/addresses/{a}/transactions` item shape (relevant fields): `hash` (String), `block_number` (Int), `timestamp` (ISO-8601 String), `from` `{ "hash": String }`, `to` `{ "hash": String }` or `null`, `value` (decimal **wei** String), `status` (`"ok"`/`"error"`/`null`), `result` (String, e.g. `"success"`). Response envelope: `{ "items": [...], "next_page_params": {…}|null }`. Internal-tx item: `transaction_hash` (String), `block_number` (Int), `timestamp` (String), `from` `{hash}`, `to` `{hash}|null`, `value` (wei String), `index` (Int), `success` (Bool). **Verify exact field names against a live response during Step 1** (`curl -s 'https://eth.blockscout.com/api/v2/addresses/0x… /transactions'` shape) and pin them in the fixtures.

- [ ] **Step 1: Capture real fixtures + write failing decode tests**

Capture (network; if unavailable, hand-author from the documented schema and note it):

```bash
mkdir -p "$WT/.agent-tmp"
curl -s "https://eth.blockscout.com/api/v2/addresses/0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60/transactions?filter=from" | python3 -m json.tool | head -120 > "$WT/.agent-tmp/bs-tx-sample.json"
curl -s "https://optimism.blockscout.com/api/v2/addresses/0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60/internal-transactions" | python3 -m json.tool | head -120 > "$WT/.agent-tmp/bs-internal-sample.json"
```

Hand-trim into 4 committed fixtures (single representative item each, `items` array + `next_page_params`):
- `blockscout-tx-value.json` — a normal ETH send (non-zero `value`, `result:"success"`, `from` = the wallet).
- `blockscout-tx-approve.json` — an ERC-20 `approve()` (`value:"0"`, `result:"success"`, `to` = token contract, `from` = wallet).
- `blockscout-tx-failed.json` — a reverted tx (`status:"error"`/`result:"…reverted…"`, `value:"0"`).
- `blockscout-internal.json` — an internal-transactions response with one non-zero-value internal credit to the wallet, plus `next_page_params: { "block_number": …, "index": …, "items_count": 50, "transaction_index": … }`.

Create `MoolahTests/Shared/CryptoImport/BlockscoutWireFormatDecodingTests.swift`:

```swift
// MoolahTests/Shared/CryptoImport/BlockscoutWireFormatDecodingTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("Blockscout wire-format decoding")
struct BlockscoutWireFormatDecodingTests {
  private func decodeTxPage(_ fixture: String) throws -> BlockscoutTransactionsPage {
    let data = try AlchemyTestSupport.loadFixture(fixture)
    return try JSONDecoder().decode(BlockscoutTransactionsPage.self, from: data)
  }

  @Test
  func decodesValueTransaction() throws {
    let page = try decodeTxPage("blockscout-tx-value")
    let tx = try #require(page.items.first)
    #expect(tx.hash.hasPrefix("0x"))
    #expect(tx.blockNumber > 0)
    #expect(tx.from.hash.hasPrefix("0x"))
    #expect(tx.value != "0")
    #expect(tx.timestamp != nil)
    #expect(tx.isSuccess == true)
  }

  @Test
  func decodesApproveAsZeroValueSuccess() throws {
    let page = try decodeTxPage("blockscout-tx-approve")
    let tx = try #require(page.items.first)
    #expect(tx.value == "0")
    #expect(tx.isSuccess == true)
    #expect(tx.to?.hash != nil)
  }

  @Test
  func decodesFailedTransaction() throws {
    let page = try decodeTxPage("blockscout-tx-failed")
    let tx = try #require(page.items.first)
    #expect(tx.isSuccess == false)
  }

  @Test
  func decodesInternalTransfersWithPageCursor() throws {
    let data = try AlchemyTestSupport.loadFixture("blockscout-internal")
    let page = try JSONDecoder().decode(BlockscoutInternalTxPage.self, from: data)
    let itx = try #require(page.items.first)
    #expect(itx.transactionHash.hasPrefix("0x"))
    #expect(itx.value != "0")
    #expect(itx.index >= 0)
    #expect(page.nextPageParams != nil)
  }

  @Test
  func missingNextPageParamsDecodesAsNil() throws {
    let json = #"{"items":[],"next_page_params":null}"#.data(using: .utf8)!
    let page = try JSONDecoder().decode(BlockscoutTransactionsPage.self, from: json)
    #expect(page.items.isEmpty)
    #expect(page.nextPageParams == nil)
  }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac BlockscoutWireFormatDecodingTests 2>&1 | tee "$WT/.agent-tmp/t2.txt"`
Expected: FAIL — `cannot find type 'BlockscoutTransactionsPage'`.

- [ ] **Step 3: Implement the wire structs**

Create `Shared/CryptoImport/BlockscoutWireFormat.swift`:

```swift
// Shared/CryptoImport/BlockscoutWireFormat.swift
import Foundation

/// Namespace anchor matching the filename so SwiftLint's `file_name`
/// rule stays satisfied alongside the loose top-level wire-format types
/// below.
enum BlockscoutWireFormat {}

/// One page of Blockscout `/api/v2/addresses/{address}/transactions`.
/// `next_page_params` is an opaque cursor object echoed back as query
/// items on the next request; `nil` when the last page has been served.
struct BlockscoutTransactionsPage: Decodable, Sendable {
  let items: [BlockscoutTransaction]
  let nextPageParams: BlockscoutPageParams?
}

extension BlockscoutTransactionsPage {
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: BlockscoutPageCodingKeys.self)
    self.items = try c.decodeIfPresent([BlockscoutTransaction].self, forKey: .items) ?? []
    self.nextPageParams = try c.decodeIfPresent(
      BlockscoutPageParams.self, forKey: .nextPageParams)
  }
}

/// One page of `/api/v2/addresses/{address}/internal-transactions`.
struct BlockscoutInternalTxPage: Decodable, Sendable {
  let items: [BlockscoutInternalTx]
  let nextPageParams: BlockscoutPageParams?
}

extension BlockscoutInternalTxPage {
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: BlockscoutPageCodingKeys.self)
    self.items = try c.decodeIfPresent([BlockscoutInternalTx].self, forKey: .items) ?? []
    self.nextPageParams = try c.decodeIfPresent(
      BlockscoutPageParams.self, forKey: .nextPageParams)
  }
}

private enum BlockscoutPageCodingKeys: String, CodingKey {
  case items
  case nextPageParams = "next_page_params"
}

/// Opaque pagination cursor. Blockscout echoes these as query
/// parameters on the next request. Only the fields the client threads
/// back are decoded; unknown keys are ignored. `blockNumber` is also
/// used to early-stop pagination once a page predates `fromBlock`.
struct BlockscoutPageParams: Decodable, Sendable, Hashable {
  let blockNumber: Int?
  let index: Int?
  let itemsCount: Int?
  let transactionIndex: Int?

  enum CodingKeys: String, CodingKey {
    case blockNumber = "block_number"
    case index
    case itemsCount = "items_count"
    case transactionIndex = "transaction_index"
  }

  /// Query items to thread back for the next page. Encodes only the
  /// non-nil cursor fields, matching what Blockscout returned.
  var queryItems: [URLQueryItem] {
    var items: [URLQueryItem] = []
    if let blockNumber { items.append(.init(name: "block_number", value: String(blockNumber))) }
    if let index { items.append(.init(name: "index", value: String(index))) }
    if let itemsCount { items.append(.init(name: "items_count", value: String(itemsCount))) }
    if let transactionIndex {
      items.append(.init(name: "transaction_index", value: String(transactionIndex)))
    }
    return items
  }
}

/// Address wrapper — Blockscout returns `{ "hash": "0x…" , … }` for
/// `from`/`to`. Only `hash` is needed.
struct BlockscoutAddress: Decodable, Sendable, Hashable {
  let hash: String
}

/// One item from the address `transactions` endpoint. `value` is wei as
/// a decimal string. Success is derived from `status`/`result` so a
/// reverted tx is still enumerated (it paid gas — #919).
struct BlockscoutTransaction: Decodable, Sendable, Hashable {
  let hash: String
  let blockNumber: Int
  let timestamp: String?
  let from: BlockscoutAddress
  let to: BlockscoutAddress?
  let value: String
  let status: String?
  let result: String?

  enum CodingKeys: String, CodingKey {
    case hash
    case blockNumber = "block_number"
    case timestamp
    case from
    case to
    case value
    case status
    case result
  }

  /// `true` unless the receipt status / execution result indicates a
  /// revert. Blockscout uses `status:"ok"|"error"` and a textual
  /// `result` (`"success"` vs an error string). A failed tx is still a
  /// real signed tx that paid gas, so this only affects the *value*
  /// leg, never whether the tx contributes a gas leg.
  var isSuccess: Bool {
    if let status { return status.lowercased() == "ok" }
    if let result { return result.lowercased() == "success" }
    return true
  }
}

/// One item from the `internal-transactions` endpoint. `index` is
/// Blockscout's stable per-call ordinal — used to build a deterministic
/// `externalId` so re-syncs dedup idempotently.
struct BlockscoutInternalTx: Decodable, Sendable, Hashable {
  let transactionHash: String
  let blockNumber: Int
  let timestamp: String?
  let from: BlockscoutAddress
  let to: BlockscoutAddress?
  let value: String
  let index: Int
  let success: Bool

  enum CodingKeys: String, CodingKey {
    case transactionHash = "transaction_hash"
    case blockNumber = "block_number"
    case timestamp
    case from
    case to
    case value
    case index
    case success
  }
}
```

> If the live-capture in Step 1 shows different field names (e.g. internal index is `"transaction_index"` not `"index"`), update both the fixture and the `CodingKeys` here and in the test before proceeding. The field names above are the documented v2 shape; the live capture is authoritative.

- [ ] **Step 4: Run to verify pass**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac BlockscoutWireFormatDecodingTests 2>&1 | tee "$WT/.agent-tmp/t2.txt"`
Expected: PASS (all 5).

- [ ] **Step 5: Format, generate, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" generate
git -C "$WT" add -A
git -C "$WT" commit -m "feat(crypto): Blockscout wire-format structs + decoding tests

Refs #918, #919.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `BlockExplorerClient` protocol + `LiveBlockscoutClient`

**Files:**
- Create: `Shared/CryptoImport/BlockExplorerClient.swift`
- Create (test, first): `MoolahTests/Shared/CryptoImport/LiveBlockscoutClientTests.swift`

The client mirrors `LiveAlchemyClient`'s structure (Sendable struct, per-request URL, `RateLimiter`, `os_signpost`, `WalletSyncError` containment, cancellation re-throw, paginated cursor loop with a requested-cursor guard). Reuses `AlchemyResponseValidator` for status mapping and the existing `AlchemyURLProtocolStub` test harness.

- [ ] **Step 1: Write failing client tests**

```swift
// MoolahTests/Shared/CryptoImport/LiveBlockscoutClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("LiveBlockscoutClient")
struct LiveBlockscoutClientTests {
  private func makeClient(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> LiveBlockscoutClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AlchemyURLProtocolStub.self]
    let session = URLSession(configuration: config)
    AlchemyURLProtocolStub.lastRequest = nil
    AlchemyURLProtocolStub.requestHandler = handler
    return LiveBlockscoutClient(
      session: session, rateLimiter: RateLimiter(permitsPerSecond: 1_000))
  }

  @Test
  func nativeTransactionsHitsCorrectHostAndPath() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("blockscout-tx-value")
    let client = makeClient { req in
      AlchemyURLProtocolStub.captureRequest(req)
      return (AlchemyTestSupport.okResponse(for: req), fixture)
    }
    let txs = try await client.nativeTransactions(
      chain: .ethereum, walletAddress: "0xABC", fromBlock: 0)
    let url = try #require(AlchemyURLProtocolStub.lastRequest?.url)
    #expect(url.host == "eth.blockscout.com")
    #expect(url.path == "/api/v2/addresses/0xABC/transactions")
    #expect(txs.count == 1)
  }

  @Test
  func internalTransactionsHitsCorrectPath() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("blockscout-internal")
    let client = makeClient { req in
      AlchemyURLProtocolStub.captureRequest(req)
      return (AlchemyTestSupport.okResponse(for: req), fixture)
    }
    _ = try await client.internalTransactions(
      chain: .optimism, walletAddress: "0xABC", fromBlock: 0)
    let url = try #require(AlchemyURLProtocolStub.lastRequest?.url)
    #expect(url.host == "optimism.blockscout.com")
    #expect(url.path == "/api/v2/addresses/0xABC/internal-transactions")
  }

  @Test
  func paginatesUntilCursorAbsentAndStopsBelowFromBlock() async throws {
    // Page 1: one item at block 100, cursor → block 50.
    // Page 2: one item at block 40 (below fromBlock 45) → stop, no page 3.
    let page1 = #"""
    {"items":[{"hash":"0xaa","block_number":100,"timestamp":"2024-01-01T00:00:00.000000Z","from":{"hash":"0xabc"},"to":{"hash":"0xdef"},"value":"10","status":"ok","result":"success"}],"next_page_params":{"block_number":50,"index":1,"items_count":50}}
    """#.data(using: .utf8)!
    let page2 = #"""
    {"items":[{"hash":"0xbb","block_number":40,"timestamp":"2024-01-01T00:00:00.000000Z","from":{"hash":"0xabc"},"to":{"hash":"0xdef"},"value":"10","status":"ok","result":"success"}],"next_page_params":{"block_number":10,"index":1,"items_count":50}}
    """#.data(using: .utf8)!
    let calls = TestCallRecorder()
    let client = makeClient { req in
      calls.record(request: req)
      let hasCursor = req.url?.query?.contains("block_number=50") ?? false
      return (AlchemyTestSupport.okResponse(for: req), hasCursor ? page2 : page1)
    }
    let txs = try await client.nativeTransactions(
      chain: .ethereum, walletAddress: "0xabc", fromBlock: 45)
    #expect(txs.map(\.hash) == ["0xaa", "0xbb"])
    #expect(calls.captured.count == 2)  // stopped: page2's last block 40 < fromBlock 45
  }

  @Test
  func mapsHTTP429ToRateLimited() async throws {
    let client = makeClient { req in
      (AlchemyTestSupport.response(for: req, statusCode: 429), Data())
    }
    await #expect(throws: WalletSyncError.self) {
      _ = try await client.nativeTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    }
  }

  @Test
  func malformedJSONThrowsProviderMalformedResponse() async throws {
    let client = makeClient { req in
      (AlchemyTestSupport.okResponse(for: req), Data("not json".utf8))
    }
    await #expect(throws: WalletSyncError.providerMalformedResponse(stage: "blockscout.transactions")) {
      _ = try await client.nativeTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    }
  }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac LiveBlockscoutClientTests 2>&1 | tee "$WT/.agent-tmp/t3.txt"`
Expected: FAIL — `cannot find 'LiveBlockscoutClient'`.

- [ ] **Step 3: Implement the protocol + client**

Create `Shared/CryptoImport/BlockExplorerClient.swift`:

```swift
// Shared/CryptoImport/BlockExplorerClient.swift
import Foundation
import OSLog
import os

/// Block-explorer source for native-ETH enumeration. Blockscout's
/// public API is indexed by *transaction* (and exposes
/// contract-internal transfers), so unlike Alchemy's Transfer-log
/// index it surfaces zero-value / `approve()` / failed signed txs
/// (#919) and OP-stack internal ETH credits (#918). No API key — the
/// public instances are unauthenticated.
protocol BlockExplorerClient: Sendable {
  /// Every transaction touching `walletAddress` (as `from` or `to`),
  /// newest-first, paginated until the cursor is absent or a page
  /// predates `fromBlock`. Includes failed / zero-value / `approve()`
  /// txs — they are real signed txs that paid gas.
  func nativeTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutTransaction]

  /// Contract-internal ETH transfers touching `walletAddress`, same
  /// pagination contract. This is the data Alchemy cannot index on
  /// OP-stack chains (#918).
  func internalTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutInternalTx]
}

/// Live `BlockExplorerClient` over Blockscout's public v2 REST API.
/// `Sendable` struct with no mutable state — mirrors `LiveAlchemyClient`.
struct LiveBlockscoutClient: BlockExplorerClient, Sendable {
  private let session: URLSession
  private let rateLimiter: RateLimiter
  private let logger: Logger

  init(session: URLSession = .shared, rateLimiter: RateLimiter) {
    self.session = session
    self.rateLimiter = rateLimiter
    self.logger = Logger(subsystem: "com.moolah.app", category: "BlockscoutClient")
  }

  func nativeTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutTransaction] {
    try await paginate(
      chain: chain,
      walletAddress: walletAddress,
      fromBlock: fromBlock,
      pathSuffix: "transactions",
      stage: "blockscout.transactions",
      decode: { try JSONDecoder().decode(BlockscoutTransactionsPage.self, from: $0) },
      items: { $0.items },
      cursor: { $0.nextPageParams },
      blockNumber: { $0.blockNumber })
  }

  func internalTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutInternalTx] {
    try await paginate(
      chain: chain,
      walletAddress: walletAddress,
      fromBlock: fromBlock,
      pathSuffix: "internal-transactions",
      stage: "blockscout.internalTransactions",
      decode: { try JSONDecoder().decode(BlockscoutInternalTxPage.self, from: $0) },
      items: { $0.items },
      cursor: { $0.nextPageParams },
      blockNumber: { $0.blockNumber })
  }

  // MARK: - Internals

  /// Generic cursor loop shared by both endpoints. Stops when the
  /// cursor is absent, when a page is empty, when a `pageKey` repeats
  /// (misbehaving provider guard, mirrors `LiveAlchemyClient`), or once
  /// every item on a page predates `fromBlock` (newest-first ordering
  /// means nothing older remains worth fetching).
  private func paginate<Page, Item>(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64,
    pathSuffix: String,
    stage: String,
    decode: @Sendable (Data) throws -> Page,
    items: (Page) -> [Item],
    cursor: (Page) -> BlockscoutPageParams?,
    blockNumber: (Item) -> Int
  ) async throws -> [Item] {
    let signpostID = OSSignpostID(log: Signposts.cryptoSync)
    os_signpost(
      .begin, log: Signposts.cryptoSync, name: "blockscout.fetch",
      signpostID: signpostID, "chain %{public}d", chain.chainId)
    defer {
      os_signpost(.end, log: Signposts.cryptoSync, name: "blockscout.fetch", signpostID: signpostID)
    }
    var collected: [Item] = []
    var pageParams: BlockscoutPageParams?
    var seenCursors: Set<BlockscoutPageParams> = []
    while true {
      if let pageParams, !seenCursors.insert(pageParams).inserted { break }
      try await rateLimiter.acquire()
      let request = try buildRequest(
        chain: chain, walletAddress: walletAddress,
        pathSuffix: pathSuffix, pageParams: pageParams)
      let data = try await send(request: request, stage: stage)
      let page: Page
      do {
        page = try decode(data)
      } catch {
        logger.error(
          "Blockscout \(stage, privacy: .public) decode failed for chain \(chain.chainId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        throw WalletSyncError.providerMalformedResponse(stage: stage)
      }
      let pageItems = items(page)
      collected.append(contentsOf: pageItems)
      // Newest-first: if the whole page is older than fromBlock, stop.
      if !pageItems.isEmpty,
        pageItems.allSatisfy({ UInt64($0.blockNumber.magnitude) < fromBlock })
      {
        break
      }
      guard let next = cursor(page) else { break }
      pageParams = next
    }
    return collected
  }

  private func buildRequest(
    chain: ChainConfig,
    walletAddress: String,
    pathSuffix: String,
    pageParams: BlockscoutPageParams?
  ) throws -> URLRequest {
    guard
      var components = URLComponents(
        url: chain.blockscoutAPIBaseURL, resolvingAgainstBaseURL: false)
    else {
      throw WalletSyncError.network(
        underlyingDescription: "Malformed Blockscout base URL for chain \(chain.chainId)")
    }
    components.path = "/api/v2/addresses/\(walletAddress)/\(pathSuffix)"
    let cursorItems = pageParams?.queryItems ?? []
    components.queryItems = cursorItems.isEmpty ? nil : cursorItems
    guard let url = components.url else {
      throw WalletSyncError.network(
        underlyingDescription: "Malformed Blockscout URL for chain \(chain.chainId)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // Hash/address is `.private`; chain is `.public` — matches the
    // Alchemy client's privacy table.
    logger.debug(
      "Blockscout GET chain \(chain.chainId, privacy: .public) \(pathSuffix, privacy: .public) address \(walletAddress, privacy: .private) paged \(pageParams != nil, privacy: .public)"
    )
    return request
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
    try AlchemyResponseValidator.validate(response: response, stage: stage, logger: logger)
    return data
  }
}
```

> `AlchemyResponseValidator.validate` maps 401/403 → `.invalidApiKey`. Blockscout never returns those for the public unauthenticated API; 429 → `.rateLimited`, other non-2xx → `.network`. Reusing it keeps status handling identical to Alchemy; do not fork it.

- [ ] **Step 4: Run to verify pass**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac LiveBlockscoutClientTests 2>&1 | tee "$WT/.agent-tmp/t3.txt"`
Expected: PASS (all 5).

- [ ] **Step 5: Format, generate, build (warnings = errors), commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t3-build.txt"
git -C "$WT" add -A
git -C "$WT" commit -m "feat(crypto): LiveBlockscoutClient (no-key public API, paginated)

Refs #918, #919.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `BlockscoutTransferAdapter` + `SignedGasTx`

**Files:**
- Create: `Shared/CryptoImport/BlockscoutTransferAdapter.swift`
- Create (test, first): `MoolahTests/Shared/CryptoImport/BlockscoutTransferAdapterTests.swift`

Pure, `Sendable`, fully unit-tested. Converts Blockscout rows → `[AlchemyTransfer]` (categories `.external`/`.internal`, Alchemy-format `uniqueId`s so downstream merge/dedup is unchanged) + `[SignedGasTx]` (every `from == wallet` tx, the authoritative gas set — fixes #919).

- [ ] **Step 1: Write failing adapter tests**

```swift
// MoolahTests/Shared/CryptoImport/BlockscoutTransferAdapterTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("BlockscoutTransferAdapter")
struct BlockscoutTransferAdapterTests {
  private let wallet = "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60"

  private func tx(
    hash: String, from: String, to: String?, value: String,
    block: Int = 100, success: Bool = true
  ) -> BlockscoutTransaction {
    BlockscoutTransaction(
      hash: hash, blockNumber: block,
      timestamp: "2024-09-12T12:34:56.000000Z",
      from: .init(hash: from), to: to.map { .init(hash: $0) },
      value: value, status: success ? "ok" : "error",
      result: success ? "success" : "reverted")
  }

  private func itx(
    parent: String, from: String, to: String?, value: String, index: Int
  ) -> BlockscoutInternalTx {
    BlockscoutInternalTx(
      transactionHash: parent, blockNumber: 100,
      timestamp: "2024-09-12T12:34:56.000000Z",
      from: .init(hash: from), to: to.map { .init(hash: $0) },
      value: value, index: index, success: true)
  }

  @Test
  func outboundValueTxBecomesExternalTransferAndSignedGasTx() {
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [tx(hash: "0xH1", from: wallet, to: "0xDEF", value: "1000000000000000000")],
      internalTxs: [],
      walletAddress: wallet,
      chain: .ethereum)
    let t = try! #require(result.transfers.first)
    #expect(result.transfers.count == 1)
    #expect(t.category == .external)
    #expect(t.uniqueId == "0xH1:external:0")
    #expect(t.from.lowercased() == wallet)
    #expect(t.to == "0xDEF")
    #expect(t.rawContract.address == nil)
    #expect(t.rawContract.rawValue == "0xde0b6b3a7640000")  // 1e18 wei
    #expect(t.blockNum == "0x64")  // 100
    #expect(t.metadata.blockTimestamp == "2024-09-12T12:34:56.000000Z")
    #expect(result.signedGasTxs.map(\.hash) == ["0xH1"])
  }

  @Test
  func zeroValueApproveYieldsNoTransferButIsSignedGasTx() {  // #919
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [tx(hash: "0xAP", from: wallet, to: "0xTOKEN", value: "0")],
      internalTxs: [],
      walletAddress: wallet,
      chain: .optimism)
    #expect(result.transfers.isEmpty)
    #expect(result.signedGasTxs.count == 1)
    #expect(result.signedGasTxs.first?.hash == "0xAP")
  }

  @Test
  func failedTxStillCountsAsSignedGasTx() {  // #919
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [tx(hash: "0xFA", from: wallet, to: "0xC", value: "0", success: false)],
      internalTxs: [],
      walletAddress: wallet,
      chain: .base)
    #expect(result.transfers.isEmpty)
    #expect(result.signedGasTxs.map(\.hash) == ["0xFA"])
  }

  @Test
  func inboundValueTxIsExternalTransferButNotSignedGasTx() {
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [tx(hash: "0xIN", from: "0xSENDER", to: wallet, value: "5")],
      internalTxs: [],
      walletAddress: wallet,
      chain: .ethereum)
    #expect(result.transfers.first?.category == .external)
    #expect(result.transfers.first?.to?.lowercased() == wallet)
    #expect(result.signedGasTxs.isEmpty)  // wallet did not sign
  }

  @Test
  func internalCreditBecomesInternalTransfer() {  // #918
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [],
      internalTxs: [itx(parent: "0xP", from: "0xROUTER", to: wallet, value: "777", index: 3)],
      walletAddress: wallet,
      chain: .optimism)
    let t = try! #require(result.transfers.first)
    #expect(t.category == .internal)
    #expect(t.hash == "0xP")
    #expect(t.uniqueId == "0xP:internal:3")
    #expect(t.to?.lowercased() == wallet)
    #expect(result.signedGasTxs.isEmpty)
  }

  @Test
  func multipleInternalMovesInOneParentGetDistinctIds() {
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [],
      internalTxs: [
        itx(parent: "0xP", from: "0xR", to: wallet, value: "1", index: 0),
        itx(parent: "0xP", from: "0xR", to: wallet, value: "2", index: 1),
      ],
      walletAddress: wallet,
      chain: .optimism)
    #expect(Set(result.transfers.map(\.uniqueId)) == ["0xP:internal:0", "0xP:internal:1"])
  }

  @Test
  func zeroValueInternalIsDropped() {
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [],
      internalTxs: [itx(parent: "0xP", from: "0xR", to: wallet, value: "0", index: 0)],
      walletAddress: wallet,
      chain: .optimism)
    #expect(result.transfers.isEmpty)
  }

  @Test
  func checksummedWalletMatchesLowercaseRows() {
    let result = BlockscoutTransferAdapter.adapt(
      nativeTxs: [tx(hash: "0xH", from: wallet.uppercased(), to: "0xD", value: "9")],
      internalTxs: [],
      walletAddress: wallet,
      chain: .ethereum)
    #expect(result.signedGasTxs.map(\.hash) == ["0xH"])
  }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac BlockscoutTransferAdapterTests 2>&1 | tee "$WT/.agent-tmp/t4.txt"`
Expected: FAIL — `cannot find 'BlockscoutTransferAdapter'`.

- [ ] **Step 3: Implement the adapter**

Create `Shared/CryptoImport/BlockscoutTransferAdapter.swift`:

```swift
// Shared/CryptoImport/BlockscoutTransferAdapter.swift
import Foundation
import OSLog

/// One signed transaction the wallet paid gas for, with the block
/// timestamp needed to date a gas-only transaction (one with no value
/// transfer of its own — `approve()`, failed, zero-movement). This is
/// the authoritative gas set that fixes #919: it includes every tx
/// where the wallet is the sender, regardless of value or status.
struct SignedGasTx: Sendable, Hashable {
  let hash: String
  let blockTimestamp: Date
}

/// Result of normalising Blockscout rows into the existing pipeline
/// model.
struct BlockscoutAdaptResult: Sendable {
  let transfers: [AlchemyTransfer]
  let signedGasTxs: [SignedGasTx]
}

/// Pure adapter: Blockscout native + internal rows → `AlchemyTransfer`s
/// (Alchemy-format `uniqueId`s so cross-account merge / per-leg dedup /
/// `externalId` indexing are reused unchanged) plus the signed-tx set.
/// Stateless and `Sendable`.
enum BlockscoutTransferAdapter {
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "BlockscoutTransferAdapter")

  /// `walletAddress` is expected pre-lowercased by the caller
  /// (`WalletSyncEngine` passes `account.walletAddress.lowercased()`),
  /// but every comparison re-lowercases defensively — Blockscout
  /// returns checksummed addresses.
  static func adapt(
    nativeTxs: [BlockscoutTransaction],
    internalTxs: [BlockscoutInternalTx],
    walletAddress rawWallet: String,
    chain: ChainConfig
  ) -> BlockscoutAdaptResult {
    let wallet = rawWallet.lowercased()
    var transfers: [AlchemyTransfer] = []
    var signed: [SignedGasTx] = []
    var seenSignedHashes: Set<String> = []

    for tx in nativeTxs {
      let from = tx.from.hash.lowercased()
      let to = tx.to?.hash.lowercased()
      // Authoritative gas set: every tx the wallet signed, regardless
      // of value / status (#919). Dedup by hash, preserve first-seen.
      if from == wallet, seenSignedHashes.insert(tx.hash).inserted {
        signed.append(
          SignedGasTx(
            hash: tx.hash,
            blockTimestamp: parseTimestamp(tx.timestamp) ?? Date(timeIntervalSince1970: 0)))
      }
      // Value leg only for non-zero transfers that touch the wallet.
      guard let weiHex = decimalStringToHexWei(tx.value), weiHex != "0x0" else { continue }
      guard from == wallet || to == wallet else { continue }
      transfers.append(
        makeTransfer(
          hash: tx.hash, uniqueId: "\(tx.hash):external:0",
          category: .external, from: tx.from.hash, to: tx.to?.hash,
          weiHex: weiHex, block: tx.blockNumber, timestamp: tx.timestamp))
    }

    for itx in internalTxs {
      let from = itx.from.hash.lowercased()
      let to = itx.to?.hash.lowercased()
      guard let weiHex = decimalStringToHexWei(itx.value), weiHex != "0x0" else { continue }
      guard from == wallet || to == wallet else { continue }
      transfers.append(
        makeTransfer(
          hash: itx.transactionHash,
          uniqueId: "\(itx.transactionHash):internal:\(itx.index)",
          category: .internal, from: itx.from.hash, to: itx.to?.hash,
          weiHex: weiHex, block: itx.blockNumber, timestamp: itx.timestamp))
    }

    return BlockscoutAdaptResult(transfers: transfers, signedGasTxs: signed)
  }

  // MARK: - Internals

  private static func makeTransfer(
    hash: String, uniqueId: String, category: AlchemyTransferCategory,
    from: String, to: String?, weiHex: String, block: Int, timestamp: String?
  ) -> AlchemyTransfer {
    AlchemyTransfer(
      hash: hash,
      uniqueId: uniqueId,
      from: from,
      to: to,
      category: category,
      asset: nil,
      rawContract: AlchemyTransfer.RawContract(
        address: nil, decimal: nil, rawValue: weiHex),
      metadata: AlchemyTransfer.Metadata(blockTimestamp: timestamp),
      blockNum: "0x" + String(UInt64(block.magnitude), radix: 16))
  }

  /// Blockscout `value` is a base-10 wei string. The builder consumes a
  /// `0x`-hex `rawValue` (`HexDecimal.parse`), so convert. Returns
  /// `"0x0"` for "0"; `nil` on non-numeric input (row logged + skipped).
  static func decimalStringToHexWei(_ decimalString: String) -> String? {
    let trimmed = decimalString.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else {
      logger.notice("Skipping Blockscout row — non-numeric value")
      return nil
    }
    if trimmed.allSatisfy({ $0 == "0" }) { return "0x0" }
    var value = Decimal(string: trimmed) ?? 0
    guard value > 0 else { return "0x0" }
    var digits = ""
    let sixteen = Decimal(16)
    while value > 0 {
      let remainder = value - (value / sixteen).rounded(.down) * sixteen
      let nibble = (remainder as NSDecimalNumber).intValue
      digits.append(Self.hexDigits[nibble])
      value = (value / sixteen).rounded(.down)
    }
    return "0x" + String(digits.reversed())
  }

  private static let hexDigits = Array("0123456789abcdef")

  /// ISO-8601 (Blockscout uses fractional seconds, e.g.
  /// `2024-09-12T12:34:56.000000Z`). Reuses the lenient policy: `nil`
  /// on unparseable input so a bad row degrades rather than fails.
  private static func parseTimestamp(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
  }
}

extension Decimal {
  /// Truncates toward zero. Local helper for the wei→hex loop; kept
  /// fileprivate-equivalent by living next to its only caller.
  fileprivate func rounded(_ rule: FloatingPointRoundingRule) -> Decimal {
    var input = self
    var result = Decimal()
    NSDecimalRound(&result, &input, 0, rule == .down ? .down : .plain)
    return result
  }
}
```

> `decimalStringToHexWei` is exercised directly by an added unit test in Step 3a below — base-10-wei→hex is the one piece of non-trivial arithmetic and the `Decimal`→`Int` footgun is real in this codebase (see memory), so it gets its own test rather than only transitive coverage.

- [ ] **Step 3a: Add a focused conversion test, run, verify pass**

Append to `BlockscoutTransferAdapterTests.swift`:

```swift
  @Test
  func decimalWeiToHexConversionIsExact() {
    #expect(BlockscoutTransferAdapter.decimalStringToHexWei("0") == "0x0")
    #expect(BlockscoutTransferAdapter.decimalStringToHexWei("1") == "0x1")
    #expect(BlockscoutTransferAdapter.decimalStringToHexWei("255") == "0xff")
    #expect(BlockscoutTransferAdapter.decimalStringToHexWei("1000000000000000000") == "0xde0b6b3a7640000")
    #expect(BlockscoutTransferAdapter.decimalStringToHexWei("abc") == nil)
    #expect(BlockscoutTransferAdapter.decimalStringToHexWei("") == nil)
  }
```

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac BlockscoutTransferAdapterTests 2>&1 | tee "$WT/.agent-tmp/t4.txt"`
Expected: PASS (all, incl. conversion).

- [ ] **Step 4: Format, generate, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" generate
git -C "$WT" add -A
git -C "$WT" commit -m "feat(crypto): BlockscoutTransferAdapter + SignedGasTx

Normalises Blockscout native/internal rows into AlchemyTransfer plus
the authoritative signed-tx set. Refs #918, #919.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `TransferEventBuilder` gas-only path (#919)

**Files:**
- Modify: `Shared/CryptoImport/TransferEventBuilder.swift`
- Modify: `Shared/CryptoImport/TransferReceiptCoalescer.swift`
- Create (test, first): `MoolahTests/Shared/CryptoImport/TransferEventBuilderGasOnlyTests.swift`

`build(...)` gains `signedGasTxs: [SignedGasTx] = []` (defaulted so the ~15 existing builder-test call sites and the engine compile unchanged until the engine is wired in Task 6). The receipt-fetch set becomes `outboundHashes ∪ signedGasTxs.hashes`. Hashes in the signed set with no transfer group emit a gas-leg-only `BuiltTransaction` dated to the signed-tx timestamp.

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Shared/CryptoImport/TransferEventBuilderGasOnlyTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransferEventBuilder — gas-only signed txs (#919)")
struct TransferEventBuilderGasOnlyTests {
  private let wallet = "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60"

  /// Reuse the existing builder test harness. `TransferEventBuilderTests`
  /// shows the canonical `BuilderServices` + `RecordingAlchemyClientStub`
  /// + discovery construction; mirror it here.
  private func services(receiptFor hash: String) -> (BuilderServices, RecordingAlchemyClientStub) {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: hash,
          gasUsed: Decimal(21_000),
          effectiveGasPrice: Decimal(1_000_000_000),
          from: wallet)),
      for: hash)
    let services = BuilderServices(
      chain: .ethereum,
      discovery: CryptoTokenDiscoveryTestDoubles.makeService(),
      alchemy: alchemy)
    return (services, alchemy)
  }

  private func account() -> Account {
    // Mirror the crypto-account factory used in TransferEventBuilderTests.
    CryptoTestSupport.cryptoAccount(walletAddress: wallet, chainId: 1)
  }

  @Test
  func gasOnlyHashWithNoTransfersEmitsGasLegOnlyTransaction() async throws {
    let (services, _) = services(receiptFor: "0xAPPROVE")
    let ts = Date(timeIntervalSince1970: 1_700_000_000)
    let built = try await TransferEventBuilder().build(
      transfers: [],  // approve() produced no Transfer
      account: account(),
      services: services,
      importOrigin: ImportOrigin.testFixture(),
      signedGasTxs: [SignedGasTx(hash: "0xAPPROVE", blockTimestamp: ts)])
    #expect(built.count == 1)
    let legs = try #require(built.first?.transaction.legs)
    #expect(legs.count == 1)
    #expect(legs.first?.externalId == "0xAPPROVE:gas")
    #expect(legs.first?.type == .expense)
    #expect((legs.first?.quantity ?? 0) < 0)
    #expect(built.first?.transaction.date == ts)
  }

  @Test
  func hashWithTransfersDoesNotGetDuplicateGasLeg() async throws {
    // A normal outbound ETH send: one transfer leg + exactly one gas leg.
    let (services, _) = services(receiptFor: "0xSEND")
    let transfer = AlchemyTransfer(
      hash: "0xSEND", uniqueId: "0xSEND:external:0",
      from: wallet, to: "0xDEF", category: .external, asset: nil,
      rawContract: .init(address: nil, decimal: nil, rawValue: "0xde0b6b3a7640000"),
      metadata: .init(blockTimestamp: "2024-09-12T12:34:56.000000Z"),
      blockNum: "0x64")
    let built = try await TransferEventBuilder().build(
      transfers: [transfer],
      account: account(),
      services: services,
      importOrigin: ImportOrigin.testFixture(),
      signedGasTxs: [SignedGasTx(hash: "0xSEND", blockTimestamp: Date())])
    #expect(built.count == 1)
    let legs = try #require(built.first?.transaction.legs)
    #expect(legs.filter { $0.externalId == "0xSEND:gas" }.count == 1)
    #expect(legs.contains { $0.externalId == "0xSEND:external:0" })
  }

  @Test
  func gasOnlyHashWhoseReceiptFailsProducesNoTransactionAndDoesNotThrow() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setReceiptResponse(.failure(WalletSyncError.network(underlyingDescription: "x")), for: "0xBAD")
    let services = BuilderServices(
      chain: .ethereum,
      discovery: CryptoTokenDiscoveryTestDoubles.makeService(),
      alchemy: alchemy)
    let built = try await TransferEventBuilder().build(
      transfers: [],
      account: account(),
      services: services,
      importOrigin: ImportOrigin.testFixture(),
      signedGasTxs: [SignedGasTx(hash: "0xBAD", blockTimestamp: Date())])
    #expect(built.isEmpty)
  }
}
```

> Before implementing, open `TransferEventBuilderGasLegTests.swift` and `TransferEventBuilderTests.swift` and copy their **exact** helpers for: the crypto `Account` factory (replace `CryptoTestSupport.cryptoAccount(...)` with whatever they use), `ImportOrigin` test value (replace `ImportOrigin.testFixture()`), discovery double (replace `CryptoTokenDiscoveryTestDoubles.makeService()`), and `RecordingAlchemyClientStub.setReceiptResponse` API. Adjust the three helpers above to match the real names — do not invent factories.

- [ ] **Step 2: Run to verify it fails**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac TransferEventBuilderGasOnlyTests 2>&1 | tee "$WT/.agent-tmp/t5.txt"`
Expected: FAIL — `extra argument 'signedGasTxs'`.

- [ ] **Step 3: Add `signedGasTxs` + the gas-only path**

In `TransferReceiptCoalescer.swift`, change `fetchReceipts` to accept extra hashes. Replace its signature and the `hashes` line:

```swift
  static func fetchReceipts(
    groups: [[AlchemyTransfer]],
    extraSignedHashes: [String] = [],
    walletAddress: String,
    chain: ChainConfig,
    alchemy: any AlchemyClient
  ) async throws -> [String: AlchemyTransactionReceipt] {
    var hashes = outboundHashes(in: groups, walletAddress: walletAddress)
    var seen = Set(hashes)
    for hash in extraSignedHashes where seen.insert(hash).inserted {
      hashes.append(hash)
    }
    guard !hashes.isEmpty else { return [:] }
```

(Keep the rest of `fetchReceipts` unchanged.)

In `TransferEventBuilder.swift`:

Change the `build` signature to add the parameter (defaulted):

```swift
  func build(
    transfers: [AlchemyTransfer],
    account: Account,
    services: BuilderServices,
    importOrigin: ImportOrigin,
    signedGasTxs: [SignedGasTx] = []
  ) async throws -> [BuiltTransaction] {
```

Replace the `fetchReceipts` call to pass the signed hashes:

```swift
    let receipts = try await TransferReceiptCoalescer.fetchReceipts(
      groups: groups,
      extraSignedHashes: signedGasTxs.map(\.hash),
      walletAddress: context.walletAddress,
      chain: chain,
      alchemy: alchemy)
```

After the existing `for events in groups { … results.append(built) }` loop and before `return results`, add the gas-only path:

```swift
    // #919: every tx the wallet signed paid gas, even when it produced
    // no transfer (approve(), failed, zero-movement). Those hashes are
    // absent from `groups`; emit a transaction whose only leg is the
    // gas leg, dated to the signed-tx block timestamp.
    let groupedHashes = Set(groups.compactMap(\.first?.hash))
    for signed in signedGasTxs where !groupedHashes.contains(signed.hash) {
      try Task.checkCancellation()
      guard
        let receipt = receipts[signed.hash],
        let gasLeg = TransferReceiptCoalescer.makeGasLeg(
          receipt: receipt,
          accountId: context.account.id,
          chain: context.chain,
          walletAddress: context.walletAddress)
      else {
        continue
      }
      let transaction = Transaction(
        date: signed.blockTimestamp,
        legs: [gasLeg],
        importOrigin: context.importOrigin)
      results.append(
        BuiltTransaction(
          originAccountId: context.account.id, transaction: transaction))
    }
    return results
```

> This reuses `makeGasLeg` verbatim — its fee math (incl. #921's L1-fee summation once #921 merges) is not touched. The `receipt.from == walletAddress` guard inside `makeGasLeg` still holds: Blockscout's signed set is `from == wallet`, so the receipt's signer is the wallet.

- [ ] **Step 4: Run the new suite + the full builder regression suite**

Run:
```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransferEventBuilderGasOnlyTests TransferEventBuilderGasLegTests TransferEventBuilderGasCoalescingTests TransferEventBuilderGasAttributionTests TransferEventBuilderTests 2>&1 | tee "$WT/.agent-tmp/t5.txt"
```
Expected: PASS — new suite green, no regression in the existing builder/gas suites (default `signedGasTxs: []` preserves prior behaviour).

- [ ] **Step 5: Format, generate, build, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t5-build.txt"
git -C "$WT" add -A
git -C "$WT" commit -m "feat(crypto): gas-leg-only path for signed txs with no transfer (#919)

TransferEventBuilder.build gains signedGasTxs; receipt set unions the
signed-tx hashes; hashes with no transfer group emit a gas-leg-only
transaction dated to the block timestamp. makeGasLeg reused unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Wire Blockscout into `WalletSyncEngine` (#918 + #919 end-to-end)

**Files:**
- Modify: `Shared/CryptoImport/WalletSyncEngine.swift`
- Modify: `MoolahTests/Shared/CryptoImport/WalletSyncTestDoubles.swift` (add `RecordingBlockExplorerClientStub` + a shared empty default)
- Modify: `MoolahTests/Shared/CryptoImport/WalletSyncEngineTests.swift` (new behaviour)
- Modify (compile-fix, exact list in Step 5): the 6 `WalletSyncEngine(` test call sites

`WalletSyncEngine` gains `blockExplorer: any BlockExplorerClient` (no default — explicit injection everywhere). Flow: Blockscout native+internal → adapter → native rows + `signedGasTxs`; Alchemy transfers filtered to `.erc20`; merge; build with `signedGasTxs`. Blockscout failure propagates as `WalletSyncError` (no fallback).

- [ ] **Step 1: Add the test double**

Append to `WalletSyncTestDoubles.swift`:

```swift
/// Scriptable `BlockExplorerClient` stub. Mirrors
/// `RecordingAlchemyClientStub`'s lock-protected `@unchecked Sendable`
/// shape. Defaults to empty results so engine tests that don't care
/// about Blockscout compile and exercise the Alchemy-only shape.
final class RecordingBlockExplorerClientStub: BlockExplorerClient, @unchecked Sendable {
  enum NativeResponse: Sendable {
    case txs([BlockscoutTransaction])
    case failure(any Error)
  }
  enum InternalResponse: Sendable {
    case txs([BlockscoutInternalTx])
    case failure(any Error)
  }

  private let lock = NSLock()
  private var native: NativeResponse = .txs([])
  private var internalTx: InternalResponse = .txs([])

  func setNative(_ r: NativeResponse) { lock.withLock { self.native = r } }
  func setInternal(_ r: InternalResponse) { lock.withLock { self.internalTx = r } }

  func nativeTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutTransaction] {
    switch lock.withLock({ native }) {
    case .txs(let t): return t
    case .failure(let e): throw e
    }
  }

  func internalTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutInternalTx] {
    switch lock.withLock({ internalTx }) {
    case .txs(let t): return t
    case .failure(let e): throw e
    }
  }
}

/// Shared empty Blockscout stub for engine-construction sites that
/// don't exercise the Blockscout path.
enum BlockExplorerTestDoubles {
  static var empty: RecordingBlockExplorerClientStub { RecordingBlockExplorerClientStub() }
}
```

- [ ] **Step 2: Write failing engine tests**

Add to `WalletSyncEngineTests.swift` (mirror its existing engine-construction helper — read the file's `WalletSyncEngine(` site at line 23 and reuse its exact discovery / state / importOrigin args; only add `blockExplorer:`):

```swift
  @Test
  func filtersAlchemyToErc20AndSourcesNativeFromBlockscout() async throws {
    let wallet = "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60"
    let alchemy = RecordingAlchemyClientStub()
    // Alchemy returns an external native row that MUST be dropped
    // (Blockscout owns native) and an erc20 row that MUST be kept.
    alchemy.setTransfersResponse(.transfers([
      AlchemyTransfer(
        hash: "0xNAT", uniqueId: "0xNAT:external:0", from: wallet, to: "0xD",
        category: .external, asset: nil,
        rawContract: .init(address: nil, decimal: nil, rawValue: "0x1"),
        metadata: .init(blockTimestamp: "2024-09-12T12:00:00.000000Z"), blockNum: "0x64"),
      AlchemyTransfer(
        hash: "0xERC", uniqueId: "0xERC:erc20:0", from: "0xS", to: wallet,
        category: .erc20, asset: "USDC",
        rawContract: .init(address: "0xtoken", decimal: "0x6", rawValue: "0xf4240"),
        metadata: .init(blockTimestamp: "2024-09-12T12:00:00.000000Z"), blockNum: "0x65"),
    ]))
    let blockscout = RecordingBlockExplorerClientStub()
    blockscout.setNative(.txs([
      BlockscoutTransaction(
        hash: "0xNAT", blockNumber: 100, timestamp: "2024-09-12T12:00:00.000000Z",
        from: .init(hash: wallet), to: .init(hash: "0xD"),
        value: "1", status: "ok", result: "success"),
    ]))
    let engine = makeEngine(alchemy: alchemy, blockExplorer: blockscout)  // see helper note
    let result = try await engine.build(
      account: cryptoAccount(wallet: wallet, chainId: 1), chain: .ethereum)
    let externalIds = result.candidates.flatMap { $0.transaction.legs.map(\.externalId) }
    #expect(externalIds.contains("0xERC:erc20:0"))  // Alchemy ERC-20 kept
    #expect(externalIds.contains("0xNAT:external:0"))  // native from Blockscout, not Alchemy
    // Exactly one native external leg for 0xNAT (no double-count).
    #expect(externalIds.filter { $0 == "0xNAT:external:0" }.count == 1)
  }

  @Test
  func blockscoutFailurePropagatesAsWalletSyncError() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let blockscout = RecordingBlockExplorerClientStub()
    blockscout.setNative(.failure(WalletSyncError.network(underlyingDescription: "blockscout down")))
    let engine = makeEngine(alchemy: alchemy, blockExplorer: blockscout)
    await #expect(throws: WalletSyncError.self) {
      _ = try await engine.build(
        account: cryptoAccount(wallet: "0xabc", chainId: 1), chain: .ethereum)
    }
  }
```

> Add a private `makeEngine(alchemy:blockExplorer:)` helper to this suite that constructs `WalletSyncEngine` using the file's existing dependency args plus the new `blockExplorer:`. Reuse the suite's existing crypto-account factory for `cryptoAccount(...)`.

- [ ] **Step 3: Run to verify it fails**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac WalletSyncEngineTests 2>&1 | tee "$WT/.agent-tmp/t6.txt"`
Expected: FAIL — `extra argument 'blockExplorer'` / missing member.

- [ ] **Step 4: Wire the engine**

In `WalletSyncEngine.swift`:

Add the stored property + init param:

```swift
  private let alchemy: any AlchemyClient
  private let blockExplorer: any BlockExplorerClient
```

```swift
  init(
    alchemy: any AlchemyClient,
    blockExplorer: any BlockExplorerClient,
    discovery: CryptoTokenDiscoveryService,
    walletSyncState: any WalletSyncStateRepository,
    importOriginFactory: @Sendable @escaping (UUID) -> ImportOrigin
  ) {
    self.alchemy = alchemy
    self.blockExplorer = blockExplorer
    self.discovery = discovery
    self.walletSyncState = walletSyncState
    self.importOriginFactory = importOriginFactory
  }
```

Replace step 3 ("Fetch transfers") and step 4/5 in `build(...)` with:

```swift
    // 3. Native + internal ETH from Blockscout (authoritative tx index;
    //    sees approve()/failed/zero-movement #919 and OP-stack internal
    //    transfers #918). A failure here is a sync error for this
    //    account — it propagates to CryptoSyncStore's persistError.
    try Task.checkCancellation()
    let blockscoutNative = try await blockExplorer.nativeTransactions(
      chain: chain, walletAddress: walletAddress, fromBlock: fromBlock)
    let blockscoutInternal = try await blockExplorer.internalTransactions(
      chain: chain, walletAddress: walletAddress, fromBlock: fromBlock)
    let adapted = BlockscoutTransferAdapter.adapt(
      nativeTxs: blockscoutNative,
      internalTxs: blockscoutInternal,
      walletAddress: walletAddress.lowercased(),
      chain: chain)

    // 3b. ERC-20 only from Alchemy — Blockscout owns native/internal.
    try Task.checkCancellation()
    let alchemyAll = try await alchemy.getAssetTransfers(
      chain: chain, walletAddress: walletAddress, fromBlock: fromBlock)
    let erc20 = alchemyAll.filter { $0.category == .erc20 }
    let transfers = adapted.transfers + erc20
    try Task.checkCancellation()

    // 4. Head block over the merged set (Blockscout blockNum included).
    let headBlock = Self.maxBlockNumber(in: transfers) ?? priorBlock
```

Update the `builder.build(...)` call to pass `signedGasTxs`:

```swift
    let built = try await builder.build(
      transfers: transfers,
      account: account,
      services: BuilderServices(
        chain: chain, discovery: discovery, alchemy: alchemy),
      importOrigin: importOrigin,
      signedGasTxs: adapted.signedGasTxs)
```

(The "builder dropped all transfers" warning block below stays as-is but now also misses the gas-only case; leave it unchanged — it is still a valid wire-regression signal for the merged set.)

- [ ] **Step 5: Fix the 6 engine-construction call sites**

Each of these constructs `WalletSyncEngine(alchemy:discovery:walletSyncState:importOriginFactory:)`. Add `blockExplorer: BlockExplorerTestDoubles.empty,` immediately after the `alchemy:` argument in each:

- `MoolahTests/Features/Settings/CryptoSettingsAccountsListTests.swift:44`
- `MoolahTests/Features/Crypto/CryptoSyncStoreTests.swift:59`
- `MoolahTests/Features/Crypto/CryptoSyncPipelineStructureTests.swift:44`
- `MoolahTests/Features/Crypto/CryptoSyncStoreGlobalErrorTests.swift:39`
- `MoolahTests/Features/Crypto/CryptoAccountCreationStoreTests.swift:42`
- `MoolahTests/Shared/CryptoImport/WalletSyncEngineTests.swift:23` (the suite's own existing helper — fold into the `makeEngine` helper from Step 2)

Concretely, each becomes:

```swift
    let walletSyncEngine = WalletSyncEngine(
      alchemy: <existing alchemy arg unchanged>,
      blockExplorer: BlockExplorerTestDoubles.empty,
      discovery: <existing unchanged>,
      walletSyncState: <existing unchanged>,
      importOriginFactory: <existing unchanged>)
```

Read each file's current call to copy the existing argument expressions verbatim; only insert the one new line.

- [ ] **Step 6: Run the affected suites**

Run:
```bash
just -d "$WT" --justfile "$WT/justfile" test-mac WalletSyncEngineTests CryptoSyncStoreTests CryptoSyncPipelineStructureTests CryptoSyncStoreGlobalErrorTests CryptoAccountCreationStoreTests CryptoSettingsAccountsListTests 2>&1 | tee "$WT/.agent-tmp/t6.txt"
```
Expected: PASS across all.

- [ ] **Step 7: Format, generate, build, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t6-build.txt"
git -C "$WT" add -A
git -C "$WT" commit -m "feat(crypto): source native ETH from Blockscout in WalletSyncEngine

Blockscout native+internal → adapter; Alchemy filtered to ERC-20;
signedGasTxs threaded to the builder. Blockscout failure = per-account
sync error (no fallback). Fixes #918, #919.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: App wiring + end-to-end store-level test

**Files:**
- Modify: `App/ProfileSession+CryptoSync.swift`
- Create (test, first): `MoolahTests/Features/Crypto/BlockscoutNativeBalanceIntegrationTests.swift`

- [ ] **Step 1: Write the failing end-to-end test**

This test drives `WalletSyncEngine` + `WalletApplyEngine` against `TestBackend` (read `WalletApplyEngineTests.swift` for the exact `TestBackend`/apply wiring and reuse it verbatim — do not invent backend setup) and asserts the native balance equals the real total after an internal credit (#918) and an `approve()` gas-only tx (#919).

```swift
// MoolahTests/Features/Crypto/BlockscoutNativeBalanceIntegrationTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("Blockscout native balance — #918 + #919 end-to-end")
struct BlockscoutNativeBalanceIntegrationTests {
  @Test
  func internalCreditAndApproveGasAreBothReflectedInNativeBalance() async throws {
    let wallet = "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60"
    // 1 ETH inbound external + 0.5 ETH internal credit (#918) + an
    // approve() that paid gas (#919). Expected native balance =
    // 1.0 + 0.5 − gas(21000 * 1 gwei = 2.1e-5 ETH).
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))  // no ERC-20
    alchemy.setReceiptResponse(
      .receipt(AlchemyTransactionReceipt(
        hash: "0xAPPROVE", gasUsed: Decimal(21_000),
        effectiveGasPrice: Decimal(1_000_000_000), from: wallet)),
      for: "0xAPPROVE")
    let blockscout = RecordingBlockExplorerClientStub()
    blockscout.setNative(.txs([
      BlockscoutTransaction(
        hash: "0xIN", blockNumber: 100, timestamp: "2024-09-12T12:00:00.000000Z",
        from: .init(hash: "0xSENDER"), to: .init(hash: wallet),
        value: "1000000000000000000", status: "ok", result: "success"),
      BlockscoutTransaction(
        hash: "0xAPPROVE", blockNumber: 101, timestamp: "2024-09-12T12:05:00.000000Z",
        from: .init(hash: wallet), to: .init(hash: "0xTOKEN"),
        value: "0", status: "ok", result: "success"),
    ]))
    blockscout.setInternal(.txs([
      BlockscoutInternalTx(
        transactionHash: "0xP", blockNumber: 102,
        timestamp: "2024-09-12T12:10:00.000000Z",
        from: .init(hash: "0xROUTER"), to: .init(hash: wallet),
        value: "500000000000000000", index: 0, success: true),
    ]))

    // --- reuse WalletApplyEngineTests' TestBackend + apply harness ---
    // Build with the engine, apply, then read the account's native
    // ETH balance from the repository and assert it equals
    //   1.0 + 0.5 − 0.000021  (in ETH), within leg quantisation.
    // (Fill in using the exact helpers from WalletApplyEngineTests.)
  }
}
```

> The arithmetic body must be completed using `WalletApplyEngineTests`'s real `TestBackend` construction, `WalletApplyEngine.apply` call, and the repository balance read it already uses. The assertion target: native ETH = `1.5 - (21000 * 1e9 / 1e18)` = `1.499979` ETH. Use the same `Decimal`/instrument-sum helper that suite uses; do not introduce a new aggregation.

- [ ] **Step 2: Run to verify it fails**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac BlockscoutNativeBalanceIntegrationTests 2>&1 | tee "$WT/.agent-tmp/t7.txt"`
Expected: FAIL (compile error until the body is filled, then a real assertion).

- [ ] **Step 3: Complete the test body, then wire the app**

Complete the test body per the note. Then wire production in `App/ProfileSession+CryptoSync.swift`:

After the `let alchemy: any AlchemyClient = LiveAlchemyClient(...)` block, add:

```swift
    // Blockscout public API needs no key. Its public instances are
    // rate-limited around 5 req/s — a dedicated limiter, separate from
    // Alchemy's 25, keeps incremental sync within budget.
    let blockExplorer: any BlockExplorerClient = LiveBlockscoutClient(
      rateLimiter: RateLimiter(permitsPerSecond: 5))
```

Update the `WalletSyncEngine(` construction to inject it:

```swift
    let walletSyncEngine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: blockExplorer,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      importOriginFactory: importOriginFactory)
```

- [ ] **Step 4: Run the integration test + the wiring's compile**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac BlockscoutNativeBalanceIntegrationTests 2>&1 | tee "$WT/.agent-tmp/t7.txt"`
Expected: PASS — native balance matches the expected real total.

- [ ] **Step 5: Format, generate, build, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/t7-build.txt"
git -C "$WT" add -A
git -C "$WT" commit -m "feat(crypto): wire LiveBlockscoutClient into ProfileSession; e2e test

Closes #918, #919.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Optional live Blockscout smoke tests (network-gated)

**Files:**
- Create: `MoolahTests/Shared/CryptoImport/LiveBlockscoutClientNetworkTests.swift`

Mirror the existing opt-in pattern used by the `LiveAlchemyClient*Tests` for real network calls (check whether those suites are unconditionally run or env-gated; replicate exactly — do **not** add an unconditional network test that would make CI flaky).

- [ ] **Step 1: Inspect the existing live-network gating**

Read `LiveAlchemyClientReceiptTests.swift` / `LiveAlchemyClientPaginationTests.swift`. Determine the gating mechanism (env var, `.disabled`, trait). Document it inline in the new file's header comment.

- [ ] **Step 2: Add gated smoke tests**

One test per chain (`.ethereum`, `.optimism`, `.base`) calling `LiveBlockscoutClient().nativeTransactions(...)` against the public instance for a known-active address and asserting non-empty decode. Use the same gating trait as the Alchemy live suites so default `just test` does not hit the network.

- [ ] **Step 3: Run gated (enabled) once locally to confirm real endpoints decode**

Run with the gate enabled (per Step 1's mechanism), capture to `.agent-tmp/t8.txt`. Expected: PASS against real Blockscout. Then run default `just test-mac` and confirm the suite is skipped.

- [ ] **Step 4: Format, generate, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" generate
git -C "$WT" add -A
git -C "$WT" commit -m "test(crypto): opt-in live Blockscout smoke tests (network-gated)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Full verification, review agents, PR

- [ ] **Step 1: Full format-check + full test suite**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" format-check 2>&1 | tee "$WT/.agent-tmp/fmt.txt"
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" test 2>&1 | tee "$WT/.agent-tmp/full-test.txt"
grep -i 'failed\|error:' "$WT/.agent-tmp/full-test.txt" || echo "clean"
```
Expected: `format-check` exits 0; full suite (iOS sim + macOS) green. Fix any SwiftLint violation by restructuring code — never by editing `.swiftlint-baseline.yml`.

- [ ] **Step 2: Compiler-warning check**

`mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` (or scan the build log). All user-code warnings must be zero (`SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`).

- [ ] **Step 3: Review agents**

Run `@code-review` and `@concurrency-review` on the changed Swift files (new client is `Sendable`, runs in the parallel build path — concurrency review is load-bearing). Apply all findings (Critical/Important/Minor) per project policy; do not dismiss.

- [ ] **Step 4: Push + open PR**

```bash
git -C "$WT" push origin worktree-fix-blockscout-native-eth:worktree-fix-blockscout-native-eth
gh pr create --repo ajsutton/moolah-native --base main \
  --head worktree-fix-blockscout-native-eth \
  --title "fix(crypto): source native ETH from Blockscout (#918, #919)" \
  --body "$(cat <<'EOF'
## Summary

Fixes #918 (contract-internal ETH transfers invisible on OP-stack) and
#919 (gas leg dropped for zero-movement signed txs). Native-ETH
enumeration moves to Blockscout's public API (a real transaction +
internal-transfer index); Alchemy is retained for ERC-20 transfers,
token discovery, and `eth_getTransactionReceipt` (gas amount, incl.
#921's L1-fee logic, reused unchanged). Polygon removed from
`ChainConfig` (no first-party public Blockscout instance). No plug
legs — every leg is a real tx/internal-transfer/gas record.

Design: `plans/2026-05-16-blockscout-native-eth-provider-design.md`

## Testing

Full `just test` green (iOS sim + macOS); new wire-decode, adapter,
client, builder gas-only, engine, and end-to-end balance suites;
opt-in live Blockscout smoke tests. `@code-review` + `@concurrency-review`
findings applied.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: Add the PR to the merge queue**

Per project policy, every PR lands via the merge-queue skill (not manual merge). Hand off the PR number to the `merge-queue` skill.

---

## Self-Review

**Spec coverage:**
- `BlockExplorerClient`/`LiveBlockscoutClient` (spec §1) → Task 3.
- `ChainConfig.blockscoutAPIBaseURL` + Polygon removal (spec §2, decision 3) → Task 1.
- `BlockscoutTransferAdapter` + `SignedGasTx` (spec §3) → Task 4.
- Builder gas-only path + receipt-set union (spec §4, #919) → Task 5.
- Engine wiring, ERC-20 filter, no-fallback error (spec §5, decisions 2 & 4) → Task 6.
- App wiring (spec §6) → Task 7.
- Idempotency/merge/reorg (spec §7) → covered by reusing Alchemy-format `uniqueId`s (Task 4) + existing dedup (no change) + the client's `fromBlock` early-stop (Task 3); end-to-end asserted in Task 7.
- Testing matrix (spec §Testing) → Tasks 2–8.
- #921 composition (spec §Risks) → Task 5 reuses `makeGasLeg` unchanged; no fee-math edits anywhere.

**Placeholder scan:** Task 7 Step 1 intentionally defers the arithmetic body to the real `WalletApplyEngineTests` harness (with the exact expected value `1.499979` ETH and explicit instruction to reuse, not invent) — this is a "read the existing harness and reuse it" instruction, not an unspecified TODO; acceptable because inventing a parallel apply/aggregation harness would contradict the project's "never mock the repository" rule. All other steps contain complete code.

**Type consistency:** `BlockscoutTransactionsPage`/`BlockscoutInternalTxPage`/`BlockscoutPageParams`/`BlockscoutAddress`/`BlockscoutTransaction`/`BlockscoutInternalTx` (Task 2) are the exact types consumed in Tasks 3/4/6/7. `BlockExplorerClient` method names `nativeTransactions`/`internalTransactions` consistent across Tasks 3/6/Stub. `SignedGasTx(hash:blockTimestamp:)` and `BlockscoutAdaptResult(transfers:signedGasTxs:)` (Task 4) consumed identically in Tasks 5/6. `BlockscoutTransferAdapter.adapt(nativeTxs:internalTxs:walletAddress:chain:)` signature identical in all call sites. `TransferReceiptCoalescer.fetchReceipts(groups:extraSignedHashes:walletAddress:chain:alchemy:)` and `TransferEventBuilder.build(...,signedGasTxs:)` consistent Task 5 ↔ Task 6.
