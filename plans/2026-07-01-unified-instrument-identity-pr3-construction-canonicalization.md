# Unified Instrument Identity — PR3: Construction-Time Canonicalization Implementation Plan

> **Intended final home:** `plans/2026-07-01-unified-instrument-identity-pr3-construction-canonicalization.md`
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure a retired cross-chain crypto id is never *minted* at construction time — so newly-synced L2 ETH legs, gas legs, presets, and discovered ERC-20s are stored under their canonical id (ETH → `1:native`, L2 USDC/USDT → mainnet contract) — and make WETH-on-L2 price via the canonical native id.

**Architecture:** PR3 is the "construction-time subset" of design §3 (§3.1, §3.2, §3.3) plus the WETH/wrapped-native pricing fix (§3a). It builds on PR1 (`accountChainId` on `ValuedPosition`, chain-of-holding from the account — already on `origin/main`) and PR2 (`CanonicalInstrumentResolver` — on `origin/unified-identity-pr2`, lands as #1195 before this branches). PR3 constructs and injects the resolver, which PR2 left unwired. Sync apply/conflict paths (§3.4/§3.5) and the data migration (§4) are **out of scope** (PR4/PR5).

**Tech Stack:** Swift 6, Swift Testing (`@Suite`/`@Test`/`#expect`), GRDB/SQLite, CloudKit, actor-isolated services, `OSAllocatedUnfairLock`.

---

## Global Constraints

- **Test framework: Swift Testing only** (`import Testing`, `@Suite`, `@Test`, `#expect`/`#require`). Never XCTest. Test files live under `MoolahTests/…` mirroring the source path, `@testable import Moolah`.
- **One extension per protocol conformance; group by responsibility.** Match neighbouring file conventions.
- **Money never crosses instruments implicitly** — `InstrumentAmount` arithmetic traps on mismatched instruments; do not introduce cross-instrument sums (guides/INSTRUMENT_CONVERSION_GUIDE.md). PR3 touches no `InstrumentAmount` arithmetic except the already-safe fold.
- **Concurrency:** the resolver is `final class … @unchecked Sendable` with an `OSAllocatedUnfairLock`-guarded map; never hold its lock across `await` (it is synchronous by design). Any new actor-boundary or lock work triggers `@concurrency-review` (guides/CONCURRENCY_GUIDE.md).
- **Chain-of-holding comes from the account, not the instrument** (design §2, shipped in PR1). `Instrument.chainId` on a canonical record is `1` for ETH and no longer means "the chain this holding is on."
- **`just format-check` must pass after every task**, and every task drives its review gate to zero findings before commit.
- **Review gate (mandatory, per task, driven to zero):** `@instrument-conversion-review` + `@code-review`. Add `@concurrency-review` for Task 1 (resolver lifecycle/threading across the actor + `SyncCoordinator` boundary). Task 6 (group-positions) additionally warrants `@code-review` on the view/valuator change.
- **`swift-format`/SwiftLint:** no new baseline entries, no cosmetic compensating shrinks.
- Build/test locally with `just build-mac` / `just test` (macOS) — capture output per guides/AI_WORKFLOW_GUIDE.md.

---

## Verified Codebase Facts (confirmed against `origin/main` + `origin/unified-identity-pr2`)

> The **local checkout is stale** (HEAD `a9fc2b66`, pre-PR1). PR1 is on `origin/main` (`5e3fa041`, `9b3203b9`). PR2 is on `origin/unified-identity-pr2`. All line citations below are from those refs — **re-read from the branch you actually build on** (main after #1195 merges).

### Resolver (PR2, `Shared/CryptoImport/CanonicalInstrumentResolver.swift`)
- `final class CanonicalInstrumentResolver: @unchecked Sendable`. **internal** access (usable across the module + `@testable` tests).
- Synchronous API: `func canonicalId(for id: String) -> String`, `func isAlias(_ id: String) -> Bool`.
- No-arg `init()` yields a **static-base-only** resolver (empty dynamic map). Static base map (`static let staticBaseMap`) already contains `"10:native"→"1:native"`, `"8453:native"→"1:native"`, and OP/Polygon/Base USDC + USDT → mainnet contracts.
- Dynamic layer: `func refresh(with registrations: [CryptoRegistration])`, `func refresh(from registry:) async`, `func startObserving(registry:changes: AsyncStream<Void>) -> Task<Void, Never>`.
- PR2 test style: `MoolahTests/Shared/CryptoImport/CanonicalInstrumentResolverTests.swift`, `@Suite`, nested `@Suite` for drift guard, constructs `CanonicalInstrumentResolver()` directly.

### §3.1 — `ChainConfig.nativeInstrument` (`Shared/CryptoImport/ChainConfig.swift`)
- `nativeInstrument` is a **stored `let`** on the `struct ChainConfig`, set in the `static let ethereum/optimism/base` literals (`:74–75`, `:90–91`, `:109–110`) via `Instrument.crypto(chainId: <n>, contractAddress: nil, symbol: "ETH", …)`. **Pure/static — no resolver in scope.**
- **All production readers of `.nativeInstrument`** (verified — no reader reads `.nativeInstrument.chainId` outside tests):
  - `Shared/CryptoImport/TransferEventBuilder.swift:310` — returns `context.chain.nativeInstrument` as a transfer-leg instrument (**wants canonicalization** ✓).
  - `Shared/CryptoImport/TransferEventBuilder.swift:345` — reads `.decimals` (ETH = 18 on all chains → unaffected).
  - `Shared/CryptoImport/TransferEventBuilder+NativeRegistration.swift:46` — `preregisterChainNativeInstrument` reads `.ticker/.name/.decimals`, then calls `discovery.resolveOrLoad(chain:contractAddress:nil,…)` which **rebuilds the id from `chain.chainId`** internally (so §3.3 canonicalizes it, not §3.1).
  - `Shared/CryptoImport/TransferReceiptCoalescer.swift:195` — reads `.decimals` (unaffected); `:201` — uses `chain.nativeInstrument` as the **gas-leg instrument** (**wants canonicalization** ✓).
  - `MoolahBenchmarks/CryptoSyncBenchmarks.swift:206,241,269` — uses `ChainConfig.ethereum.nativeInstrument` (chain 1, unchanged).
- **`nativeInstrument.chainId` readers = 3, all in tests** (`MoolahTests/Shared/CryptoImport/ChainConfigTests.swift:19,34,47`). **None are chain-of-holding-unsafe** — production chain-of-holding already reads `accountChainId` (PR1). The three test assertions (`optimism.nativeInstrument.chainId == 10`, `base … == 8453`, and `ChainConfigTests.nativeInstrumentsUseCorrectFactoryFormat`'s `"10:native"`/`"8453:native"`) **must be updated** to the canonical values.

### §3.2 — Presets (`Domain/Models/CryptoRegistration.swift:75–149`)
- `builtInPresets` includes `1:native` (`:84`), **`10:native` (`:92`)**, **`8453:native` (`:100`)**, `137:native`, `0:native` BTC, and ERC-20s (OP/UNI/ENS).
- `registerBuiltInPresetsIfMissing` (`Domain/Repositories/InstrumentRegistryRepository+Presets.swift:18`) currently skips via **id-based** `cryptoRegistration(byId: preset.id) != nil` (`:24`).
- `CryptoRegistration.assetKeys(from:)` (`:32`) and `CryptoProviderMapping.assetKey` already exist for assetKey-based logic.

### §3.3 — Discovery (`Shared/CryptoImport/CryptoTokenDiscoveryService.swift`)
- `actor CryptoTokenDiscoveryService`, `init(registry:resolver:)` where `resolver` is the **pricing** `CryptoRegistrationResolver` (NOT the canonical resolver — the new param needs a distinct name, e.g. `canonicalResolver`).
- `resolveOrLoad(chainId:contractAddress:symbol:name:decimals:)` (`:78`) builds `Instrument.crypto(chainId:contractAddress:…)` (`:85`), then registry lookup by `instrument.id` (`:92`), in-flight key `inFlight[instrument.id]` (`:95,102,108`), and `performResolution(instrument:)` persists (`:186,197`).
- Decompose helpers to promote: `Shared/CryptoPriceService.swift:187` `chainId(fromCryptoId:) -> Int?` and `:196` `contractAddress(fromCryptoId:) -> String?` — both `private`.
- Construction site: `App/ProfileSession+CryptoSync.swift:116` `CryptoTokenDiscoveryService(registry: registry, resolver: cryptoPriceService)` inside `makeCryptoSyncWiring` (`@MainActor static func`, called from `App/ProfileSession.swift:316`). **10+ test call sites** of `CryptoTokenDiscoveryService(registry:resolver:)` — a **defaulted** new param keeps them compiling.

### §3a — WETH/wrapped-native (`Domain/Models/WrappedNativeContracts.swift`)
- `canonicalByChain: [Int: String]` (`:28`) — chain → lowercased wrapper address. OP & Base WETH are both `0x4200…0006` (`:32,34`).
- `nativePricingInstrumentId(chainId:contractAddress:) -> String?` (`:49`) returns `"\(chainId):native"` (`:59`) — so OP WETH → `"10:native"` (retired post-migration).
- `canonicalWrappedInstrumentId(forChainId:) -> String?` (`:68`) returns the **single** wrapper id for a chain.
- Reader: `Shared/CryptoPriceService.swift:217` `registration(for:)` uses `nativePricingInstrumentId(...) ?? instrument.id` (`:219–222`).
- `Shared/FullConversionService.swift:293` `invalidateCache(for:)` — for a native crypto (`contractAddress == nil`), inserts `canonicalWrappedInstrumentId(forChainId: instrument.chainId)` into `staleIds` (`:298–304`). After §3.1, the only native id that exists is `1:native`, and OP/Base WETH now price via it — so evicting must enumerate **all** wrappers pricing via `1:native`.
- Test file: `MoolahTests/Domain/Models/WrappedNativeContractsTests.swift`.

### §2 revisit — fold & group-positions (all `origin/main`)
- `AssetHolding+Fold.swift:100` (PR1): `let chainIds = Set(group.compactMap { $0.accountChainId ?? $0.instrument.chainId })`; drives `contributingChainIds` (`:116`) → `AssetHolding.chainSummaryLabel`/`contributingChainNames` (`Domain/Models/AssetHolding.swift:99–107`, the #1191 chain caption).
- `ValuedPosition.accountChainId: Int?` (`:23`), default nil.
- Group host path: `Features/Accounts/Views/GroupDetailView.swift:8` `aggregatedGroupPositions(across:in:)` **sums per-instrument quantities keyed by `Instrument`** (`:11–25`) → returns `[Position]` (no chain). `GroupDetailView.swift:61` passes them to `.multiInstrumentPositionsSplit(… accountIds: context.accountIds)` with **no** `accountChainId`.
- `MultiInstrumentPositionsSplitModifier.swift:110`: `let owningChainId = accountIds.count == 1 ? accountChainId : nil` → **group hosts pass `nil`** to `PositionsValuator.valuate(… accountChainId:)`.
- **Confirmed regression (post-§3.1):** OP-ETH and Base-ETH legs both become `1:native`, so `aggregatedGroupPositions` (keyed by `Instrument`) **coalesces them into one `1:native` Position**; the group path stamps `accountChainId = nil`; the fold computes `contributingChainIds = {nil ?? 1} = [1]`. The grouped ETH row's `chainSummaryLabel` shows "Ethereum" instead of "OP · Base". Pre-§3.1 this worked because the two legs were distinct instruments (`10:native`, `8453:native`) whose `instrument.chainId` fallback carried the real chains. **Display-only** — quantity/value are correct. Single-account crypto wallet views are unaffected (`CryptoWalletAccountView.swift:56` passes `accountChainId: account.chainId`).

### Resolver injection wiring (App)
- `App/MoolahApp+SharedInstrumentScope.swift`: `bootstrapSyncCoordinator(setup:)` builds `scope = makeSharedInstrumentScope(...)` (owns `scope.registry: GRDBInstrumentRegistryRepository`), then `SyncCoordinator(… sharedInstrumentRegistry: scope.registry, …)`.
- `SyncCoordinator` (`Backends/CloudKit/Sync/SyncCoordinator.swift`) carries the shared services: `sharedInstrumentRegistry` (`:113`), `sharedMarketData` (`:121`), `sharedNetworking` (`:127`), `sharedRegistryStore` (`:146`), all `init`-injected (`:347–357`). **This is the natural carrier for the shared resolver** — reachable by both `ProfileSession` (Task 1) and `ProfileDataSyncHandler` (PR4).
- `ProfileSession.swift:316` reads `instrumentRegistry` + `cryptoPriceService` and calls `makeCryptoSyncWiring`; it can read `syncCoordinator?.sharedCanonicalResolver`.
- `GRDBInstrumentRegistryRepository.observeChanges() -> AsyncStream<Void>` exists (`…+InstrumentChangeObserving`, `GRDBInstrumentRegistryRepository.swift:232`), `@MainActor`.

---

## File Structure

**Create:**
- `Domain/Models/CryptoInstrumentID.swift` — `enum CryptoInstrumentID` namespacing `chainId(from:)` / `contractAddress(from:)` (promoted decompose helpers). *(Task 4)*
- `MoolahTests/Domain/Models/CryptoInstrumentIDTests.swift` *(Task 4)*
- `MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryCanonicalizationTests.swift` *(Task 4)*
- `MoolahTests/Domain/CryptoRegistrationPresetCanonicalizationTests.swift` *(Task 3)*

**Modify:**
- `Backends/CloudKit/Sync/SyncCoordinator.swift` — add `sharedCanonicalResolver` stored prop + init param. *(Task 1)*
- `App/MoolahApp+SharedInstrumentScope.swift` — construct resolver, `startObserving`, pass to `SyncCoordinator`. *(Task 1)*
- `App/ProfileSession+CryptoSync.swift` — thread `canonicalResolver` into `makeCryptoSyncWiring` → discovery init. *(Task 1)*
- `App/ProfileSession.swift` — pass `syncCoordinator?.sharedCanonicalResolver` at the `makeCryptoSyncWiring` call. *(Task 1)*
- `Shared/CryptoImport/CryptoTokenDiscoveryService.swift` — accept `canonicalResolver`, canonicalize `(chainId, contractAddress)` before build/lookup/inflight/persist, decompose to value fields. *(Tasks 1 + 4)*
- `Shared/CryptoImport/ChainConfig.swift` — OP/Base `nativeInstrument` → canonical `1:native`. *(Task 2)*
- `MoolahTests/Shared/CryptoImport/ChainConfigTests.swift` — update 3 assertions + add drift guard. *(Task 2)*
- `Domain/Models/CryptoRegistration.swift` — remove `10:native`/`8453:native` presets. *(Task 3)*
- `Domain/Repositories/InstrumentRegistryRepository+Presets.swift` — assetKey-based skip. *(Task 3)*
- `Shared/CryptoPriceService.swift` — delegate the two decompose privates to `CryptoInstrumentID`. *(Task 4)*
- `Domain/Models/WrappedNativeContracts.swift` — L2 WETH → `1:native`; add `wrapperIds(pricingVia:)` enumeration. *(Task 5)*
- `MoolahTests/Domain/Models/WrappedNativeContractsTests.swift` — L2 WETH + enumeration cases. *(Task 5)*
- `Shared/FullConversionService.swift` — evict all wrappers pricing via the invalidated native id. *(Task 5)*
- `MoolahTests/Shared/FullConversionServiceTests.swift` (or nearest existing) — WETH eviction case. *(Task 5)*
- **Task 6 (flagged):** `Features/Accounts/Views/GroupDetailView.swift`, `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`, `Shared/PositionsValuator.swift` (+ tests) — chain-aware group aggregation. *(see Task 6 for the option decision)*

---

## Task Ordering & Dependency Notes

1. **Task 1 (resolver wiring)** — construct/inject the shared resolver. Dependency for Task 4 (and PR4). *Note: §3.1 (Task 2) does **not** need the resolver — L2-ETH→`1:native` is a fixed fact also encoded in `staticBaseMap` — but the team lead requested wiring first, and Task 4 does need it, so it leads.*
2. **Task 2 (§3.1 ChainConfig)** — independent of the resolver.
3. **Task 3 (§3.2 presets)** — independent.
4. **Task 4 (§3.3 discovery canonicalization + decompose helper)** — depends on Task 1.
5. **Task 5 (§3a WETH)** — independent.
6. **Task 6 (fold/group-positions revisit)** — ⚠️ **FLAGGED risky / multi-approach** (see task). Do last; controller picks the option.

---

### Task 1: Construct and inject the shared `CanonicalInstrumentResolver`

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift` (add `sharedCanonicalResolver` around the other `shared*` props `:113–146` and init `:347–357`)
- Modify: `App/MoolahApp+SharedInstrumentScope.swift:14` (`bootstrapSyncCoordinator`)
- Modify: `App/ProfileSession+CryptoSync.swift:105` (`makeCryptoSyncWiring` signature) + `:116` (discovery init)
- Modify: `App/ProfileSession.swift:316` (call site)
- Modify: `Shared/CryptoImport/CryptoTokenDiscoveryService.swift:42` (init) — add stored `canonicalResolver`, defaulted
- Test: `MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryCanonicalizationTests.swift` (wiring smoke test — shared with Task 4)

**Interfaces:**
- Consumes: `CanonicalInstrumentResolver` (PR2), `GRDBInstrumentRegistryRepository.observeChanges()`.
- Produces:
  - `SyncCoordinator.sharedCanonicalResolver: CanonicalInstrumentResolver?` (nonisolated let).
  - `CryptoTokenDiscoveryService.init(registry:resolver:canonicalResolver: CanonicalInstrumentResolver = CanonicalInstrumentResolver())`.
  - `ProfileSession.makeCryptoSyncWiring(…, canonicalResolver: CanonicalInstrumentResolver = CanonicalInstrumentResolver())`.

- [ ] **Step 1: Write the failing test** — a defaulted-resolver discovery service canonicalizes an OP native via the static base layer (proves the new param exists and is applied end-to-end).

```swift
// MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryCanonicalizationTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoTokenDiscovery — canonicalization")
struct CryptoTokenDiscoveryCanonicalizationTests {
  @Test("OP native resolves and persists under the canonical mainnet id")
  func opNativeCanonicalizes() async throws {
    let registry = InMemoryInstrumentRegistry()  // existing test double
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: StubCryptoRegistrationResolver.succeedingNative,  // existing double
      canonicalResolver: CanonicalInstrumentResolver())  // static base only
    let reg = try await discovery.resolveOrLoad(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    #expect(reg.instrument.id == "1:native")
    #expect(reg.instrument.chainId == 1)
    #expect(reg.instrument.contractAddress == nil)
    #expect(try await registry.cryptoRegistration(byId: "10:native") == nil)
    #expect(try await registry.cryptoRegistration(byId: "1:native") != nil)
  }
}
```
> Reuse the exact registry/resolver test doubles used by neighbouring `MoolahTests/Features/Sync/SyncedAccountStore*Tests.swift` and `CryptoTokenDiscoveryServiceTests` — read one before writing to copy the double names.

- [ ] **Step 2: Run the test to verify it fails** — `just test` filtered to the suite. Expected: compile failure ("extra argument 'canonicalResolver'") then, after Step 3 wiring but before Task 4 logic, `reg.instrument.id == "10:native"` mismatch.

- [ ] **Step 3: Add the discovery `canonicalResolver` param (plumbing only — no canonicalization logic yet; that is Task 4).**

```swift
// CryptoTokenDiscoveryService.swift
private let canonicalResolver: CanonicalInstrumentResolver

init(
  registry: any InstrumentRegistryRepository,
  resolver: any CryptoRegistrationResolver,
  canonicalResolver: CanonicalInstrumentResolver = CanonicalInstrumentResolver()
) {
  self.registry = registry
  self.resolver = resolver
  self.canonicalResolver = canonicalResolver
}
```

- [ ] **Step 4: Carry the resolver on `SyncCoordinator`.**

```swift
// SyncCoordinator.swift — beside the other shared* props
nonisolated let sharedCanonicalResolver: CanonicalInstrumentResolver?
// … in init, add param `sharedCanonicalResolver: CanonicalInstrumentResolver? = nil`
self.sharedCanonicalResolver = sharedCanonicalResolver
```

- [ ] **Step 5: Construct + observe in `bootstrapSyncCoordinator`.**

```swift
// MoolahApp+SharedInstrumentScope.swift, inside bootstrapSyncCoordinator, after `scope` is built:
let canonicalResolver = CanonicalInstrumentResolver()
// App-lifetime observation: rebuilds the dynamic alias map on every registry change.
_ = canonicalResolver.startObserving(
  registry: scope.registry, changes: scope.registry.observeChanges())
let coordinator = SyncCoordinator(
  containerManager: setup.manager,
  sharedInstrumentRegistry: scope.registry,
  sharedMarketData: scope.marketData,
  sharedRegistryStore: registryStore,
  sharedNetworking: networking,
  sharedCanonicalResolver: canonicalResolver)
```
> The returned `Task` runs for the app's lifetime; `SyncCoordinator` outlives boot so no explicit cancellation is needed (matches the fire-and-forget `attachSharedInstrumentRegistrySyncHooks` pattern). If `@concurrency-review` wants the task retained, store it on the coordinator.

- [ ] **Step 6: Thread through `makeCryptoSyncWiring` and its call site.**

```swift
// ProfileSession+CryptoSync.swift
static func makeCryptoSyncWiring(
  backend: BackendProvider,
  registry: (any InstrumentRegistryRepository)?,
  cryptoPriceService: CryptoPriceService,
  profileInstrument: Instrument,
  canonicalResolver: CanonicalInstrumentResolver = CanonicalInstrumentResolver()
) -> CryptoSyncWiring? {
  …
  let discovery = CryptoTokenDiscoveryService(
    registry: registry, resolver: cryptoPriceService, canonicalResolver: canonicalResolver)
  …
}
```
```swift
// ProfileSession.swift:316
let cryptoWiring = Self.makeCryptoSyncWiring(
  backend: backend,
  registry: instrumentRegistry,
  cryptoPriceService: cryptoPriceService,
  profileInstrument: profile.instrument,
  canonicalResolver: syncCoordinator?.sharedCanonicalResolver ?? CanonicalInstrumentResolver())
```

- [ ] **Step 7: Run the test** — expected: still fails on `reg.instrument.id == "1:native"` (canonicalization logic lands in Task 4). Confirm it now fails on the *assertion*, not compilation. Leave the test file in place for Task 4.

- [ ] **Step 8: Build the full app to prove wiring compiles** — `just build-mac`. Expected: PASS. Confirm existing `CryptoTokenDiscoveryService(registry:resolver:)` test call sites still compile (defaulted param).

- [ ] **Step 9: Review gate + commit** — `@code-review` + `@concurrency-review` (resolver lifecycle across the `SyncCoordinator`/actor boundary) to zero.

```bash
git add Backends/CloudKit/Sync/SyncCoordinator.swift App/MoolahApp+SharedInstrumentScope.swift \
  App/ProfileSession+CryptoSync.swift App/ProfileSession.swift \
  Shared/CryptoImport/CryptoTokenDiscoveryService.swift \
  MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryCanonicalizationTests.swift
git commit -m "feat(crypto): construct and inject the shared canonical instrument resolver"
```

---

### Task 2: §3.1 — `ChainConfig.nativeInstrument` returns the canonical `1:native` for L2s

**Files:**
- Modify: `Shared/CryptoImport/ChainConfig.swift:90–91` (optimism), `:109–110` (base)
- Modify: `MoolahTests/Shared/CryptoImport/ChainConfigTests.swift:34,47` and `nativeInstrumentsUseCorrectFactoryFormat`

**Interfaces:**
- Consumes: `Instrument.crypto`, `CanonicalInstrumentResolver.staticBaseMap` (drift guard).
- Produces: `ChainConfig.optimism.nativeInstrument.id == "1:native"`, `ChainConfig.base.nativeInstrument.id == "1:native"`.

> **Chosen approach (recommended): hardcode the canonical instrument in the static literals.** The L2-ETH→`1:native` mapping is a fixed constant, mirrored in the resolver's `staticBaseMap`, so no resolver injection into `ChainConfig` is warranted (injecting one would force `nativeInstrument` to become a function taking a resolver and would ripple into every `TransferEventBuilder`/`TransferReceiptCoalescer` call site — far more invasive for zero behavioural gain). A **drift-guard test** ties the two hardcoded facts together.

- [ ] **Step 1: Write/adjust the failing tests.**

```swift
// ChainConfigTests.swift — optimismConfigIsCorrect:
#expect(config.nativeInstrument.ticker == "ETH")
#expect(config.nativeInstrument.id == "1:native")      // canonical, not 10:native
#expect(config.nativeInstrument.chainId == 1)          // was 10
// baseConfigIsCorrect: same two lines (was 8453)
// nativeInstrumentsUseCorrectFactoryFormat:
#expect(ChainConfig.ethereum.nativeInstrument.id == "1:native")
#expect(ChainConfig.optimism.nativeInstrument.id == "1:native")
#expect(ChainConfig.base.nativeInstrument.id == "1:native")
```
Add a drift guard (new `@Test`):

```swift
@Test("L2 native instruments match the resolver's static canonical map")
func l2NativeMatchesResolverStaticMap() {
  let resolver = CanonicalInstrumentResolver()
  #expect(ChainConfig.optimism.nativeInstrument.id == resolver.canonicalId(for: "10:native"))
  #expect(ChainConfig.base.nativeInstrument.id == resolver.canonicalId(for: "8453:native"))
}
```

- [ ] **Step 2: Run the tests to verify they fail** — `just test` filtered to `ChainConfig`. Expected: FAIL (still `10:native`/`8453:native`).

- [ ] **Step 3: Change the two literals.**

```swift
// ChainConfig.swift — optimism:
nativeInstrument: Instrument.crypto(
  chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
// base: identical (chainId: 1)
```
Update each `nativeInstrument` doc comment (`:20–22`) to note "the canonical mainnet ETH instrument (`1:native`); chain-of-holding comes from the account (design §2/§3.1)".

- [ ] **Step 4: Run the tests** — expected: PASS. Also run `TransferEventBuilder`, `TransferReceiptCoalescer` suites — expected: PASS (gas/native legs now stamp `1:native`; `.decimals` unchanged at 18).

- [ ] **Step 5: Review gate + commit** — `@code-review` + `@instrument-conversion-review` to zero.

```bash
git add Shared/CryptoImport/ChainConfig.swift MoolahTests/Shared/CryptoImport/ChainConfigTests.swift
git commit -m "feat(crypto): L2 native gas instrument canonicalizes to mainnet ETH (design §3.1)"
```

---

### Task 3: §3.2 — Remove L2 native presets; skip presets by assetKey

**Files:**
- Modify: `Domain/Models/CryptoRegistration.swift:92–107` (drop `10:native` + `8453:native`)
- Modify: `Domain/Repositories/InstrumentRegistryRepository+Presets.swift:18–39`
- Test: `MoolahTests/Domain/CryptoRegistrationPresetCanonicalizationTests.swift`

**Interfaces:**
- Consumes: `CryptoRegistration.assetKeys(from:)`, `InstrumentRegistryRepository.allCryptoRegistrations()`, `cryptoRegistration(byId:)`, `registerCrypto`.
- Produces: no `builtInPresets` entry with id `10:native`/`8453:native`; `registerBuiltInPresetsIfMissing` skips any preset whose `mapping.assetKey` matches an already-registered canonical registration.

- [ ] **Step 1: Write the failing tests.**

```swift
// CryptoRegistrationPresetCanonicalizationTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("builtInPresets — canonical only")
struct CryptoRegistrationPresetCanonicalizationTests {
  @Test("no L2 native ETH presets remain")
  func noL2NativePresets() {
    let ids = Set(CryptoRegistration.builtInPresets.map(\.instrument.id))
    #expect(ids.contains("1:native"))
    #expect(!ids.contains("10:native"))
    #expect(!ids.contains("8453:native"))
  }

  @Test("preset skipped when a same-assetKey canonical registration exists")
  func skipsByAssetKey() async throws {
    let registry = InMemoryInstrumentRegistry()
    // Seed canonical mainnet ETH already registered.
    try await registry.registerCrypto(
      .crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ethereum",
        cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"))
    // A hypothetical non-canonical same-asset preset must NOT be minted.
    await registry.registerBuiltInPresetsIfMissing(
      presets: [CryptoRegistration(
        instrument: .crypto(
          chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
        mapping: CryptoProviderMapping(
          instrumentId: "10:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"))])
    #expect(try await registry.cryptoRegistration(byId: "10:native") == nil)
  }
}
```
> If `registerBuiltInPresetsIfMissing` has no `presets:` seam today, **add a testable overload** `registerBuiltInPresetsIfMissing(presets: [CryptoRegistration])` and make the no-arg version call it with `CryptoRegistration.builtInPresets` (keeps the production entry point unchanged, gives the test a seam). Confirm `InMemoryInstrumentRegistry` exists as a double; else use the neighbouring double from `MoolahTests/Domain/InstrumentRegistryContractTests.swift`.

- [ ] **Step 2: Run the tests to verify they fail** — Expected: FAIL (`10:native` still present / still minted).

- [ ] **Step 3: Remove the two presets** (`CryptoRegistration.swift` — delete the `10:native` and `8453:native` `CryptoRegistration(…)` blocks at `:92–107`).

- [ ] **Step 4: Switch the skip to assetKey-based.**

```swift
// InstrumentRegistryRepository+Presets.swift
func registerBuiltInPresetsIfMissing() async {
  await registerBuiltInPresetsIfMissing(presets: CryptoRegistration.builtInPresets)
}

func registerBuiltInPresetsIfMissing(presets: [CryptoRegistration]) async {
  let logger = Logger(subsystem: "com.moolah.app", category: "InstrumentRegistryPresets")
  let existingAssetKeys: Set<String>
  do {
    existingAssetKeys = Set(try await allCryptoRegistrations().map { $0.mapping.assetKey })
  } catch is CancellationError {
    return
  } catch {
    logger.warning("registerBuiltInPresetsIfMissing: allCryptoRegistrations failed: \(error.localizedDescription, privacy: .public)")
    existingAssetKeys = []
  }
  for preset in presets {
    do {
      try Task.checkCancellation()
      if existingAssetKeys.contains(preset.mapping.assetKey) { continue }
      try await registerCrypto(preset.instrument, mapping: preset.mapping)
    } catch is CancellationError {
      return
    } catch {
      logger.warning("""
        registerBuiltInPresetsIfMissing: \(preset.id, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }
}
```
> **Verify** `CryptoProviderMapping.assetKey` is non-optional `String` (`Domain/Models/CryptoProviderMapping.swift:29`) so a no-key preset's assetKey defaults to its own id — a distinct assetKey per no-key preset, so unrelated presets are never skipped against each other. The `existingAssetKeys` snapshot is captured once up front (not re-queried per preset) — presets seeded in the same run don't cross-skip each other, preserving the prior per-preset behaviour for distinct assets.

- [ ] **Step 5: Run the tests** — Expected: PASS. Also run the existing preset/`#791` suites to confirm the offline-seed path still lands `1:native`, BTC, MATIC, OP/UNI/ENS.

- [ ] **Step 6: Review gate + commit** — `@code-review` + `@instrument-conversion-review` + `@database-code-review` (touches a registry write path) to zero.

```bash
git add Domain/Models/CryptoRegistration.swift Domain/Repositories/InstrumentRegistryRepository+Presets.swift \
  MoolahTests/Domain/CryptoRegistrationPresetCanonicalizationTests.swift
git commit -m "feat(crypto): drop L2 native presets, skip presets by assetKey (design §3.2)"
```

---

### Task 4: §3.3 — Canonicalize `(chainId, contractAddress)` in discovery + promote decompose helpers

**Files:**
- Create: `Domain/Models/CryptoInstrumentID.swift`
- Create: `MoolahTests/Domain/Models/CryptoInstrumentIDTests.swift`
- Modify: `Shared/CryptoPriceService.swift:187–199` (delegate privates to `CryptoInstrumentID`)
- Modify: `Shared/CryptoImport/CryptoTokenDiscoveryService.swift:78–114`
- Test: `MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryCanonicalizationTests.swift` (from Task 1)

**Interfaces:**
- Consumes: `CanonicalInstrumentResolver.canonicalId(for:)` (Task 1 injection).
- Produces:
  - `enum CryptoInstrumentID { static func chainId(from id: String) -> Int?; static func contractAddress(from id: String) -> String? }`.
  - Discovery persists the canonical id with **matching value fields** (`instrument.chainId`/`contractAddress` decomposed from the canonical id).

- [ ] **Step 1: Write the failing decompose-helper test.**

```swift
// CryptoInstrumentIDTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoInstrumentID")
struct CryptoInstrumentIDTests {
  @Test("chainId parses the prefix")
  func chainIdParses() {
    #expect(CryptoInstrumentID.chainId(from: "1:native") == 1)
    #expect(CryptoInstrumentID.chainId(from: "8453:0xabc") == 8453)
    #expect(CryptoInstrumentID.chainId(from: "notacrypto") == nil)
  }
  @Test("contractAddress is nil for native, else the suffix")
  func addressParses() {
    #expect(CryptoInstrumentID.contractAddress(from: "1:native") == nil)
    #expect(CryptoInstrumentID.contractAddress(from: "1:0xABC") == "0xABC")
    #expect(CryptoInstrumentID.contractAddress(from: "nocolon") == nil)
  }
}
```

- [ ] **Step 2: Run to verify it fails** — Expected: compile failure ("CryptoInstrumentID not found").

- [ ] **Step 3: Create `CryptoInstrumentID`** (move the two private impls from `CryptoPriceService.swift:187–199` verbatim into static funcs; keep the doc comments).

```swift
// Domain/Models/CryptoInstrumentID.swift
import Foundation

/// Parses a crypto `Instrument.id` of the form `"<chainId>:native"` or
/// `"<chainId>:<contractAddress>"` back into its components. Shared by the
/// price service and the discovery service's canonicalization decomposition.
enum CryptoInstrumentID {
  static func chainId(from id: String) -> Int? {
    Int(id.prefix(while: { $0 != ":" }))
  }
  static func contractAddress(from id: String) -> String? {
    guard let colon = id.firstIndex(of: ":") else { return nil }
    let suffix = String(id[id.index(after: colon)...])
    return suffix == "native" ? nil : suffix
  }
}
```
Then in `CryptoPriceService.swift`, replace the two private method bodies with `CryptoInstrumentID.chainId(from:)` / `.contractAddress(from:)` (or delete them and update their call sites — grep `chainId(fromCryptoId:`/`contractAddress(fromCryptoId:` first).

- [ ] **Step 4: Run** the `CryptoInstrumentID` + `CryptoPriceService` suites — Expected: PASS.

- [ ] **Step 5:** The discovery canonicalization test already exists (Task 1). Add the ERC-20 decomposition case:

```swift
// append to CryptoTokenDiscoveryCanonicalizationTests
@Test("L2 USDC resolves under the mainnet contract with mainnet value fields")
func opUSDCCanonicalizes() async throws {
  let registry = InMemoryInstrumentRegistry()
  let discovery = CryptoTokenDiscoveryService(
    registry: registry,
    resolver: StubCryptoRegistrationResolver.succeeding,
    canonicalResolver: CanonicalInstrumentResolver())
  let reg = try await discovery.resolveOrLoad(
    chainId: 10,
    contractAddress: "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
    symbol: "USDC", name: "USD Coin", decimals: 6)
  #expect(reg.instrument.id == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
  #expect(reg.instrument.chainId == 1)
  #expect(reg.instrument.contractAddress == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
}

@Test("an unknown ERC-20 is unchanged (own id)")
func unknownTokenUnchanged() async throws {
  let registry = InMemoryInstrumentRegistry()
  let discovery = CryptoTokenDiscoveryService(
    registry: registry,
    resolver: StubCryptoRegistrationResolver.unpriced,
    canonicalResolver: CanonicalInstrumentResolver())
  let reg = try await discovery.resolveOrLoad(
    chainId: 10, contractAddress: "0xdeadbeef", symbol: "ZZZ", name: "Zzz", decimals: 18)
  #expect(reg.instrument.id == "10:0xdeadbeef")
}
```

- [ ] **Step 6: Run to verify failure** — Expected: `id == "10:native"` / `"10:0x0b2c…"` mismatch (Task 1 plumbing present, logic absent).

- [ ] **Step 7: Implement canonicalization in `resolveOrLoad`.**

```swift
// CryptoTokenDiscoveryService.swift, top of resolveOrLoad(chainId:...)
let requestedId = Instrument.crypto(
  chainId: chainId, contractAddress: contractAddress,
  symbol: symbol, name: name, decimals: decimals).id
let canonicalId = canonicalResolver.canonicalId(for: requestedId)
// Decompose the canonical id so the row's value fields match its id.
let canonicalChainId = CryptoInstrumentID.chainId(from: canonicalId) ?? chainId
let canonicalAddress = CryptoInstrumentID.contractAddress(from: canonicalId)
let instrument = Instrument.crypto(
  chainId: canonicalChainId,
  contractAddress: canonicalAddress,
  symbol: symbol, name: name, decimals: decimals)
// … existing registry lookup / inFlight / performResolution now all key on
// instrument.id == canonicalId.
```
> `symbol/name/decimals` are kept from the caller. For a real canonical collapse (ETH↔ETH, USDC↔USDC) these already match the mainnet member by `assetKey` definition; the canonical **id and value fields** are what must be correct. Do **not** re-canonicalize inside `performResolution` — `instrument` is already canonical there.

- [ ] **Step 8: Run** the discovery canonicalization suite — Expected: PASS (all 4 cases incl. Task 1's OP-native).

- [ ] **Step 9: Run the full crypto discovery/sync test suites** — audit for pre-existing tests that resolve a **real** L2 native or L2 USDC/USDT address and assert the old per-chain id; update those to the canonical id (behavioural change is intended). Tests using synthetic addresses (`0xToken…`) are unaffected (unknown → own id).

- [ ] **Step 10: Review gate + commit** — `@code-review` + `@instrument-conversion-review` + `@concurrency-review` (actor `resolveOrLoad` now reads the injected resolver) to zero.

```bash
git add Domain/Models/CryptoInstrumentID.swift MoolahTests/Domain/Models/CryptoInstrumentIDTests.swift \
  Shared/CryptoPriceService.swift Shared/CryptoImport/CryptoTokenDiscoveryService.swift \
  MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryCanonicalizationTests.swift
git commit -m "feat(crypto): canonicalize discovered tokens at construction, decomposing value fields (design §3.3)"
```

---

### Task 5: §3a — WETH-on-L2 prices via the canonical native id; invalidation evicts all wrappers

**Files:**
- Modify: `Domain/Models/WrappedNativeContracts.swift`
- Modify: `MoolahTests/Domain/Models/WrappedNativeContractsTests.swift`
- Modify: `Shared/FullConversionService.swift:293–304`
- Test: `MoolahTests/Shared/FullConversionServiceTests.swift` (or the nearest existing invalidateCache suite — grep `invalidateCache` under `MoolahTests` first)

**Interfaces:**
- Produces:
  - `WrappedNativeContracts.nativePricingInstrumentId(chainId: 10/8453, contractAddress: <WETH>) == "1:native"`.
  - `WrappedNativeContracts.wrapperIds(pricingVia nativeId: String) -> [String]` — every listed wrapper id whose native pricing id equals `nativeId` (for `"1:native"`: mainnet + OP + Base WETH).

- [ ] **Step 1: Write the failing `WrappedNativeContracts` tests.**

```swift
// WrappedNativeContractsTests.swift
@Test("L2 WETH prices via the canonical mainnet native id")
func l2WethMapsToMainnetNative() {
  let opWeth = "0x4200000000000000000000000000000000000006"
  #expect(WrappedNativeContracts.nativePricingInstrumentId(chainId: 10, contractAddress: opWeth) == "1:native")
  #expect(WrappedNativeContracts.nativePricingInstrumentId(chainId: 8453, contractAddress: opWeth) == "1:native")
  #expect(WrappedNativeContracts.nativePricingInstrumentId(chainId: 1,
    contractAddress: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2") == "1:native")
}

@Test("Polygon WMATIC still prices via its own native id")
func polygonWmaticUnchanged() {
  #expect(WrappedNativeContracts.nativePricingInstrumentId(chainId: 137,
    contractAddress: "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270") == "137:native")
}

@Test("wrapperIds enumerates every wrapper pricing via the canonical native id")
func wrapperIdsForCanonicalNative() {
  let ids = Set(WrappedNativeContracts.wrapperIds(pricingVia: "1:native"))
  #expect(ids == [
    "1:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
    "10:0x4200000000000000000000000000000000000006",
    "8453:0x4200000000000000000000000000000000000006",
  ])
  #expect(WrappedNativeContracts.wrapperIds(pricingVia: "137:native")
    == ["137:0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270"])
}
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL (`"10:native"` / no `wrapperIds`).

- [ ] **Step 3: Rework `WrappedNativeContracts`** — carry a per-chain canonical native id.

```swift
// WrappedNativeContracts.swift
/// Wrapped-native contract address (lowercased) + the canonical native
/// instrument id it prices via. L2 ETH wrappers price via mainnet ETH
/// (`1:native`, design §3a); non-unified chains price via their own native.
private static let entries: [Int: (address: String, nativeId: String)] = [
  1: ("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", "1:native"),      // WETH
  10: ("0x4200000000000000000000000000000000000006", "1:native"),      // OP WETH → mainnet ETH
  8453: ("0x4200000000000000000000000000000000000006", "1:native"),    // Base WETH → mainnet ETH
  42161: ("0x82af49447d8a07e3bd95bd0d56f35241523fbab1", "42161:native"),// Arbitrum WETH (not yet unified)
  137: ("0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270", "137:native"),   // WMATIC
  43114: ("0xb31f66aa3c1e785363f0875a1b74e27b85fd66c7", "43114:native"),// WAVAX
]

static func nativePricingInstrumentId(chainId: Int?, contractAddress: String?) -> String? {
  guard let chainId, let contractAddress, let entry = entries[chainId],
    contractAddress.lowercased() == entry.address
  else { return nil }
  return entry.nativeId
}

/// Every listed wrapper id (`"<chainId>:<address>"`) that prices via `nativeId`.
/// Used by cache invalidation: dropping the native rate must also evict all
/// wrappers memoised under their own id (design §3a).
static func wrapperIds(pricingVia nativeId: String) -> [String] {
  entries.compactMap { chainId, entry in
    entry.nativeId == nativeId ? "\(chainId):\(entry.address)" : nil
  }
}
```
> Replace the old `canonicalByChain` + `canonicalWrappedInstrumentId(forChainId:)`. Grep for `canonicalWrappedInstrumentId` callers first — the only production caller is `FullConversionService.invalidateCache` (Step 4). If other callers exist, keep a thin `canonicalWrappedInstrumentId(forChainId:)` shim over `entries` or migrate them. **Arbitrum stays `42161:native`** (not in the resolver's static/unified set for PR3).

- [ ] **Step 4: Update `FullConversionService.invalidateCache`.**

```swift
// FullConversionService.swift — replace the wrapper block:
if instrument.kind == .cryptoToken, instrument.contractAddress == nil {
  // A native rate change invalidates every wrapper priced via this native id
  // (mainnet + L2 WETH all price via 1:native post-canonicalization).
  for wrapperId in WrappedNativeContracts.wrapperIds(pricingVia: instrument.id) {
    staleIds.insert(wrapperId)
  }
}
```

- [ ] **Step 5: Write/adjust the `invalidateCache` test** — invalidating `1:native` marks OP + Base WETH ids stale (assert via a seeded `rateCache` entry keyed on an L2 WETH id being dropped after `invalidateCache(for: 1:native ETH)`). Mirror the existing WETH-eviction test's harness.

- [ ] **Step 6: Run** the WrappedNativeContracts + FullConversionService suites — Expected: PASS.

- [ ] **Step 7: Review gate + commit** — `@code-review` + `@instrument-conversion-review` to zero.

```bash
git add Domain/Models/WrappedNativeContracts.swift MoolahTests/Domain/Models/WrappedNativeContractsTests.swift \
  Shared/FullConversionService.swift MoolahTests/Shared/FullConversionServiceTests.swift
git commit -m "feat(pricing): L2 WETH prices via canonical mainnet ETH; invalidation evicts all wrappers (design §3a)"
```

---

### Task 6: ⚠️ Fold / group-positions revisit — keep the per-chain breakdown for grouped unified holdings

> **FLAGGED — risky / multi-approach. Controller decides the option before implementation.**
>
> **The regression (confirmed):** after Task 2, OP-ETH and Base-ETH legs mint as `1:native`. `aggregatedGroupPositions` (`GroupDetailView.swift:8`, keyed by `Instrument`) coalesces them into one `1:native` `Position`; the group host forces `accountChainId = nil` (`MultiInstrumentPositionsSplitModifier.swift:110`); so `AssetHolding+Fold.swift:100` computes `contributingChainIds = [1]` and the grouped ETH row's `chainSummaryLabel` shows "Ethereum" instead of "OP · Base". **Display-only** (quantity/value correct); confined to **multi-account group hosts** spanning ≥2 L2 chains holding the same native/unified asset. Single-account crypto-wallet views are correct (they pass `accountChainId: account.chainId`). PR1's `accountChainId ?? instrument.chainId` fallback no longer rescues this because both the account chain (nil) and the instrument chain (1) are now wrong for the breakdown.
>
> **Design tension to resolve:** design §5 says "Suppress the #1191 chain caption for the canonical/unified case," which — if applied to the holdings-row `chainSummaryLabel` — would make the regression moot. But the team-lead's PR3 brief (and the project memory note) explicitly wants grouped unified holdings to **keep their per-chain breakdown**. These conflict. **Controller: pick Option 1 (keep breakdown) or Option 2 (suppress, align §5).**

**Option 1 (recommended by the brief — keep the breakdown):** make the group-positions pipeline chain-aware so the fold sees the real contributing chains.

**Files (Option 1):**
- Modify: `Features/Accounts/Views/GroupDetailView.swift:8–27` — key aggregation by `(Instrument, chainId)`, emitting one `(Position, accountChainId)` per (instrument, chain).
- Modify: `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift` — accept per-row chain and pass to the valuator.
- Modify: `Shared/PositionsValuator.swift` — overload/extend `valuate` to stamp a **per-position** `accountChainId` (e.g. accept `[(Position, Int?)]`), instead of one host-wide value.
- Tests: `MoolahTests/Features/Accounts/GroupDetailAggregationTests.swift` (or existing `aggregatedGroupPositions` test), `MoolahTests/Domain/Models/AssetHoldingFoldTests.swift`.

**Interfaces (Option 1):**
- Produces: a grouped fold over OP-wallet ETH + Base-wallet ETH (both `1:native`) yields `AssetHolding.contributingChainIds == [10, 8453]` and `chainSummaryLabel == "OP · Base"`, with summed quantity/value unchanged.

- [ ] **Step 1 (Option 1): Write the failing fold test** — two `ValuedPosition`s, same instrument `1:native`, `accountChainId` 10 and 8453; assert `AssetHolding.fold(...).first?.contributingChainIds == [10, 8453]` and `quantity` summed. *(This test passes today only if per-position chains survive to the fold — it fails once aggregation coalesces them or forces nil.)*

- [ ] **Step 2 (Option 1): Write the failing aggregation test** — `aggregatedGroupPositions`-equivalent over two accounts (chain 10 & 8453) each holding `1:native` ETH returns **two** chain-tagged rows, not one.

- [ ] **Step 3 (Option 1): Run** — Expected: FAIL (coalesced to one row / chain lost).

- [ ] **Step 4 (Option 1): Implement chain-aware aggregation** — change `aggregatedGroupPositions` to key `sums`/`order` by `struct GroupKey { let instrument: Instrument; let chainId: Int? }` (chain from `accounts.by(id:)?.chainId`), returning `[(position: Position, accountChainId: Int?)]`. Thread the tuple list through `multiInstrumentPositionsSplit` and `PositionsValuator.valuate` (new overload stamping each row's own `accountChainId`). Remove the `owningChainId = accountIds.count == 1 ? … : nil` collapse — chain now travels per-row.

- [ ] **Step 5 (Option 1): Run** the fold + aggregation + `MultiInstrumentPositionsSplitModifier` + `PositionsValuator` suites — Expected: PASS. Confirm the single-account crypto-wallet path still yields its account's single chain.

- [ ] **Step 6 (Option 1): Review gate + commit** — `@code-review` + `@instrument-conversion-review` (batch-conversion coalescing unaffected; the extra rows still net the same host-currency sums) to zero.

```bash
git add Features/Accounts/Views/GroupDetailView.swift \
  Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift \
  Shared/PositionsValuator.swift MoolahTests/Features/Accounts/GroupDetailAggregationTests.swift \
  MoolahTests/Domain/Models/AssetHoldingFoldTests.swift
git commit -m "fix(positions): grouped unified holdings keep their per-chain breakdown (design §2/§3.1)"
```

**Option 2 (smaller — align with §5, drop the breakdown display):** suppress `chainSummaryLabel`/`contributingChainNames` when a holding is unified (its `contributingInstrumentIds` collapse to a single canonical id but span multiple accounts/chains). One change in `Domain/Models/AssetHolding.swift:99–107` + a test asserting a unified holding returns `chainSummaryLabel == nil`. Accepts the loss of the "OP · Base" caption. Choose only if the controller decides §5 supersedes the memory note.

---

## Self-Review

- **§3.1** → Task 2 (ChainConfig + tests + drift guard; gas/native legs fixed transitively). ✓
- **§3.2** → Task 3 (remove L2 native presets + assetKey skip). ✓
- **§3.3** → Task 4 (discovery canonicalize + decompose value fields + promoted helpers). ✓ Resolver injection → Task 1. ✓
- **§3a** → Task 5 (WETH→`1:native`, `wrapperIds` enumeration, invalidateCache). ✓
- **Fold/group-positions revisit** → Task 6 (flagged, two options). ✓
- **`nativeInstrument.chainId` reader audit** → Verified facts: 3 readers, all tests, none chain-of-holding-unsafe; updated in Task 2. ✓
- **Type consistency:** `canonicalResolver` param name is consistent across Tasks 1/4; `CryptoInstrumentID.chainId(from:)`/`contractAddress(from:)` consistent Task 4; `WrappedNativeContracts.wrapperIds(pricingVia:)` consistent Task 5. ✓
- **No placeholders:** every code step shows real code. Test doubles (`InMemoryInstrumentRegistry`, `StubCryptoRegistrationResolver`) are named as *reuse existing doubles* — the implementer must open a neighbouring test to copy the exact double name/factory (flagged inline).
- **Out of scope (do NOT implement here):** §3.4/§3.5 sync-apply canonicalization + `ProfileDataSyncHandler` resolver injection (PR4); §4 data migration + capital-gains gate (PR5); registry/picker `WHERE alias_of IS NULL` display filter (§5 — PR5/consequences); physical deletion (PR6).

## Review Gate (mandatory)

Per task, driven to **zero findings**: `@instrument-conversion-review` + `@code-review`; add `@concurrency-review` for Tasks 1 and 4 (resolver lifecycle/threading + actor read); add `@database-code-review` for Task 3 (registry write path). Re-run review + fix until clean before each commit. `just format-check` after every task.
