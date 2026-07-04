# Unified cross-chain instrument identity — design

**Status:** Design converged and reviewed clean across three rounds of domain
review (sync, database-schema, database-code, instrument-conversion) — the final
round produced only minor completions (index columns, which registry queries carry
the alias filter), now incorporated. Proceeding to implementation plan.

**Relationship to prior work:** Supersedes the *identity* decision in
[`2026-06-13-cross-chain-asset-aggregation-design.md`](2026-06-13-cross-chain-asset-aggregation-design.md)
(issue [#1101](https://github.com/moolah-rocks/moolah-native/issues/1101)). That
design treated cross-chain ETH as **display/aggregation-only** — rolling up
per-chain instruments into one line via `assetKey` at the presentation layer
while leaving identity per-chain. That fixed the displayed *quantity* but could
not fix **transfer reconciliation**, which keys on instrument identity. This
design hoists the `assetKey` collapse down into identity/storage so the same
asset is genuinely one instrument.

## Problem

Crypto instruments use a chain-scoped identity: `Instrument.id` is
`"<chainId>:native"` or `"<chainId>:<address>"`, built in one place —
`Domain/Models/Instrument.crypto(...)` (`Domain/Models/Instrument.swift:199`).
ETH on mainnet, Optimism, and Base are **three distinct `Instrument` rows**
sharing name/ticker and a `coingeckoId` of `"ethereum"`.

Chain-scoped identity breaks down for anything that isn't a chain:

- **Transfer reconciliation fails across chains and chain↔exchange.** Coinstash
  (an exchange) holds plain "ETH" with no chain, mapping to mainnet Ethereum
  (`1:native`). A transfer of ETH *from* an Optimism wallet (`10:native`) *to*
  Coinstash (`1:native`) cannot be matched, because the two legs reference
  **different instruments**. This is the concrete driver.
- **Duplicate instruments** clutter the registry, picker, token list, and
  spam/impersonation surface.
- **Redundant pricing/mapping** — N identical provider mappings resolving to the
  same `coingeckoId` and price series.

## Goal

The same asset across chains is **one canonical `Instrument`**, so transfer
matching, the picker, the registry, and pricing treat ETH as a single asset —
while per-chain accuracy (sync import, gas accounting, block-explorer links,
per-chain balances) is preserved everywhere it genuinely matters.

## Non-goals

- Changing how a synced wallet is modelled (still one Account per (address,
  chain)).
- Unifying tokens with no provider key (`coingeckoId` / `cryptocompareSymbol` /
  `binanceSymbol`) — those stay chain-scoped.
- Merging genuinely different assets that share a symbol (guarded by keying on the
  provider `assetKey`, not the symbol).
- Physical deletion / CloudKit tombstoning of retired rows (deferred; see §4).

## Key enabling fact

A synced crypto wallet is **one `Account` per (address, chain)** — a wallet
holding ETH on mainnet, Optimism, and Base yields **three Accounts**, each with
its own `account.chainId` (`Features/Crypto/CryptoAccountCreationLogic.swift:37`,
`Shared/Sync/WalletSyncSource.swift:40`). `account.chainId` is non-nil for
on-chain wallets, nil for exchange/manual accounts. An Account holds **many**
instruments via `positions` computed from leg aggregation
(`Domain/Models/Position.swift:16`); `account.instrument_id` is the account's
fiat **denomination**, not its only asset.

**Consequence:** the chain dimension already lives on the account. A Base wallet
and an OP wallet remain separate accounts, each holding a `Position` in the *same*
ETH instrument, so the per-chain breakdown survives structurally.

## Core decisions

1. **Unification key = `assetKey`** (`coingeckoId ?? cryptocompareSymbol ??
   binanceSymbol`), the key the fold already uses
   (`Domain/Models/CryptoProviderMapping.swift:29`). Instruments sharing an
   `assetKey` are one asset; no-key instruments stay chain-scoped.
2. **Canonical id = the group member on the canonical chain** — prefer
   `chainId == 1`, else the lowest `chainId`. ETH → `1:native`; USDC → mainnet
   USDC's contract id. The canonical id stays a **valid pricing key**.
3. **Retire by aliasing, not deleting.** Retired rows are kept and marked with a
   new **local-only** `alias_of` column pointing at their canonical id. The
   registry/picker filter aliased rows; the resolver uses `alias_of` to route
   stray retired ids. This avoids the multi-profile/multi-device hazards of
   deleting a shared registry row other profiles reference, and avoids a CloudKit
   tombstone/resurrection battle. Physical deletion is **deferred** (§4).
4. **Canonicalize at instrument construction**, not only at leg-stamping — so a
   retired id is never minted (§3).
5. **Chain-of-holding comes from the account, not the instrument.**
   `Instrument.chainId` stays populated on the canonical record (=1 for ETH) but
   no longer means "the chain this holding is on."
6. **The one-shot data rewrite is an app-side async migration**, not a
   `DatabaseMigrator` step — it needs both SQLite files at once (§4).

## Design

### 1. Identity, the `alias_of` column, and the canonical resolver

**Schema change (ProfileIndexSchema, `DatabaseMigrator` v9 — the only migrator
change in the feature).** Bump `ProfileIndexSchema.version` 8 → 9; register
`"v9_add_instrument_alias_of"` (frozen literal) with its body in a new
`Backends/GRDB/ProfileIndexSchema+InstrumentAliasOf.swift`:

```sql
ALTER TABLE instrument
  ADD COLUMN alias_of TEXT
  CHECK (alias_of IS NULL OR alias_of != id);   -- self-reference would loop the resolver
CREATE INDEX instrument_by_alias ON instrument (id, alias_of) WHERE alias_of IS NOT NULL;
-- (id, alias_of) — not (id) alone — so the resolver's map-building query
-- `SELECT id, alias_of ... WHERE alias_of IS NOT NULL` is covered (§4 rule: the
-- WHERE column must be in the index).
```

**`alias_of` is a LOCAL-ONLY column (Option A).** It is **not** added to
`InstrumentRow.CodingKeys`, **not** in `toCKRecord()`, and never decoded from a
CKRecord. Consequences that resolve a cluster of review findings:
- Every Codable-driven `upsert`/`update` (registration, `reResolve`, normal sync
  apply) writes only `CodingKeys` columns, so it **cannot clobber `alias_of`**.
  Stickiness through `registerCrypto`/`reResolve` is automatic.
- `alias_of` is written in exactly two places, both raw SQL: the migration (§4)
  and the resolver-driven apply post-step (§3.5).
- Reads that need it (registry/picker filter, resolver map build) reference the
  column directly (`Column("alias_of")` / raw SQL), independent of `CodingKeys`.

**Canonical resolver** — one type answering `canonicalId(for id:) -> String` and
`isAlias(_ id:) -> Bool`. It has **two layers**:
- A **static hardcoded base layer**, present at startup, for known cross-chain
  assets (ETH L2 natives `10:native`/`8453:native` → `1:native`; known mainnet
  stablecoin contracts). This closes the **local pre-migration window**: from the
  instant the updated app launches — before the migration writes any `alias_of` —
  construction-time canonicalization (§3) already maps retired ids, so the local
  device never mints one.
- A **dynamic layer** built from the shared registry's `alias_of` column
  (refreshed on registry change), covering discovered ERC-20s that aren't in the
  static list.

**Canonical mapping derivation:** group crypto registrations by `assetKey`;
canonical = member with `chainId == 1`, else lowest `chainId`. No-key instruments
are their own canonical (unchanged).

**Stablecoin canonical ids (closed — a pre-implementation blocker).** For every
stablecoin in `Shared/CryptoImport/CanonicalTokenRegistry.swift`, canonical = the
**mainnet contract**. Implementation step 1 confirms `CanonicalTokenRegistry`
holds each mainnet contract and adds a test asserting
`StablecoinPriceClient.isPegged` still returns the peg for the canonical id
(`isPegged` calls `CanonicalTokenRegistry.symbol(chainId:1, contractAddress:)`,
`Backends/Stablecoin/StablecoinPriceClient.swift:59`). Add any missing mainnet
contract before the resolver ships.

### 2. Chain moves to the account — **ships first (prerequisite PR)**

This section is a **hard prerequisite** for §3.1 and §4: both make existing L2 ETH
legs carry `instrument.chainId == 1`, which would break block-explorer links until
this lands. It must merge before either.

- **`ValuedPosition` gains `accountChainId: Int?`** (`Domain/Models/ValuedPosition.swift`),
  populated from the owning account's `chainId` (nil for exchange/manual). Trace it
  through the valuation layer (`InvestmentStore`, `MultiInstrumentPositionsAssembler`,
  group-positions path). Today `ValuedPosition` carries no account data, so this
  field is what makes the fold's chain-source shift implementable.
- **`AssetHolding+Fold.contributingChainIds`** (`Domain/Models/AssetHolding+Fold.swift:93`)
  shifts from `Set(compactMap { $0.instrument.chainId })` to
  `Set(compactMap { $0.accountChainId })`. Otherwise every unified ETH position
  reports `[1]` regardless of the wallets' real chains.
- **`AssetHolding+Fold.contributingInstrumentIds`** (`:108`) is deduplicated
  (`.uniqued()` / `Set`) — post-unification all members share `1:native`, so the
  raw list would be `["1:native","1:native",…]`.
- **Block-explorer links** (`Features/Transactions/Views/Detail/TransactionDetailBlockExplorerSection.swift:55`)
  switch from `leg.instrument.chainId` to the leg's account chain. Specify the
  lookup: thread `accountChainId` onto the leg view-model at assembly (the section
  has no account-store access), hide the link when `accountId == nil` (manual tx),
  and fall back to `instrument.chainId` only for still-chain-scoped tokens.

### 3. Canonicalize at construction and every ingestion boundary

Retired ids must never be minted or stored. Every point that constructs,
registers, or applies a crypto instrument routes through the resolver.

1. **`ChainConfig.nativeInstrument`** (`Shared/CryptoImport/ChainConfig.swift:74,90,109`):
   for ETH L2 chains, return the **canonical** `1:native` instrument. One change
   fixes native transfer legs (`TransferEventBuilder.swift:310`) and gas legs
   (`TransferReceiptCoalescer.makeGasLeg`, `:195`), which read `nativeInstrument`
   directly and bypass `resolveInstrument`. **Side effect:**
   `ChainConfig.optimism.nativeInstrument.chainId == 1`; audit every reader of
   `nativeInstrument.chainId` (chain-of-holding readers must use the account, §2).
   **Depends on §2 (ordering).**
2. **`CryptoRegistration.builtInPresets`** (`Domain/Models/CryptoRegistration.swift:94-107`):
   remove the `10:native`/`8453:native` ETH entries. Change
   `registerBuiltInPresetsIfMissing` (`InstrumentRegistryRepository+Presets.swift:24`,
   currently an **id-based** skip) to skip any preset whose **`assetKey`** matches
   an existing canonical registration — so a future non-canonical preset can't
   re-mint a retired id.
3. **`CryptoTokenDiscoveryService.resolveOrLoad`** (`Shared/CryptoImport/CryptoTokenDiscoveryService.swift:85`):
   apply the resolver to `(chainId, contractAddress)` **before** building the
   instrument, the registry lookup (`:92`), the in-flight key (`:95`), and persist.
   **Decompose the canonical id string** back to `(canonicalChainId,
   canonicalContractAddress)` (split on first `:`, `"native"` → nil address) and
   build the `Instrument` from those — otherwise the row is stored under the
   canonical id but with the wrong `chainId`/`contractAddress` value fields.
   (Promote the private `chainId(fromCryptoId:)` / `contractAddress(fromCryptoId:)`
   helpers in `Shared/CryptoPriceService.swift:187-199`.) The discovery actor
   receives the resolver at init.
4. **CloudKit apply — FK-holding records** (legs, earmarks, earmark budget items,
   investment values, account groups): `ProfileDataSyncHandler` canonicalizes the
   incoming `instrument_id` at the upsert call site in the `applyBatchSave*`
   helpers, so a `10:native` leg from an un-migrated peer is stored as `1:native`.
   Requires **injecting the resolver into `ProfileDataSyncHandler`** (a cross-DB
   dependency it lacks today — it operates only on `data.sqlite`; the resolver is
   backed by the shared alias map). The implementation must **locate the
   per-profile-zone `.serverRecordChanged` conflict handler** and confirm it routes
   through `applyBatchSaves` (so the same canonicalization covers it); if it uses a
   separate decode-and-write path, that path must canonicalize `instrument_id` too
   — otherwise a conflict re-applies and re-uploads `10:native` and the server never
   converges.
5. **CloudKit apply — instrument records** (profile-index zone): for every incoming
   record, run a resolver-driven raw-SQL
   `UPDATE instrument SET alias_of = :canonical WHERE id = :id` when the id is an
   alias. This runs **unconditionally and before the stale-echo gate**
   (`GRDBInstrumentRegistryRepository+SyncEntryPoints.swift:137`) — the gate
   `continue`s before the upsert, so alias-setting must not be gated behind it, or a
   stale echo leaves a retired row unaliased and visible. The `id`/recordName is
   never mutated (that would corrupt `encodedSystemFields`); only the local-only
   `alias_of` column is written. The **conflict path**
   `applyInstrumentServerRecordChangedMerge`
   (`Backends/CloudKit/Sync/ProfileIndexSyncHandler+Instruments.swift:160`) shares
   this apply path and is covered.

Because the resolver has a static base layer + dynamic alias map, this is
self-maintaining: even a never-before-seen L2 instrument from an un-migrated peer
is aliased on arrival.

### 3a. WETH / wrapped-native pricing

`CryptoPriceService.registration(for:)` (`Shared/CryptoPriceService.swift:217`)
routes wrapped-native pricing through
`WrappedNativeContracts.nativePricingInstrumentId(chainId:contractAddress:)`
(`Domain/Models/WrappedNativeContracts.swift:59`), which today returns
`"<chainId>:native"` — e.g. `"10:native"` for OP WETH. Post-migration that id is
aliased and its price cache purged, so WETH-on-L2 would price as unavailable.

- Update `WrappedNativeContracts` so L2 WETH maps to the canonical native id
  (`10:0x4200…0006` → `1:native`, `8453:0x4200…0006` → `1:native`), e.g. a
  `[chainId: (address, canonicalNativeId)]` table; add unit cases asserting
  `nativePricingInstrumentId(chainId: 10, …) == "1:native"` (and 8453).
- Update `FullConversionService.invalidateCache`
  (`Shared/FullConversionService.swift:301`): when the canonical ETH (`1:native`)
  rate is invalidated, also evict all L2 WETH ids that map to `1:native`
  (`canonicalWrappedInstrumentId` must enumerate them), else stale L2 WETH rates
  persist after an ETH price update.

### 4. The one-shot data migration (app-side async, not `DatabaseMigrator`)

The FK rewrite **cannot** be a `DatabaseMigrator` step: a migration closure gets
one `Database` handle for `data.sqlite`, but the canonical mapping for
runtime-discovered ERC-20s lives in the `instrument` table in the **shared**
`profile-index.sqlite`, and GRDB migrations cannot `ATTACH` a second file. It is
an **async app-side migration struct** modelled on `App/ValuationModeMigration.swift`
(UserDefaults-gated, injected `DatabaseQueue`s for both files + the resolver).
FK enforcement is already off (`v5_drop_foreign_keys`), so the rewrite is a plain
`UPDATE` — **not** a table rebuild (a rebuild that mis-lists v18's exact
columns/indexes would silently drop data; cite `v5` only for the fact that
`DatabaseMigrator` handles PRAGMA FK toggling, irrelevant to a plain `UPDATE`).

**Execution order (retired shared rows survive to the end, so the mapping is
always derivable; every step idempotent):**

1. **Alias step (shared DB):** derive the canonical mapping from the live registry;
   `UPDATE instrument SET alias_of = :canonical WHERE id = :retired` (one write).
2. **Per-profile FK rewrite** (each profile's `data.sqlite`), one plain `UPDATE`
   per table, each also setting `needs_push = 1`:
   ```sql
   UPDATE transaction_leg
      SET instrument_id = :canonical, needs_push = 1
    WHERE instrument_id IN (:retiredIdsForThisCanonical);
   ```
   Repeat for `earmark.instrument_id`, `earmark.savings_target_instrument_id`,
   `earmark_budget_item.instrument_id`, `account_group.instrument_id`,
   `investment_value.instrument_id`. **`needs_push = 1` is required — but it is NOT
   the re-push trigger** (see step 4); it protects the rewritten row from
   echo-clobber via the apply-path dirty guard. Set it via raw SQL (`needsPush` is
   absent from these records' `CodingKeys`).
   - **Legacy columns** (`earmark.savings_target_instrument_id`,
     `earmark_budget_item.instrument_id`) are rewritten even though `toDomain()`
     ignores them today, so no stale id survives for a future reader.
   - **`account.instrument_id` guard:** normally a fiat denomination, but the schema
     doesn't enforce it — defensively rewrite any `account.instrument_id` that is a
     retired crypto id (with `needs_push = 1`).
3. **Re-push promotion (per rewritten profile):** call
   `SyncCoordinator.queueAllRecordsAfterImport(for: profileId)`
   (`Backends/CloudKit/Sync/SyncCoordinator+Backfill.swift:26`) after the profile's
   SQL. This is the actual re-upload mechanism: the startup backfill scan filters
   `encodedSystemFields IS NULL` only, so already-synced rewritten rows are invisible
   to it regardless of `needs_push`; and `hasCompletedBackfillScan` would skip the
   profile anyway. `queueAllRecordsAfterImport` explicitly queues the profile's
   records and sets the backfill flag itself.
4. **Price cache (shared DB):** set the canonical `crypto_token_meta.first_traded_on`
   to the **MIN across the canonical's existing value and all retired rows'** values
   (don't overwrite an earlier canonical date); then
   `DELETE FROM crypto_price WHERE token_id IN (:retired)` and the matching
   `crypto_token_meta` rows (precedent: `v7_purge_crypto_price_cache`). Re-fetch is
   cheap.
5. **Completion flag** set only after all steps succeed for all profiles.
   Kill-mid-run re-runs recompute the mapping (retired rows still present, aliased)
   and re-apply idempotently.

**App-launch ordering (constraint for the PR sequence):** shared
`profile-index.sqlite` is opened/migrated before any per-profile `data.sqlite`, and
the alias step precedes the per-profile rewrite. Correctness for a lazily-opened
profile is backstopped by the resolver-based apply-time canonicalization (§3.4) and
the resolver's static base layer (§1).

**Migration-window UX gate:** the capital-gains / cost-basis surface
(`Shared/CostBasisEngine.swift`, keyed by `instrument.id`) is **wrong while a
profile is mid-rewrite** (retired and canonical lots split into separate FIFO
queues). Gate that view on the completion flag — render "updating…" until set —
rather than showing mixed-id lots.

**Deferred (out of scope):** physical deletion + CloudKit tombstoning of aliased
rows, gated on confirmed cross-device convergence. When it runs it must write a
`DeletionJournal` entry (`zoneName = DeletionJournal.profileIndexZoneName`,
`recordName = InstrumentRow.recordName(for: retiredId)`) in the **same write** as
each delete (mirroring `GRDBInstrumentRegistryRepository.remove(id:)`).

### 5. Consequences / cleanup

- **Display queries filter OUT aliased rows** (`WHERE alias_of IS NULL`, via
  `Column("alias_of")` since it's not in `CodingKeys`), so ETH shows once. The two
  concrete sites are `GRDBInstrumentRegistryRepository.all()`
  (`:111` → picker registered list via `InstrumentSearchService`) and
  `allCryptoRegistrations()` (`:124` → Settings registry via `SharedRegistryStore`).
  **`fetchInstrumentMap` (`InstrumentRow+Mapping.swift:14`) must NOT filter** — it is
  the FK resolver that turns a stored `instrument_id` back into an `Instrument`, and
  it must keep aliased rows so a not-yet-rewritten migration-window leg still resolves
  (filtering it would render those legs with a nil instrument). Suppress the
  [#1191](https://github.com/moolah-rocks/moolah-native/pull/1191) chain caption for
  the canonical/unified case.
- The `assetKey` presentation fold becomes a near-no-op for unified assets, stays
  for the chain-scoped tail.
- `DefiLlamaCoinID` / `StablecoinPriceClient` keep working off the canonical mainnet
  id — **verify with tests**, don't rework.
- `Instrument.chainId` stays populated on canonical records; harmless once
  chain-of-holding reads the account.

## Suggested PR sequence

1. **§2** — `ValuedPosition.accountChainId`, fold chain-source shift,
   `contributingInstrumentIds` dedupe, block-explorer account-chain switch.
   (Prerequisite; no identity change yet.)
2. **§1** — `alias_of` migration (v9), the canonical resolver (static + dynamic
   layers).
3. **§3.1–3.3, §3a** — construction-time canonicalization (`ChainConfig`, presets,
   `resolveOrLoad`), WETH fix. (Depends on 1 for §3.1.)
4. **§3.4–3.5** — sync apply-path + conflict-path canonicalization; resolver
   injection into `ProfileDataSyncHandler` and the instrument apply path.
5. **§4** — the app-side one-shot migration + re-push promotion + capital-gains gate.
6. **Deferred** — physical deletion + tombstoning (separate, later).

## Blast radius (line-verified)

- **Construction/registration:** `Instrument.crypto` (`Instrument.swift:199`),
  `ChainConfig.nativeInstrument` (`ChainConfig.swift:74,90,109`), `builtInPresets`
  (`CryptoRegistration.swift:94-107`), `registerBuiltInPresetsIfMissing`
  (`InstrumentRegistryRepository+Presets.swift:24`),
  `CryptoTokenDiscoveryService.resolveOrLoad` (`:85`),
  `TransferEventBuilder+NativeRegistration.swift:42`,
  `TransferReceiptCoalescer.makeGasLeg` (`:195`).
- **Pricing:** `WrappedNativeContracts.nativePricingInstrumentId` (`:59`),
  `CryptoPriceService.registration(for:)` (`:217`),
  `FullConversionService.invalidateCache` (`:301`).
- **FK columns (per-profile `UPDATE … SET needs_push = 1`):**
  `transaction_leg.instrument_id`, `earmark.instrument_id` +
  `savings_target_instrument_id`, `earmark_budget_item.instrument_id`,
  `account_group.instrument_id`, `investment_value.instrument_id`; defensive
  `account.instrument_id`.
- **Shared DB:** `instrument.alias_of` (new local-only column, v9),
  `crypto_price.token_id`, `crypto_token_meta.token_id` + `first_traded_on`.
- **Sync apply/conflict:** `ProfileDataSyncHandler` (+resolver injection) & its
  `applyBatchSave*` helpers; per-profile-zone `.serverRecordChanged` handler
  (locate); `GRDBInstrumentRegistryRepository+SyncEntryPoints.swift:137` (alias-on-apply,
  before stale-echo gate); `ProfileIndexSyncHandler+Instruments.swift:160` (conflict);
  `SyncCoordinator+Backfill.swift:26` (`queueAllRecordsAfterImport`).
- **Registry/picker alias filter:** `GRDBInstrumentRegistryRepository.all()` (`:111`)
  and `allCryptoRegistrations()` (`:124`) add `WHERE alias_of IS NULL`;
  `fetchInstrumentMap` (`InstrumentRow+Mapping.swift:14`) deliberately does **not**
  (FK resolver — keeps aliased rows).
- **Fold/positions/display:** `ValuedPosition.swift`, `AssetHolding+Fold.swift:93,108`,
  `InvestmentStore`, `MultiInstrumentPositionsAssembler`,
  `TransactionDetailBlockExplorerSection.swift:55`, picker caption suppression,
  capital-gains view gate (`CostBasisEngine`).

## Risks & correctness

- **Multi-device convergence** — apply-time canonicalization (§3.4) + `alias_of`
  on-apply (§3.5) + `queueAllRecordsAfterImport` re-push (§4.3). A device on the old
  build cannot reintroduce a per-chain id on a migrated device.
- **Local pre-migration window** — the resolver's static base layer (§1) makes
  construction-time canonicalization effective from first launch, before the
  migration writes any `alias_of`.
- **No delete/resurrect battle** — aliasing (not tombstoning) means retired records
  simply stay, aliased; terminal convergence still requires all active devices to
  update.
- **Two files, no cross-file transaction** — ordering (alias + rewrite before any
  deletion; retired rows survive), per-step idempotency, completion flag last.
- **Production data** — per `guides/AI_PROJECT_GUIDE.md`, validate on a development
  profile, then stop, summarise the exact production change, and get explicit
  in-the-moment confirmation before running against production.
- **Wrongful merges** — keying on `assetKey` (not symbol) + no-key tail stays
  chain-scoped.
- **No `InstrumentAmount` trap from aliasing** (verified): `PositionBook` keys raw
  `Decimal` by `Instrument`; `AssetHolding.sum` only adds post-conversion
  host-currency amounts guarded by preconditions.

## Testing strategy

Resolver / construction:
- Canonical resolver: ETH L2s → `1:native`; USDC L2s → mainnet USDC; no-key token
  unchanged; canonical-chain rule; **static base layer resolves before any
  `alias_of` exists**.
- `ChainConfig.optimism.nativeInstrument.id == "1:native"`; `builtInPresets` has no
  `10:native`/`8453:native`; `registerBuiltInPresetsIfMissing` no-ops when the
  canonical (by `assetKey`) exists; `resolveOrLoad(chainId: 10, contractAddress:
  <opUSDC>)` registers under mainnet USDC's id **with mainnet `chainId`/address in
  the value fields** (decomposition).
- WETH: `nativePricingInstrumentId(chainId: 10/8453, …) == "1:native"`;
  `invalidateCache("1:native")` evicts L2 WETH ids.

Migration:
- Seed both DBs with per-chain ETH legs + earmarks (incl. legacy cols) + account
  groups + investment values + a Coinstash ETH leg; run; assert every FK →
  canonical, `needs_push = 1` on rewritten rows, retired rows have `alias_of`, and
  OP→Coinstash reconciles.
- **Idempotent re-run** unchanged. **Rollback:** inject a mid-run failure; assert
  affected tables byte-identical to seed (DATABASE_CODE_GUIDE §5).
- `account.instrument_id` pointing at a retired crypto id is rewritten.
- `first_traded_on` = MIN(canonical, retired) preserved.
- **Re-push:** after migration a rewritten leg is queued for upload
  (`queueAllRecordsAfterImport`), not silently skipped.
- Plan-pinning tests for each of the six `UPDATE`s; verify/add `instrument_id`
  indexes on all six FK tables.

Sync:
- Incoming `10:native` leg → stored `1:native` (normal + `.serverRecordChanged`
  conflict path; re-queued upload carries `1:native`).
- Incoming `10:native` `InstrumentRecord` (fresh **and stale-echo**) → row retained
  with `alias_of` set, filtered from the registry query.

Pricing / conversion:
- DefiLlama + stablecoin resolution off the canonical id.
- WETH-on-L2 prices via `1:native` (else silent zero).
- **Cost-basis FIFO merge** (`CostBasisEngine`): OP-ETH buy 2021 + mainnet-ETH buy
  2022, sell 2023 → single FIFO queue consumes the 2021 lot first; and the
  capital-gains view is gated while a profile is mid-migration.

## Resolved review questions

- Stablecoin canonical ids — mainnet contract per asset; verified present in
  `CanonicalTokenRegistry` as the resolver's first step (§1).
- Keep vs null `Instrument.chainId` on canonical records — keep (=1).
- Picker caption on unified assets — suppress (§5).
- `alias_of` clobber / stickiness — resolved by the local-only (out-of-`CodingKeys`)
  design (§1).
- Re-push trigger — `queueAllRecordsAfterImport`, not `needs_push`/backfill scan
  (§4.3).

## Remaining follow-ups (deferrable)

- Physical deletion + CloudKit tombstoning of aliased rows, gated on confirmed
  convergence, with the `DeletionJournal` write pattern (§4).
- Audit of any non-crypto reader of `ChainConfig.nativeInstrument.chainId` after it
  becomes `1` for L2s (§3.1) — enumerate during implementation.
