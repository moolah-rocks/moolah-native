# Remove CryptoCompare Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all runtime use of CryptoCompare (pricing + token detection), its
API-key surface, and its GRDB column; deprecate (not delete) its CloudKit field.

**Architecture:** Two stacked PRs. PR 1 stops the app touching CryptoCompare
(pricing chain, USDT-rate, token cache, resolver + reconcile steps, Settings key,
help) while leaving the data-model field/column dormant. PR 2 removes the GRDB column
via migration, drops `cryptocompareSymbol` from `CryptoProviderMapping`, deprecates the
CloudKit field, and removes the `SyncProvider.cryptoCompare` case.

**Tech Stack:** Swift, SwiftUI, GRDB (SQLite), CloudKit (CKSyncEngine), Swift Testing.

## Global Constraints

- **Design spec:** `plans/2026-07-05-remove-cryptocompare-design.md` — authoritative.
- **Worktree:** all work in the `remove-cryptocompare` worktree; never edit `main`.
- **Build:** `just build-mac` must pass after each task.
- **Format:** `just format-check` must pass before every commit
  (`just format` to fix). SwiftLint uses the CI-pinned binary.
- **Tests:** Swift Testing (`@Test`/`@Suite`), not XCTest. Run relevant suites with
  `just test-mac` (long runs stay in the controller, not delegated to a subagent).
- **AI review gate:** run the routed reviewer(s) before each commit; fix every finding
  and re-review until clean. Routing per task below.
- **CloudKit is additive-only:** never remove a field from `schema.ckdb`; deprecate.
- **No prod-migration gate:** nothing here deletes a CloudKit field, so no prod gate.
- **Provider chain after removal:** price = DefiLlama → CoinGecko → Binance →
  Stablecoin peg; USDT-rate = CoinGecko → Stablecoin peg.

---

# PR 1 — Stop using CryptoCompare

Branch: `remove-cryptocompare` (this worktree). Each task ends green
(`just build-mac` + touched tests) and reviewed. Commit per task.

### Task 1: Remove CryptoCompare from the price + USDT-rate chains

**Files:**
- Modify: `App/ProfileSession+Factories.swift` (`cryptoCompareClient` L89,
  `usdtRateClients` L100–101, `priceClients` L115–118)
- Modify: `App/ProfileSession+CryptoSync.swift` (`resolveCryptoCompareApiKey()`)
- Test: `MoolahTests/Shared/CryptoPriceServiceFallbackTests.swift`

**Interfaces:**
- Consumes: existing `defiLlamaClient`, `coinGeckoClient`, `binanceClient`,
  `stablecoinClient` locals in `+Factories.swift`.
- Produces: `priceClients == [defiLlama, coinGecko, binance, stablecoin]`;
  `usdtRateClients == [coinGecko, stablecoin]`. No `resolveCryptoCompareApiKey`.

- [ ] **Step 1: Update the fallback-chain test to the new order.** In
  `CryptoPriceServiceFallbackTests.swift`, find any assertion referencing a
  CryptoCompare provider in the chain and rewrite it for the 4-provider chain
  (DefiLlama → CoinGecko → Binance → Stablecoin). If the suite drives the chain via
  stub clients, drop the CryptoCompare stub from the array.

- [ ] **Step 2: Run it, expect failure.**
  `just test-mac` filtered to `CryptoPriceServiceFallbackTests` — expect FAIL
  (production still injects `cryptoCompareClient`).

- [ ] **Step 3: Remove `cryptoCompareClient` from both arrays** in
  `+Factories.swift`: delete its construction (L89 block through the closing `)`),
  remove it from `usdtRateClients` (leaving `[coinGeckoClient, stablecoinClient]`) and
  from `priceClients` (leaving `[defiLlamaClient, coinGeckoClient, binanceClient,
  stablecoinClient]`). Update the surrounding docstring (L70–75) to drop CryptoCompare.

- [ ] **Step 4: Remove `resolveCryptoCompareApiKey()`** from `+CryptoSync.swift`
  (its only caller was the client just deleted; confirm no other caller with
  `grep -rn resolveCryptoCompareApiKey`).

