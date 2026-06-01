# Coinstash Instrument Resolution — Design Spec

**Status:** Approved design · 2026-05-17
**Branch:** `feat/exchange-accounts-coinstash`
**Related:** Fuzzy cross-account transfer detection is **deferred** to
[#928](https://github.com/ajsutton/moolah-native/issues/928) and is **out of
scope** for this spec.

---

## Problem

Coinstash imports resolve every crypto leg through
`ExchangeInstrumentResolver.instrument(forSymbol:isFiat:)`, which does a
symbol-only, case-insensitive `ticker` scan of the instrument registry and
returns the first match:

```swift
return try await registry.all().first {
  $0.kind == .cryptoToken && $0.ticker?.caseInsensitiveCompare(symbol) == .orderedSame
}
```

When the registry holds more than one instrument with ticker `OP` — a spam
`OP` discovered via wallet/Alchemy token scanning (`pricingStatus == .spam`)
**and** the real Optimism `OP` (`10:0x4200…0042`) — scan order decides the
result. In the large test profile it picks the spam token, so every imported
`OP` row is mis-resolved and flagged spam (and Coinstash does not even list
the spam token — it only trades the real one). The mis-resolved instrument
also breaks any future cross-account transfer detection, because detection
matches on instrument identity.

Coinstash transaction rows carry only a `symbol` string. The per-row `chain`
field exists in the schema but is **not reliably populated** (see
Investigation), so the chain/contract must come from elsewhere.

## Goal

Resolve every Coinstash crypto leg to the correct chain-pinned `Instrument`
using Coinstash's own authoritative token metadata, reusing the existing
crypto discovery/registration path so the resolved instrument is priced and
spam-classified consistently with wallet import. Fiat legs are unchanged.

## Investigation (completed 2026-05-17, live API)

Run against `https://graph.coinstash.com.au/graphql` with a read-only key.

- **`getCoinBySymbol(symbol: String!, userId: ID)`** returns
  `GetCoinResponse` with the fields we need:
  `symbol`, `name`, `displaySymbol`, `coinId` (a Coinstash-internal id,
  *not* a CoinGecko id), `blockchains: [String]`, and
  **`defiAddresses: [{ chain: Chain, address: String, decimals: Int,
  solanaTokenAccount: String? }]`**.
- The `Chain` enum: `ETHEREUM, OPTIMISM, BSC, GNOSIS, POLYGON, SONIC,
  FANTOM, BASE, SOLANA, ARBITRUM, AVALANCE, LINEA` (note Coinstash's
  spelling `AVALANCE`).
- Real `defiAddresses` shapes observed:
  - **`OP`** → exactly one entry:
    `OPTIMISM / 0x4200000000000000000000000000000000000042 / 18`. Single
    chain — unambiguous. **This is the reported bug, deterministically
    fixed.**
  - **`USDC`** → 9 entries (Ethereum `0xa0b8…eb48` decimals 6, Optimism,
    BSC, Gnosis, Polygon, Fantom, Arbitrum, Avalanche, Base). Multi-chain.
  - **`ETH`** → 6 entries; ETHEREUM/OPTIMISM/ARBITRUM use the native
    sentinel address `0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee` (40
    lowercase `e`), i.e. *not* a real ERC-20 contract.
  - **`BTC`** → `defiAddresses: []` (Bitcoin is not modelled as EVM).
    The codebase already represents Bitcoin as
    `Instrument.crypto(chainId: 0, contractAddress: nil, symbol: "BTC",
    name: "Bitcoin", decimals: 8)` (id `0:native`) and ships it in
    `CryptoRegistration.builtInPresets` with a CoinGecko mapping
    (`coingeckoId: "bitcoin"`), seeded into every profile at session
    start. `chainId == 0` is the established "Bitcoin" convention
    (`Instrument.swift` display map; `CryptoRegistration.swift`
    presets).
  - **`SOL`** → one `SOLANA` entry with a base58 address (non-EVM).
- The per-transaction `chain` field was `null` on 28/30 rows and `""` on
  the two crypto deposits; `externalTxId` / `referenceTxId` / `scanUrl`
  were all `null`. **Conclusion:** the transaction row cannot tell us the
  chain; `getCoinBySymbol` is the source of truth. (The absence of an
  on-chain hash also confirms #928's Coinstash↔wallet matching must be
  fuzzy, not `externalId`-based.)
- `getChain(chainId:)` keyed by the `Chain` enum name returned
  `isSuccessful: false`; it expects a different identifier. We do **not**
  depend on it — the `Chain` enum → EVM chain-id mapping is a small static
  table (below).

## Resolution policy

For each imported leg in `ExchangeSyncEngine.buildCandidate`:

- **Fiat leg** (`isFiat`): unchanged — the injected fiat instrument.
- **Crypto leg** (symbol `S`):

  0. **Explicit non-EVM natives.** First consult a small static table of
     non-EVM native coins the app pins by convention, keyed by Coinstash
     symbol (uppercased). v1 contains exactly one entry:
     `BTC → Instrument.crypto(chainId: 0, contractAddress: nil,
     symbol: "BTC", name: "Bitcoin", decimals: 8)` (id `0:native`). On a
     hit, resolve directly to that instrument and **skip the
     `getCoinBySymbol` call entirely** — it is a `builtInPresets` member,
     already registered with a CoinGecko mapping at session start. If it
     is somehow absent from the registry (defensive), register it through
     the generalised discovery path (chain id 0, native, symbol `BTC`;
     CoinGecko resolves `bitcoin`). This is the easy, exact match the
     product wants for Bitcoin and removes BTC from the fuzzy fallback
     entirely. (`SOL` and other non-EVM assets are *not* in this table
     in v1 — no Solana instrument convention exists in the codebase yet;
     they take the registry fallback, step 5.)

  1. **Fetch metadata.** `meta = getCoinBySymbol(S)` via the Coinstash
     client, cached for the duration of the build run keyed by `S`
     uppercased (a sync touches only a handful of distinct symbols). A
     *transient* failure (network/HTTP/GraphQL error) **throws** so the
     enclosing sync retries — it must not silently fall through. Only a
     *definitive* answer ("no usable EVM contract", below) takes the
     registry fallback. This mirrors the existing resolver's "throw on
     registry failure, never silently drop everything" rule.

  2. **Select the canonical EVM entry.** From `meta.defiAddresses`, keep
     entries whose `chain` maps to a known EVM chain id (table below);
     drop `SOLANA` and any enum value not in the table. If ≥1 remain,
     pick by this deterministic preference order (Ethereum-preferred per
     product decision, then app-supported chains, then the rest):

     ```
     ETHEREUM, OPTIMISM, BASE, ARBITRUM, POLYGON, BSC,
     AVALANCE, GNOSIS, FANTOM, LINEA, SONIC
     ```

  3. **Native vs token.** If the chosen `address` equals the native
     sentinel `0x` + forty `e` (compared case-insensitively), build a
     **native** instrument
     `Instrument.crypto(chainId: c, contractAddress: nil,
     symbol: meta.symbol, name: meta.name, decimals: chosen.decimals)`
     (id `c:native`). Otherwise build a token instrument with
     `contractAddress: chosen.address` (the factory normalises to
     lowercase) and `decimals: chosen.decimals`.

  4. **Resolve + register via the discovery path** (single source of
     truth — see Discovery-path generalisation):
     - If `ChainConfig.config(for: c) != nil` (Ethereum/OP/Base):
       `CryptoTokenDiscoveryService.resolveOrLoad(...)` exactly as wallet
       import does (provider mapping → Alchemy spam check → register).
     - Else (EVM chain CoinGecko prices but the wallet importer doesn't
       ingest — e.g. Arbitrum/Polygon/BSC): the generalised path — build
       the instrument, resolve a provider mapping via
       `CryptoPriceService.resolveRegistration(chainId:contractAddress:
       symbol:isNative:)` (CoinGecko-by-contract is chain-id-keyed and
       covers these), register via
       `registry.registerCrypto(_:mapping:forcingStatus:)`. The Alchemy
       spam step is **skipped** (no `ChainConfig` network slug; Coinstash
       lists only real, tradable assets). Status `.priced` if a mapping
       resolved, else `.unpriced`.
     The leg uses the resolved registration's `Instrument`.

  5. **Registry fallback** — taken only when the symbol is not an
     explicit non-EVM native (step 0) **and** `getCoinBySymbol` returns a
     *definitive* "no usable EVM contract": `defiAddresses` empty, or only
     non-EVM/unknown entries (e.g. `SOL`). Disambiguate among
     `kind == .cryptoToken && ticker.caseInsensitiveCompare(S) ==
     .orderedSame`:
     1. exclude `pricingStatus == .spam`;
     2. prefer a registration with a provider mapping / `.priced` over an
        unmapped `.unpriced` stub;
     3. prefer an instrument already used on an existing `TransactionLeg`
        in any of the profile's accounts;
     4. deterministic tie-break: lowest `Instrument.id`.
     Zero non-spam matches → unresolved; the group is dropped and logged
     (current behaviour). The fallback never returns a `.spam`
     instrument. This path is safe precisely because these symbols have
     no chain to get wrong.

### `Chain` enum → EVM chain id

| Coinstash `Chain` | EVM chain id | `ChainConfig`? |
|---|---|---|
| `ETHEREUM` | 1 | yes |
| `OPTIMISM` | 10 | yes |
| `BASE` | 8453 | yes |
| `ARBITRUM` | 42161 | no |
| `POLYGON` | 137 | no |
| `BSC` | 56 | no |
| `AVALANCE` | 43114 | no |
| `GNOSIS` | 100 | no |
| `FANTOM` | 250 | no |
| `LINEA` | 59144 | no |
| `SONIC` | 146 | no |
| `SOLANA` | — (non-EVM, excluded) | — |

Any `Chain` value absent from this table is treated as "no usable EVM
contract" → registry fallback (safe, conservative). The table is the only
place to extend when Coinstash adds a chain we care to pin precisely.

## Discovery-path generalisation

`CryptoTokenDiscoveryService.resolveOrLoad(chain: ChainConfig, ...)` and
its private `performResolution` currently require a `ChainConfig`, whose
only `ChainConfig`-specific use is `fetchSpamFlag(chain:contractAddress:)`
(Alchemy) — everything else (`resolver.resolveRegistration`, instrument
construction, registry write) is already `chainId: Int`-keyed.

Change the entry point to accept the chain id plus an **optional**
`ChainConfig` (or derive `ChainConfig.config(for:)` internally). When no
`ChainConfig` is available, skip `fetchSpamFlag` (treat `isSpam == false`)
and keep the rest unchanged. The existing ETH/OP/Base call path stays
behaviourally identical (a `ChainConfig` is still passed/derived, Alchemy
spam check still runs). This preserves a single discovery/registration
implementation rather than forking exchange-specific resolution logic.

## GraphQL & client changes

- **`CoinstashGraphQL`**: add a `getCoinBySymbol` query selecting
  `symbol name defiAddresses { chain address decimals }`, plus Codable
  models (`CoinstashCoinMetadata`, `CoinstashDefiAddress`,
  `Chain`-as-`String`). Mirror the existing `CoinstashGraphQLResponse`
  decoding and error handling.
- **Provider-neutral seam**: introduce
  `protocol ExchangeAssetMetadataResolving` (neutral, in `Shared/Exchange`)
  with `func assetMetadata(forSymbol:) async throws ->
  ExchangeAssetMetadata?` where `ExchangeAssetMetadata` is the neutral
  shape (`symbol`, `name`, `[ (chainId: Int, contractAddress: String?,
  decimals: Int) ]`, native-sentinel already collapsed to
  `contractAddress: nil`). `CoinstashClient` implements it via
  `getCoinBySymbol` and the enum→chain-id table. A future exchange
  provides its own conformance. Keeps `ExchangeClient` unchanged and the
  engine provider-agnostic.
- **Caching**: the per-build-run symbol cache lives in the resolver layer
  the engine calls, not in `CoinstashClient` (the client stays stateless,
  matching its current design).

## Wiring

- `ExchangeSyncEngine.buildCandidate` resolves instruments through a new
  resolver that, per leg: fiat → injected fiat; crypto → metadata path
  (steps 1–4) with the `ExchangeInstrumentResolver` registry
  disambiguation (step 5) as the definitive-miss fallback.
- Construction (`App/ProfileSession+CryptoSync.swift`, where
  `CoinstashSyncSource` / `ExchangeSyncEngine` are assembled): thread in
  `CryptoTokenDiscoveryService`, the `ExchangeAssetMetadataResolving`
  conformance, and a narrow "instruments appearing on existing legs"
  lookup (used **only** by fallback step 5.3, so it runs only on genuine
  ambiguity). The crypto wallet sync already builds a
  `CryptoTokenDiscoveryService`; reuse the same instance.
- `ExchangeInstrumentResolver` keeps its fiat handling and gains the
  spam/priced/used disambiguation; its symbol-only first-match scan is
  removed.
- Group-drop behaviour in `ExchangeSyncEngine` is unchanged: an
  unresolved leg still drops the whole `orderId`/`externalId` group with
  a log line.

## Remediation of already-imported rows

Operational, not code. After this lands, use the `automate-app` skill to
delete the Coinstash account's transactions and trigger a resync so they
re-import through the corrected resolver. No migration/back-fill code.

## Testing

GraphQL decode fixtures use the real shapes captured during the
investigation (OP single-chain; USDC 9-chain; ETH native-sentinel;
BTC empty `defiAddresses`; SOL `SOLANA`-only).

1. **Metadata decode**: `getCoinBySymbol` response → `ExchangeAssetMetadata`
   for OP / USDC / ETH / BTC; native sentinel collapses to
   `contractAddress: nil`; `AVALANCE` spelling handled.
2. **Canonical selection**: USDC → Ethereum `1:0xa0b8…eb48` decimals 6;
   a token listed on OP+Base but not Ethereum → OP (preference order);
   determinism across input re-ordering.
3. **OP regression**: registry seeded with spam `OP` + real OP →
   resolves to `10:0x4200…0042`, `pricingStatus != .spam`.
4. **Native**: ETH → `1:native` (sentinel detection, case-insensitive).
5. **Discovery-path generalisation**: ChainConfig chain (OP) → Alchemy
   spam step invoked; non-ChainConfig EVM chain (Arbitrum) → spam step
   skipped, still registers with a CoinGecko-resolved mapping.
6. **Explicit BTC**: symbol `BTC` → `0:native` (decimals 8) with **no**
   `getCoinBySymbol` call (assert the metadata resolver is not invoked);
   resolves to the seeded preset registration with its CoinGecko mapping;
   defensive path registers it if absent.
7. **Registry fallback**: `SOL` (only a `SOLANA` entry) and an
   unknown-symbol case → fallback; spam excluded; `.priced` preferred
   over `.unpriced` stub; used-in-accounts preferred; deterministic id
   tie-break; all-spam → unresolved (group dropped + logged).
8. **Transient failure**: `getCoinBySymbol` network/GraphQL error →
   throws (sync retries); does not silently fall back or drop.
9. **Fiat unchanged**: AUD/fiat legs still resolve to the injected fiat
   instrument with no metadata call.
10. **End-to-end** (`TestBackend`, stubbed Coinstash transport): profile
    → accounts → transactions including an OP deposit → leg resolves to
    real Optimism OP and is not spam-flagged.

Tests follow `guides/TEST_GUIDE.md` (Swift Testing; one extension per
protocol conformance; reuse `StubInstrumentRegistry`).

## Out of scope

All fuzzy cross-account transfer detection (Coinstash↔bank,
Coinstash↔on-chain wallet, including the 40167 OP ↔ Trust-Optimism case)
→ [#928](https://github.com/ajsutton/moolah-native/issues/928). Once
instruments resolve correctly here, those pairs become detectable by that
engine.

## Open questions

None blocking. `SONIC` chain id (146) is included for completeness but the
user holds no Sonic assets; if it is ever wrong the conservative
"unknown → registry fallback" behaviour bounds the blast radius, and the
table is the single fix site.
