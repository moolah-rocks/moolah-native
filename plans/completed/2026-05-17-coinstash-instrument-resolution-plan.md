# Coinstash Instrument Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve Coinstash crypto legs to the correct chain-pinned `Instrument` using Coinstash's `getCoinBySymbol` token metadata through the existing crypto discovery path, fixing the spam-OP mis-resolution.

**Architecture:** A neutral `ExchangeAssetMetadataResolving` seam returns `(symbol, name, [chainId, contractAddress, decimals])` per token. `CoinstashClient` implements it via a `getCoinBySymbol` GraphQL query (collapsing the native-ETH sentinel and Coinstash's `Chain` enum to EVM chain ids). `ExchangeSyncEngine` picks a canonical chain (Ethereum-preferred), registers via the (generalised) `CryptoTokenDiscoveryService`, with an explicit BTC short-circuit and a non-spam registry fallback for tokens with no usable EVM metadata.

**Tech Stack:** Swift 6, Swift Testing (`@Suite`/`@Test`), GraphQL over `URLSession`, GRDB. Build/test via `just`.

**Spec:** `plans/2026-05-17-coinstash-instrument-resolution-design.md`. Fuzzy cross-account transfer detection is out of scope (deferred to [#928](https://github.com/ajsutton/moolah-native/issues/928)).

**Conventions (apply to every task):**
- TDD: write the failing test first, watch it fail, implement, watch it pass, commit.
- Tests use Swift Testing (`import Testing`, `@testable import Moolah`, `@Suite`, `@Test`, `#expect`, `#require`) — never XCTest. One protocol conformance per `extension`.
- Run tests with `just test-mac <ClassName>` and capture output: `mkdir -p .agent-tmp && just test-mac <Filter> 2>&1 | tee .agent-tmp/test-output.txt`, then `grep -i 'failed\|error:' .agent-tmp/test-output.txt`. Delete the temp file when done.
- Before every commit: `just format` then `just format-check`. Never edit `.swiftlint-baseline.yml`.
- Use `git -C <repo> ...` form is not needed here (commands run from the worktree root) — plain `git add`/`git commit` from the worktree is correct.
- Commit messages: imperative, with the `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer.

---

## File Structure

**Create:**
- `Shared/Exchange/ExchangeAssetMetadata.swift` — neutral metadata value type + `ExchangeAssetMetadataResolving` protocol.
- `Shared/Exchange/CoinstashAssetMetadataResolver.swift` — token-bound adapter wrapping `CoinstashClient` + bearer token.
- `MoolahTests/Shared/Exchange/CoinstashCoinMetadataTests.swift` — GraphQL decode + Coinstash→neutral mapping tests.
- `MoolahTests/Shared/Exchange/ExchangeSyncEngineResolutionTests.swift` — canonical selection / BTC / native / fallback / transient tests.

**Modify:**
- `Shared/CryptoImport/CryptoTokenDiscoveryService.swift` — add `resolveOrLoad(chainId:contractAddress:symbol:name:decimals:)` overload; make Alchemy spam step conditional on `ChainConfig`.
- `Shared/Exchange/CoinstashGraphQL.swift` — add `coinBySymbolQuery` + Codable models.
- `Shared/Exchange/CoinstashClient.swift` — implement `coinMetadata(symbol:token:)` (query + Chain→chainId table + sentinel collapse).
- `Shared/Exchange/ExchangeInstrumentResolver.swift` — replace symbol-only scan with `fiatInstrument` accessor + `fallbackInstrument(forSymbol:)` (non-spam → priced → used → id).
- `Shared/Exchange/ExchangeSyncEngine.swift` — orchestrate resolution (BTC table → metadata → canonical → discovery → fallback); new `discovery` dependency; `build` gains `metadata:` param.
- `Shared/Exchange/CoinstashSyncSource.swift` — build the token-bound metadata resolver, pass into `engine.build`.
- `Domain/Repositories/TransactionRepository.swift` — add `distinctLegInstrumentIds()`.
- `Backends/GRDB/Repositories/GRDBTransactionRepository+ExternalIdLookup.swift` — implement `distinctLegInstrumentIds()` (DISTINCT query).
- `App/ProfileSession+CryptoSync.swift` — thread `discovery` + existing-leg lookup into the exchange wiring.

---

## Task 1: Generalise `CryptoTokenDiscoveryService.resolveOrLoad` to a chain id

**Files:**
- Modify: `Shared/CryptoImport/CryptoTokenDiscoveryService.swift`
- Test: `MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryServiceTests.swift`

The existing `resolveOrLoad(chain: ChainConfig, ...)` and private `performResolution(chain: ChainConfig, ...)` require a `ChainConfig`, used only for `fetchSpamFlag` (Alchemy). Add a `chainId: Int` entry point that derives `ChainConfig.config(for:)` and skips the Alchemy spam step when there is no config (CoinGecko-by-contract still resolves pricing for those chains). Keep the existing `chain:` API delegating to it so wallet-import call sites are unchanged.

- [ ] **Step 1: Write the failing test**

Add to `CryptoTokenDiscoveryServiceTests.swift` (reuse the suite's existing `CountingRegistrationResolver` / Alchemy stub setup pattern already in that file; mirror an existing test's construction of the service):

```swift
@Test
func resolveByChainIdWithoutChainConfigSkipsAlchemyAndRegisters() async throws {
  let registry = StubInstrumentRegistry()
  let resolver = CountingRegistrationResolver()
  resolver.setDefault(.success(coingecko: "usd-coin", cryptocompare: nil, binance: nil))
  let alchemy = CountingAlchemyClient()  // existing stub in this test file's doubles
  let service = CryptoTokenDiscoveryService(
    registry: registry, resolver: resolver, alchemy: alchemy)

  // Arbitrum (chain 42161) has no ChainConfig.
  let registration = try await service.resolveOrLoad(
    chainId: 42161,
    contractAddress: "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8",
    symbol: "USDC",
    name: "USDC",
    decimals: 6)

  #expect(registration.instrument.id == "42161:0xff970a61a04b1ca14834a43f5de4533ebddb5cc8")
  #expect(registration.instrument.decimals == 6)
  #expect(registration.pricingStatus == .priced)
  #expect(alchemy.getTokenMetadataCallCount == 0)  // spam step skipped: no ChainConfig
  let snap = registry.snapshot()
  #expect(snap.registeredCryptos.contains { $0.id == registration.instrument.id })
}
```

If the Alchemy stub in this file does not already expose a `getTokenMetadataCallCount`, add a thread-safe counter to that existing stub (it follows the lock-bracket pattern) — do not create a new stub class.

- [ ] **Step 2: Run test to verify it fails**

Run: `mkdir -p .agent-tmp && just test-mac CryptoTokenDiscoveryServiceTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: FAIL — `resolveOrLoad(chainId:...)` does not exist (compile error).

- [ ] **Step 3: Implement the chain-id overload and conditional spam step**

In `CryptoTokenDiscoveryService.swift`, change the public entry point and `performResolution` to key off `chainId: Int` plus an optional `ChainConfig`. Add this overload and refactor `performResolution`:

```swift
/// Resolve/register by raw EVM chain id. Derives `ChainConfig` when the
/// chain is one the wallet importer supports (Ethereum/OP/Base) so the
/// Alchemy spam check still runs; for other CoinGecko-priced EVM chains
/// no `ChainConfig` exists, so the spam check is skipped (Alchemy has no
/// network slug for them) and pricing still resolves by contract.
func resolveOrLoad(
  chainId: Int,
  contractAddress: String?,
  symbol: String,
  name: String,
  decimals: Int
) async throws -> CryptoRegistration {
  let id = Instrument.crypto(
    chainId: chainId, contractAddress: contractAddress,
    symbol: symbol, name: name, decimals: decimals).id
  if let existing = try await registry.cryptoRegistration(byId: id) { return existing }
  if let task = inFlight[id] { return try await task.value }

  let task = Task<CryptoRegistration, Error> { [self] in
    try await performResolution(
      chainId: chainId,
      chain: ChainConfig.config(for: chainId),
      contractAddress: contractAddress,
      symbol: symbol,
      name: name,
      decimals: decimals)
  }
  inFlight[id] = task
  do {
    let result = try await task.value
    inFlight[id] = nil
    return result
  } catch {
    inFlight[id] = nil
    throw error
  }
}
```

Change the existing `resolveOrLoad(chain:...)` body to delegate:

```swift
func resolveOrLoad(
  chain: ChainConfig,
  contractAddress: String?,
  symbol: String,
  name: String,
  decimals: Int
) async throws -> CryptoRegistration {
  try await resolveOrLoad(
    chainId: chain.chainId,
    contractAddress: contractAddress,
    symbol: symbol,
    name: name,
    decimals: decimals)
}
```

Change `performResolution`'s signature to `performResolution(chainId: Int, chain: ChainConfig?, contractAddress: String?, symbol: String, name: String, decimals: Int)`. Inside it, replace every `chain.chainId` with `chainId`, build the instrument with `chainId`, and gate the spam lookup:

```swift
let isSpam: Bool
if let chain, let contractAddress, !isNative {
  isSpam = try await fetchSpamFlag(chain: chain, contractAddress: contractAddress)
} else {
  isSpam = false
}
```

Update the private `reResolve(_:chain:)` call into `performResolution` to pass `chainId: chain.chainId, chain: chain`. (It still receives a concrete `ChainConfig` from its caller; no behaviour change.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test-mac CryptoTokenDiscoveryServiceTests CryptoTokenDiscoveryCoalescerTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: PASS (new test + all existing discovery tests still green — the `chain:` overload is behaviourally identical for Ethereum/OP/Base).

- [ ] **Step 5: Format and commit**

```bash
just format && just format-check
git add Shared/CryptoImport/CryptoTokenDiscoveryService.swift MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryServiceTests.swift MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryTestDoubles.swift
git commit -m "$(cat <<'EOF'
feat: chain-id resolveOrLoad overload; skip Alchemy spam off-ChainConfig

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Neutral `ExchangeAssetMetadata` value type + resolver protocol

**Files:**
- Create: `Shared/Exchange/ExchangeAssetMetadata.swift`
- Test: `MoolahTests/Shared/Exchange/CoinstashCoinMetadataTests.swift`

Provider-neutral shape. `chains` is already filtered to EVM-mappable chains, native sentinel collapsed to `contractAddress == nil`, ordered as the provider listed them. `nil` from the resolver means a *definitive* "no usable EVM metadata" (BTC empty, non-EVM only, unknown symbol); a thrown error means *transient* (network/GraphQL) and must propagate so the sync retries.

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Shared/Exchange/CoinstashCoinMetadataTests.swift`:

```swift
import Testing

@testable import Moolah

@Suite("ExchangeAssetMetadata value type")
struct ExchangeAssetMetadataValueTests {
  @Test
  func chainStoresContractAndDecimals() {
    let chain = ExchangeAssetChain(
      chainId: 1, contractAddress: "0xA0B8…", decimals: 6)
    let meta = ExchangeAssetMetadata(symbol: "USDC", name: "USDC", chains: [chain])
    #expect(meta.symbol == "USDC")
    #expect(meta.chains.first?.chainId == 1)
    #expect(meta.chains.first?.decimals == 6)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac ExchangeAssetMetadataValueTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: FAIL — types not defined.

- [ ] **Step 3: Implement the value type and protocol**

Create `Shared/Exchange/ExchangeAssetMetadata.swift`:

```swift
import Foundation

/// One chain on which a provider lists a token. `contractAddress == nil`
/// means the chain's native asset (the provider's native-token sentinel
/// has already been collapsed by the mapping layer).
struct ExchangeAssetChain: Sendable, Hashable {
  let chainId: Int
  let contractAddress: String?
  let decimals: Int
}

/// Provider-neutral token metadata. `chains` is restricted to
/// EVM chains with a known chain id, in the provider's own listing order.
struct ExchangeAssetMetadata: Sendable, Hashable {
  let symbol: String
  let name: String
  let chains: [ExchangeAssetChain]
}

/// Resolves an exchange asset symbol to neutral token metadata.
///
/// Returns `nil` for a *definitive* "no usable EVM metadata" answer
/// (symbol unknown to the provider, or it lists the token only on
/// non-EVM chains). Throws for *transient* failures (network / provider
/// error) so the caller's sync retries instead of mis-resolving.
protocol ExchangeAssetMetadataResolving: Sendable {
  func assetMetadata(forSymbol symbol: String) async throws -> ExchangeAssetMetadata?
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac ExchangeAssetMetadataValueTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
just format && just format-check
git add Shared/Exchange/ExchangeAssetMetadata.swift MoolahTests/Shared/Exchange/CoinstashCoinMetadataTests.swift
git commit -m "$(cat <<'EOF'
feat: neutral ExchangeAssetMetadata + resolver protocol

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Coinstash `getCoinBySymbol` GraphQL query + Codable models

**Files:**
- Modify: `Shared/Exchange/CoinstashGraphQL.swift`
- Test: `MoolahTests/Shared/Exchange/CoinstashCoinMetadataTests.swift`

Add the query and decode models only (mapping to neutral is Task 4).

- [ ] **Step 1: Write the failing test**

Append to `CoinstashCoinMetadataTests.swift`:

```swift
@Suite("CoinstashCoinMetadata decode")
struct CoinstashCoinMetadataDecodeTests {
  private func decode(_ json: String) throws -> CoinstashCoinData {
    try JSONDecoder().decode(
      CoinstashGraphQLResponse<CoinstashCoinData>.self,
      from: Data(json.utf8)
    ).data!  // test fixture is always a success shape
  }

  @Test
  func decodesSingleChainToken() throws {
    let json = """
      {"data":{"getCoinBySymbol":{"symbol":"OP","name":"Optimism",
      "defiAddresses":[{"chain":"OPTIMISM",
      "address":"0x4200000000000000000000000000000000000042","decimals":18}]}}}
      """
    let coin = try #require(try decode(json).getCoinBySymbol)
    #expect(coin.symbol == "OP")
    #expect(coin.defiAddresses.count == 1)
    #expect(coin.defiAddresses[0].chain == "OPTIMISM")
    #expect(coin.defiAddresses[0].address == "0x4200000000000000000000000000000000000042")
    #expect(coin.defiAddresses[0].decimals == 18)
  }

  @Test
  func decodesEmptyDefiAddresses() throws {
    let json = """
      {"data":{"getCoinBySymbol":{"symbol":"BTC","name":"Bitcoin","defiAddresses":[]}}}
      """
    let coin = try #require(try decode(json).getCoinBySymbol)
    #expect(coin.defiAddresses.isEmpty)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac CoinstashCoinMetadataDecodeTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: FAIL — `CoinstashCoinData` undefined.

- [ ] **Step 3: Add the query and models**

In `CoinstashGraphQL.swift`, add to the `CoinstashGraphQL` enum (after `transactionsQuery`):

```swift
/// Token metadata for a Coinstash symbol. The per-transaction `chain`
/// field is unreliable (observed null/empty live 2026-05-17), so the
/// chain + contract come from here. `defiAddresses` is the per-chain
/// contract list; `[]` for non-EVM-modelled assets (e.g. BTC).
/// Decodes into `CoinstashGraphQLResponse<CoinstashCoinData>`.
static let coinBySymbolQuery = """
  query Q($s: String!) {
    getCoinBySymbol(symbol: $s) {
      symbol name
      defiAddresses { chain address decimals }
    }
  }
  """
```

Add these models at file scope (after the existing transaction models):

```swift
struct CoinstashDefiAddress: Decodable, Sendable, Hashable {
  let chain: String
  /// Optional defensively: a malformed row must not fail the whole decode.
  let address: String?
  let decimals: Int?
}

struct CoinstashCoinMetadata: Decodable, Sendable, Hashable {
  let symbol: String
  let name: String
  let defiAddresses: [CoinstashDefiAddress]
}

struct CoinstashCoinData: Decodable, Sendable {
  /// `null` when Coinstash does not recognise the symbol.
  let getCoinBySymbol: CoinstashCoinMetadata?
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac CoinstashCoinMetadataDecodeTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
just format && just format-check
git add Shared/Exchange/CoinstashGraphQL.swift MoolahTests/Shared/Exchange/CoinstashCoinMetadataTests.swift
git commit -m "$(cat <<'EOF'
feat: Coinstash getCoinBySymbol query + decode models

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `CoinstashClient.coinMetadata` — query + Chain→chainId + sentinel collapse

**Files:**
- Modify: `Shared/Exchange/CoinstashClient.swift`
- Test: `MoolahTests/Shared/Exchange/CoinstashCoinMetadataTests.swift`

Map Coinstash's `Chain` enum to EVM chain ids, drop non-EVM/unknown chains, collapse the native sentinel `0x` + forty `e` (case-insensitive) to `contractAddress == nil`, and preserve Coinstash's listing order. Use the existing private `query(_:variables:token:decoding:)` transport.

- [ ] **Step 1: Write the failing test**

Append to `CoinstashCoinMetadataTests.swift`. Use the existing transport-stub pattern from `CoinstashClientTests.swift` (a `@Sendable (URLRequest) async throws -> (Data, URLResponse)` returning a canned 200 body); copy that helper's shape:

```swift
@Suite("CoinstashClient.coinMetadata mapping")
struct CoinstashClientCoinMetadataTests {
  private func client(returning body: String) -> CoinstashClient {
    CoinstashClient(transport: { _ in
      (Data(body.utf8),
       HTTPURLResponse(
        url: CoinstashGraphQL.endpoint, statusCode: 200,
        httpVersion: nil, headerFields: nil)!)
    })
  }

  @Test
  func mapsSingleChainOptimismToken() async throws {
    let c = client(returning: """
      {"data":{"getCoinBySymbol":{"symbol":"OP","name":"Optimism",
      "defiAddresses":[{"chain":"OPTIMISM",
      "address":"0x4200000000000000000000000000000000000042","decimals":18}]}}}
      """)
    let meta = try #require(try await c.coinMetadata(symbol: "OP", token: "t"))
    #expect(meta.symbol == "OP")
    #expect(meta.chains == [
      ExchangeAssetChain(
        chainId: 10,
        contractAddress: "0x4200000000000000000000000000000000000042",
        decimals: 18)
    ])
  }

  @Test
  func collapsesNativeSentinelToNilContract() async throws {
    let c = client(returning: """
      {"data":{"getCoinBySymbol":{"symbol":"ETH","name":"Ethereum",
      "defiAddresses":[
      {"chain":"ETHEREUM","address":"0xEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE","decimals":18},
      {"chain":"SOLANA","address":"So111","decimals":9}]}}}
      """)
    let meta = try #require(try await c.coinMetadata(symbol: "ETH", token: "t"))
    // SOLANA dropped (non-EVM); sentinel → nil contract.
    #expect(meta.chains == [
      ExchangeAssetChain(chainId: 1, contractAddress: nil, decimals: 18)
    ])
  }

  @Test
  func unknownSymbolReturnsNil() async throws {
    let c = client(returning: #"{"data":{"getCoinBySymbol":null}}"#)
    #expect(try await c.coinMetadata(symbol: "ZZZ", token: "t") == nil)
  }

  @Test
  func emptyDefiAddressesReturnsMetadataWithNoChains() async throws {
    let c = client(returning: """
      {"data":{"getCoinBySymbol":{"symbol":"BTC","name":"Bitcoin","defiAddresses":[]}}}
      """)
    let meta = try #require(try await c.coinMetadata(symbol: "BTC", token: "t"))
    #expect(meta.chains.isEmpty)
  }

  @Test
  func providerErrorThrows() async throws {
    let c = CoinstashClient(transport: { _ in
      (Data(#"{"errors":[{"message":"boom"}]}"#.utf8),
       HTTPURLResponse(
        url: CoinstashGraphQL.endpoint, statusCode: 200,
        httpVersion: nil, headerFields: nil)!)
    })
    await #expect(throws: ExchangeClientError.self) {
      _ = try await c.coinMetadata(symbol: "OP", token: "t")
    }
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac CoinstashClientCoinMetadataTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: FAIL — `coinMetadata(symbol:token:)` undefined.

- [ ] **Step 3: Implement `coinMetadata` + the chain table + sentinel collapse**

In `CoinstashClient.swift`, add the chain table and method (the chain id values come from the spec's `Chain` enum → EVM chain-id table):

```swift
// Coinstash `Chain` enum → EVM chain id. Non-EVM (SOLANA) and any
// value absent here are intentionally excluded: a symbol that lists
// only excluded chains falls through to the caller's registry
// fallback. `AVALANCE` is Coinstash's spelling.
private static let evmChainIds: [String: Int] = [
  "ETHEREUM": 1, "OPTIMISM": 10, "BASE": 8453, "ARBITRUM": 42161,
  "POLYGON": 137, "BSC": 56, "AVALANCE": 43114, "GNOSIS": 100,
  "FANTOM": 250, "LINEA": 59144, "SONIC": 146,
]

/// The well-known "native asset" sentinel address (`0x` + forty `e`).
private static let nativeSentinel = "0x" + String(repeating: "e", count: 40)

/// Token metadata for `symbol`, or `nil` when Coinstash does not
/// recognise the symbol (definitive — caller takes the registry
/// fallback). Throws on transport / provider error (transient — the
/// sync retries). Non-EVM and unknown chains are dropped; the native
/// sentinel collapses to `contractAddress == nil`; Coinstash's listing
/// order is preserved.
func coinMetadata(symbol: String, token: String) async throws -> ExchangeAssetMetadata? {
  let data = try await query(
    CoinstashGraphQL.coinBySymbolQuery,
    variables: ["s": .string(symbol)],
    token: token,
    decoding: CoinstashCoinData.self)
  guard let coin = data.getCoinBySymbol else { return nil }

  let chains: [ExchangeAssetChain] = coin.defiAddresses.compactMap { entry in
    guard let chainId = Self.evmChainIds[entry.chain] else { return nil }
    guard let address = entry.address else { return nil }
    let isSentinel = address.caseInsensitiveCompare(Self.nativeSentinel) == .orderedSame
    return ExchangeAssetChain(
      chainId: chainId,
      contractAddress: isSentinel ? nil : address,
      decimals: entry.decimals ?? 18)
  }
  return ExchangeAssetMetadata(symbol: coin.symbol, name: coin.name, chains: chains)
}
```

Add the protocol conformance in its own extension at the end of the file:

```swift
extension CoinstashClient {
  // Token-bound conformance is provided by CoinstashAssetMetadataResolver
  // (the protocol has no token parameter; the bearer token is per-account).
}
```

(The `CoinstashClient` keeps `coinMetadata(symbol:token:)`; the protocol adapter is Task 5. The empty extension above is a placeholder comment only — omit it if SwiftLint flags an empty extension; the real conformance lives in Task 5.)

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac CoinstashClientCoinMetadataTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
just format && just format-check
git add Shared/Exchange/CoinstashClient.swift MoolahTests/Shared/Exchange/CoinstashCoinMetadataTests.swift
git commit -m "$(cat <<'EOF'
feat: CoinstashClient.coinMetadata with Chain→chainId + sentinel collapse

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `CoinstashAssetMetadataResolver` token-bound adapter

**Files:**
- Create: `Shared/Exchange/CoinstashAssetMetadataResolver.swift`
- Test: `MoolahTests/Shared/Exchange/CoinstashCoinMetadataTests.swift`

`ExchangeAssetMetadataResolving` has no token parameter (it is provider-neutral; the Coinstash bearer token is per-account). This adapter binds a `CoinstashClient` + token.

- [ ] **Step 1: Write the failing test**

Append to `CoinstashCoinMetadataTests.swift`:

```swift
@Suite("CoinstashAssetMetadataResolver")
struct CoinstashAssetMetadataResolverTests {
  @Test
  func forwardsToClientWithBoundToken() async throws {
    let client = CoinstashClient(transport: { _ in
      (Data("""
        {"data":{"getCoinBySymbol":{"symbol":"OP","name":"Optimism",
        "defiAddresses":[{"chain":"OPTIMISM",
        "address":"0x4200000000000000000000000000000000000042","decimals":18}]}}}
        """.utf8),
       HTTPURLResponse(
        url: CoinstashGraphQL.endpoint, statusCode: 200,
        httpVersion: nil, headerFields: nil)!)
    })
    let resolver: any ExchangeAssetMetadataResolving =
      CoinstashAssetMetadataResolver(client: client, token: "secret")
    let meta = try #require(try await resolver.assetMetadata(forSymbol: "OP"))
    #expect(meta.chains.first?.chainId == 10)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac CoinstashAssetMetadataResolverTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: FAIL — type undefined.

- [ ] **Step 3: Implement the adapter**

Create `Shared/Exchange/CoinstashAssetMetadataResolver.swift`:

```swift
import Foundation

/// Binds a `CoinstashClient` to a per-account bearer token so the
/// provider-neutral `ExchangeAssetMetadataResolving` seam carries no
/// token. Constructed per sync by `CoinstashSyncSource` once the
/// account's token is read from the keychain.
struct CoinstashAssetMetadataResolver: ExchangeAssetMetadataResolving {
  private let client: CoinstashClient
  private let token: String

  init(client: CoinstashClient, token: String) {
    self.client = client
    self.token = token
  }

  func assetMetadata(forSymbol symbol: String) async throws -> ExchangeAssetMetadata? {
    try await client.coinMetadata(symbol: symbol, token: token)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac CoinstashAssetMetadataResolverTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
just format && just format-check
git add Shared/Exchange/CoinstashAssetMetadataResolver.swift MoolahTests/Shared/Exchange/CoinstashCoinMetadataTests.swift
git commit -m "$(cat <<'EOF'
feat: CoinstashAssetMetadataResolver token-bound adapter

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `distinctLegInstrumentIds()` repository read (used-in-accounts tie-break)

**Files:**
- Modify: `Domain/Repositories/TransactionRepository.swift`
- Modify: `Backends/GRDB/Repositories/GRDBTransactionRepository+ExternalIdLookup.swift`
- Test: an existing GRDB transaction-repository test suite under `MoolahTests/` (locate the suite that builds a `DatabaseQueue` and seeds legs — follow its existing setup helper exactly; add one `@Test` there).

The registry fallback's tertiary tie-break ("prefer an instrument already used on an existing leg"). A focused `SELECT DISTINCT instrument_id FROM transaction_leg` — cheap, and only awaited when ≥2 non-spam same-ticker candidates survive (near-never).

- [ ] **Step 1: Write the failing test**

In the existing GRDB transaction-repository test suite (the one with a `makeRepository()`/`DatabaseQueue` helper that already creates transactions with legs), add:

```swift
@Test
func distinctLegInstrumentIdsReturnsEachInstrumentOnce() async throws {
  let repo = try makeRepository()  // existing suite helper
  // Seed two transactions whose legs reference the same instrument id
  // plus one other — reuse the suite's existing transaction-builder
  // helper rather than hand-rolling Transaction values here.
  try await seedTwoTxnsSharingAnInstrument(repo)  // existing/added suite helper
  let ids = try await repo.distinctLegInstrumentIds()
  #expect(ids.contains("10:0x4200000000000000000000000000000000000042"))
  #expect(ids.contains("AUD"))
}
```

If the suite has no leg-seeding helper, add a minimal private one in that test file using the project's existing `Transaction`/`TransactionLeg` initialisers (mirror another test in the same file that calls `repo.create(_:)`).

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac <ThatRepoSuiteName> 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: FAIL — `distinctLegInstrumentIds()` undefined.

- [ ] **Step 3: Add the protocol requirement and GRDB implementation**

In `Domain/Repositories/TransactionRepository.swift`, add to the protocol (near `legs(matchingExternalId:)`):

```swift
/// Distinct instrument ids appearing on any persisted transaction leg.
/// Used only by exchange-import resolution's rare registry-fallback
/// tie-break; cheap (`SELECT DISTINCT`), not on a hot path.
func distinctLegInstrumentIds() async throws -> Set<String>
```

In `GRDBTransactionRepository+ExternalIdLookup.swift`, add the implementation (mirror the `dbQueue.read { ... }` pattern already used by `legs(matchingExternalId:)` in this file; `TransactionLegRow.databaseTableName == "transaction_leg"`, column `instrument_id`):

```swift
func distinctLegInstrumentIds() async throws -> Set<String> {
  try await dbQueue.read { db in
    let rows = try String.fetchAll(
      db, sql: "SELECT DISTINCT instrument_id FROM transaction_leg")
    return Set(rows)
  }
}
```

If any other `TransactionRepository` conformance exists (e.g. a test/in-memory double in `MoolahTests/Support/`), add the same method there returning `Set(...)` over its in-memory legs so the project still compiles. Locate them with `grep -rl "TransactionRepository" MoolahTests/Support` and conform each.

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac <ThatRepoSuiteName> 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: PASS.

- [ ] **Step 5: Format, review, commit**

```bash
just format && just format-check
```

Then run the database review agents on the working tree (they operate pre-PR):
`@database-code-review` and `@database-schema-review`. Address any Critical/Important findings before committing.

```bash
git add Domain/Repositories/TransactionRepository.swift Backends/GRDB/Repositories/GRDBTransactionRepository+ExternalIdLookup.swift MoolahTests/
git commit -m "$(cat <<'EOF'
feat: TransactionRepository.distinctLegInstrumentIds (DISTINCT read)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `ExchangeInstrumentResolver` — fiat accessor + non-spam registry fallback

**Files:**
- Modify: `Shared/Exchange/ExchangeInstrumentResolver.swift`
- Test: `MoolahTests/Shared/Exchange/ExchangeInstrumentResolverTests.swift`

Replace the symbol-only first-match scan with: (a) a `fiatInstrument` accessor, (b) `fallbackInstrument(forSymbol:)` implementing exclude-spam → prefer-priced/mapped → prefer-used → deterministic-id. The "used" set is injected as a closure so unit tests stay trivial.

- [ ] **Step 1: Write the failing tests**

Replace the body of `ExchangeInstrumentResolverTests.swift` with (keep the fiat tests, retarget the asset tests to `fallbackInstrument`):

```swift
import Testing

@testable import Moolah

@Suite("ExchangeInstrumentResolver")
struct ExchangeInstrumentResolverTests {
  private func op(_ contract: String, spam: Bool = false, mapped: Bool = true)
    -> CryptoRegistration
  {
    let inst = Instrument.crypto(
      chainId: 10, contractAddress: contract, symbol: "OP",
      name: "Optimism", decimals: 18)
    return CryptoRegistration(
      instrument: inst,
      mapping: CryptoProviderMapping(
        instrumentId: inst.id,
        coingeckoId: mapped ? "optimism" : nil,
        cryptocompareSymbol: nil, binanceSymbol: nil),
      pricingStatus: spam ? .spam : (mapped ? .priced : .unpriced))
  }

  private func resolver(
    _ regs: [CryptoRegistration],
    used: Set<String> = []
  ) -> ExchangeInstrumentResolver {
    ExchangeInstrumentResolver(
      registry: StubInstrumentRegistry(
        instruments: regs.map(\.instrument),
        cryptoRegistrations: regs),
      fiatInstrument: .AUD,
      existingLegInstrumentIds: { used })
  }

  @Test
  func fiatAccessorReturnsInjectedInstrument() {
    #expect(resolver([]).fiatInstrument == .AUD)
  }

  @Test
  func fallbackExcludesSpamAndPicksRealOP() async throws {
    let spam = op("0xdeadbeef00000000000000000000000000000000", spam: true)
    let real = op("0x4200000000000000000000000000000000000042")
    let got = try await resolver([spam, real]).fallbackInstrument(forSymbol: "OP")
    #expect(got == real.instrument)
  }

  @Test
  func fallbackPrefersMappedOverUnpricedStub() async throws {
    let stub = op("0x1111111111111111111111111111111111111111", mapped: false)
    let mapped = op("0x4200000000000000000000000000000000000042")
    let got = try await resolver([stub, mapped]).fallbackInstrument(forSymbol: "OP")
    #expect(got == mapped.instrument)
  }

  @Test
  func fallbackPrefersUsedThenLowestId() async throws {
    let a = op("0xaaaa000000000000000000000000000000000000")
    let b = op("0xbbbb000000000000000000000000000000000000")
    // Both priced+mapped; "used" picks b even though a's id sorts lower.
    let got = try await resolver([a, b], used: [b.instrument.id])
      .fallbackInstrument(forSymbol: "OP")
    #expect(got == b.instrument)
  }

  @Test
  func fallbackDeterministicIdTieBreak() async throws {
    let a = op("0xaaaa000000000000000000000000000000000000")
    let b = op("0xbbbb000000000000000000000000000000000000")
    let got = try await resolver([b, a]).fallbackInstrument(forSymbol: "OP")
    #expect(got == a.instrument)  // "10:0xaaaa…" < "10:0xbbbb…"
  }

  @Test
  func fallbackAllSpamReturnsNil() async throws {
    let got = try await resolver([op("0xdead000000000000000000000000000000000000", spam: true)])
      .fallbackInstrument(forSymbol: "OP")
    #expect(got == nil)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test-mac ExchangeInstrumentResolverTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: FAIL — new init signature / `fiatInstrument` / `fallbackInstrument` undefined.

- [ ] **Step 3: Rewrite the resolver**

Replace `Shared/Exchange/ExchangeInstrumentResolver.swift` with:

```swift
import Foundation
import OSLog

/// Fiat denomination + the registry fallback for exchange asset legs.
/// The chain-pinned resolution (provider token metadata → discovery) is
/// orchestrated by `ExchangeSyncEngine`; this type owns only the fiat
/// instrument and the *fallback* used when the provider gives no usable
/// EVM metadata (e.g. non-EVM-modelled assets).
struct ExchangeInstrumentResolver: Sendable {
  let fiatInstrument: Instrument
  private let registry: any InstrumentRegistryRepository
  private let existingLegInstrumentIds: @Sendable () async throws -> Set<String>
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeInstrumentResolver")

  init(
    registry: any InstrumentRegistryRepository,
    fiatInstrument: Instrument,
    existingLegInstrumentIds: @escaping @Sendable () async throws -> Set<String>
  ) {
    self.registry = registry
    self.fiatInstrument = fiatInstrument
    self.existingLegInstrumentIds = existingLegInstrumentIds
  }

  /// Registry fallback for a crypto symbol with no usable EVM metadata.
  /// Excludes `.spam`; prefers a mapped/`.priced` registration over an
  /// `.unpriced` stub; then an instrument already used on an existing
  /// leg; then the lowest `Instrument.id` (deterministic). `nil` when
  /// every match is spam or none exist — caller drops + logs the group.
  ///
  /// Throws on registry failure (transient) so the sync retries rather
  /// than silently dropping every leg.
  func fallbackInstrument(forSymbol symbol: String) async throws -> Instrument? {
    let regs: [CryptoRegistration]
    do {
      regs = try await registry.allCryptoRegistrations()
    } catch {
      Self.logger.error(
        "Registry scan failed for '\(symbol, privacy: .public)': \(error, privacy: .public)")
      throw error
    }
    let candidates = regs.filter {
      $0.instrument.kind == .cryptoToken
        && $0.instrument.ticker?.caseInsensitiveCompare(symbol) == .orderedSame
        && $0.pricingStatus != .spam
    }
    guard !candidates.isEmpty else { return nil }

    let used = try await existingLegInstrumentIds()
    func rank(_ r: CryptoRegistration) -> (Int, Int, String) {
      let priced = (r.pricingStatus == .priced && hasMapping(r.mapping)) ? 0 : 1
      let isUsed = used.contains(r.instrument.id) ? 0 : 1
      return (priced, isUsed, r.instrument.id)
    }
    return candidates.min { rank($0) < rank($1) }?.instrument
  }

  private func hasMapping(_ m: CryptoProviderMapping) -> Bool {
    m.coingeckoId != nil || m.cryptocompareSymbol != nil || m.binanceSymbol != nil
  }
}
```

(`(Int, Int, String)` tuples are `Comparable` via `<` lexicographically in Swift, so `rank($0) < rank($1)` orders priced-first, then used-first, then lowest id.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test-mac ExchangeInstrumentResolverTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: PASS. (The project will not fully build yet — `ExchangeSyncEngine`/wiring still use the old API; that is fixed in Tasks 8–9. Running just this suite compiles the test target against the module; if the module fails to build because callers reference the removed `instrument(forSymbol:isFiat:)`, proceed to Task 8 which updates them, then re-run Tasks 7–8 tests together.)

- [ ] **Step 5: Format and commit**

```bash
just format && just format-check
git add Shared/Exchange/ExchangeInstrumentResolver.swift MoolahTests/Shared/Exchange/ExchangeInstrumentResolverTests.swift
git commit -m "$(cat <<'EOF'
feat: ExchangeInstrumentResolver fiat accessor + non-spam fallback

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `ExchangeSyncEngine` resolution orchestration

**Files:**
- Modify: `Shared/Exchange/ExchangeSyncEngine.swift`
- Test: `MoolahTests/Shared/Exchange/ExchangeSyncEngineResolutionTests.swift`

Add the resolution pipeline: fiat → BTC table → metadata canonical pick → discovery → registry fallback. New deps: `discovery: CryptoTokenDiscoveryService`; `build` gains `metadata: any ExchangeAssetMetadataResolving`.

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Shared/Exchange/ExchangeSyncEngineResolutionTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("ExchangeSyncEngine resolution")
struct ExchangeSyncEngineResolutionTests {
  // Scriptable neutral metadata resolver.
  final class StubMetadata: ExchangeAssetMetadataResolving, @unchecked Sendable {
    let map: [String: ExchangeAssetMetadata?]
    let onCall: @Sendable (String) -> Void
    init(_ map: [String: ExchangeAssetMetadata?], onCall: @escaping @Sendable (String) -> Void = { _ in }) {
      self.map = map
      self.onCall = onCall
    }
    func assetMetadata(forSymbol symbol: String) async throws -> ExchangeAssetMetadata? {
      onCall(symbol)
      guard let hit = map[symbol] else { return nil }
      return hit
    }
  }

  private func engine(
    registry: StubInstrumentRegistry,
    resolver: CountingRegistrationResolver = {
      let r = CountingRegistrationResolver()
      r.setDefault(.success(coingecko: "id", cryptocompare: nil, binance: nil))
      return r
    }()
  ) -> ExchangeSyncEngine {
    let discovery = CryptoTokenDiscoveryService(
      registry: registry, resolver: resolver, alchemy: CountingAlchemyClient())
    return ExchangeSyncEngine(
      resolver: ExchangeInstrumentResolver(
        registry: registry, fiatInstrument: .AUD,
        existingLegInstrumentIds: { [] }),
      discovery: discovery)
  }

  private func depositRow(_ symbol: String, _ amount: Decimal) -> ExchangeImportedTransaction {
    ExchangeImportedTransaction(
      externalId: "ext-\(symbol)", occurredAt: Date(timeIntervalSince1970: 1_762_000_000),
      category: "DEPOSIT", direction: .credit, assetSymbol: symbol,
      amount: amount, isFiat: false, orderId: nil)
  }

  private func account() -> Account {
    // Reuse the project's exchange-account test factory if one exists in
    // MoolahTests/Support; otherwise build a minimal .exchange Account
    // mirroring an existing Coinstash test's account construction.
    ExchangeCreationHarness.coinstashAccount()  // existing harness (see Task notes)
  }

  @Test
  func opDepositResolvesToRealOptimismOPNotSpam() async throws {
    let registry = StubInstrumentRegistry()
    let meta = StubMetadata([
      "OP": ExchangeAssetMetadata(
        symbol: "OP", name: "Optimism",
        chains: [ExchangeAssetChain(
          chainId: 10,
          contractAddress: "0x4200000000000000000000000000000000000042",
          decimals: 18)])
    ])
    let result = try await engine(registry: registry).build(
      account: account(), imported: [depositRow("OP", 40167)], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument.id == "10:0x4200000000000000000000000000000000000042")
    #expect(leg.instrument.decimals == 18)
  }

  @Test
  func btcShortCircuitsWithoutMetadataCall() async throws {
    let registry = StubInstrumentRegistry(
      cryptoRegistrations: CryptoRegistration.builtInPresets)
    var called: [String] = []
    let meta = StubMetadata([:], onCall: { called.append($0) })
    let result = try await engine(registry: registry).build(
      account: account(), imported: [depositRow("BTC", 1)], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument.id == "0:native")
    #expect(leg.instrument.decimals == 8)
    #expect(called.isEmpty)  // getCoinBySymbol not invoked for BTC
  }

  @Test
  func multiChainPicksEthereumCanonical() async throws {
    let registry = StubInstrumentRegistry()
    let meta = StubMetadata([
      "USDC": ExchangeAssetMetadata(
        symbol: "USDC", name: "USDC",
        chains: [
          ExchangeAssetChain(chainId: 10,
            contractAddress: "0x7f5c764cbc14f9669b88837ca1490cca17c31607", decimals: 6),
          ExchangeAssetChain(chainId: 1,
            contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", decimals: 6),
        ])
    ])
    let result = try await engine(registry: registry).build(
      account: account(), imported: [depositRow("USDC", 100)], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument.id == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
  }

  @Test
  func nativeContractNilBuildsNativeInstrument() async throws {
    let registry = StubInstrumentRegistry()
    let meta = StubMetadata([
      "ETH": ExchangeAssetMetadata(
        symbol: "ETH", name: "Ethereum",
        chains: [ExchangeAssetChain(chainId: 1, contractAddress: nil, decimals: 18)])
    ])
    let result = try await engine(registry: registry).build(
      account: account(), imported: [depositRow("ETH", 2)], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument.id == "1:native")
  }

  @Test
  func noEvmMetadataUsesRegistryFallback() async throws {
    let real = CryptoRegistration(
      instrument: .crypto(
        chainId: 1399, contractAddress: nil, symbol: "SOL",
        name: "Solana", decimals: 9),
      mapping: CryptoProviderMapping(
        instrumentId: "1399:native", coingeckoId: "solana",
        cryptocompareSymbol: nil, binanceSymbol: nil))
    let registry = StubInstrumentRegistry(
      instruments: [real.instrument], cryptoRegistrations: [real])
    let meta = StubMetadata([
      "SOL": ExchangeAssetMetadata(symbol: "SOL", name: "Solana", chains: [])
    ])
    let result = try await engine(registry: registry).build(
      account: account(), imported: [depositRow("SOL", 5)], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument.id == "1399:native")
  }

  @Test
  func transientMetadataErrorThrows() async throws {
    struct Boom: Error {}
    final class Throwing: ExchangeAssetMetadataResolving {
      func assetMetadata(forSymbol symbol: String) async throws -> ExchangeAssetMetadata? {
        throw Boom()
      }
    }
    let registry = StubInstrumentRegistry()
    await #expect(throws: Boom.self) {
      _ = try await engine(registry: registry).build(
        account: account(), imported: [depositRow("OP", 1)], metadata: Throwing())
    }
  }

  @Test
  func fiatLegSkipsMetadata() async throws {
    let registry = StubInstrumentRegistry()
    var called: [String] = []
    let meta = StubMetadata([:], onCall: { called.append($0) })
    let row = ExchangeImportedTransaction(
      externalId: "f1", occurredAt: Date(timeIntervalSince1970: 1_762_000_000),
      category: "DEPOSIT", direction: .credit, assetSymbol: "AUD",
      amount: 50, isFiat: true, orderId: nil)
    let result = try await engine(registry: registry).build(
      account: account(), imported: [row], metadata: meta)
    let leg = try #require(result.candidates.first?.transaction.legs.first)
    #expect(leg.instrument == .AUD)
    #expect(called.isEmpty)
  }
}
```

> Note on `account()` and stubs: reuse the existing `ExchangeCreationHarness` (referenced in recent commits) or whatever the existing Coinstash tests (`CoinstashSyncSourceTests`, `ExchangeSyncEngineTests`) use to build an `.exchange` `Account`; mirror that exactly. `CountingRegistrationResolver` and the Alchemy counting stub are the existing doubles in `MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryTestDoubles.swift` — import path is the same test module, no extra import needed.

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test-mac ExchangeSyncEngineResolutionTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: FAIL — `ExchangeSyncEngine` has no `discovery:` init param / `build(...metadata:)`.

- [ ] **Step 3: Implement the orchestration**

Rewrite `Shared/Exchange/ExchangeSyncEngine.swift`. Keep `legType(for:)`, the grouping, signpost/log, and group-drop behaviour; change `init`, `build`, and `buildCandidate`:

```swift
import Foundation
import OSLog

struct ExchangeSyncEngine: Sendable {
  private let resolver: ExchangeInstrumentResolver
  private let discovery: CryptoTokenDiscoveryService
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeSyncEngine")

  // Canonical multi-chain preference: Ethereum first (product
  // decision), then the wallet-supported chains, then the rest.
  private static let chainPreference: [Int] =
    [1, 10, 8453, 42161, 137, 56, 43114, 100, 250, 59144, 146]

  // Non-EVM natives the app pins by convention, keyed by uppercased
  // symbol. Resolved directly (no getCoinBySymbol call) — these are
  // `CryptoRegistration.builtInPresets` members.
  private static let nonEvmNatives: [String: Instrument] = [
    "BTC": .crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC",
      name: "Bitcoin", decimals: 8)
  ]

  init(resolver: ExchangeInstrumentResolver, discovery: CryptoTokenDiscoveryService) {
    self.resolver = resolver
    self.discovery = discovery
  }

  private static func legType(for category: String) -> TransactionType {
    switch category {
    case "DEPOSIT", "AWARD": return .income
    case "WITHDRAW", "TRADEFEE": return .expense
    default: return .trade
    }
  }

  func build(
    account: Account,
    imported: [ExchangeImportedTransaction],
    metadata: any ExchangeAssetMetadataResolving
  ) async throws -> WalletSyncBuildResult {
    let groups = Dictionary(grouping: imported) { $0.orderId ?? $0.externalId }
    var candidates: [BuiltTransaction] = []
    for (groupKey, rows) in groups {
      try Task.checkCancellation()
      if let candidate = try await buildCandidate(
        groupKey: groupKey, rows: rows, account: account, metadata: metadata)
      {
        candidates.append(candidate)
      }
    }
    Self.logger.info(
      "Built \(candidates.count, privacy: .public) candidates from \(imported.count, privacy: .public) rows"
    )
    return WalletSyncBuildResult(candidates: candidates, headBlockNumber: 0)
  }

  private func buildCandidate(
    groupKey: String,
    rows: [ExchangeImportedTransaction],
    account: Account,
    metadata: any ExchangeAssetMetadataResolving
  ) async throws -> BuiltTransaction? {
    var legs: [TransactionLeg] = []
    for row in rows {
      try Task.checkCancellation()
      guard
        let instrument = try await resolveInstrument(
          symbol: row.assetSymbol, isFiat: row.isFiat, metadata: metadata)
      else {
        Self.logger.warning(
          "Dropping group \(groupKey, privacy: .public): unresolvable instrument externalId=\(row.externalId, privacy: .public) symbol=\(row.assetSymbol ?? "nil", privacy: .public) isFiat=\(row.isFiat, privacy: .public)"
        )
        return nil
      }
      let quantity = row.direction.multiplier * row.amount
      legs.append(
        TransactionLeg(
          accountId: account.id,
          instrument: instrument,
          quantity: quantity,
          externalId: row.externalId,
          type: Self.legType(for: row.category)))
    }
    guard let date = rows.map(\.occurredAt).min() else { return nil }
    return BuiltTransaction(
      originAccountId: account.id,
      transaction: Transaction(date: date, legs: legs))
  }

  /// Resolution pipeline (spec §"Resolution policy").
  private func resolveInstrument(
    symbol: String?,
    isFiat: Bool,
    metadata: any ExchangeAssetMetadataResolving
  ) async throws -> Instrument? {
    if isFiat { return resolver.fiatInstrument }
    guard let symbol else { return nil }

    // 0. Explicit non-EVM natives (BTC) — skip the metadata call.
    if let native = Self.nonEvmNatives[symbol.uppercased()] {
      if let existing = try await registryInstrument(id: native.id) { return existing }
      let reg = try await discovery.resolveOrLoad(
        chainId: native.chainId ?? 0,
        contractAddress: nil,
        symbol: native.ticker ?? symbol,
        name: native.name,
        decimals: native.decimals)
      return reg.instrument
    }

    // 1. Provider metadata (transient errors propagate).
    let meta = try await metadata.assetMetadata(forSymbol: symbol)

    // 2–4. Canonical EVM pick → discovery path.
    if let meta, let chosen = Self.canonical(meta.chains) {
      let reg = try await discovery.resolveOrLoad(
        chainId: chosen.chainId,
        contractAddress: chosen.contractAddress,
        symbol: meta.symbol,
        name: meta.name,
        decimals: chosen.decimals)
      return reg.instrument
    }

    // 5. Definitive "no usable EVM metadata" → registry fallback.
    return try await resolver.fallbackInstrument(forSymbol: symbol)
  }

  private func canonical(_ chains: [ExchangeAssetChain]) -> ExchangeAssetChain? {
    guard !chains.isEmpty else { return nil }
    for preferred in Self.chainPreference {
      if let hit = chains.first(where: { $0.chainId == preferred }) { return hit }
    }
    return chains.first  // EVM but outside the preference list: stable first-listed
  }

  private func registryInstrument(id: String) async throws -> Instrument? {
    try await discovery.registry.cryptoRegistration(byId: id)?.instrument
  }
}
```

`discovery.registry` is not accessible (private). Instead, give the engine the registry directly via the resolver: add a method on `ExchangeInstrumentResolver` `func registeredInstrument(id: String) async throws -> Instrument?` returning `try await registry.cryptoRegistration(byId: id)?.instrument`, and call `resolver.registeredInstrument(id:)` from `registryInstrument(id:)`. Add that method to the resolver in this task (small addition to Task 7's file) and a one-line test in `ExchangeInstrumentResolverTests` asserting it returns a seeded registration's instrument.

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test-mac ExchangeSyncEngineResolutionTests ExchangeInstrumentResolverTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
just format && just format-check
git add Shared/Exchange/ExchangeSyncEngine.swift Shared/Exchange/ExchangeInstrumentResolver.swift MoolahTests/Shared/Exchange/ExchangeSyncEngineResolutionTests.swift MoolahTests/Shared/Exchange/ExchangeInstrumentResolverTests.swift
git commit -m "$(cat <<'EOF'
feat: ExchangeSyncEngine metadata-driven instrument resolution

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Wire `CoinstashSyncSource` + `ProfileSession+CryptoSync`

**Files:**
- Modify: `Shared/Exchange/CoinstashSyncSource.swift`
- Modify: `App/ProfileSession+CryptoSync.swift`
- Test: `MoolahTests/Shared/Exchange/CoinstashSyncSourceTests.swift` (existing — update for the new `engine.build(...metadata:)` shape)

`CoinstashSyncSource` already reads the per-account token. After fetching transactions, build a token-bound `CoinstashAssetMetadataResolver` and pass it into `engine.build`.

- [ ] **Step 1: Update the existing failing test**

In `CoinstashSyncSourceTests.swift`, the source is constructed with a `client:` and `engine:`. Update the construction so the engine is built with the new `init(resolver:discovery:)` and assert an OP deposit resolves to `10:0x4200…0042`. Mirror Task 8's `engine(...)` helper (a `CryptoTokenDiscoveryService` with `CountingRegistrationResolver` + `CountingAlchemyClient`, an `ExchangeInstrumentResolver` with `existingLegInstrumentIds: { [] }`). The Coinstash transport stub must answer **both** the transactions query and the `getCoinBySymbol` query — branch on whether the request body contains `"getCoinBySymbol"`:

```swift
let transport: CoinstashClient.Transport = { request in
  let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
  let json: String
  if body.contains("getCoinBySymbol") {
    json = """
      {"data":{"getCoinBySymbol":{"symbol":"OP","name":"Optimism",
      "defiAddresses":[{"chain":"OPTIMISM",
      "address":"0x4200000000000000000000000000000000000042","decimals":18}]}}}
      """
  } else if body.contains("userProfile") {
    json = #"{"data":{"userProfile":{"userId":"u1"}}}"#
  } else if body.contains("getUserAccounts") {
    json = #"{"data":{"getUserAccounts":{"accounts":[{"accountId":"a1","accountType":"TRADING"}]}}}"#
  } else {
    json = """
      {"data":{"accountTransactions":{"isSuccessful":true,"errorMessage":null,
      "totalRecordsFound":1,"result":[{"transactionId":"t1",
      "transactedOn":"2025-11-01T00:00:00.000Z","category":"DEPOSIT","type":"CREDIT",
      "symbol":"OP","amount":40167,"amountType":"ASSET","quoteBuyPrice":null,
      "quoteSellPrice":null,"orderId":null,"orderType":null,
      "transactionStatus":"COMPLETED"}]}}}
      """
  }
  return (Data(json.utf8),
    HTTPURLResponse(url: CoinstashGraphQL.endpoint, statusCode: 200,
      httpVersion: nil, headerFields: nil)!)
}
```

Assert the produced candidate's leg instrument id is `10:0x4200000000000000000000000000000000000042`.

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac CoinstashSyncSourceTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt`
Expected: FAIL — compile error on `engine.build` arity / `CoinstashSyncSource` not passing metadata.

- [ ] **Step 3: Wire the source and production assembly**

In `CoinstashSyncSource.swift`, the stored `client` is `any ExchangeClient`. Add a stored `coinstashClient: CoinstashClient` is **not** ideal (keeps neutrality). Instead, change `CoinstashSyncSource` to hold a `metadataResolverFactory: @Sendable (_ token: String) -> any ExchangeAssetMetadataResolving` injected at construction, and in `build(account:)` after the token is read:

```swift
let imported = try await client.fetchTransactions(token: token)
let metadata = metadataResolverFactory(token)
return try await engine.build(account: account, imported: imported, metadata: metadata)
```

Update `CoinstashSyncSource.init` to accept `metadataResolverFactory`. In `ProfileSession+CryptoSync.makeCryptoSyncWiring`, build a single `CoinstashClient()` and reuse it for both transports:

```swift
let coinstashClient = CoinstashClient()
let coinstashSource = CoinstashSyncSource(
  tokenStore: ExchangeTokenStore(synchronizable: true),
  client: coinstashClient,
  engine: ExchangeSyncEngine(
    resolver: ExchangeInstrumentResolver(
      registry: registry,
      fiatInstrument: profileInstrument,
      existingLegInstrumentIds: { [backend] in
        (try? await backend.transactions.distinctLegInstrumentIds()) ?? []
      }),
    discovery: discovery),
  metadataResolverFactory: { token in
    CoinstashAssetMetadataResolver(client: coinstashClient, token: token)
  })
```

`discovery` is the `CryptoTokenDiscoveryService` already created earlier in `makeCryptoSyncWiring` (line ~78) and reused by wallet sync — pass that same instance (do **not** construct a second one). `backend.transactions` is the `TransactionRepository` (confirm the accessor name on `BackendProvider`; it is used elsewhere in this file as `backend.transactions`).

- [ ] **Step 4: Run tests + full build**

Run:
```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt; grep -i 'error:' .agent-tmp/build.txt
just test-mac CoinstashSyncSourceTests ExchangeSyncEngineResolutionTests ExchangeInstrumentResolverTests CoinstashCoinMetadataTests 2>&1 | tee .agent-tmp/test-output.txt; grep -i 'failed\|error:' .agent-tmp/test-output.txt
```
Expected: clean build, all PASS.

- [ ] **Step 5: Format and commit**

```bash
just format && just format-check
git add Shared/Exchange/CoinstashSyncSource.swift App/ProfileSession+CryptoSync.swift MoolahTests/Shared/Exchange/CoinstashSyncSourceTests.swift
git commit -m "$(cat <<'EOF'
feat: wire Coinstash token metadata resolution into sync

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Regression sweep, reviews, full suite

**Files:** none new — verification only.

- [ ] **Step 1: Full exchange + crypto-import test sweep**

Run:
```bash
just test-mac ExchangeSyncEngineTests CoinstashClientTests SyncedAccountStoreExchangeTests CryptoTokenDiscoveryServiceTests CryptoTokenDiscoveryCoalescerTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```
Expected: all PASS. `ExchangeSyncEngineTests` (the pre-existing suite) likely constructs the engine with the old `init(resolver:)` / calls `build(account:imported:)` — update those call sites to the new `init(resolver:discovery:)` + `build(account:imported:metadata:)` using a stub metadata resolver that returns metadata for the symbols those tests use (or `nil` + a seeded registry where they assert fallback). Keep each existing test's intent; only adapt construction.

- [ ] **Step 2: Compiler-warning check**

Run `just build-mac` and confirm zero warnings in changed files (the project treats warnings as errors; a clean build is sufficient evidence).

- [ ] **Step 3: Code reviews**

Invoke `@code-review` and `@concurrency-review` on the changed Swift files (new actor-touching paths: `ExchangeSyncEngine` → `CryptoTokenDiscoveryService` actor; the injected `@Sendable` closure capturing `backend`). Address Critical/Important findings; re-run the relevant suite after any fix.

- [ ] **Step 4: Whole-suite gate + cleanup**

Run:
```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
rm -f .agent-tmp/test-output.txt .agent-tmp/build.txt
```
Expected: full iOS + macOS suite green.

- [ ] **Step 5: Final commit (if reviews produced fixes)**

```bash
just format && just format-check
git add -A
git commit -m "$(cat <<'EOF'
chore: address review findings for Coinstash instrument resolution

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Manual remediation (operational, after merge — not a code task)

The large test profile already has Coinstash rows resolved to the wrong OP instrument. Per the design, remediate via the `automate-app` skill: delete the Coinstash account's transactions, then trigger a resync so they re-import through the corrected resolver. Not part of this plan's automated steps.

---

## Self-Review

**Spec coverage:**
- Stage 0 explicit BTC → Task 8 (`nonEvmNatives`, no metadata call) ✓
- `getCoinBySymbol` fetch + decode → Tasks 3–5 ✓
- Canonical Ethereum-preferred order → Task 8 `chainPreference`/`canonical` ✓
- Native sentinel → Task 4 collapse + Task 8 `contractAddress == nil` ✓
- Discovery path, supported vs non-ChainConfig chains → Task 1 generalisation + Task 8 call ✓
- Registry fallback (spam/priced/used/id) → Task 7; "used" data → Task 6 ✓
- Transient throws vs definitive fallback → Task 4 (throw on provider error / `nil` on unknown), Task 8 (errors propagate) ✓
- Fiat unchanged → Task 8 `isFiat` branch + Task 7 `fiatInstrument` ✓
- Wiring → Task 9 ✓
- End-to-end → Task 9 Step 1 + Task 10 ✓
- Out of scope (transfer detection) → not in plan ✓ (correct)

**Placeholder scan:** Task 4 Step 3 contains an explicitly-labelled placeholder extension comment with an instruction to delete it — acceptable (it is guidance, not shipped code). All other steps contain complete code. No "TBD"/"handle edge cases"/"similar to" left.

**Type consistency:** `ExchangeAssetChain`/`ExchangeAssetMetadata`/`ExchangeAssetMetadataResolving` (Task 2) used identically in Tasks 4/5/8. `coinMetadata(symbol:token:)` (Task 4) called by Task 5. `resolveOrLoad(chainId:contractAddress:symbol:name:decimals:)` (Task 1) called by Task 8. `fallbackInstrument(forSymbol:)` / `fiatInstrument` / `registeredInstrument(id:)` (Task 7) called by Task 8. `distinctLegInstrumentIds()` (Task 6) used by Task 9's closure. `build(account:imported:metadata:)` (Task 8) called by Task 9. Consistent.

**Known soft spots for the implementer to confirm against the live codebase (do not assume):** the exact `BackendProvider` accessor for the transaction repository (`backend.transactions`); the existing exchange-account test factory name (`ExchangeCreationHarness`); the existing Alchemy counting stub's name/counter in `CryptoTokenDiscoveryTestDoubles.swift`; the GRDB transaction-repo test suite's setup helper. Each task step says to mirror the existing pattern rather than invent.