- [ ] **Step 5: Build + test.** `just build-mac`, then the filtered test — expect PASS.
  Expect compile errors pointing at remaining `CryptoCompareClient` references
  (resolver/reconcile) — those are Tasks 2–4; if the build cannot pass yet because
  `CryptoCompareClient` is still referenced elsewhere, proceed to Task 2 and treat
  Tasks 1–4 as one build-green checkpoint at the end of Task 4.

- [ ] **Step 6: Review.** `@code-review` + `@concurrency-review` on the factory
  changes. Fix findings.

- [ ] **Step 7: Commit** (only if `just build-mac` is green; otherwise commit at end of
  Task 4). `git add -A && git commit`:
  `refactor(pricing): drop CryptoCompare from price and USDT-rate chains`

### Task 2: Simplify the token resolver (remove CryptoCompare steps)

**Files:**
- Modify: `Shared/CompositeTokenResolutionClient.swift`
- Modify: `MoolahTests/Shared/CompositeTokenResolutionClientTests.swift`,
  `MoolahTests/Shared/CompositeTokenResolutionCacheTests.swift`

**Interfaces:**
- Produces: `CompositeTokenResolutionClient` with no `cryptoCompareLookup` param, no
  `preloadedCoinList`, no `resolveFromCryptoCompare` / `postConfirmCryptoCompareBySymbol`
  / `fetchCoinListData`. `resolve(...)` flow: local-first → CoinGecko contract →
  Binance pair. `result.cryptocompareSymbol` is never set here.

- [ ] **Step 1: Update resolver tests.** In both test files, delete cases asserting
  CryptoCompare resolution (step 1 contract/native match, step 2b post-confirm) and
  any that pass `coinListData:` / `cryptoCompareLookup:`. Keep/adjust cases for
  local-first, CoinGecko contract lookup, and the Binance #790 gate — the gate now
  relies on CoinGecko setting `resolvedSymbol`. Update the `coinListData:`/
  `exchangeInfoData:` test init usage: replace the two-arg reference-data init with the
  primary init (or a Binance-only equivalent) per what the remaining tests need.

- [ ] **Step 2: Run, expect failure.** `just test-mac` filtered to the two suites —
  FAIL (methods/params still exist / signatures changed).

- [ ] **Step 3: Edit `CompositeTokenResolutionClient.swift`:**
  - Remove the `cryptoCompareLookup` stored property (L23) and its init params in
    both initializers; remove `preloadedCoinList` (L30) and the `coinListData:` test
    init param.
  - In `resolve(...)`: delete the `coinListData` fetch (L92), the
    `resolveFromCryptoCompare(...)` call (L94–99), and the
    `postConfirmCryptoCompareBySymbol(...)` call (L106–107).
  - Delete the `resolveFromCryptoCompare`, `postConfirmCryptoCompareBySymbol`, and
    `fetchCoinListData` methods.
  - Update the type doc comment (L3–4) to drop CryptoCompare.
  - Leave CoinGecko + Binance steps and `fetchExchangeInfoData` / `fetchAssetPlatforms`
    intact.

- [ ] **Step 4: Build + test.** `just build-mac` (may still error on
  `ProviderCatalogLookups` / factory wiring — resolved in Tasks 3–4), then filtered
  suites — expect PASS once the type compiles.

- [ ] **Step 5: Review.** `@code-review` + `@concurrency-review`. Fix findings.

- [ ] **Step 6: Commit (if build green):**
  `refactor(crypto): remove CryptoCompare steps from token resolver`

### Task 3: Remove the CryptoCompare catalog lookup + reconcile branches

**Files:**
- Modify: `Domain/Repositories/ProviderCatalogLookups.swift` (remove `cryptoCompare`
  member, L8)
- Modify: `Domain/Repositories/InstrumentRegistryRepository+Reconcile.swift`
  (branches L136, L144, L150)
- Modify: `MoolahTests/Domain/InstrumentRegistryReconcileTests.swift`
- Delete: `Shared/CryptoImport/CryptoCompareSymbolLookup.swift`

**Interfaces:**
- Produces: `ProviderCatalogLookups` without a `cryptoCompare` member; reconcile
  resolves symbols via the surviving catalog lookups (Binance) only.

