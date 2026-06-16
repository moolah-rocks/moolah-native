# Stablecoin $1 Fallback + CryptoCompare Key + Per-request CoinGecko Key — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore deep-history price backfill for crypto tokens by (a) pegging held USDC/USDT to $1.00 as a last-resort provider, (b) letting the user enter a CryptoCompare API key, and (c) making the CoinGecko key take effect immediately across all consumers.

**Architecture:** Add a `StablecoinPriceClient` last in the existing `CryptoPriceService` provider chain so real prices always win and $1 only fills otherwise-empty dates. Replace baked `String?` API keys with `@Sendable () -> String?` key-provider closures (mirroring the existing `LiveAlchemyClient(apiKeyProvider:)` pattern) for both CryptoCompare and CoinGecko, read from the keychain per request. Add a Settings field + keychain entry for the CryptoCompare key and a help article.

**Tech stack:** Swift 6, Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`), GRDB, SwiftUI, `just` build/test/format. Project conventions: one extension per protocol conformance; tests are Swift Testing not XCTest; never edit `project.pbxproj` (run `just generate` if a new file must join a target).

**Conventions for every task:**
- New `.swift` files under an existing source dir are picked up by `xcodegen` globs, but run `just generate` after adding files, before building.
- Capture test output: `mkdir -p .agent-tmp && just test-mac <Filter> 2>&1 | tee .agent-tmp/out.txt`.
- After each task: `just format` then `just format-check`, then `just build-mac`, then the task's tests. Commit only when green.
- Worktree: `/Users/aj/Documents/code/moolah-project/moolah-native.stablecoin-peg-cc-key`, branch `stablecoin-peg-cc-key`. Use `git -C <worktree>` for git.

---

## File Structure

**Create:**
- `Backends/Stablecoin/StablecoinPriceClient.swift` — the $1 fallback `CryptoPriceClient`.
- `MoolahTests/Backends/StablecoinPriceClientTests.swift` — unit tests.
- `MoolahTests/Shared/CryptoPriceServiceStablecoinTests.swift` — integration (peg is last-resort).
- `site/help/_src/topics/get-a-cryptocompare-api-key.html` — help article.

**Modify:**
- `Domain/Models/SyncProvider.swift` — add `.peggedStablecoin` case + display name.
- `Backends/CryptoCompare/CryptoCompareClient.swift` — `apiKeyProvider` closure + `api_key` query item.
- `Backends/CoinGecko/CoinGeckoClient.swift` — `apiKeyProvider` closure + per-request host/key.
- `Shared/CompositeTokenResolutionClient.swift` — `apiKeyProvider` closure.
- `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift` + `SQLiteCoinGeckoCatalog+Refresh.swift` — key-aware refresh.
- `App/ProfileSession+Factories.swift` — wire `StablecoinPriceClient` + key-provider closures.
- `App/ProfileSession+CatalogFactory.swift` — pass key-provider closures to catalog/lookup.
- `App/ProfileSession+CryptoSync.swift` — add `resolveCryptoCompareApiKey()` + `resolveCoinGeckoApiKey()`.
- `Features/Settings/CryptoTokenStore.swift` — CryptoCompare key store methods.
- `Features/Settings/CryptoSettingsView*.swift` — CryptoCompare key UI section.
- `MoolahTests/.../CryptoTokenStoreTests*.swift`, `CryptoCompareClientTests.swift`, `CoinGeckoClientTests.swift`, `CompositeTokenResolutionClientTests.swift`, catalog refresh tests — extend.
- `site/help/_src/toc.json`, `manage-crypto-tokens.html`, `supported-crypto-chains-and-providers.html` — register + cross-link.

---

## Task 1: Add `SyncProvider.peggedStablecoin`

**Files:** Modify `Domain/Models/SyncProvider.swift`; Test `MoolahTests/Domain/SyncProviderTests.swift` (create if absent, else extend).

- [ ] **Step 1 — failing test:** add a `@Test` asserting `SyncProvider.peggedStablecoin.displayName == "Pegged stablecoin"` and that `.peggedStablecoin` is in `SyncProvider.allCases`.
- [ ] **Step 2 — run, expect fail** (`just test-mac SyncProviderTests`): compile error / missing case.
- [ ] **Step 3 — implement:** add `case peggedStablecoin` to the enum and `case .peggedStablecoin: return "Pegged stablecoin"` to `displayName`. (String raw value defaults to `"peggedStablecoin"`.)
- [ ] **Step 4 — run, expect pass.**
- [ ] **Step 5 — format + commit:** `feat(crypto): add SyncProvider.peggedStablecoin`.

---

## Task 2: `StablecoinPriceClient` + unit tests

**Files:** Create `Backends/Stablecoin/StablecoinPriceClient.swift`, `MoolahTests/Backends/StablecoinPriceClientTests.swift`.

Canonical addresses come from `CanonicalTokenRegistry.symbol(chainId:contractAddress:) -> String?` (returns `"USDC"`/`"USDT"` for the canonical mainnet/L2 addresses, `nil` otherwise). `CryptoProviderMapping.instrumentId` is `"<chainId>:<address>"` (or `"<chainId>:native"`). Enumerate days with `Calendar.utc` and key with the same `ISO8601DateFormatter` (`.withFullDate`) shape the other clients use.

- [ ] **Step 1 — failing tests** (`StablecoinPriceClientTests`), Swift Testing `@Suite`:
  - mainnet USDC `dailyPrices(in:)` over a 3-day range returns 3 entries all `Decimal(1)`, keyed `yyyy-MM-dd`.
  - mainnet USDT `dailyPrice(on:)` returns `Decimal(1)`.
  - an Optimism USDC address (look it up via `CanonicalTokenRegistry.bundled[10]["USDC"]`) returns `1`.
  - a non-stablecoin token (e.g. UNI `1:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984`) throws `CryptoPriceError.noProviderMapping`.
  - a `:native` id (`1:native`) throws `noProviderMapping`.
  - an impersonator (USDC symbol mapping but a random non-canonical address) throws `noProviderMapping`.
  - `currentPrices(for:)` returns `1` for canonical USDC/USDT instrumentIds and omits others.
  - `syncProvider == .peggedStablecoin`.
- [ ] **Step 2 — run, expect fail** (type not found).
- [ ] **Step 3 — implement** `struct StablecoinPriceClient: CryptoPriceClient, Sendable`:
  - `var syncProvider: SyncProvider { .peggedStablecoin }`.
  - private `func isPegged(_ instrumentId: String) -> Bool`: split on first `":"`, parse `chainId` `Int`, require an address segment (not `"native"`); return `CanonicalTokenRegistry.symbol(chainId:contractAddress:)` is `"USDC"` or `"USDT"`.
  - `dailyPrices(for:in:)`: `guard isPegged(mapping.instrumentId) else { throw .noProviderMapping(tokenId: mapping.instrumentId, provider: "Stablecoin peg") }`; enumerate each UTC day from `range.lowerBound` to `range.upperBound` inclusive, key with the formatter, value `Decimal(1)`.
  - `dailyPrice(for:on:)`: reuse `dailyPrices(for: mapping, in: date...date)`, return the single value (or throw `.noPriceAvailable` if absent — won't happen for pegged).
  - `currentPrices(for:)`: map each `isPegged` mapping's `instrumentId → Decimal(1)`, skip others; return `[:]` when none.
- [ ] **Step 4 — `just generate` then run, expect pass.**
- [ ] **Step 5 — format + commit:** `feat(crypto): add StablecoinPriceClient $1 fallback provider`.

---

## Task 3: Wire `StablecoinPriceClient` last + integration test

**Files:** Modify `App/ProfileSession+Factories.swift` (`makeCryptoPriceService`, the `priceClients` array ~lines 90-96). Test `MoolahTests/Shared/CryptoPriceServiceStablecoinTests.swift`.

The integration test constructs `CryptoPriceService` directly with a fake `[CryptoPriceClient]` chain + an in-memory `DatabaseWriter` (copy the construction pattern from the nearest existing `CryptoPriceService` test — likely `CryptoPriceServiceCoalescingTests` / `CryptoPriceServiceTests`; reuse its `DatabaseQueue` + `GatedCryptoPriceClient`/stub helpers).

- [ ] **Step 1 — failing integration tests:**
  - Chain `[failingClient, StablecoinPriceClient()]` where `failingClient` throws for USDT over a deep range → `prices(for: usdtMapping, in: deepRange)` yields `Decimal(1)` for every day (peg filled the gap).
  - Chain `[stubReturningRealValue, StablecoinPriceClient()]` where the stub returns e.g. `0.88` for the range → result is `0.88`, **not** `1` (real provider wins; peg never consulted because it's last and the loop stops on first non-empty).
- [ ] **Step 2 — run, expect fail.**
- [ ] **Step 3 — implement:** append `StablecoinPriceClient()` as the final element of the `priceClients` array in `makeCryptoPriceService` (after `binanceClient`). Add a one-line comment: last-resort $1 for canonical USDC/USDT only.
- [ ] **Step 4 — run, expect pass.**
- [ ] **Step 5 — format + commit:** `feat(crypto): peg held USDC/USDT to $1 as last-resort price`.

---

## Task 4: CryptoCompare API key — client injection + URL-builder tests

**Files:** Modify `Backends/CryptoCompare/CryptoCompareClient.swift`. Test: extend `MoolahTests/.../CryptoCompareClientTests.swift` (find it; if URL-builder tests live there, add there).

Mirror `CoinGeckoClient.authQueryItem`. CryptoCompare authenticates via `api_key` query item.

- [ ] **Step 1 — failing tests:**
  - `CryptoCompareClient.histodayURL(symbol:from:to:)` is currently keyless and static; refactor so the key reaches the URL. Test that when the client's provider returns `"k123"`, the built request URL contains `api_key=k123`; when it returns `nil`/`""`, no `api_key` item is present. (If the URL builders must stay static for testability, make them take an `apiKey: String` param like CoinGecko's, and test the static builder directly: `histodayURL(symbol:from:to:apiKey:)` contains/omits `api_key`.)
- [ ] **Step 2 — run, expect fail.**
- [ ] **Step 3 — implement:**
  - Add stored `private let apiKeyProvider: @Sendable () -> String?`. Change `init(http:)` → `init(http:apiKeyProvider:)`. Update all construction sites (Task 5 covers the live one; update any test/preview constructors to pass `{ nil }`).
  - Add `private static func authQueryItem(apiKey: String) -> URLQueryItem?` returning `api_key` when non-empty.
  - Thread the resolved key into `histodayURL` and `priceMultiURL` (add an `apiKey: String` parameter to each, append the auth item when present), and resolve `let apiKey = apiKeyProvider() ?? ""` at each call inside `dailyPrices`/`currentPrices`.
- [ ] **Step 4 — run, expect pass; `just build-mac` to catch construction-site breaks.**
- [ ] **Step 5 — format + commit:** `feat(crypto): send CryptoCompare api_key when configured`.

---

## Task 5: Wire CryptoCompare key resolver

**Files:** Modify `App/ProfileSession+CryptoSync.swift` (add resolver), `App/ProfileSession+Factories.swift` (`makeCryptoPriceService`: pass provider to `CryptoCompareClient`; note the `usdtRateLookup` closure also builds with `cryptoCompareClient`, so it inherits the key automatically).

- [ ] **Step 1 — implement resolver** (no separate unit test — it's a thin keychain read mirroring `resolveAlchemyApiKey`; covered indirectly):
```swift
nonisolated static func resolveCryptoCompareApiKey() -> String? {
  let store = KeychainStore(
    service: KeychainServices.apiKeys, account: "cryptocompare", synchronizable: true)
  return try? store.restoreString()
}
```
- [ ] **Step 2 — wire:** in `makeCryptoPriceService`, construct `CryptoCompareClient(http: ..., apiKeyProvider: { ProfileSession.resolveCryptoCompareApiKey() })`.
- [ ] **Step 3 — `just build-mac`, run crypto price/test suites green.**
- [ ] **Step 4 — format + commit:** `feat(crypto): resolve CryptoCompare key from keychain per request`.

---

## Task 6: CoinGecko client — per-request key + host

**Files:** Modify `Backends/CoinGecko/CoinGeckoClient.swift`. Test: extend `MoolahTests/.../CoinGeckoClientTests.swift`.

The static URL builders already take `apiKey: String` and pick host via `baseURL(apiKey:)` — keep them. The change is: the **instance** must resolve the key per request AND route the HTTP call to the matching host (today `http` is bound to one host at construction, so a runtime key flip would desync URL-host vs gate-host).

- [ ] **Step 1 — failing test:** construct a `CoinGeckoClient` whose `apiKeyProvider` returns `""` then `"prokey"`; assert (via an injected fake networking/HTTP that records the requested host + URL) that an empty key targets `api.coingecko.com` with no `x_cg_pro_api_key`, and a non-empty key targets `pro-api.coingecko.com` with `x_cg_pro_api_key=prokey` — without reconstructing the client. (Follow the existing CoinGeckoClient test's HTTP-stub pattern; if it currently injects a single `RateLimitedHTTPClient`, extend the client to accept a host-resolving closure or a `NetworkingServices` so the stub can observe both hosts.)
- [ ] **Step 2 — run, expect fail.**
- [ ] **Step 3 — implement:** replace `apiKey: String` + single `http` with `apiKeyProvider: @Sendable () -> String?` and a way to obtain a host-bound client per request. Preferred: inject `networking: NetworkingServices` and call `networking.client(forHost: host)` per request, where `host = apiKey.isEmpty ? "api.coingecko.com" : "pro-api.coingecko.com"`. Resolve `let apiKey = apiKeyProvider() ?? ""` at the top of `dailyPrices`/`currentPrices`, pass it to the existing static URL builders, and dispatch through the per-request host client. Keep the URL builders unchanged.
- [ ] **Step 4 — `just generate` (no new file, skip) → run, expect pass; `just build-mac`.**
- [ ] **Step 5 — format + commit:** `refactor(crypto): resolve CoinGecko key + host per request`.

---

## Task 7: `CompositeTokenResolutionClient` — per-request key

**Files:** Modify `Shared/CompositeTokenResolutionClient.swift`. Test: extend `MoolahTests/Shared/CompositeTokenResolutionClientTests.swift`.

It already selects host per request (`resolveFromCoinGecko`, `fetchAssetPlatforms`) and holds `networking`. Replace stored `coinGeckoApiKey: String?` with `apiKeyProvider: @Sendable () -> String?`.

- [ ] **Step 1 — failing test:** a resolution call with a provider returning `"prokey"` hits the pro host with `x_cg_pro_api_key`; with `""` hits the free host. (Reuse the suite's existing networking stub; the existing tests pass `coinGeckoApiKey:` — they'll need updating to pass a closure, which is expected churn.)
- [ ] **Step 2 — run, expect fail.**
- [ ] **Step 3 — implement:** change both `init`s to take `apiKeyProvider: @Sendable () -> String?` (production default `{ nil }`); store it; at each use `let apiKey = apiKeyProvider() ?? ""`. Today `resolveFromCoinGecko` early-returns when key is `nil`; preserve "empty ⇒ still query free host" semantics (don't early-return on empty — only treat the resolver as available; today it's passed `?? ""` so it always queries). Match current behaviour: free host queried even with empty key.
- [ ] **Step 4 — update all construction sites** (`ProfileSession+Factories.swift` ×2) — Task 9 finalises wiring; for now pass `{ nil }` or the real resolver to keep the build green. Update test constructors.
- [ ] **Step 5 — run, expect pass; format + commit:** `refactor(crypto): resolve CoinGecko key per request in token resolver`.

---

## Task 8: `SQLiteCoinGeckoCatalog` refresh — key-aware

**Files:** Modify `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift`, `SQLiteCoinGeckoCatalog+Refresh.swift`. Test: extend / create `MoolahTests/Backends/SQLiteCoinGeckoCatalogRefreshTests.swift`.

Today refresh uses hardcoded free-tier URL literals (`coinsListURL`, `assetPlatformsURL`) and a pre-bound `http`, ignoring the key entirely. Make the catalog hold a key provider + `NetworkingServices` and build refresh URLs/host per refresh.

- [ ] **Step 1 — failing test:** drive a refresh with a key provider returning `"prokey"` against a recording HTTP stub; assert it requested `pro-api.coingecko.com/.../coins/list...` with `x_cg_pro_api_key=prokey` and `asset_platforms` likewise; with `""` it requested `api.coingecko.com` and no key param. (Build URLs via the existing `CoinGeckoClient` static helpers where possible — `assetPlatformsURL(apiKey:)` exists; add a `coinsListURL(apiKey:)` static builder to `CoinGeckoClient` with `include_platform=true` so both URL shapes live in one place and are unit-testable.)
- [ ] **Step 2 — run, expect fail.**
- [ ] **Step 3 — implement:**
  - Add `static func coinsListURL(apiKey: String) -> URL` to `CoinGeckoClient` (path `coins/list`, query `include_platform=true` + auth item).
  - Change `SQLiteCoinGeckoCatalog.make(...)`/init to take `apiKeyProvider: @Sendable () -> String?` + `networking: NetworkingServices` instead of a pre-bound `http`. In `+Refresh.swift`, resolve `let apiKey = apiKeyProvider() ?? ""`, build the two URLs via the new static builders, and obtain `networking.client(forHost:)` for the matching host. Remove the hardcoded URL literals.
- [ ] **Step 4 — `just generate` (if new test file) → run, expect pass; `just build-mac`.**
- [ ] **Step 5 — format + commit:** `fix(crypto): catalog refresh honours CoinGecko key + host`.

---

## Task 9: Thread CoinGecko key-provider through factories

**Files:** Modify `App/ProfileSession+Factories.swift` (`makeMarketDataServices`, `makeCryptoPriceService`, `makeRegistryWiring`), `App/ProfileSession+CatalogFactory.swift` (`makeCoinGeckoCatalog`, `makeLookupCatalog`), `App/ProfileSession+CryptoSync.swift` (add `resolveCoinGeckoApiKey`).

- [ ] **Step 1 — add resolver** in `ProfileSession+CryptoSync.swift`:
```swift
nonisolated static func resolveCoinGeckoApiKey() -> String? {
  let store = KeychainStore(
    service: KeychainServices.apiKeys, account: "coingecko", synchronizable: true)
  return try? store.restoreString()
}
```
- [ ] **Step 2 — replace baked reads:** remove the one-shot `coinGeckoApiKey = try? apiKeyStore.restoreString()` reads; define `let cgKeyProvider: @Sendable () -> String? = { ProfileSession.resolveCoinGeckoApiKey() }` and pass it to: `CoinGeckoClient`, `CompositeTokenResolutionClient` (both sites), `makeCoinGeckoCatalog`, `makeLookupCatalog`, `makeCryptoPriceService`. Update those factory signatures from `coinGeckoApiKey: String?` to `coinGeckoApiKeyProvider: @Sendable () -> String?`. The `MarketDataServices.coinGeckoApiKey` field (consumed by `makeRegistryWiring`) becomes `coinGeckoApiKeyProvider`.
- [ ] **Step 3 — `just build-mac`** — fix every call site the signature change touches until it compiles.
- [ ] **Step 4 — run full crypto + resolver + catalog suites green.**
- [ ] **Step 5 — format + commit:** `feat(crypto): CoinGecko key takes effect immediately everywhere`.

---

## Task 10: `CryptoTokenStore` — CryptoCompare key methods

**Files:** Modify `Features/Settings/CryptoTokenStore.swift`. Test: extend the store's test file (mirror the Alchemy key tests — find `saveAlchemyApiKey`/`hasAlchemyApiKey` tests).

- [ ] **Step 1 — failing tests** (inject an in-memory/temp `KeychainStore` as the existing Alchemy tests do): `saveCryptoCompareApiKey("k")` ⇒ `hasCryptoCompareApiKey == true`; `clearCryptoCompareApiKey()` ⇒ `false`; saving trims whitespace (match Alchemy behaviour).
- [ ] **Step 2 — run, expect fail.**
- [ ] **Step 3 — implement:** add `private let cryptocompareKeyStore: KeychainStore` (account `"cryptocompare"`, service `KeychainServices.apiKeys`, `synchronizable: true`) to both the designated and convenience initialisers (mirror `alchemyKeyStore`). Add `saveCryptoCompareApiKey(_:)`, `var hasCryptoCompareApiKey: Bool`, `clearCryptoCompareApiKey()` — copy the Alchemy method bodies, logging `localizedDescription` only.
- [ ] **Step 4 — run, expect pass; `just build-mac`.**
- [ ] **Step 5 — format + commit:** `feat(settings): store CryptoCompare API key in keychain`.

---

## Task 11: Settings UI — CryptoCompare key section

**Files:** Modify the CoinGecko/Alchemy key section view (`Features/Settings/CryptoSettingsView+TokenList.swift` or wherever the CoinGecko key `SecureField` lives — grep `hasAlchemyApiKey`/`saveApiKey`).

- [ ] **Step 1 — implement** a CryptoCompare section mirroring the CoinGecko one exactly: `@State private var cryptocompareApiKeyInput = ""`; a `SecureField`; a Save button → `store.saveCryptoCompareApiKey(trimmed)` then clear input; a "Configured ✓ / Remove" row gated on `store.hasCryptoCompareApiKey` → `store.clearCryptoCompareApiKey()`; a footer `Link` to `https://developers.coindesk.com` with copy explaining the key restores deep price history. Use exact section/label wording consistent with neighbours; apply `.accessibilityIdentifier` consistent with the Alchemy/CoinGecko fields if they have them.
- [ ] **Step 2 — `just build-mac`; check no warnings** (`mcp__xcode__XcodeListNavigatorIssues` severity warning, or xcodebuild).
- [ ] **Step 3 — `@agent-ui-review`** on the changed view; apply findings.
- [ ] **Step 4 — format + commit:** `feat(settings): add CryptoCompare API key field`.

