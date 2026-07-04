# Self-refreshing provider token-list caches + re-detection — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Follow superpowers:test-driven-development for each task.

**Goal:** Cache CryptoCompare and Binance token lists on disk like CoinGecko's, on one shared self-refreshing SQLite engine, and re-detect provider support for already-registered tokens so months stop rendering "—" (issue #1140).

**Architecture:** Extract the proven `SQLiteCoinGeckoCatalog` machinery (SQLite lifecycle + 24h ETag refresh) into a reusable engine; refactor CoinGecko onto it and add CryptoCompare + Binance caches; route token resolution through the caches; then a startup reconciliation pass re-derives missing provider ids from the caches and merge-only upgrades registered tokens.

**Tech Stack:** Swift 6 (actors, Swift Testing), raw `sqlite3` C API (caches use drop-and-recreate retention, not GRDB — see `DATABASE_SCHEMA_GUIDE.md`), `StubURLProtocol` for network tests. Build/test/format via `just`.

**Delivery:** Two stacked PRs. PR1 = engine + caches + resolution rewire (no #1140 behaviour change). PR2 (stacked on PR1's branch) = reconciliation that closes #1140.

---

## Context for the implementer

- **Spec:** `plans/2026-06-17-crypto-provider-catalog-design.md`. Read it.
- **The template being generalized:** `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift` (+`+SQLite.swift`, `+Refresh.swift`, `+Search.swift`, `+ContractLookup.swift`) and `Backends/CoinGecko/CoinGeckoCatalogSchema.swift`. It is an `actor` holding an `OpaquePointer?`, opened via `static make(directory:apiKeyProvider:networking:)` → `<dir>/catalog.sqlite`, with drop-and-recreate on `meta.schema_version` mismatch (including `-wal`/`-shm` sidecars), WAL, extended result codes, 24h `maxAge`, ETag conditional GET (`fetchConditional` → `.ok(Data,etag)`/`.notModified`).
- **SQLite helpers** (`+SQLite.swift`): `exec/prepare/bind(String)/bind(Int)/step/rollback/readText/errorMessage/scalarInt`, all `static`, throwing `CatalogError.sqlite(String)`. They embed `sqlite3_errmsg`. Reuse verbatim.
- **Networking:** `networking.client(forHost:)` → `RateLimitedHTTPClient`; `http.data(for:)` returns `(Data, HTTPURLResponse)` (read `statusCode`, `value(forHTTPHeaderField:)`). 304 is returned (not thrown). Rate-limit/4xx handling is transparent.
- **Provider clients & parsers (reuse, do not rewrite the parsing):**
  - `CryptoCompareClient.coinListURL()` → `/data/all/coinlist?summary=true`; `parseCoinListResponse(_:) -> [String:String]` (lowercased contract → symbol), `parseNativeSymbols(_:) -> Set<String>`, `parseCoinSymbols(_:) -> Set<String>`. **Note:** the live coinlist requires the CC api key (HTTP 401 without). The cache must send it.
  - `BinanceClient.exchangeInfoURL()` → `/api/v3/exchangeInfo`; `parseExchangeInfoResponse(_:) -> Set<String>` (the set of `<BASE>USDT` pair symbols that are `TRADING`).
  - `CoinGeckoClient.coinsListURL(apiKey:)`, `assetPlatformsURL(apiKey:)`, `host(apiKey:)`.
- **Resolution client:** `Shared/CompositeTokenResolutionClient.swift`. `fetchCoinListData()` / `fetchExchangeInfoData()` currently do ad-hoc live downloads; the `preloaded*` inits are test-only. Local-first **early-returns** on a CoinGecko contract match (lines 63–71) — this is why PR2 cannot reuse `resolve()`.
- **Wiring:** `App/ProfileSession+CatalogFactory.swift` (`makeCoinGeckoCatalog`, `makeLookupCatalog`, both open `<moolahScopedApplicationSupport>/InstrumentRegistry/catalog.sqlite`), `App/ProfileSession+Factories.swift` (`makeMarketDataServices`, `makeCryptoPriceService`, `makeRegistryWiring` builds `CompositeTokenResolutionClient`), `App/ProfileSession.swift:282` (`seedBuiltInCryptoPresets`, runs in a `crossStoreUpdateTasks` task).
- **Lint:** `Backends/`, `Shared/`, `App/` are NOT excluded → linted (`file_length` warn 400/err 1000; `type_body_length` warn 250/err 350; `function_body_length` warn 50/err 100). Keep files focused. `swift-format` via `just format`.
- **Tests:** Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`), run `just test-mac <Filter>` capturing to `.agent-tmp/`. Network stubbed via `StubURLProtocol` + `NetworkingServices(session: URLSession(configuration:.ephemeral, protocolClasses:[StubURLProtocol.self]))` (see `SQLiteCoinGeckoCatalogRefreshTests`, `CompositeTokenResolutionClientTests`). Cache tests use a per-test temp directory.
- **DB rules** (`DATABASE_SCHEMA_GUIDE.md`): caches are drop-and-recreate (source of truth = network), so a schema bump just bumps `schema_version` and the file is recreated — no migration. Use `STRICT` tables (FTS5 virtual tables excepted). WAL. Index lookups.
- **Git:** worktree `/.worktrees/crypto-provider-catalog`, branch `feature/crypto-provider-catalog`. Use `git -C <worktree>`. PR2 stacks on PR1 (see project CLAUDE.md "Stacked-PR worktrees").

---

# PART A — PR1: shared engine + caches + resolution rewire

File structure (PR1):

| File | Responsibility | Action |
|---|---|---|
| `Backends/Catalog/CatalogDatabase.swift` | shared SQLite handle wrapper: open/bootstrap/drop-recreate + the C-API helpers | Create |
| `Backends/Catalog/CatalogRefresh.swift` | shared 24h-maxAge + per-endpoint ETag conditional-GET orchestration | Create |
| `Backends/Catalog/RefreshableCatalog.swift` | `protocol RefreshableCatalog { func refreshIfStale() async }` + `CatalogEndpoint` value | Create |
| `Backends/CoinGecko/SQLiteCoinGeckoCatalog*.swift` + `CoinGeckoCatalogSchema.swift` | refactor onto `CatalogDatabase`/`CatalogRefresh` | Modify |
| `Backends/CryptoCompare/CryptoCompareTokenCache.swift` (+`+Schema.swift`) | new CC coinlist cache | Create |
| `Backends/Binance/BinanceTokenCache.swift` (+`+Schema.swift`) | new Binance exchangeInfo cache | Create |
| `Domain/Repositories/ProviderTokenCaches.swift` | `ProviderCatalogLookups` query seams (CC contract→symbol, native set, all-symbols; Binance hasUsdtPair) | Create |
| `Shared/CompositeTokenResolutionClient.swift` | read CC/Binance via caches (fetch-on-miss); keep algorithm | Modify |
| `App/ProfileSession+CatalogFactory.swift` / `+Factories.swift` / `ProfileSession.swift` | build + refresh the two new caches; inject lookups | Modify |
| `MoolahTests/Backends/Catalog/*` + `CryptoCompareTokenCacheTests.swift` + `BinanceTokenCacheTests.swift` | new tests | Create |

> **Refactor discipline:** PR1 must keep every existing test passing — `SQLiteCoinGeckoCatalog*Tests`, `CompositeTokenResolutionClient*Tests`, `CoinGeckoClientTests`, `NetworkingServicesTests`. They are the behaviour-preservation guard. Where a refactor changes an internal seam a test reaches into (e.g. `readMetaForTesting`), update the test minimally to the new seam — do not weaken assertions.

---

## Task A0: Spike — confirm the extraction boundary (no code shipped)

- [ ] **Step 1:** Re-read the five `SQLiteCoinGeckoCatalog*` files and `CoinGeckoCatalogSchema.swift` in full. Write a 10-line note in `.agent-tmp/extraction-notes.md` listing exactly which members move to `CatalogDatabase` (the C-API helpers + open/connect/createFresh/drop-recreate), which move to `CatalogRefresh` (maxAge, `FetchOutcome`, `fetchConditional`, the refresh loop), and which stay CoinGecko-specific (schema DDL, `RawCoin`/`RawPlatform`, `parseCoins`/`parsePlatforms`, `applyUpdates`, search, contract lookup, `coin`-specific meta etag columns).
- [ ] **Step 2:** Decide the generic meta/etag shape: replace per-provider etag columns (`coins_etag`, `platforms_etag`) with an engine-owned `etag(endpoint_key TEXT PRIMARY KEY, value TEXT) STRICT` table + `meta(schema_version INTEGER, last_fetched REAL)`. Confirm CoinGecko's two endpoints map to keys `"coins"` and `"platforms"`. Note this in the file. (No commit — this is a planning spike.)

If the boundary turns out materially different from the design, STOP and report — do not improvise a different architecture silently.

---

## Task A1: `CatalogDatabase` — shared SQLite handle + helpers

**Files:** Create `Backends/Catalog/CatalogDatabase.swift`; Test `MoolahTests/Backends/Catalog/CatalogDatabaseTests.swift`.

`CatalogDatabase` is a non-`Sendable` value/class used **only inside** a provider actor. It owns `var handle: OpaquePointer?` and exposes:
- `static func open(dbURL:schemaVersion:schemaDDL:[String]) throws -> CatalogDatabase` — replicates `SQLiteCoinGeckoCatalog.open/connect/createFresh`: if the file exists and `meta.schema_version` ≠ `schemaVersion`, remove the db + `-wal`/`-shm` and recreate from `schemaDDL`; else connect. Enables extended result codes.
- instance methods `exec/prepare/bind(String)/bind(Int)/step/rollback/readText/scalarInt` delegating to the same C calls (moved verbatim from `+SQLite.swift`), throwing a shared `CatalogError` (move the enum here: `case sqlite(String)`, `case network(String)`).
- `func close()` for the actor's `isolated deinit`.
- `func readLastFetched() -> Date?`, `func writeLastFetched(_:Date)`, `func readEtag(key:String) -> String?`, `func writeEtag(key:String,value:String?)` against the engine-owned `meta`/`etag` tables.

The DDL for `meta`+`etag` is engine-owned; provide `CatalogDatabase.baseSchemaStatements(schemaVersion:Int) -> [String]` that providers prepend to their own DDL.

- [ ] **Step 1: Write failing tests** — `CatalogDatabaseTests`:
  - opens a fresh db in a temp dir, `readLastFetched()` is nil, round-trips `writeLastFetched`/`writeEtag`/`readEtag`.
  - reopening with a different `schemaVersion` drops & recreates (old rows gone).
  - `exec` of bad SQL throws `CatalogError.sqlite`.
- [ ] **Step 2:** Run `just test-mac CatalogDatabaseTests` → FAIL (type missing).
- [ ] **Step 3: Implement** `CatalogDatabase` by moving the helper bodies from `SQLiteCoinGeckoCatalog+SQLite.swift` and the open/connect/createFresh/drop-recreate logic from `SQLiteCoinGeckoCatalog.swift`, parameterized by `schemaVersion`/`schemaDDL`. Add the `meta`/`etag` base schema + accessors. Keep the `sqlite3_errmsg`-embedding throw sites.
- [ ] **Step 4:** Run `just test-mac CatalogDatabaseTests` → PASS.
- [ ] **Step 5:** `just format` then commit: `feat(catalog): shared CatalogDatabase SQLite engine (#1140)`.

---

## Task A2: `CatalogRefresh` — shared ETag/maxAge refresh loop

**Files:** Create `Backends/Catalog/CatalogRefresh.swift`, `Backends/Catalog/RefreshableCatalog.swift`; Test `MoolahTests/Backends/Catalog/CatalogRefreshTests.swift`.

```swift
// RefreshableCatalog.swift
protocol RefreshableCatalog: Sendable { func refreshIfStale() async }

/// One conditional-GET endpoint in a catalog refresh.
struct CatalogEndpoint: Sendable {
  let key: String                 // etag table key, e.g. "coins"
  let url: URL
}

enum CatalogFetchOutcome: Sendable {     // moved from SQLiteCoinGeckoCatalog+Refresh
  case ok(Data, etag: String?)
  case notModified
}
```

`CatalogRefresh` provides:
- `static func fetchConditional(http:RateLimitedHTTPClient, url:URL, ifNoneMatch:String?) async throws -> CatalogFetchOutcome` (moved verbatim).
- `static let defaultMaxAge: TimeInterval = 24 * 3600`.
- `static func run(database:CatalogDatabase, endpoints:[CatalogEndpoint], http:RateLimitedHTTPClient, maxAge:TimeInterval = defaultMaxAge, now:Date, apply:([String: Data]) throws -> Void) async throws` — staleness gate on `database.readLastFetched()`; per endpoint conditional GET using `database.readEtag(key:)`; build `[key: Data]` of the `.ok` bodies; call `apply`; persist new etags + `writeLastFetched(now)`. (A 304 leaves that endpoint's body out of the dict; if ALL are 304 still bump `last_fetched`, matching today.)

> The actor wrapping this is responsible for the `do/catch`+log graceful-degradation (so `last_fetched` is untouched on throw). `run` propagates errors.

- [ ] **Step 1: Write failing tests** — stub `RateLimitedHTTPClient` via `StubURLProtocol`:
  - 200 with ETag → `apply` receives the body, etag persisted, `last_fetched` set.
  - within `maxAge` → `run` is a no-op (no network) — assert via a stub call counter.
  - 304 → `apply` not given that body; `last_fetched` still bumped.
  - network throw → propagates (caller preserves `last_fetched`); assert `last_fetched` unchanged after the actor's catch (test via a thin actor wrapper).
- [ ] **Step 2:** `just test-mac CatalogRefreshTests` → FAIL.
- [ ] **Step 3: Implement** by moving `fetchConditional`, `maxAge`, and the refresh skeleton out of `SQLiteCoinGeckoCatalog+Refresh.swift`.
- [ ] **Step 4:** `just test-mac CatalogRefreshTests` → PASS.
- [ ] **Step 5:** `just format`; commit: `feat(catalog): shared CatalogRefresh ETag/maxAge loop (#1140)`.

---

## Task A3: Refactor `SQLiteCoinGeckoCatalog` onto the shared engine

**Files:** Modify the five `SQLiteCoinGeckoCatalog*.swift` + `CoinGeckoCatalogSchema.swift`; Tests: existing `SQLiteCoinGeckoCatalog*Tests` (update seams as needed).

- [ ] **Step 1:** Run the existing suites first to capture the green baseline: `just test-mac SQLiteCoinGeckoCatalogStorageTests SQLiteCoinGeckoCatalogSearchTests SQLiteCoinGeckoCatalogRefreshTests SQLiteCoinGeckoCatalogParseTests 2>&1 | tee .agent-tmp/a3-before.txt`. Expected: PASS.
- [ ] **Step 2:** Bump `CoinGeckoCatalogSchema.version` to 2 and drop the `coins_etag`/`platforms_etag`/`last_fetched`/`schema_version` columns from its `meta` DDL (those move to the engine's `meta`+`etag`). Prepend `CatalogDatabase.baseSchemaStatements(schemaVersion:)`. Keep `coin`/`coin_platform`/`platform`/`coin_fts` + triggers + indexes (make `coin`/`coin_platform`/`platform` `STRICT` if not already).
- [ ] **Step 3:** Replace the actor's `OpaquePointer? database` + `+SQLite.swift` helpers + open/connect/createFresh with a held `CatalogDatabase`. `make(...)` calls `CatalogDatabase.open(dbURL:schemaVersion:schemaDDL:)`. `replaceAll`/`insertCoins`/`insertPlatforms`/`readMeta`/search/contract-lookup now call `database.exec(...)` etc. Delete `SQLiteCoinGeckoCatalog+SQLite.swift`.
- [ ] **Step 4:** Rewrite `refreshIfStale()` to call `CatalogRefresh.run(endpoints:[coins, platforms], apply:)` where `apply` parses `parseCoins`/`parsePlatforms` from whichever bodies are present and applies via `applyUpdates`. Keep the partial-replace optimization (a key absent from the `[key:Data]` dict = `.unchanged`). Keep the `do/catch`+log so `last_fetched` is preserved on error.
- [ ] **Step 5:** Update `*ForTesting` seams: `readMetaForTesting` now reads `last_fetched` + etags via the engine accessors; `writeMetaSchemaVersionForTesting` writes the engine `meta`. Adjust the existing tests minimally to the new seams (do not weaken).
- [ ] **Step 6:** Run the four suites: `just test-mac SQLiteCoinGeckoCatalog... 2>&1 | tee .agent-tmp/a3-after.txt`. Expected: PASS (same tests, refactored internals).
- [ ] **Step 7:** `just build-mac 2>&1 | tail -5` (whole app still compiles — `makeCoinGeckoCatalog`/`makeLookupCatalog` unchanged signatures). `just format`.
- [ ] **Step 8:** Commit: `refactor(coingecko): move SQLiteCoinGeckoCatalog onto shared engine (#1140)`.

If the refactor balloons beyond a clean mechanical move (e.g. search/FTS resists the `CatalogDatabase` seam), report DONE_WITH_CONCERNS describing the friction rather than forcing it.

---

## Task A4: `CryptoCompareTokenCache`

**Files:** Create `Backends/CryptoCompare/CryptoCompareTokenCache.swift` + `+Schema.swift`; Test `MoolahTests/Backends/CryptoCompare/CryptoCompareTokenCacheTests.swift`.

Actor mirroring `SQLiteCoinGeckoCatalog`'s shape, file `cryptocompare.sqlite`, holding a `CatalogDatabase`. Schema (v1):

```sql
CREATE TABLE cc_coin (
  symbol           TEXT NOT NULL,
  contract_address TEXT          -- NULL for chain-agnostic/native listings
) STRICT;
CREATE INDEX cc_coin_contract ON cc_coin(contract_address);
CREATE INDEX cc_coin_symbol   ON cc_coin(symbol);
```

Refresh: one endpoint `key:"coinlist"`, url `CryptoCompareClient.coinListURL()`, **sent with the api key** (the cache holds a `apiKeyProvider: @Sendable () -> String?`; build the request with the `api_key` query item — extract a small internal `coinListURL(apiKey:)` or append the item; the live endpoint is 401 without it). `apply`: decode via the existing parsers and rebuild rows — reuse `CryptoCompareClient.parseCoinListResponse` (contract→symbol) for the contract rows and `parseNativeSymbols`/`parseCoinSymbols` for symbol-only rows; insert each as `(symbol, contract?)`. Query API:

```swift
func symbol(forContract address: String) async -> String?   // lowercased match
func nativeSymbols() async -> Set<String>                    // contract_address IS NULL
func allSymbols() async -> Set<String>
```

Plus a **fetch-on-miss** entry used by resolution: `func ensureFreshThenSymbol(...)` is overkill — instead expose `func snapshotIsEmpty() async -> Bool` and have the cache's query methods trigger a blocking `refreshIfStale()` (which is a no-op when warm) before reading if the table is empty. Keep it simple: a private `func loadingIfEmpty() async` that calls `refreshIfStale()` when `cc_coin` count is 0, then the public queries call it first.

- [ ] **Step 1: Write failing tests** (temp dir; `StubURLProtocol` serving a small coinlist JSON fixture with one contract token (e.g. RPL → 0xd335…) + one native (BTC) + one symbol-only (USDT)):
  - after `refreshIfStale()`: `symbol(forContract: "0xd335…") == "RPL"`; `nativeSymbols().contains("BTC")`; `allSymbols()` ⊇ {RPL,BTC,USDT}.
  - cold cache + a query triggers fetch-on-miss (stub call count == 1), warm query adds no call.
  - schema-version drop-and-recreate works (reuse pattern).
- [ ] **Step 2:** `just test-mac CryptoCompareTokenCacheTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** `just test-mac CryptoCompareTokenCacheTests` → PASS.
- [ ] **Step 5:** `just generate` (new files) ; `just format`; commit: `feat(cryptocompare): self-refreshing token-list cache (#1140)`.

---

## Task A5: `BinanceTokenCache`

**Files:** Create `Backends/Binance/BinanceTokenCache.swift` + `+Schema.swift`; Test `MoolahTests/Backends/Binance/BinanceTokenCacheTests.swift`.

Actor, file `binance.sqlite`, `CatalogDatabase`. Schema (v1):

```sql
CREATE TABLE binance_pair (
  pair_symbol TEXT NOT NULL PRIMARY KEY     -- e.g. "RPLUSDT" (TRADING, quote USDT)
) STRICT;
```

Refresh: one endpoint `key:"exchangeInfo"`, url `BinanceClient.exchangeInfoURL()` (keyless). `apply`: `BinanceClient.parseExchangeInfoResponse(body)` → insert each pair symbol. Query API:

```swift
func hasUsdtPair(base symbol: String) async -> Bool   // checks "<SYMBOL>USDT" present (uppercased)
func usdtPairs() async -> Set<String>
```

Same fetch-on-miss-when-empty behaviour as A4.

- [ ] **Step 1: Write failing tests** (stub serving an exchangeInfo fixture with `RPLUSDT TRADING` + a `FOOBTC` non-USDT + a `BARUSDT BREAK` non-trading):
  - `hasUsdtPair(base:"RPL") == true`; `hasUsdtPair(base:"FOO") == false`; `hasUsdtPair(base:"BAR") == false`.
  - cold-cache fetch-on-miss call-count == 1; warm == 0 extra.
- [ ] **Step 2:** `just test-mac BinanceTokenCacheTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** `just test-mac BinanceTokenCacheTests` → PASS.
- [ ] **Step 5:** `just generate`; `just format`; commit: `feat(binance): self-refreshing exchangeInfo cache (#1140)`.

---

## Task A6: Route `CompositeTokenResolutionClient` through the caches

**Files:** Modify `Shared/CompositeTokenResolutionClient.swift`; Tests: existing `CompositeTokenResolutionClient*Tests` + 1 new.

- [ ] **Step 1:** Add optional injected caches to the production init: `cryptoCompareCache: CryptoCompareTokenCache?`, `binanceCache: BinanceTokenCache?` (keep the `preloaded*` test init unchanged). When a cache is present, `fetchCoinListData()` / `fetchExchangeInfoData()` serve from it (cache provides a `rawSnapshotData()`? No — instead refactor the *resolution steps* to call the cache query methods directly: `resolveFromCryptoCompare` uses `cache.symbol(forContract:)`/`nativeSymbols()`, `postConfirmCryptoCompareBySymbol` uses `allSymbols()`, `resolveBinancePair` uses `cache.hasUsdtPair(base:)`). When the cache is nil (tests passing `preloaded*`), keep the current `parse*` path over the preloaded `Data`.
- [ ] **Step 2:** Keep the algorithm identical — same order, same #790 contract-gating on the Binance step, same local-first early return. Only the data source changes.
- [ ] **Step 3:** Run existing suites: `just test-mac CompositeTokenResolutionClientTests CompositeTokenResolutionLocalFirstTests CompositeTokenResolutionProKeyTests 2>&1 | tee .agent-tmp/a6.txt` → PASS.
- [ ] **Step 4:** Add a test: with cache-backed sources warm, a resolve issues no CC/Binance network call (stub counter == 0 after warm-up).
- [ ] **Step 5:** `just format`; commit: `refactor(resolution): source CC/Binance from caches (#1140)`.

---

## Task A7: Wire the new caches into `ProfileSession`

**Files:** Modify `App/ProfileSession+CatalogFactory.swift`, `App/ProfileSession+Factories.swift`, `App/ProfileSession.swift`.

- [ ] **Step 1:** In `+CatalogFactory.swift` add `makeCryptoCompareCache` + `makeBinanceCache` mirroring `makeCoinGeckoCatalog` (same `InstrumentRegistry` directory; CC gets `apiKeyProvider: { ProfileSession.resolveCryptoCompareApiKey() }`; both kick a background `refreshIfStale()` task returned for teardown cancellation). Store the cache handles + refresh tasks on `ProfileSession` (mirror the existing `catalogRefreshTask` storage).
- [ ] **Step 2:** In `+Factories.swift` `makeRegistryWiring`, build `CompositeTokenResolutionClient` with the two caches injected. Thread the cache instances out via `RegistryWiring` so PR2 can reach them (add `cryptoCompareCache`/`binanceCache`/`coinGeckoCatalog` to the bundle; `coinGeckoCatalog` already there).
- [ ] **Step 3:** `just build-mac 2>&1 | tail -5` → succeeds. Run a broad crypto slice: `just test-mac CompositeTokenResolutionClientTests CryptoCompareTokenCacheTests BinanceTokenCacheTests 2>&1 | tee .agent-tmp/a7.txt` → PASS.
- [ ] **Step 4:** `just format`; commit: `feat(app): build + refresh CryptoCompare/Binance caches at session start (#1140)`.

---

## Task A8: PR1 verification + open PR

- [ ] **Step 1:** `just format-check 2>&1 | tail -20` → clean (fix inline; never baseline).
- [ ] **Step 2:** Run the full affected set: `just test-mac SQLiteCoinGeckoCatalogStorageTests SQLiteCoinGeckoCatalogSearchTests SQLiteCoinGeckoCatalogRefreshTests SQLiteCoinGeckoCatalogParseTests CatalogDatabaseTests CatalogRefreshTests CryptoCompareTokenCacheTests BinanceTokenCacheTests CompositeTokenResolutionClientTests CompositeTokenResolutionLocalFirstTests CompositeTokenResolutionProKeyTests 2>&1 | tee .agent-tmp/a8.txt`; `grep -i 'failed\|error:' .agent-tmp/a8.txt || echo "no failures"`.
- [ ] **Step 3:** `@agent-concurrency-review` and `@agent-database-code-review` over the new `Backends/Catalog/*` and the two caches (actor isolation, SQLite-on-actor, STRICT/index rules). Apply all findings.
- [ ] **Step 4:** `rm -f .agent-tmp/a*.txt .agent-tmp/extraction-notes.md`.
- [ ] **Step 5:** Push + PR: `git -C <worktree> push origin feature/crypto-provider-catalog:feature/crypto-provider-catalog` then `gh pr create --fill --title "refactor(crypto): shared self-refreshing provider token-list caches (#1140 PR1)"` with a body noting "no #1140 behaviour change; PR2 stacks the re-detection."

---

# PART B — PR2 (stacked on PR1): re-detection reconciliation

Branch off PR1's head with `--no-track` (see CLAUDE.md stacked-PR section): `git -C <repo> worktree add --no-track .worktrees/crypto-provider-catalog-pr2 -b feature/crypto-provider-catalog-redetect feature/crypto-provider-catalog`, copy `.env`, `EnterWorktree` into it. PR2 targets base `feature/crypto-provider-catalog`.

File structure (PR2):

| File | Responsibility | Action |
|---|---|---|
| `Domain/Models/CryptoProviderMapping.swift` | merge-only `merging(_:)` | Modify |
| `Domain/Repositories/ProviderTokenCaches.swift` | `ProviderCatalogLookups` protocol bundle (if not added in A6/A7) | Create/confirm |
| `Domain/Repositories/InstrumentRegistryRepository+Reconcile.swift` | `reconcileProviderMappings(using:)` | Create |
| `App/ProfileSession.swift` | run reconcile after preset seeding | Modify |
| `MoolahTests/Domain/CryptoProviderMappingTests.swift` | merging tests | Create |
| `MoolahTests/Domain/InstrumentRegistryReconcileTests.swift` | reconciliation contract tests | Create |

## Task B1: `CryptoProviderMapping.merging(_:)`

**Files:** Modify `Domain/Models/CryptoProviderMapping.swift`; Test `MoolahTests/Domain/CryptoProviderMappingTests.swift`.

- [ ] **Step 1: Write failing test** `CryptoProviderMappingTests`:

```swift
import Testing
@testable import Moolah

@Suite("CryptoProviderMapping.merging")
struct CryptoProviderMappingTests {
  @Test("fills nil columns from other, never downgrades populated ones")
  func mergeFillsNilsOnly() {
    let stored = CryptoProviderMapping(
      instrumentId: "1:0xrpl", coingeckoId: "rocket-pool",
      cryptocompareSymbol: nil, binanceSymbol: nil)
    let extra = CryptoProviderMapping(
      instrumentId: "1:0xrpl", coingeckoId: "WRONG",
      cryptocompareSymbol: "RPL", binanceSymbol: "RPLUSDT")
    let merged = stored.merging(extra)
    #expect(merged.coingeckoId == "rocket-pool")
    #expect(merged.cryptocompareSymbol == "RPL")
    #expect(merged.binanceSymbol == "RPLUSDT")
    #expect(merged.instrumentId == "1:0xrpl")
  }

  @Test("no-op merge equals self")
  func noOp() {
    let full = CryptoProviderMapping(
      instrumentId: "1:0xrpl", coingeckoId: "rocket-pool",
      cryptocompareSymbol: "RPL", binanceSymbol: "RPLUSDT")
    #expect(full.merging(.init(instrumentId: "1:0xrpl", coingeckoId: nil,
      cryptocompareSymbol: nil, binanceSymbol: nil)) == full)
  }
}
```

- [ ] **Step 2:** `just test-mac CryptoProviderMappingTests` → FAIL.
- [ ] **Step 3: Implement** in `CryptoProviderMapping`:

```swift
  /// Merge-only fill: each nil provider id is taken from `other`; a populated
  /// column is never overwritten. `instrumentId` unchanged. Used by the
  /// re-detection pass to upgrade a stored mapping without downgrading (#1140).
  func merging(_ other: CryptoProviderMapping) -> CryptoProviderMapping {
    CryptoProviderMapping(
      instrumentId: instrumentId,
      coingeckoId: coingeckoId ?? other.coingeckoId,
      cryptocompareSymbol: cryptocompareSymbol ?? other.cryptocompareSymbol,
      binanceSymbol: binanceSymbol ?? other.binanceSymbol)
  }
```

- [ ] **Step 4:** `just test-mac CryptoProviderMappingTests` → PASS.
- [ ] **Step 5:** `just format`; commit.

## Task B2: `ProviderCatalogLookups` + attribution helper

**Files:** `Domain/Repositories/ProviderTokenCaches.swift` (define the seam if not already created in PR1).

Define a Sendable bundle of just the query seams reconciliation needs, so it is stub-testable and does not pull the concrete actors into Domain:

```swift
protocol CryptoCompareSymbolLookup: Sendable {
  func symbol(forContract address: String) async -> String?
  func nativeSymbols() async -> Set<String>
  func allSymbols() async -> Set<String>
}
protocol BinancePairLookup: Sendable {
  func hasUsdtPair(base symbol: String) async -> Bool
}
struct ProviderCatalogLookups: Sendable {
  let cryptoCompare: any CryptoCompareSymbolLookup
  let binance: any BinancePairLookup
  let coinGecko: (any LocalContractResolver)?
}
```

Conform `CryptoCompareTokenCache`/`BinanceTokenCache` to these (the methods already exist).

- [ ] **Step 1:** Add the protocols + conformances. `just build-mac` → succeeds.
- [ ] **Step 2:** `just format`; commit.

## Task B3: `reconcileProviderMappings(using:)`

**Files:** Create `Domain/Repositories/InstrumentRegistryRepository+Reconcile.swift`; Test `MoolahTests/Domain/InstrumentRegistryReconcileTests.swift`.

Semantics (per design): for each `allCryptoRegistrations()` entry, derive an additive mapping from the caches (binance via ticker `hasUsdtPair`; CC via contract / native / by-symbol; coingecko via contract match), `merging` onto the stored mapping, and `registerCrypto` **only when changed**.

- [ ] **Step 1: Write failing tests** (`makeRepo()` in-memory like `InstrumentRegistryContractTests.makeSubject`; stub `ProviderCatalogLookups`):
  - coingecko-only RPL (ticker "RPL", contract 0xd335…) + Binance stub `hasUsdtPair("RPL")=true` + CC stub `symbol(forContract:0xd335…)="RPL"` → upgraded to binance `RPLUSDT` + cc `RPL`.
  - token already full → no change, no `onRecordChanged` (assert via hook box like `InstrumentRegistryContractTests`).
  - token whose caches return nothing → untouched.
  - idempotent: second run → no further `onRecordChanged`.
- [ ] **Step 2:** `just test-mac InstrumentRegistryReconcileTests` → FAIL.
- [ ] **Step 3: Implement** the extension method (logger, `allCryptoRegistrations()` load with cancellation/​error guards, per-token attribution + `merging` + change-gated `registerCrypto`, best-effort catch). Reuse a shared attribution helper if A6 extracted one; otherwise inline the same #790-safe logic (identity is already contract-confirmed because the row has ≥1 provider id).
- [ ] **Step 4:** `just test-mac InstrumentRegistryReconcileTests` → PASS.
- [ ] **Step 5:** `just format`; commit.

## Task B4: Wire reconciliation at startup

**Files:** Modify `App/ProfileSession.swift` (`seedBuiltInCryptoPresets`, ~line 295).

- [ ] **Step 1:** After `await registry.registerBuiltInPresetsIfMissing()` in the same tracked task, build `ProviderCatalogLookups` from the wired caches and `await registry.reconcileProviderMappings(using: lookups)`. Update the method doc comment to mention re-detection (#1140). Guard for nil caches (skip reconcile if unavailable).
- [ ] **Step 2:** `just build-mac 2>&1 | tail -5` → succeeds; `just test-mac InstrumentRegistryReconcileTests` → PASS.
- [ ] **Step 3:** `just format`; commit.

## Task B5: PR2 verification + stacked PR

- [ ] **Step 1:** `just format-check` → clean.
- [ ] **Step 2:** `just test-mac CryptoProviderMappingTests InstrumentRegistryReconcileTests InstrumentRegistryContractTests 2>&1 | tee .agent-tmp/b5.txt`; `grep -i 'failed\|error:' .agent-tmp/b5.txt || echo "no failures"`.
- [ ] **Step 3:** `@agent-code-review` + `@agent-concurrency-review` over the reconcile path. Apply all findings.
- [ ] **Step 4:** `rm -f .agent-tmp/b5.txt`.
- [ ] **Step 5:** Push with explicit refspec and base PR1 (CLAUDE.md stacked rules): `git -C <pr2-worktree> push origin feature/crypto-provider-catalog-redetect:feature/crypto-provider-catalog-redetect`; `gh pr create --base feature/crypto-provider-catalog --fill --title "feat(crypto): re-detect provider mappings for registered tokens (#1140 PR2)"` body `Closes #1140.` + the 🤖 footer.

---

## Self-review notes

- **Spec coverage:** generalize caching (A1–A3) ✓; CC cache (A4) ✓; Binance cache (A5) ✓; resolution rewire / fetch-on-miss (A6–A7) ✓; re-detection reconcile (B3–B4) ✓; merge-only never-downgrade (B1, B3) ✓; two stacked PRs (A8, B5) ✓; HEX not reclassified (no task touches it) ✓.
- **Behaviour-preservation guard:** A3/A6 keep existing CoinGecko + resolution suites green; that is the explicit regression gate for the refactor.
- **Type consistency:** `CatalogDatabase`, `CatalogRefresh.run`, `CatalogEndpoint`, `CatalogFetchOutcome`, `RefreshableCatalog`, `symbol(forContract:)`, `nativeSymbols()`, `allSymbols()`, `hasUsdtPair(base:)`, `ProviderCatalogLookups`, `merging(_:)`, `reconcileProviderMappings(using:)` are referenced identically across tasks.
- **Risk:** A3 is the riskiest (refactor of working, tested code); A0 spike de-risks it and the existing suites bound it. If the FTS/search seam resists extraction, the implementer reports DONE_WITH_CONCERNS rather than forcing it.
- **CC key:** the CC cache must send the api key (401 without). Free-tier cap is fine: one bulk call / 24h.