- [ ] **Step 1: Update reconcile tests.** In `InstrumentRegistryReconcileTests.swift`,
  remove construction of a `cryptoCompare` lookup in the `ProviderCatalogLookups`
  fixtures and delete/adjust assertions that expected a symbol resolved *via
  CryptoCompare*. Keep cases covered by the Binance/other lookups.

- [ ] **Step 2: Run, expect failure.** `just test-mac` filtered to the suite — FAIL.

- [ ] **Step 3: Edit production:**
  - `ProviderCatalogLookups.swift`: delete the
    `let cryptoCompare: any CryptoCompareSymbolLookup` member and its init param;
    fix every construction site the compiler flags (factories/wiring — coordinate
    with Task 4).
  - `InstrumentRegistryRepository+Reconcile.swift`: delete the three
    `catalogs.cryptoCompare.*` branches (symbol-by-contract L136, `allSymbols` L144,
    `nativeSymbols` L150), preserving the surrounding control flow (e.g. keep the
    ticker/native checks that route through remaining lookups).
  - Delete `Shared/CryptoImport/CryptoCompareSymbolLookup.swift`.

- [ ] **Step 4: Build + test.** `just build-mac`, filtered suite — PASS once wiring
  (Task 4) compiles.

- [ ] **Step 5: Review.** `@code-review` + `@concurrency-review` +
  `@database-code-review` (reconcile touches the registry repo). Fix findings.

- [ ] **Step 6: Commit (if build green):**
  `refactor(crypto): drop CryptoCompare catalog lookup and reconcile branches`

### Task 4: Delete the token cache + factory/wiring, restore green build

**Files:**
- Delete: `Backends/CryptoCompare/CryptoCompareTokenCache.swift`,
  `CryptoCompareTokenCache+Refresh.swift`, `CryptoCompareTokenCacheSchema.swift`,
  `Backends/CryptoCompare/CryptoCompareClient.swift`
- Delete: `MoolahTests/Backends/CryptoCompare/CryptoCompareTokenCacheTests.swift`,
  `MoolahTests/Backends/CryptoCompareClientTests.swift`,
  `MoolahTests/Backends/CryptoCompareClientAuthTests.swift`
- Modify: `App/ProfileSession.swift` (`cryptoCompareCache` prop L65),
  `App/ProfileSession+CatalogFactory.swift` (`makeCryptoCompareCache`),
  `App/ProfileSession+RegistryWiring.swift` (L27, L41 cache params),
  `App/ProfileSession+CryptoPresets.swift` (L63 guard),
  `App/PreloadedTokenResolutionClient.swift`
- Modify: `project.yml` if the deleted files are individually listed (usually
  glob-sourced — check).

**Interfaces:**
- Produces: no `CryptoCompareTokenCache` / `CryptoCompareClient` types anywhere; the
  app builds and the full suite passes.

- [ ] **Step 1: Delete the four production files and the three test files** listed
  above.

- [ ] **Step 2: Remove wiring:**
  - `ProfileSession.swift`: delete `private(set) var cryptoCompareCache:
    CryptoCompareTokenCache?` (L65) and any assignment to it.
  - `+CatalogFactory.swift`: delete `makeCryptoCompareCache(...)` and its call site;
    remove `cryptoCompare:` from the `ProviderCatalogLookups` construction.
  - `+RegistryWiring.swift`: delete the `cryptoCompareCache` params (L27, L41) and
    pass-through.
  - `+CryptoPresets.swift`: at L63 the `guard let cryptoCompareCache, let binanceCache`
    becomes `guard let binanceCache` (drop the CC clause); if the whole preset step was
    CC-only, delete it.
  - `PreloadedTokenResolutionClient.swift`: remove `cryptocompareSymbol` / CC-cache
    references so it constructs `CompositeTokenResolutionClient` with the new signature.

- [ ] **Step 3: Full build.** `just build-mac` — expect PASS (this is the build-green
  checkpoint for Tasks 1–4). Fix any remaining reference the compiler flags.

- [ ] **Step 4: Full relevant tests.** `just test-mac` filtered to
  `Backends`, `Shared`, `Domain` crypto suites — expect PASS.