---

## Task 12: Help docs

**Files:** Create `site/help/_src/topics/get-a-cryptocompare-api-key.html`; modify `site/help/_src/toc.json`, `manage-crypto-tokens.html`, `supported-crypto-chains-and-providers.html`.

- [ ] **Step 1 — verify live signup flow:** WebFetch `https://developers.coindesk.com` (and its API-keys / free-tier pages) to confirm the current account-creation + key-generation steps and free-tier limits. CryptoCompare rebranded to CoinDesk Data — the article MUST reflect the live portal, not memory.
- [ ] **Step 2 — write the article** as an `<article>` fragment following `add-an-exchange-account.html` structure (h1 verb-led title, one-sentence intro, **Before you start**, **Steps** (ol, imperative, verified URLs/labels), **Result**, **Related**). HELP_GUIDE/BRAND_GUIDE voice: second person, Australian spelling, no banned marketing words, bold exact UI labels (`**Settings**`), "select" not "click".
- [ ] **Step 3 — register** in `toc.json` under `parent: "investments-and-crypto"`; add a CryptoCompare-key paragraph to `manage-crypto-tokens.html` and a key-required note beside CryptoCompare in `supported-crypto-chains-and-providers.html`; cross-link via Related.
- [ ] **Step 4 — `just build-help` (or `just generate`)** to confirm it builds; `@agent-help-review` over the new + edited articles; apply findings.
- [ ] **Step 5 — commit:** `docs(help): how to create and enter a CryptoCompare API key`.

