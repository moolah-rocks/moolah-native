# Unified Account-Detail Layout — Design

Date: 2026-07-05
Status: Design (approved shape, pending spec review)

## Problem

The account-detail screen (positions + chart above a transactions list) has grown
awkward, most visibly on crypto wallets:

- **Chart wastes its own height.** The value chart's Y-axis anchors at `$0` while the
  values sit in a narrow band near the top (e.g. `$60–80K` on a `0–80K` axis), so
  roughly two-thirds of the chart is empty. The chart is uninformative *regardless* of
  how tall its container is.
- **Mac: the top region is too big.** The crypto/exchange/standard/group path wraps the
  positions surface in `PositionsTransactionsSplit` using the *chartless* preset
  (`initialTopHeight: 180`, the **default** shared `autosaveName`), even though these
  accounts now render a full chart. The tall chart region dominates the split, and the
  shared autosave key lets the divider bleed between genuinely-chartless accounts and
  chart-bearing ones.
- **iOS: the positions list is starved.** On iOS the split is a plain `VStack` (no
  resizing). The fixed 220pt chart + "All positions" + legend + range picker + positions
  title — *plus* the crypto wallet header stacked above — leave almost no room for the
  positions list.
- **Header wastes space.** The sync status caption (e.g. "Alchemy rate-limited") wraps to
  its own line instead of using the empty horizontal space between "Open in block
  explorer" and "Synced 2 days ago".
- **Five near-duplicate layouts.** `CryptoWalletAccountView`, `InvestmentAccountView`,
  `ExchangeAccountView`, `StandardAccountView`, and `GroupDetailView` each assemble their
  own version of "header + performance + chart + positions + transactions", diverging in
  which pieces show and how the split is configured.

This is a rethink, not a knob-tweak.

## Goals

- **One unified, data-driven account-detail layout** used by every account type. Each
  element shows only when it has relevant data; nothing is hard-coded per account type.
- A **dense, informative chart** whose Y-axis hugs the data.
- A **compact header** that uses its horizontal space.
- A **correct total-value / balance-over-time chart for every account**, including
  plain fiat accounts and mixed fiat + non-fiat accounts.
- Deduplicate the five per-type detail views into one.

## Non-Goals

- **Recorded-value investment accounts (`.recordedValue`)** are deprecated and slated for
  removal. They are explicitly out of scope — they keep their current legacy layout and
  are not folded into the unified container.
- No change to the underlying valuation, conversion, or sync engines beyond what the
  history-series and performance changes below require.

## The Unified Layout

A single `AccountDetailView` replaces the per-type dispatch bodies in
`ContentView+AccountDetail.swift` (crypto / exchange / standard / investment) and the
group body in `ContentView+GroupDetail.swift`. Its elements are **data-driven** — each
appears only when it has data to show:

| Element | Shows when |
|---|---|
| **Type header slot** (wallet address, chain, sync status, sync error) | The account is synced (crypto today); empty slot otherwise |
| **Performance tiles** (value, contributions, P&L, return) | Invested / contribution data exists → crypto, investments, mixed groups. Individual tiles hide when their field is nil (e.g. a transfer-in-only wallet with no cost basis). Fully hidden for fiat-only |
| **Chart** (value / balance over time) | **Always** — every account has a balance history |
| **Positions table** | ≥1 non-host-currency holding (multi-instrument). Hidden for single-currency fiat |
| **Transactions list** | **Always** |

### Structure — tabs (iOS) / stacked split (Mac)

