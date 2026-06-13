# Cross-chain asset aggregation — design

**Issue:** [#1101](https://github.com/moolah-rocks/moolah-native/issues/1101) — Native ETH (and same-asset multi-chain tokens) not aggregated across chains.

**Status:** Design approved (brainstorming). Awaiting implementation plan.

## Problem

Moolah models a chain's native asset as a **per-chain instrument** — mainnet ETH
is `1:native`, Optimism ETH is `10:native`, an ERC-20 is `<chainId>:<address>`.
The holdings table therefore shows the *same asset* (ETH) as two separate
balance rows and never rolls them up. To the user — and to every external tool
(Koinly, explorers, exchanges) — "ETH" is one asset regardless of chain, so the
split reads as if ETH is missing.

Concrete case from the Crypto-account migration wallets:

| | ETH |
|---|---|
| Mainnet ETH (`1:native`) | 11.36718 |
| Optimism ETH (`10:native`) | 1.58976 |
| **Combined** | **12.95694** |
| Koinly's single "ETH" figure | 12.9573 |

The per-chain balances are individually correct (verified against on-chain
`eth_getBalance`) and **net worth is already correct** — each per-chain
instrument is priced (Optimism ETH at the ETH price), so the value is in the
totals. **Only the displayed quantity is split.** This is an
identity/aggregation/display concern, not data loss.

The same identity model splits any token deployed on multiple chains (USDC on
`1:0xa0b8…` vs `10:0x…`). Native ETH is just the most visible case.

## Goal

Same-asset-across-chains holdings roll up into a single asset line (one "ETH"
= 12.957) while per-chain accuracy is preserved everywhere it genuinely matters
(sync import, gas accounting, cost basis, pricing).

## Non-goals

- Re-keying any stored transactions (see Migration).
- Changing how net worth, account totals, or reports compute (already correct).
- Collapsing the instrument identity itself — per-chain instruments remain the
  recorded truth.

## Approach

A **presentation-layer asset rollup fold**. Per-chain instruments remain the
recorded truth in every upstream layer (transaction legs, `Position`
aggregation, sync, gas, cost basis, pricing). We fold same-asset rows together
only at the holdings surface (`PositionsTable` + its chart selection).

This was chosen over two alternatives:

- **Display-only grouping with no canonical key** — rejected: every consumer
  wanting a rollup would re-implement grouping, and ticker-based grouping is
  fragile (a token reusing another's ticker on some chain would wrongly merge).
- **Collapsing the instrument identity** (ETH is just "ETH", not `1:native`) —
  rejected: loses per-chain accuracy the issue explicitly says to preserve, and
  is the heaviest, riskiest migration.

## Core model

### 1. Canonical asset key (derived, not stored)

The asset key for a crypto instrument is its **price-provider id**:
`coingeckoId` if present, else `cryptocompareSymbol`, else `binanceSymbol`, else
the instrument's own `id` (stands alone — no provider id means we cannot safely
claim it is "the same asset"). Stocks and fiat always key on their own `id`
(never merged).

So `1:native` and `10:native` both yield `"ethereum"` and merge; a brand-new
unpriced token merges with nothing. The key is **derived from data already
present** — no schema column, no migration.

**Where the key comes from (important):** `coingeckoId` lives on
`CryptoProviderMapping` in the instrument registry, **not** on the domain
`Instrument` (which carries only `id, kind, name, decimals, ticker, exchange,
chainId, contractAddress`) and **not** on `ValuedPosition`. So the asset key is
not a pure computed property on `Instrument` — it must be resolved from the
registry's `allCryptoRegistrations()`. We build a `[instrumentId: assetKey]`
map at the point the holdings input is assembled (the store, which has registry
access) and thread it into the surface via a new
`PositionsViewInput.assetKeysByInstrumentId` field (default empty — an absent
key means "stand alone", preserving today's behaviour at any call site that
doesn't populate it). The fold reads this map; it never reaches into the
registry itself, keeping the view layer pure.

### 2. Display-row model — `AssetHolding`

Wraps **one or many** `ValuedPosition`s sharing an `assetKey`:

- `id` = `assetKey`.
- `quantity` = sum of contributors' quantities (same asset unit → summable).
- `value` / `costBasis` = sum of contributors', following the existing
  **"never display a partial aggregate"** rule: if *any* contributor's `value`
  is `nil` (conversion failed on one chain), the rolled-up `value` is `nil`
  ("—") and the asset is excluded from any total.
- `gainLoss` undefined (`—`) if any contributor lacks a cost basis; `costBasis`
  sums only when every contributor has one. Mirrors today's single
  `ValuedPosition` behaviour.
- `name` / `displayLabel` from the shared ticker.
- Quantity formatting uses the max `decimals` among contributors (capped at 8,
  as today).
- Retains the list of contributing per-chain `ValuedPosition`s, for a future
  per-chain drill-in.

### 3. One pure fold function

`[ValuedPosition] → [AssetHolding]`: folds crypto by `assetKey`, passes stocks
and cash through 1:1. No UI dependency, fully unit-testable in isolation.

### 4. Integration points

- `PositionsTable` renders `AssetHolding`s instead of raw `ValuedPosition`s; the
  sortable columns map to the rolled-up aggregates.
- Selection generalises from `Instrument?` to an **asset** (its set of
  contributing instrument ids + display name). `PositionsChart` sums the
  selected ids' `perInstrument` historical series so the chart filter matches
  the rolled-up row, rather than papering over the mismatch by filtering to a
  single representative chain.

### Untouched

`Position.computeForAccount`, `PositionsViewInput.totalValue` and the other
totals, the historical-series construction, sync, and the database schema. The
fold is applied late, the same way the table already folds by `Kind`.

## Data flow

```
legs
  → Position.computeForAccount        (per-chain, unchanged)
  → ValuedPosition                    (per-chain, unchanged)
  → fold [ValuedPosition]→[AssetHolding]   (NEW)
  → PositionsTable rows
```

Totals / net worth: summing rolled-up assets is arithmetically identical to
summing per-chain positions, so `totalValue` and friends are unchanged. Chart
historical series construction is unchanged; only the *selection filter* now
sums multiple series.

## Edge cases

- **Partial conversion failure** — one chain's `value` is `nil`. Quantity still
  sums (always known); the rolled `value` renders `—` and the asset is excluded
  from totals, per the partial-aggregate rule.
- **Mixed cost basis** — some contributors have a cost basis, others don't:
  rollup gain/loss is undefined (`—`); cost sums only when all present.
- **Unpriced / no-provider-id token** — `assetKey` falls back to its own `id`;
  stands as its own row; no false merge.
- **Quantity formatting** — max `decimals` among contributors (cap 8); shared
  ticker label.
- **Stocks & cash** — never merged; each keeps its own row and instrument-based
  selection.
- **Single-chain asset** — folds to a one-contributor `AssetHolding`; display
  identical to today.
- **Different tokens sharing a ticker** — cannot collide; keyed on the curated
  provider id, not the ticker.

## Migration

**None.** The asset key is derived from data already present (`coingeckoId`),
and no transactions are re-keyed.

During the Crypto-account migration, the reconstructed L2 venues (Scroll,
zkSync) deliberately recorded their ETH as `1:native` (mainnet) while the synced
Optimism accounts keep the real `10:native`. With asset aggregation, the
`1:native`-recorded Scroll/zkSync ETH rolls up under the single ETH line
correctly, so the display is right regardless. **Decision (per #1101 triage):
leave those venues as-is** — the internal mislabel is cosmetically invisible
after this change and re-keying real transaction data is not worth the risk
here. This is a documented decision, not a silent gap; if per-chain accuracy on
those venues is wanted later it is a separate, isolated migration.

## Testing

- `assetKey` derivation: coingecko → cryptocompare → binance → own-id fallback;
  stocks/cash always own-id.
- Fold function: merges multi-chain ETH; sums quantity; sums value/cost;
  **partial-failure → nil value**; undefined-gain propagation; unpriced stands
  alone; stocks not merged; single-chain passthrough.
- **Issue-reproduction test**: `1:native` 11.36718 + `10:native` 1.58976 → one
  ETH row, quantity 12.95694 (the exact numbers from #1101).
- Chart selection: selecting an asset sums its contributors' `perInstrument`
  series.
- A `#Preview` / snapshot of the table showing the single rolled-up ETH line.

## Affected files (initial map)

- `Domain/Models/CryptoProviderMapping.swift` — `assetKey` helper (provider-id
  fallback chain).
- `Domain/Models/` — new `AssetHolding` display model + pure fold function
  `[ValuedPosition] + [instrumentId: assetKey] → [AssetHolding]`, and an
  asset-key map builder from `[CryptoRegistration]`.
- `Domain/Models/PositionsViewInput.swift` — add `assetKeysByInstrumentId`
  (default `[:]`).
- `Features/Investments/InvestmentStore+PositionsInput.swift` — build the map
  from the registry and pass it into the input. (Plus any other crypto-bearing
  input site — enumerated in the plan.)
- `Shared/Views/Positions/PositionsTable.swift` — render `AssetHolding`s;
  generalise selection to a `PositionSelection`.
- `Shared/Views/Positions/PositionsView.swift` — selection type change.
- `Shared/Views/Positions/PositionsChart.swift` — sum selected-asset series via
  a new `HistoricalValueSeries.series(forInstrumentIds:)`.
- `Domain/Models/HistoricalValueSeries.swift` — `series(forInstrumentIds:)`
  summation by date.
- `Domain/Models/ValuedPosition+Display.swift` — quantity/label helpers reused
  by `AssetHolding`.
- Tests under `MoolahTests/Domain/`.
