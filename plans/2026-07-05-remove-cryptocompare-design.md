# Remove CryptoCompare Support — Design

**Date:** 2026-07-05
**Status:** Approved, ready for plan

## Background

CryptoCompare's API (`min-api.cryptocompare.com`, branded in-app as "CoinDesk Data,
formerly CryptoCompare") was acquired by CoinDesk. As of **2026-05-21 the free API
tier is fully retired** — accounts without a paid subscription lose API access even
with a key. The `min-api` host already returns `401` for keyless requests today.

In moolah CryptoCompare plays two roles, and neither is primary:

1. **Price provider** — 3rd of 5 in the fallback chain
   (DefiLlama → CoinGecko → **CryptoCompare** → Binance → Stablecoin peg), and the
   **primary** USDT→USD rate source for Binance-quoted tokens.
2. **Token-detection reference data** — its `/data/all/coinlist` endpoint feeds a
   local cache and the token resolver's contract→symbol mapping.

The decision is to **remove CryptoCompare entirely**.

## Goals

- Stop all runtime use of CryptoCompare for pricing and token detection.
- Remove the API-key surface (Settings UI + keychain storage).
- Remove the `cryptocompare_symbol` **GRDB** column for real.
- Stop reading/writing the `cryptocompareSymbol` **CloudKit** field (deprecate & ignore).
- Remove the dead help content and adjust tests.

## Non-goals

- **Deleting the CloudKit field.** CloudKit production schemas are additive-only; a
  shipped field cannot be removed, only deprecated. The field stays in `schema.ckdb`,
  inert, and the app stops reading/writing it. There is therefore **no prod-migration
  gate** on this work.
- Replacing CryptoCompare with a new provider. DefiLlama (primary) + CoinGecko already
  cover the surviving chain.

## Removal inventory

### Pricing
- Delete `Backends/CryptoCompare/CryptoCompareClient.swift`.
- `App/ProfileSession+Factories.swift`
  - Remove `cryptoCompareClient` from the price chain (`priceClients`, ~L115–122).
    New chain: DefiLlama → CoinGecko → Binance → Stablecoin peg.
  - Remove it from `usdtRateClients` (~L100–102). New USDT-rate chain:
    CoinGecko → Stablecoin peg.
- `App/ProfileSession+CryptoSync.swift` — remove `resolveCryptoCompareApiKey()`.

### Token detection
- Delete `Backends/CryptoCompare/CryptoCompareTokenCache.swift`,
  `…+Refresh.swift`, `…CryptoCompareTokenCacheSchema.swift`.
- Delete `Shared/CryptoImport/CryptoCompareSymbolLookup.swift`.
- `Shared/CompositeTokenResolutionClient.swift` — remove step 1
  (`resolveFromCryptoCompare`), step 2b (`postConfirmCryptoCompareBySymbol`),
  the `cryptoCompareLookup` dependency, `fetchCoinListData()`, and the
  `coinListData` plumbing. Resolver simplifies to:
  **local-first → CoinGecko contract → Binance pair.**
- `App/ProfileSession+CatalogFactory.swift` — remove `makeCryptoCompareCache(...)`.
- `App/ProfileSession+RegistryWiring.swift` — remove the `cryptoCompareCache` wiring.
- `App/ProfileSession.swift` — remove the `cryptoCompareCache` property.
- `App/PreloadedTokenResolutionClient.swift`, `ProfileSession+CryptoPresets.swift`
  — remove `cryptocompareSymbol` / cache carry-through.
- `Domain/Repositories/ProviderCatalogLookups.swift` — remove the
  `cryptoCompare: any CryptoCompareSymbolLookup` member from the catalog bundle and
  fix every construction site.
- `Domain/Repositories/InstrumentRegistryRepository+Reconcile.swift` — remove the
  three `catalogs.cryptoCompare` branches (symbol-by-contract, `allSymbols`,
  `nativeSymbols`). Reconcile's symbol resolution then relies on the surviving
  catalog lookups (Binance) only — a detection change, same class as consequence 1.
  Update `MoolahTests/Domain/InstrumentRegistryReconcileTests.swift`.

### Settings / secrets
- `Features/Settings/CryptoTokenStore.swift` — remove `cryptocompareKeyStore` and the
  `"cryptocompare"` keychain account.
- `Features/Settings/CryptoTokenStore+APIKeys.swift` — remove
  `hasCryptoCompareApiKey` / `saveCryptoCompareApiKey` / `clearCryptoCompareApiKey`.
