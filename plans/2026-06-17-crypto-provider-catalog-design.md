# Pre-shipped crypto provider mappings + re-detection — design

Issue: [#1140](https://github.com/moolah-rocks/moolah-native/issues/1140)
Date: 2026-06-17

## Problem

Several real, actively-traded tokens are registered with **only** a
`coingecko_id` and no `cryptocompare_symbol` / `binance_symbol`. CoinGecko's
free tier hard-refuses historical data older than 365 days (`error 10012`),
so those tokens cannot backfill pre-365-day history and the monthly Income &
Expense table renders the affected financial months as "—" (a single
un-priceable `.priced` leg blanks the whole month, per strict Rule 11 /
#1077).

Confirmed gaps (CoinGecko-only today, but a keyless deep-history source
exists):

| Token | Available elsewhere |
|---|---|
| RPL (Rocket Pool) | Binance `RPLUSDT` (keyless), verified `2024-07-12` close `$16.14` |
| ILV (Illuvium) | Binance `ILVUSDT` (keyless) |
| IMX (Immutable X) | Binance `IMXUSDT` (keyless) |
| AVAIL | no Binance pair — needs CoinGecko Pro or CryptoCompare |
| STRK (Starknet) | (probe — Binance/CC) |
| HEX | CoinGecko-only, $0 market cap — included for probing, not reclassified |

Root cause: provider IDs are resolved **only once, at registration time**.
When these instruments were registered the Binance/CryptoCompare lookup wasn't
completed, so only the CoinGecko id was populated — and there is no mechanism
to upgrade a mapping later when a token gains support from another provider.

## Goals

1. **Pre-ship full provider mappings** for a curated set of known tokens so
   they carry the right `binance_symbol` / `coingecko_id` /
   `cryptocompare_symbol` — preferring the keyless Binance path for deep
   history where a pair exists.
2. **Re-detect expanded provider support**: when a newer mapping table ships
   in an app update, already-registered instruments whose stored mapping is
   incomplete get upgraded automatically (merge-only).
3. **Script-driven, transient-safe vendoring** that probes the providers and
   regenerates the table without ever losing a committed mapping on a
   rate-limit / network failure.

## Non-goals

- Reclassifying HEX (or any token) to `.unpriced` / `.spam`. HEX is included
  in the curated universe for probing only.
- Online re-resolution for tokens **absent** from the catalog. Those keep
  today's behaviour (online resolution at registration time).
- Per-token live provider probing. The script downloads each provider's full
  catalog **once** and resolves locally (CryptoCompare's free key is ~100
  calls/month — a single bulk call is the only affordable shape).
- Changing the 8 hand-coded `builtInPresets` (native BTC/ETH/MATIC + OP/UNI/
  ENS). Natives have no ERC-20 contract and cannot come from token lists, so
  they stay hand-curated for fresh-profile seeding.

## Architecture

Three artifacts plus one behaviour change. Each has a single responsibility
and a clean interface.

### 1. `CryptoProviderCatalog` — bundled provider-ID lookup (new)

A protocol so the storage strategy can change without touching consumers
(this is the "design for B" hook):

```swift
protocol CryptoProviderCatalog: Sendable {
  /// The pre-known provider mapping for an instrument id
  /// ("chainId:address" / "chainId:native"), or nil when the token is not
  /// in the bundled catalog.
  func mapping(for instrumentId: String) -> CryptoProviderMapping?
}
```

- **Now (Option A):** `BundledCryptoProviderCatalog` — backed by a generated
  Swift `static let` dictionary literal keyed by `instrumentId`. The curated
  universe is tens-to-low-hundreds of entries (~tens of KB), lazily
  initialised once. Negligible device memory.
- **Later (Option B), no consumer rework:** a `ResourceCryptoProviderCatalog`
  reading a bundled JSON resource (all CoinGecko tokens on supported chains
  with ≥1 provider listing), parsed lazily during reconciliation and released
  after — never resident for the process lifetime. Swap the conformer; the
  reconciliation pass is unchanged.

`instrumentId` fully encodes chain + address (`Instrument.crypto` builds
`"\(chainId):\(address.lowercased())"` or `"\(chainId):native"`), so it is a
sufficient key — no separate chain/contract columns needed.

### 2. Extended vendoring — `scripts/vendor-token-registry.sh`

A second generation pass appended to the existing address-registry pass (the
two share the curated token universe so they can never drift):

**Download full provider catalogs once:**
- Binance `GET /api/v3/exchangeInfo` → all trading symbols (keyless).
- CoinGecko `GET /api/v3/coins/list?include_platform=true` → id + per-chain
  contract addresses (keyless).
- CryptoCompare `GET /data/all/coinlist` → all symbols.
  **Requires `CRYPTOCOMPARE_API_KEY`** (verified: returns HTTP 401 "API key
  required" without one).

**Curated universe** = the protected-symbol token set the script already
builds for `CanonicalTokenRegistry`, extended with the gap tokens
(RPL, ILV, IMX, AVAIL, STRK, HEX) added to `PROTECTED`. Their contract
addresses come from the authoritative token lists / CoinGecko platform map —
**never hand-typed** (a wrong address would pin a spam contract).

**Resolve each token locally (by intersection):**
- `coingecko_id`: match the token's contract address against the CoinGecko
  platform map for its chain (most reliable). Native tokens match by id.
- `binance_symbol`: `"\(SYMBOL)USDT"` present in `exchangeInfo` → use it.
- `cryptocompare_symbol`: symbol listed in the CC coinlist → use it.

**Transient-failure safety (hard requirements from the issue):**
- A CryptoCompare key is **required** at run time — without it we cannot
  *confirm* CC availability, so we must not record "CC absent".
- Each provider lookup is classified `present` / `definitively-absent` /
  `unknown`. `unknown` = the *catalog download* for that provider returned
  HTTP ≠ 200, `Response: "Error"`, `Type: 99` (rate limit), or
  network/timeout.
- **Merge-only / additive:** the script reads the committed generated file and
  merges. A confirmed `present` adds/upgrades a column; a confirmed
  `definitively-absent` may clear *only* if previously sourced from the same
  run's confirmed data; an `unknown` **always preserves** the committed value.
- **Fail loudly:** if a provider's *catalog download itself* fails, exit
  non-zero and **write nothing** (no partial table). A successful download
  where an individual token is merely missing is a normal `definitively-absent`,
  not a failure.
- **Idempotent:** re-running with the same upstream data produces no diff.

**Output:** `Shared/CryptoImport/BundledCryptoProviderCatalog.swift`
(generated, DO-NOT-EDIT header, same style as
`CanonicalTokenRegistry+Bundled.swift`). Not wired into `just generate` — it
hits live network APIs and would break offline/CI builds. Run manually or via
the weekly CI job below.

### 3. Weekly CI workflow

`.github/workflows/vendor-token-registry.yml`, scheduled weekly (plus manual
`workflow_dispatch`):
- Runs the script with `CRYPTOCOMPARE_API_KEY` from repo secrets.
- If the script produces a diff, opens a PR with `gh pr create`.
- A rate-limited / failed-download week produces **no diff** (merge-only) or a
  **non-zero exit** (loud failure) — never a destructive PR. By construction a
  bad week is a no-op.

### 4. Startup reconciliation pass — the re-detection behaviour

A new repository method, run at session startup alongside
`registerBuiltInPresetsIfMissing`:

```swift
extension InstrumentRegistryRepository {
  /// Upgrade already-registered crypto instruments' provider mappings from
  /// the bundled catalog, merge-only. A catalog id fills a nil/missing
  /// stored column; a populated stored column is never downgraded. Idempotent.
  func reconcileProviderMappings(using catalog: any CryptoProviderCatalog) async
}
```

- Iterates registered crypto instruments; for each, looks up the catalog and,
  if it carries a provider id the stored row lacks, upgrades via the existing
  `upsertCrypto` → `mergeResolvedFields` path (already merge-only: a non-nil
  incoming column overwrites, nil never downgrades — see
  `GRDBInstrumentRegistryRepository+Upsert.swift`).
- Skips instruments already fully covered (no write, no sync churn).
- Best-effort + cancellation-aware, mirroring
  `registerBuiltInPresetsIfMissing`.

This fixes the existing Real Profile on next launch (RPL/ILV/IMX gain
`binance_symbol` → keyless deep history → months stop rendering "—") and gives
automatic re-detection whenever a newer catalog ships.

## Data flow

```
vendor script (CI weekly / manual)
  └─ download Binance + CoinGecko + CryptoCompare full catalogs
  └─ resolve curated universe locally (merge-only, transient-safe)
  └─ emit BundledCryptoProviderCatalog.swift  ──► committed via PR

app launch (ProfileSession)
  └─ registerBuiltInPresetsIfMissing()   (existing — fresh-profile seeding)
  └─ reconcileProviderMappings(using: BundledCryptoProviderCatalog())  (new)
        └─ per registered crypto instrument: merge-only upgrade from catalog

price fetch (existing, unchanged)
  └─ mapping now carries binance_symbol → keyless Binance deep history
```

## Error handling

- **Reconciliation**: best-effort; per-instrument failures logged and skipped;
  cancellation returns immediately. A missing/empty catalog is a no-op.
- **Vendor script**: download failure → non-zero exit, no write. Per-token
  provider absence → recorded as absent (a normal outcome). Rate-limit /
  network on a provider catalog → loud failure (we cannot trust partial data).
- **Merge semantics**: never downgrade a populated stored column from an
  `unknown` result — both in the script (vs committed file) and in
  reconciliation (vs stored row).

## Testing

- **Catalog lookup**: `BundledCryptoProviderCatalog.mapping(for:)` returns the
  expected mapping for a known id and nil for an unknown id.
- **Reconciliation contract test** (against `CloudKitBackend` + in-memory
  GRDB):
  - registered token with partial mapping (coingecko-only) + catalog with
    binance/cc → upgraded, merge-only.
  - registered token with a *fuller* stored mapping than the catalog →
    untouched (no downgrade, no spurious write/sync).
  - token absent from catalog → untouched.
  - idempotent: second run produces no further change.
- **Script classification self-test**: golden fixture JSON for each provider
  (present / absent / rate-limited Type 99) → assert the merge preserves the
  committed mapping on `unknown` and only writes on confirmed results, and that
  a re-run is a no-op.

## Known constraints

- The provided CryptoCompare key is a free-tier key (~100 calls/month) and was
  already over its monthly limit at design time. The single-bulk-call design
  fits within the cap once it resets; until then the CC path can only be
  exercised via the script's fixture self-test, not live. This is exactly why
  the transient-safety requirements are load-bearing.

## Decisions log

- Upgrade path: add a reconciliation pass reading from the catalog (not just
  fresh-profile seeding) — fixes existing profiles.
- HEX: included in the curated universe for probing; **not** reclassified.
- Codegen wiring: generated Swift file, manual run + weekly CI auto-PR; **not**
  part of `just generate`.
- Token scope: reuse the `CanonicalTokenRegistry` universe + gap tokens.
- Manifest source: download full provider catalogs, resolve locally; **not**
  sourced from the Real Profile.
- Catalog: Option A (curated Swift literal) now, behind a `CryptoProviderCatalog`
  protocol so Option B (resource-backed complete list) is a drop-in later.
