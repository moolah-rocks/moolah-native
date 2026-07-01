# Unified cross-chain instrument identity — design

**Status:** Design approved (brainstorming). Awaiting implementation plan.

**Relationship to prior work:** Supersedes the *identity* decision in
[`2026-06-13-cross-chain-asset-aggregation-design.md`](2026-06-13-cross-chain-asset-aggregation-design.md)
(issue [#1101](https://github.com/moolah-rocks/moolah-native/issues/1101)). That
design deliberately treated cross-chain ETH as an **display/aggregation-only**
concern — it rolled up per-chain instruments into one line via `assetKey` at the
presentation layer while leaving identity per-chain (`1:native`, `10:native`,
`8453:native` stay distinct instruments). That fixed the *displayed quantity*
but could not fix **transfer reconciliation** (below), because reconciliation
keys on instrument identity, not on the presentation fold. This design hoists the
existing `assetKey` collapse down into identity/storage so the same asset is
genuinely **one instrument**.

## Problem

Crypto instruments use a chain-scoped identity: `Instrument.id` is
`"<chainId>:native"` or `"<chainId>:<address>"`, built in one place —
`Domain/Models/Instrument.crypto(...)` (`Domain/Models/Instrument.swift:191`).
So ETH on mainnet, Optimism, and Base are **three distinct `Instrument` rows**
sharing name/ticker and a `coingeckoId` of `"ethereum"`.

Chain-scoped identity breaks down for anything that isn't a chain:

- **Transfer reconciliation fails across chains and chain↔exchange.** Coinstash
  (an exchange) holds plain "ETH" with no chain, so its holding maps to mainnet
  Ethereum (`1:native`). A transfer of ETH *from* an Optimism wallet (`10:native`)
  *to* Coinstash (`1:native`) cannot be matched/merged, because the two legs
  reference **different instruments**. "The same asset in two places" looks like
  two different assets. This is the concrete driver.
- **Duplicate instruments** clutter the registry, the picker, the token list, and
  the spam/impersonation surface — one asset needs N per-chain rows registered
  and managed.
- **Redundant pricing/mapping** — N identical provider mappings all resolving to
  the same `coingeckoId` and the same price series.

The user treats ETH as one bridgeable asset; the chain it currently sits on is
metadata, not identity.

## Goal

The same asset across chains is **one `Instrument`** with **one identity**, so
that transfer matching, the picker, the registry, and pricing all treat ETH as a
single asset — while per-chain accuracy (sync import, gas accounting, block
explorer links, per-chain balances) is preserved everywhere it genuinely matters.

## Non-goals

- Changing how a synced wallet is modelled (still one Account per (address,
  chain); see below — this is what lets chain leave the instrument for free).
- Unifying tokens that do **not** share a provider key (no `coingeckoId` /
  `cryptocompareSymbol` / `binanceSymbol`) — those stay chain-scoped.
- Merging genuinely different assets that happen to share a symbol (guarded by
  keying on the provider `assetKey`, not the symbol).

## Key enabling fact

A synced crypto wallet is **one `Account` per (address, chain)** — importing a
wallet that holds ETH on mainnet, Optimism, and Base yields **three Accounts**,
each with its own `account.chainId` (`Features/Crypto/CryptoAccountCreationLogic.swift:37`,
`Shared/Sync/WalletSyncSource.swift:40`). `account.chainId` is non-nil for
on-chain wallets and nil for exchange/manual accounts (Coinstash uses
`exchangeProvider`, `App/ProfileSession+CryptoSync.swift:179`). An Account holds
**many** instruments via `positions` computed from leg aggregation
(`Domain/Models/Position.swift:16`); `account.instrument_id` is the account's
fiat **denomination**, not its only asset.

**Consequence:** the chain dimension already lives on the account. Moving it off
the instrument loses no information — a Base wallet and an OP wallet remain
separate accounts, each holding a `Position` in the *same* ETH instrument, so the
per-chain breakdown survives structurally.

## Decisions

1. **Unification key = `assetKey`** (`coingeckoId ?? cryptocompareSymbol ??
   binanceSymbol`), the same key the fold already uses
   (`Domain/Models/CryptoProviderMapping.swift:29`). Crypto instruments sharing an
   `assetKey` are one asset. Instruments with no provider key keep their
   chain-scoped id.
2. **Canonical id = the group member on the canonical chain**, where the canonical
   chain is **`chainId == 1` (mainnet) if present, else the lowest `chainId` in the
   group**. ETH → `1:native`; USDC → mainnet USDC's contract id. This keeps the
   canonical id a **valid pricing key** (mainnet contract / native), so the
   DefiLlama, stablecoin, and CoinGecko price paths keep working unchanged.
3. **Chain-of-holding comes from the account, not the instrument.**
   `Instrument.chainId` survives on the canonical record (e.g. `1` for ETH) but no
   longer means "the chain this holding is on"; it is just the canonical/home chain.
4. **Canonicalize at every ingestion boundary** (not only in a one-shot migration)
   — this is what makes multi-device correct. See §3 below.

## Design

### 1. Identity & the canonical resolver

A resolver maps any crypto instrument (or `assetKey`) to its canonical id:

- Input: a resolved `Instrument` (has `assetKey` via its provider mapping) or a
  raw `(chainId, contractAddress)` with a known `assetKey`.
- Output: the canonical `Instrument.id` for that `assetKey`, or the input id
  unchanged when there is no `assetKey` (chain-scoped tail).
- Canonical-chain rule: prefer `chainId == 1`, else lowest `chainId` among known
  instances of the `assetKey`. The known instances come from the built-in presets
  (`Domain/Models/CryptoRegistration.swift:75`) plus the registry; the resolver is
  deterministic given an `assetKey`.

The built-in presets already define mainnet ETH (`1:native`) and mainnet
stablecoin contracts, so the canonical id for the common assets is stable and
known ahead of time.

### 2. Chain moves to the account (already there)

- `contributingChainIds` in `Domain/Models/AssetHolding+Fold.swift:93` shifts its
  source from `instrument.chainId` to the contributing accounts' `chainId`.
- Block-explorer links (`Features/Transactions/Views/Detail/TransactionDetailBlockExplorerSection.swift:55`)
  switch from `leg.instrument.chainId` to `leg.accountId → account.chainId`,
  falling back to `instrument.chainId` only for still-chain-scoped tokens.
- The `assetKey` presentation fold becomes a near-no-op for unified assets
  (positions already share an id) but stays for the chain-scoped tail.

### 3. Canonicalize at the ingestion boundary (the architectural core)

Every point that mints or applies a leg's instrument canonicalizes it, so storage
is uniformly canonical and an un-migrated peer cannot reintroduce per-chain ids:

- **Wallet sync** — `Shared/CryptoImport/TransferEventBuilder.resolveInstrument`
  (`:304`): after resolving a chain-native or discovered ERC-20 instrument, map it
  through the canonical resolver before stamping the leg. An OP-wallet ETH leg gets
  `1:native`; the OP account preserves the chain. Native pre-registration
  (`TransferEventBuilder+NativeRegistration.swift:42`) and gas legs
  (`TransferReceiptCoalescer.swift:195`) route through the same canonicalization.
- **CloudKit apply** — when a peer on the old build sends a `10:native` leg, the
  apply path canonicalizes it to `1:native` on ingestion. Because the alias is
  derivable from `assetKey`, this is a permanent, self-maintaining guard rather
  than a fixed transition window.

### 4. Migration (one-shot, both migrator chains + CloudKit)

The `instrument` table lives in the **shared** `profile-index.sqlite`
(`ProfileIndexSchema`, currently v8); the FK-holding tables live in the
**per-profile** `data.sqlite` (`ProfileSchema`, currently v18). FK enforcement is
already off (`v5_drop_foreign_keys`), so a remap is a pure data rewrite.

- **`ProfileIndexSchema` migration** (shared DB): ensure canonical instrument rows
  exist; delete retired per-chain instrument rows; purge `crypto_price` /
  `crypto_token_meta` cache entries for retired `token_id`s (cheap, re-fetched —
  precedent: `v7_purge_crypto_price_cache`).
- **`ProfileSchema` migration** (per-profile DB): rewrite every `instrument_id` FK
  from retired → canonical, table-rebuild-and-copy style (precedent:
  `v5_drop_foreign_keys`). Columns: `transaction_leg.instrument_id`,
  `earmark.instrument_id` **and** `earmark.savings_target_instrument_id`,
  `earmark_budget_item.instrument_id`, `account_group.instrument_id`,
  `investment_value.instrument_id`. (`account.instrument_id` is a fiat
  denomination and is unaffected unless it points at a retired crypto id.)
- **CloudKit** (profile-index zone): `Instrument.id` **is** the CloudKit
  recordName (bare string, `Backends/GRDB/Records/InstrumentRow.swift:6`).
  - Tombstone the retired instrument recordNames. The canonical (mainnet) record
    **survives** — the reason for picking mainnet as canonical.
  - Re-push the FK-holding records (Account/Leg/Earmark/AccountGroup/
    InvestmentValue) whose `instrumentId` changed, so peers converge.
  - Add a `SyncCoordinator+LegacyInstrumentDrain`-style guard so echoes of retired
    ids don't resurrect them, plus the §3 apply-time canonicalization.
- **Gating:** a migration-version flag (precedent: `App/ValuationModeMigration.swift`),
  idempotent, re-runnable.

### 5. Cleanup / consequences

- The picker naturally shows one ETH row. The chain caption shipped in
  [#1191](https://github.com/moolah-rocks/moolah-native/pull/1191) would still show
  "Ethereum" for `1:native`; suppress `chainDisplayName` for unified assets (or
  when `chainId` is the canonical/only chain) so the caption doesn't read
  redundantly.
- `DefiLlamaCoinID` (`Backends/DefiLlama/DefiLlamaCoinID.swift:22`) and
  `StablecoinPriceClient` (`Backends/Stablecoin/StablecoinPriceClient.swift:56`)
  parse `chainId` from the id — with a canonical mainnet id these keep resolving
  correctly. **Verify** (add a test), not rework.

## Blast radius (concrete)

- **FK columns to rewrite:** `transaction_leg.instrument_id`
  (`TransactionLegRow.swift:18`), `earmark.instrument_id` +
  `savings_target_instrument_id` (`EarmarkRow.swift:23`),
  `earmark_budget_item.instrument_id` (`EarmarkBudgetItemRow.swift:17`),
  `account_group.instrument_id` (`AccountGroupRow.swift:19`),
  `investment_value.instrument_id` (`InvestmentValueRow.swift:21`).
- **Price cache token_id:** `crypto_price.token_id`
  (`CryptoPriceRecord.swift:16`), `crypto_token_meta.token_id`
  (`CryptoTokenMetaRecord.swift:22`).
- **Id construction/parse sites:** `Instrument.crypto` (`Instrument.swift:191`),
  `InstrumentRow+Mapping.swift:59`, `CryptoTokenDiscoveryService.swift:85`,
  `ChainConfig.swift:74`, presets `CryptoRegistration.swift:75`, and the string
  splitters `DefiLlamaCoinID.swift:22`, `StablecoinPriceClient.swift:56`.
- **Sync write path:** `TransferEventBuilder.swift:304`,
  `TransferEventBuilder+NativeRegistration.swift:42`,
  `TransferReceiptCoalescer.swift:195`,
  `GRDBInstrumentRegistryRepository+Upsert.swift:32`.
- **CloudKit:** `InstrumentRow+CloudKit.swift`,
  `ProfileIndexSyncHandler+Instruments.swift`,
  `SyncCoordinator+LegacyInstrumentDrain.swift`, schema `CloudKit/schema.ckdb:145`.
- **Fold / positions:** `AssetHolding+Fold.swift:93`, `InvestmentStore.swift:76`,
  `MultiInstrumentPositionsAssembler.swift:152`.

## Risks & correctness

- **Multi-device convergence is the main risk.** Handled by §3 (canonicalize on
  apply) + the drain guard, so a device on the old build cannot reintroduce
  per-chain ids on a migrated device.
- **CloudKit tombstone/echo races** — mitigated by re-pushing FK records and the
  legacy-drain guard (there is prior art for exactly this shape of churn).
- **Production data** — per `guides/AI_PROJECT_GUIDE.md`, validate the migration on
  a development profile, then stop and get explicit in-the-moment confirmation
  before running against the production profile.
- **Wrongful merges** — keying on `assetKey` (not symbol) and leaving the no-key
  tail chain-scoped guards against merging lookalike/spam tokens.

## Testing strategy

- Unit: canonical resolver (ETH L2s → `1:native`; USDC L2s → mainnet USDC;
  no-key token unchanged; canonical-chain rule mainnet-preferred / lowest-else).
- Migration: seed a DB with per-chain ETH legs + earmarks + account groups + an
  exchange (Coinstash) ETH leg, run the migration, assert all FKs point at the
  canonical id and the transfer now reconciles. Assert idempotent re-run.
- Sync apply: an incoming `10:native` leg is stored as `1:native`.
- Pricing regression: DefiLlama/stablecoin resolution still works off the
  canonical id.
- Plan-pinning tests for the rewritten migrations (per `DATABASE_SCHEMA_GUIDE.md`).

## Open questions / follow-ups

- Exact canonical id string for stablecoins with both a native and a bridged
  contract on mainnet (pick the CoinGecko-canonical mainnet contract).
- Whether to keep `Instrument.chainId` populated on canonical records (=1) or null
  it — leaning keep, since pricing consumers read it and it's harmless once
  chain-of-holding reads the account.
- Suppression rule for the picker chain caption on unified assets (§5).