---

## Task 13: Whole-suite verification + reviews

- [ ] **Step 1 — `just format-check`** — zero diffs / zero SwiftLint violations (fix in place; never baseline).
- [ ] **Step 2 — `just build-mac`** — zero warnings in user code.
- [ ] **Step 3 — `just test`** (iOS + macOS) → `.agent-tmp/full.txt`; grep `failed|error:`; all green.
- [ ] **Step 4 — review agents:** `@agent-code-review` (all changed Swift), `@agent-concurrency-review` (clients/closures/Sendable), `@agent-instrument-conversion-review` (peg path). Apply every Critical/Important/Minor finding (separate follow-up only if truly out of scope, and ask first).
- [ ] **Step 5 — push branch, open PR** with a body summarising the three changes + the production diagnosis that motivated them; then land via the `landing-prs` skill (merge queue / automerge). Monitor to merged.

---

## Self-review notes (author)
- Spec coverage: peg (T1-3), CryptoCompare key client+wire+UI+store (T4,5,10,11), CoinGecko all-consumers per-request (T6-9), help (T12), verification/reviews (T13). All spec sections mapped.
- DAI deliberately not pegged — `isPegged` gate is `{"USDC","USDT"}` only (T2).
- Type consistency: `apiKeyProvider: @Sendable () -> String?` used uniformly across CryptoCompare/CoinGecko clients, resolver, catalog; factory params renamed to `…Provider`. Resolver names: `resolveCryptoCompareApiKey`, `resolveCoinGeckoApiKey` (mirror `resolveAlchemyApiKey`).
- Risk: T6-9 is the broad refactor; keep build green after each by updating all call sites + test constructors in the same task.