- `Features/Settings/CryptoSettingsView+TokenList.swift` — remove the CC key UI
  section (copy + signup link).
- **Keychain cleanup:** on first launch after the update, delete any stored
  `"cryptocompare"` keychain item (one-time best-effort cleanup) so a synced secret
  doesn't linger. If simpler, fold this into existing settings/migration startup.

### Data model
- **GRDB — drop the column.** Register a new `DatabaseMigrator` migration that drops
  `cryptocompare_symbol` from the instruments table (per DATABASE_SCHEMA_GUIDE:
  column-drop / table-rebuild). Remove `cryptocompareSymbol` from `InstrumentRow`,
  `InstrumentRow+Mapping.swift`, `InstrumentRow+CloudKit.swift`, and the
  `GRDBInstrumentRegistryRepository` upsert/register sites.
- **CloudKit — deprecate & ignore.** Via the modifying-cloudkit-schema skill: mark
  `cryptocompareSymbol` deprecated in `schema.ckdb` (field remains) and remove it from
  the generated `InstrumentRecordCloudKitFields` read/write mapping so records no
  longer set or consume the key. No field deletion, no prod gate.
- `Domain/Models/CryptoProviderMapping.swift` — remove the `cryptocompareSymbol`
  property and its use in `hasProviderMapping` / `assetKey`.
- `Domain/Models/SyncProvider.swift` — remove the `.cryptoCompare` case + its
  `displayName`. **Confirmed safe:** `syncProvider` is a runtime-only
  `CryptoPriceClient` attribution property, not persisted (grep found no record/row
  column; the enum's own doc comment notes adding a case doesn't touch
  `DataFormatVersion`).

### Docs / help
- Delete `site/help/get-a-cryptocompare-api-key.html` (+ `_src` source).
- Update `site/help/supported-crypto-chains-and-providers.html`,
  `investments-and-crypto.html`, `manage-crypto-tokens.html` to drop CryptoCompare.
- Route via the help-review agent.

### Tests
- Delete `MoolahTests/Backends/CryptoCompareClientTests.swift`,
  `CryptoCompareClientAuthTests.swift`,
  `MoolahTests/Backends/CryptoCompare/CryptoCompareTokenCacheTests.swift`,
  `MoolahTests/Features/Settings/CryptoSettingsCryptoCompareKeyTests.swift`.
- Update `CompositeTokenResolutionClientTests` / `…CacheTests`,
  `CryptoProviderMappingTests`, `SyncProviderTests`,
  `CryptoPriceServiceFallbackTests` to the new chain/resolver shape.

## Functional consequences (accepted)

1. **ERC-20 anti-spam gate (#790) now leans solely on CoinGecko.** Today either
   CryptoCompare's contract index or CoinGecko can confirm an ERC-20's symbol for a
   given contract before a Binance pair is attributed. With CC gone, CoinGecko is the
   sole contract confirmer. A contract CoinGecko cannot resolve will no longer receive
   a Binance pair. **Plan must verify** CoinGecko confirms the common contracts.
2. **DAI/HEX lose their dedicated backfill.** They fall to DefiLlama-by-contract (both
   have contract addresses) and CoinGecko. DAI has **no $1 peg** (peg = USDC/USDT
   only). **Plan must verify** DAI still prices via DefiLlama without gapping.

## Sequencing

Nothing here is prod-gated, so this can land as normal PRs. Two-phase split keeps each
PR coherent and independently landable:

- **PR 1 — Stop using CryptoCompare.** Remove the price client + chain slots +
  USDT-rate use, the token cache + resolver steps, the Settings key UI + keychain +
  cleanup, and the help content. The data-model field/column go dormant (always nil)
  but remain in place. App fully stops touching CryptoCompare. Ships immediately.
- **PR 2 — Data-model cleanup.** Drop the GRDB `cryptocompare_symbol` column
  (migration), remove `cryptocompareSymbol` from `CryptoProviderMapping`, deprecate the
  CloudKit field (modifying-cloudkit-schema skill), and remove the `SyncProvider`
  case. Stacked on PR 1.

Verification checks (consequences 1 & 2 above) live in PR 1.

## Review gates

Standard AI review gate before each commit. Route by touched area:
`database-schema-review` + `database-code-review` (GRDB migration/column),
`sync-review` (CloudKit deprecation), `code-review` + `concurrency-review`
(resolver/factories), `ui-review` (Settings), `help-review` (help content),
`instrument-conversion-review` if any pricing-aggregation path is touched.