Chosen in visual brainstorming (structure = "three tabs"; Mac = "stacked, positions on
top"; default tab = Transactions).

**iOS — data-driven segmented tabs:**

- Base: `[Transactions | Chart]` — Transactions is first and is the default.
- A **`Positions`** tab is inserted (→ `[Transactions | Positions | Chart]`) only when the
  account has non-host holdings.
- So a plain checking account shows 2 tabs; a crypto wallet or investment account shows 3.

**Mac — stacked split (positions pinned):**

- When positions exist: a vertical `ResizableVSplit` with the **positions table pinned in
  the top pane**; the resizable bottom pane carries a `[Transactions | Chart]` toggle
  (default Transactions). Divider position autosaved under a key distinct from any
  legacy chartless key.
- When no positions exist (fiat-only): no split — a single pane with the
  `[Transactions | Chart]` toggle, full height.

**Where performance + total live:** the **performance tiles and the account total ride at
the top of the Chart tab / Chart companion pane** (chart and P&L belong together), so the
Transactions and Positions list tabs stay uncluttered. The Positions tab/pane keeps a
lightweight title + total header.

**Selection behaviour preserved:** tapping a position row still filters the chart to that
asset (today's `PositionSelection` behaviour), and Escape / the chip ✕ clears it.

## Chart Density (`Shared/Views/Positions/PositionsChart.swift`)

- The Y-axis **domain hugs the data**: `min…max` over the union of the value line and the
  baseline/invested line (when a baseline exists), padded by ~5–8% so the extremes aren't
  flush against the frame. It no longer anchors at `$0`.
- Gain/loss area shading is unchanged in intent but only renders when a cost-basis
  baseline exists (already the case via `PositionsChartBaselineResolver`). Fiat balance
  charts are a single line with no baseline.
- With the wasted vertical space gone, the fixed `220pt` height is reduced, and the split
  presets shrink to match. Exact heights are tuned against `#Preview` during
  implementation.

## Header Fix (`Features/Sync/SyncedAccountHeaderView.swift`)

- The status caption (missing-credential hint / sync error, e.g. "Alchemy rate-limited")
  fits **inline** within the status row when there is horizontal room (via `ViewThatFits`),
  wrapping to its own line only when genuinely cramped. This reclaims the empty space
  between the explorer link and the last-synced text and reduces header height in the
  common wide case.

## Data Changes Enabling the Unified Layout

### 1. History series includes all instruments (`Shared/PositionsHistoryBuilder.swift`)

Today the builder excludes host-currency legs
(`for leg in accountLegs where leg.instrument != hostCurrency`) because it was scoped to
"non-cash position holdings" — so a pure-fiat account yields an empty value series.

Change: **include all instruments (host-currency legs too)** so the series becomes a
correct **total-value / balance-over-time** line for every account, and correctly values
accounts that mix fiat and non-fiat assets.

- Care point: the `contributions` (invested) baseline is already folded from
  host-currency flows. Including host-currency legs in the value line must **not
  double-count** them against contributions. TDD covers: (a) a pure-fiat account's balance
  line equals its running transaction balance; (b) an existing investment account's total
  line still matches value-plus-cash and its P&L/baseline is unchanged.

### 2. Performance for all account types (`Shared/AccountPerformanceCalculator.swift`)

`AccountPerformanceCalculator.compute(...)` is account-type-agnostic (cash flows via
`AccountCashFlows.flowAmounts` + valued positions → Modified Dietz + IRR). Today only
`InvestmentStore` drives it; the crypto/standard/exchange/group split path passes
`performance: nil`.

Change: **drive performance computation for every account** in the unified path, threading
the result into `PositionsAssemblyContext.performance` (as `InvestmentStore` already does).

- When a wallet has no cost basis (transfers/airdrops only), `totalContributions` /
  `profitLoss` come out nil and the corresponding tiles hide — the layout degrades
  gracefully to showing only what's known (current value).

### 3. Relax the positions/surface gate

`PositionsViewInput.shouldHide` currently hides the *entire* surface when the only non-zero
holding is the host currency. Under the unified layout the **chart and transactions always
show**; only the **Positions tab/pane** is gated on having non-host holdings. `shouldHide`
(or its callers) is refactored so it gates the positions element specifically, not the
whole screen.

## Deduplication / Dispatch

- `ContentView+AccountDetail.swift` and `ContentView+GroupDetail.swift` route every account
  type (except `.recordedValue` investment) to the shared `AccountDetailView`, passing the
  account context (positions, transactions filter, host currency, title, accountIds,
  chainId) and an optional **type-specific header slot** (crypto → `SyncedAccountHeaderView`;
  others → empty).
- The new tab/split container is a reworked `PositionsTransactionsSplit` (or a successor)
  that takes **three** content builders — transactions, positions, chart+performance — and
  renders the iOS tabs / Mac stacked-split described above, with data-driven tab presence.
- Once all types route through the shared container, the redundant per-type views
  (`CryptoWalletAccountView`, `ExchangeAccountView`, `StandardAccountView`,
  `GroupDetailView`, and the `.calculatedFromTrades` branch of `InvestmentAccountView`) are
  deleted.

## Suggested Phasing

Detailed breakdown belongs to the implementation plan; the intended order:

1. **Chart density + header inline fix.** Shared, low-risk, immediately addresses the
   visible complaints. (`PositionsChart`, `SyncedAccountHeaderView`.)
2. **History series includes all instruments.** Correct total-value / balance line for all
   accounts; verify investment charts unchanged. (`PositionsHistoryBuilder`.)
3. **Unified tab/split container + relaxed gate**, applied to the crypto / exchange /
   standard / group path. New `[Transactions | Positions | Chart]` iOS tabs and Mac
   positions-pinned `[Transactions | Chart]` toggle, distinct autosave key, right-sized
   presets.
4. **Performance tiles for all account types** in the unified path.
5. **Fold `.calculatedFromTrades` investment accounts** into the shared container.
6. **Delete the redundant per-type views.**

## Testing

- **Unit:** `PositionsHistoryBuilder` all-instruments series (pure-fiat balance line;
  mixed fiat+crypto total; investment total unchanged; no contribution double-count).
  Performance computation for a crypto account with and without cost basis. Tab-presence
  logic (2 vs 3 tabs) as a pure function of the input.
- **Chart:** Y-domain hugging via `#Preview` visual review (`reviewing-ui-with-preview`),
  including empty and single-point series.
- **UI (`MoolahUITests_macOS`):** Mac stacked split shows positions pinned with a working
  `[Transactions | Chart]` toggle defaulting to Transactions; header caption renders inline
  when wide.
- **Regression:** investment `.calculatedFromTrades` accounts retain performance tiles,
  chart, positions, and transactions after folding into the shared container.

## Risks

- **Investment chart behaviour change:** including host-currency (cash) legs makes the
  investment value line a *total account value* line rather than *non-cash holdings value*.
  This is intended (matches the displayed total) but is a visible change — call it out in
  the phase-2 PR and verify against a real investment account.
- **Contribution double-counting** in the history builder (see §1 care point) — guarded by
  TDD.
- **Performance for cost-basis-less wallets** yields partial data — the layout must hide
  nil tiles cleanly rather than showing zeros.
- **Autosave-key migration on Mac:** the new container must use a fresh autosave key so no
  user inherits a stale oversized divider from the legacy shared key.