- [ ] **Step 5: Review.** `@code-review` + `@concurrency-review`. Fix findings.

- [ ] **Step 6: Commit:**
  `refactor(crypto): delete CryptoCompare client and token cache`

### Task 5: Remove the Settings API-key surface + keychain, with cleanup

**Files:**
- Modify: `Features/Settings/CryptoTokenStore.swift` (`cryptocompareKeyStore` L103,
  `"cryptocompare"` account L180)
- Modify: `Features/Settings/CryptoTokenStore+APIKeys.swift` (L89–129 CC helpers)
- Modify: `Features/Settings/CryptoSettingsView+TokenList.swift` (CC key UI section)
- Delete: `MoolahTests/Features/Settings/CryptoSettingsCryptoCompareKeyTests.swift`
- Test: an existing Settings suite for the surviving key(s) (CoinGecko) still passes.

**Interfaces:**
- Produces: no `cryptocompareKeyStore` / `hasCryptoCompareApiKey` /
  `saveCryptoCompareApiKey` / `clearCryptoCompareApiKey`; a one-time keychain cleanup
  of the `"cryptocompare"` account.

- [ ] **Step 1: Delete the CC key test file** and, in any Settings test that also
  exercises CoinGecko, remove references to the CC helpers.

- [ ] **Step 2: Run, expect failure.** `just test-mac` filtered to Settings crypto
  suites — FAIL (helpers still referenced).

- [ ] **Step 3: Remove production surface:**
  - `CryptoTokenStore+APIKeys.swift`: delete the three CC helpers (L89–129).
  - `CryptoTokenStore.swift`: delete `cryptocompareKeyStore` (L103) and the
    `"cryptocompare"` keychain account constant (L180).
  - `CryptoSettingsView+TokenList.swift`: delete the CC key `Section`/row (the
    "Requires a free API key from CoinDesk Data…" copy L192 and the signup link
    L227–235).

- [ ] **Step 4: Add one-time keychain cleanup.** In the existing settings/startup
  migration path (find via `grep -rn "KeychainServices.apiKeys" App Features`), add a
  best-effort delete of the `(service: apiKeys, account: "cryptocompare",
  synchronizable: true)` item so a synced secret does not linger. Guard it so it runs
  once (reuse whatever one-shot flag pattern the codebase already uses; if none, a
  simple unconditional delete-if-present at store init is acceptable since delete is
  idempotent).

- [ ] **Step 5: Build + test.** `just build-mac`, filtered Settings suites — PASS.

- [ ] **Step 6: Review.** `@code-review` + `@ui-review` (Settings view copy/layout).
  Fix findings.

- [ ] **Step 7: Commit:**
  `refactor(settings): remove CryptoCompare API-key surface and keychain`

### Task 6: Remove CryptoCompare help content

**Files:**
- Delete: `site/help/get-a-cryptocompare-api-key.html` and its `_src/topics/` source.
- Modify: `site/help/supported-crypto-chains-and-providers.html`,
  `site/help/investments-and-crypto.html`, `site/help/manage-crypto-tokens.html`
  (+ their `_src` sources if the HTML is generated).

- [ ] **Step 1: Locate sources.** `grep -rln -i cryptocompare site/help` to find every
  file (generated HTML + `_src`). Determine whether HTML is generated from `_src`
  (edit source + regenerate) or hand-authored (edit HTML directly).

- [ ] **Step 2: Delete the dedicated article** (both `_src` and generated HTML) and
  remove any nav/index/TOC entry that links to it (search the help index for the
  slug).

- [ ] **Step 3: Edit the three overview pages** to drop CryptoCompare mentions and the
  "get a free key" guidance; describe the current keyless DefiLlama/CoinGecko coverage
  instead. Do not invent new claims — state that crypto prices come from DefiLlama and
  CoinGecko.

- [ ] **Step 4: Regenerate** if generated (run the help build the repo uses; find via
  `grep -rn help site/**/justfile` or the site build script) and verify no dead links
  to the deleted slug remain (`grep -rn get-a-cryptocompare-api-key site`).

- [ ] **Step 5: Review.** `@help-review`. Fix findings.

- [ ] **Step 6: Commit:** `docs(help): remove CryptoCompare help content`

### Task 7: Verify functional consequences (no code, gate before PR)

**Purpose:** confirm the two accepted consequences don't silently break real tokens.

- [ ] **Step 1: DAI still prices via DefiLlama.** Confirm DAI's instrument carries a
  contract address and that `DefiLlamaClient` prices by contract address (read
  `Backends/DefiLlama/DefiLlamaClient.swift`). If a DefiLlama-by-contract test fixture
  for a DAI-like token exists, note it; otherwise record that DAI relies on
  DefiLlama-by-contract + CoinGecko with no $1 peg (expected, accepted).

- [ ] **Step 2: #790 gate still holds via CoinGecko.** Re-read the Binance-pair gate in
  `CompositeTokenResolutionClient.resolveBinancePair` and confirm `resolvedSymbol` is
  set only by local-first or CoinGecko for ERC-20s (no ticker-only path reintroduced).
  Confirm the resolver tests cover "ERC-20 with unresolvable contract gets no Binance
  pair."

- [ ] **Step 3: Full suite.** `just test-mac` (whole suite, in the controller) — record
  0 failures. Re-run any known-flaky suite once per the flake memory notes rather than
  investigating.

- [ ] **Step 4: Open PR 1.** Push the branch, `gh pr create` with a body summarising
  the removal + the two accepted consequences. Do **not** auto-land yet — PR 2 stacks
  on it. (Per repo default the PR auto-queues; add "don't land yet, PR 2 stacks on
  this" or hold the queue per the landing-prs skill.)

---

# PR 2 — Data-model cleanup (stacked on PR 1)

Create the stacked worktree per the CLAUDE.md stacked-PR rules (`--no-track`, explicit
push refspec) or via the landing-prs stacked flow. Branch: `remove-cryptocompare-schema`.

### Task 8: Deprecate the CloudKit field + drop CryptoProviderMapping property

**Files:**
- Modify (via modifying-cloudkit-schema skill): `CloudKit/schema.ckdb` (mark
  `cryptocompareSymbol` deprecated — field stays),
  `Backends/CloudKit/Sync/Generated/InstrumentRecordCloudKitFields.swift`
- Modify: `Backends/GRDB/Sync/InstrumentRow+CloudKit.swift` (L21, L60)
- Modify: `Domain/Models/CryptoProviderMapping.swift` (`cryptocompareSymbol` L12 +
  `hasProviderMapping`/`assetKey`)
- Modify: `MoolahTests/Domain/CryptoProviderMappingTests.swift`

**Interfaces:**
- Produces: CloudKit records neither read nor write `cryptocompareSymbol`;
  `CryptoProviderMapping` has no `cryptocompareSymbol`.

- [ ] **Step 1: Invoke the modifying-cloudkit-schema skill** and follow it to mark
  `cryptocompareSymbol` deprecated in `schema.ckdb` (do NOT delete the field) and
  regenerate/edit `InstrumentRecordCloudKitFields` so the generated struct no longer
  has the property (or no longer maps it in `init(record:)` / `apply(to:)`). Follow the
  skill's `cktool` steps exactly.

- [ ] **Step 2: Update `CryptoProviderMappingTests`** — remove assertions on
  `cryptocompareSymbol`, `hasProviderMapping` contributions from it, and `assetKey`
  segments. Run filtered → expect FAIL.

- [ ] **Step 3: Edit `CryptoProviderMapping.swift`** — delete the `cryptocompareSymbol`
  property (L12) and remove it from `hasProviderMapping` and `assetKey`.

- [ ] **Step 4: Edit `InstrumentRow+CloudKit.swift`** — remove `cryptocompareSymbol:`
  from the record-build (L21) and the field-read (L60) so it compiles against the
  regenerated wire struct.

- [ ] **Step 5: Build + test.** `just build-mac`, filtered Domain + Sync suites — PASS.

- [ ] **Step 6: Review.** `@sync-review` (CloudKit deprecation + mapping) +
  `@code-review`. Fix findings.

- [ ] **Step 7: Commit:**
  `refactor(sync): deprecate CryptoCompare CloudKit field, drop mapping property`

### Task 9: Drop the GRDB `cryptocompare_symbol` column

**Files:**
- Modify: the `DatabaseMigrator` registration file (find via
  `grep -rn "migrator.registerMigration" Backends/GRDB`)
- Modify: `Backends/GRDB/Records/InstrumentRow.swift` (columns L32/L49, property L72),
  `Backends/GRDB/Records/InstrumentRow+Mapping.swift`,
  `Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+InstrumentRegistering.swift`,
  `+Upsert.swift`
- Test: a GRDB migration/plan-pinning test (per DATABASE_SCHEMA_GUIDE)

**Interfaces:**
- Produces: instruments table has no `cryptocompare_symbol` column; `InstrumentRow`
  has no `cryptocompareSymbol`.

- [ ] **Step 1: Read DATABASE_SCHEMA_GUIDE** for the sanctioned column-drop pattern
  (SQLite `ALTER TABLE DROP COLUMN` vs table-rebuild) and the migration-test
  expectations. Follow it.

- [ ] **Step 2: Add a migration test** asserting the column is gone after migration
  (mirror an existing schema-migration test in `MoolahTests`). Run → expect FAIL.

- [ ] **Step 3: Register the migration** — a new, appended `registerMigration` that
  drops `cryptocompare_symbol` from the instruments table per the guide. Never edit an
  existing shipped migration.

- [ ] **Step 4: Remove the column from the record** — delete the
  `cryptocompareSymbol = "cryptocompare_symbol"` `CodingKeys`/`Columns` entries (L32,
  L49) and the `var cryptocompareSymbol: String?` property (L72) in `InstrumentRow`;
  drop it from `+Mapping.swift` and from the two repository files' upsert/register
  column lists.

- [ ] **Step 5: Build + test.** `just build-mac`, then the migration test + the
  `Backends/GRDB` instrument suites — expect PASS.

- [ ] **Step 6: Review.** `@database-schema-review` + `@database-code-review`. Fix
  findings.

- [ ] **Step 7: Commit:**
  `refactor(db): drop cryptocompare_symbol column from instruments`

### Task 10: Remove the SyncProvider case + final sweep

**Files:**
- Modify: `Domain/Models/SyncProvider.swift` (case L14, displayName L29)
- Modify: `MoolahTests/Domain/Models/SyncProviderTests.swift`

- [ ] **Step 1: Update `SyncProviderTests`** — remove the `.cryptoCompare` /
  "CryptoCompare" displayName assertion. Run → expect FAIL.

- [ ] **Step 2: Remove the case** `case cryptoCompare` (L14) and its `displayName`
  branch (L29) in `SyncProvider.swift`.

- [ ] **Step 3: Final sweep.** `grep -rin cryptocompare .` across the repo (excluding
  `plans/` and the deprecated `schema.ckdb` field). Expect **zero** production/test
  hits. Resolve any stragglers.

- [ ] **Step 4: Build + full test.** `just build-mac`, then `just test-mac` (whole
  suite in the controller) — 0 failures.

- [ ] **Step 5: Review.** `@code-review`. Fix findings.

- [ ] **Step 6: Commit:** `refactor(crypto): remove SyncProvider.cryptoCompare case`

- [ ] **Step 7: Open PR 2** stacked on PR 1 (`gh pr create --base
  remove-cryptocompare`). Land both via the landing-prs stacked flow.

---

## Self-review notes

- **Build-green seam:** Tasks 1–4 are mutually dependent (deleting the client breaks
  the resolver/reconcile/wiring). They form one build-green checkpoint at the end of
  Task 4; earlier commits are allowed only if `just build-mac` happens to pass. If a
  reviewer prefers one atomic commit for 1–4, squash them.
- **Spec coverage:** pricing (T1), resolver (T2), catalog+reconcile (T3), cache/client
  delete + wiring (T4), settings/keychain (T5), help (T6), consequences (T7), CloudKit
  deprecate + mapping (T8), GRDB column (T9), SyncProvider + sweep (T10). All design
  inventory items mapped.
- **Migration files:** exact `DatabaseMigrator` file located in Task 9 Step 1 (guide
  read) — intentionally discovered at execution, not guessed here.
