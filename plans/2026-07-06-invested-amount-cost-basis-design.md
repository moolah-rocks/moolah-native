# Amount Invested & Cost Basis Model — Design Spec

*Issue: [#1248](https://github.com/moolah-rocks/moolah-native/issues/1248). Supersedes the `contributions`-driven "invested amount" baseline.*

## Problem

The account-detail chart's "invested amount" baseline (dashed line + gain/loss shading) and the "Invested" performance tile are both driven by **`contributions`** — cumulative net *external cash flow* (`AccountCashFlows` / `PositionsHistoryBuilder.foldContributions`). This is wrong in two user-visible ways:

- **Symptom 1 — fiat account shows a baseline it shouldn't.** A fiat-only savings account accrues non-zero `contributions` (opening balance + transfers), so a baseline + shading render. A fiat-only account should show *balance history only* — a single line.
- **Symptom 2 — crypto wallet shows a negative invested amount.** A self-custody wallet funded by on-chain receives (which are external, null-counterparty `.income` legs → *zero* counted inflow) whose only boundary-crossing flow is an outbound transfer books a **negative** `contributions` (e.g. −21,186.47 AUD). A negative invested amount is nonsensical.

The shared root cause: `contributions` is the wrong quantity, and it is drawn unconditionally whenever it is non-zero. The same figure also backs the "Invested" tile, P&L, and the annualised-return tiles via `AccountPerformanceCalculator`, so the fix is a model change, not a chart patch.

## Goals

1. **One definition of "amount invested"**, used by the chart baseline, the tile, and (via the same engine) the realised-CGT figures.
2. Fix both symptoms *by construction* (fiat → no baseline; crypto → never negative).
3. **Annualised return that works for every account type, including self-custody wallets.**
4. Align "amount invested" with the **ATO cost base** so the realised-CGT numbers are reasonably accurate. The **profile base currency (`Profile.instrument`, AUD) is always the reference currency** for cost base.
5. Keep the realised-CGT calculators **tax-report-ready** (the calculation exists in `ReportingStore.loadCapitalGains`; no UI renders it yet — see Non-Goals).

## Non-Goals

- **Building a tax-report UI.** The realised-CGT calculation already exists in `ReportingStore` but is unsurfaced. Exposing it is a fast follow-up; this spec only requires the enriched engine keep producing a correct, richer `CapitalGainsResult` / `CapitalGainsSummary`.
- **The income-tax (assessable-income) side of received crypto.** Treating a received token as an *acquisition at market value* is the cost-base half. Declaring that receipt as assessable ordinary income is a separate concern owned by the tax feature, out of scope here.
- **A "mark as self-transfer" escape hatch** for external moves to your own untracked wallets (see Policy decisions). Named as future work.
- **User-entered acquisition cost/date for opening balances.** Deferred (see Policy decisions).

---

## The single definition

> **Amount invested** = the AUD value of an asset at the moment it *entered* your holdings.

| How the asset arrived | Amount invested |
|---|---|
| Bought with cash (`.trade`, fiat-paired) | price paid **+ incidental fees** |
| Acquired in a crypto-to-crypto swap (`.trade`, non-fiat pair) | AUD market value at the swap (see Crypto-to-crypto) |
| Received / airdropped / staking income (external inbound `.income`) | **AUD market value on the day received** |
| Opening balance (non-fiat) | **AUD market value on the opening date** |
| Transferred from your own tracked account (`.transfer`) | **carries over unchanged** (original amount invested + original acquisition date) |

Rationale for received tokens (user framing): *"I could have sold them that day for that value but didn't, so I effectively invested that amount."* This makes **amount invested and the ATO cost base the same number** — a received/airdropped asset's cost base under the ATO *is* its market value on receipt.

Everything else on the screen derives from this one quantity and its mirror on the way out (proceeds).

---

## Event model

A single classifier maps every leg of every transaction to one of: **acquisition**, **disposal**, **move**, or **non-event**. Fiat legs are never CGT assets (but a fiat fee *attached to a trade* is an incidental cost — see Fees).

| moolah event | ATO treatment | Ledger effect | Today |
|---|---|---|---|
| `.trade` buy leg (non-fiat, +qty) | acquisition for money | add lot @ price + fees | ✓ |
| `.trade` sell leg (non-fiat, −qty) | disposal | consume lots (FIFO), realise gain | ✓ |
| `.trade` non-fiat swap (both legs non-fiat) | disposal of one + acquisition of other | sell + buy @ AUD crossing value | ✓ |
| non-fiat `.income` (external inbound) | acquired other than for money; cost base = market value | **add lot @ market value on date** | ✗ (contributed 0) |
| `.transfer` leg (tracked → tracked) | **not a CGT event**, same asset | **move lots between account tags, preserving amount invested + acquisition date** | ✗ |
| non-fiat `.expense` (external outbound: gas, spend, send-out) | disposal (using/spending crypto is a CGT event) | consume lots (FIFO), realise gain @ market value | ✗ |
| `.openingBalance` leg (non-fiat) | pre-existing holding | **add lot @ market value on the opening date** | ✗ (contributed 0) |
| any fiat leg (not an attached trade fee) | not a CGT asset | none | ✓ |

The disposal side matters even ignoring tax: today a `.transfer`-out or `.expense`-out reduces an account's *quantity* (the value line) but **not** its cost lots, leaving a stale remaining cost against a smaller holding. Consuming/moving lots on the way out is a correctness requirement for the baseline, not only a tax nicety.

### Crypto-to-crypto (unchanged, ATO-confirmed)

The ATO treats a crypto-to-crypto swap as a CGT event on the disposed asset and establishes a **new cost base for the acquired asset**, both set to the same AUD figure — the **market value of the asset received** at the time (falling back to the market value of the asset disposed of if the received asset can't be valued).
Sources: [ATO — Crypto to crypto exchange or swap](https://www.ato.gov.au/individuals-and-families/investments-and-assets/crypto-asset-investments/transactions-acquiring-and-disposing-of-crypto-assets/crypto-to-crypto-exchange-or-swap), [ATO — How to work out and report CGT on crypto](https://www.ato.gov.au/individuals-and-families/investments-and-assets/crypto-asset-investments/how-to-work-out-and-report-cgt-on-crypto).

`TradeEventClassifier` already does this: a non-fiat swap emits a sell on the disposed leg and a buy on the acquired leg, each valued in AUD on the trade date **from its paired leg**. So the disposed asset's proceeds take the AUD value of the asset *received* (the ATO's primary rule) and the acquired asset's cost base takes the AUD value of the asset *disposed of* (the ATO fallback). For a fair-value swap these two AUD amounts are equal; where the two independent price lookups differ (spread/slippage), each side still follows a valid ATO ordering. Left as-is.

### Fees & incidental costs

Fees are the ATO's cost-base "incidental costs" (element 2). They fold into amount invested / proceeds — they are never a separate displayed line.

| Fee situation | Treatment | Status |
|---|---|---|
| Fee on a **buy** (fiat or crypto) | added to that asset's **amount invested** (raises cost base) | ✓ `TradeEventClassifier.feeContribution` folds attached `.expense` legs into `costPerUnit` |
| Fee on a **sell** | **subtracted from proceeds** (lowers realised gain) | ✓ folded into `proceedsPerUnit` |
| Fee paid **in crypto** (e.g. ETH gas) | *also* a **disposal of that crypto** at the same AUD value that became the incidental cost | ✗ **new** — today the fee crypto's quantity drops but no lot is consumed and no gain is realised |
| **Standalone fiat expense** (account fee, not tied to a trade) | no cost-base effect (cash out only) | — |

No double-counting: a crypto fee's AUD value plays two legitimate roles — the incidental cost of the trade it is attached to, **and** the proceeds of the fee-asset it consumed.

---

## Architecture

Cost base becomes **profile-global and account-aware**, because a tracked→tracked transfer carries lots between accounts — an account's remaining cost cannot be computed from that account's transactions in isolation.

### Account-aware `CostBasisEngine`

Each `CostBasisLot` gains a **holding-account tag**. Operations:

- `processBuy(instrument:quantity:costPerUnit:date:account:)` — append a lot to that account's FIFO queue for the instrument.
- `processSell(instrument:quantity:proceedsPerUnit:date:account:)` — consume that account's lots FIFO, emit `CapitalGainEvent`s.
- `moveLots(instrument:quantity:from:to:date:)` — **new.** Consume `quantity` from the source account's FIFO lots and re-append them to the destination account, **preserving each lot's `costPerUnit` and `acquiredDate`** (so the 12-month CGT-discount clock is not reset). Not a CGT event; emits no gain.

Realised `CapitalGainEvent`s are unchanged in shape; the account tag is irrelevant to profile-wide tax totals but lets a per-account view attribute realised gains later.

### Enriched event classifier

Extend the current `.trade`-only classification into a single component (working name `CostBasisEventBuilder`, likely absorbing/wrapping `TradeEventClassifier`) that, given a transaction + the set of tracked account IDs, emits acquisition / disposal / move events per the Event-model table, each valued in AUD on the transaction date. `TradeEventClassifier`'s existing buy/sell/fee logic is reused verbatim for `.trade` legs.

### Profile-global cost pass → `HoldingsCostLedger` (SQL-sourced, cached)

Cross-account carryover means the ledger must see **every account's** acquisition history — a per-view build over one account's transactions would show a transferred-in holding as zero-invested. But it must **not** materialise the whole ~20k-row transaction table into Swift (that is exactly the hotspot `ReportingStore.loadAllLegTransactions()` + `CapitalGainsCalculator.computeWithConversion(transactions:)` is today, and reintroducing it would regress the transaction-list/analysis perf work). FIFO is inherently sequential, but it only needs the **cost-basis-relevant** legs, which are a small fraction of the table.

**SQL does the heavy lifting; Swift does only the FIFO over the reduced set:**

1. **SQL key-event query.** A new GRDB repository method returns, ordered by `(date, sort_order)`, only the legs of transactions that touch **at least one non-fiat instrument** — i.e. `transaction_leg JOIN "transaction" ... WHERE transaction_id IN (SELECT transaction_id FROM transaction_leg JOIN instrument ON kind != 'fiatCurrency')`, with `instrument.kind` joined in (NULL → fiat). Pure-fiat income/expense transactions (the bulk of the table) never leave SQLite. This follows the existing `fetchIncomeAndExpenseAggregation` / `subtotalsAfterPage` aggregate patterns and must ship a paired EXPLAIN-QUERY-PLAN-pinning test (`guides/DATABASE_CODE_GUIDE.md`); the covering index `leg_analysis_by_type_account (type, account_id, instrument_id, …)` and `transaction_by_date` already back it.
2. **Conversions deduped to (instrument, day).** The reduced event set is collapsed to its distinct `(non-fiat instrument, day)` pairs (the daily price is the same for every event that day) and resolved in **one** `convertResultBatch` call — the same batching `PositionsHistoryBuilder+Batch` and the analysis repos already use. This is the "reduce the amount of currency conversion required" win.
3. **Swift FIFO pass.** The enriched classifier + account-aware `CostBasisEngine` walk the reduced, pre-converted event stream once, producing three outputs. Remaining amount invested is a **step function that only changes on cost-basis events**, so the ledger emits change-points (per account, per instrument), not a row per calendar day — consumers carry forward between events (matching the existing "cost only changes on events" chart semantics):
   - **Remaining amount invested change-points** per (account, instrument) — the baseline source.
   - **Realised `CapitalGainEvent`s** — consumed by `CapitalGainsCalculator` → `ReportingStore` (tax).
   - **Per-account market-valued flow list** — consumed by the Return (IRR) calculation.

**Built once per load, cached, invalidated on change.** The profile-wide ledger is built once and cached behind the existing `ReportingStore` generation-bump seam (`reportGeneration`, the same guard `loadCapitalGains`/`loadProfitLoss` use), then shared by the account-detail views (`PositionsHistoryBuilder`, `AccountPerformanceCalculator`), `CapitalGainsCalculator`, and `ProfitLossCalculator`. It is rebuilt only when transactions change. This is what replaces `loadAllLegTransactions()`.

`PositionsHistoryBuilder` stops building its own `.trade`-only engine and stops folding `contributions`; it reads the per-account remaining-invested change-points from the cached ledger and keeps its existing per-account value-line batch-conversion pass unchanged. `AccountCashFlows` and `BuildState.contributions` are **retired**.

---

## Derived surfaces

| Surface | Derivation | Label |
|---|---|---|
| Value line | daily holdings value (non-cash instruments only, unchanged) | balance history |
| Chart baseline + shading | remaining **amount invested** of currently-held lots for the viewed account(s) — **≥ 0 by construction** | "Amount invested" |
| Gain tile / shading | current value − amount invested (unrealised) | "Gain" |
| Return tile (**all account types**) | money-weighted **IRR** over the account-set's acquisition/disposal flows, terminal = current holdings value | "Return" |
| Realised capital gains (future tax report) | disposal proceeds − consumed lots' amount invested, per financial year | (tax-report copy, later) |

### Baseline suppression (replaces the `contributions != 0` gate)

A baseline is shown iff the viewed account(s) hold at least one lot with a non-zero remaining amount invested. Consequences fall out automatically:

- **Fiat-only account** — fiat legs never create lots → remaining amount invested is 0 → **no baseline, no shading** (Symptom 1 fixed).
- **Remaining amount invested is ≥ 0 always** → **negative invested is impossible** (Symptom 2 fixed).

### Return (works for self-custody)

The old `contributions` counted only fiat boundary-crossings, so a wallet funded by on-chain receives had negative/zero flows and no meaningful return. The new IRR flows are **assets entering/leaving the viewed account-set, valued at AUD market value on their date**, with terminal = current holdings value:

- Received/airdropped token → **inflow at market value on receipt** (matching amount invested).
- Buy → inflow at cost; sell → outflow at proceeds; spend/external send → outflow at market value.
- Terminal → current holdings value.

"External" is relative to the **viewed account-set**: for a single-account view, a transfer to a sibling tracked account is an external flow of that account; for an aggregate view over the whole set, inter-account transfers net to zero.

### The one transfer nuance (stated, not a question)

A `.transfer` between your own tracked accounts is valued **two ways, each correct for its purpose**:

- **Amount invested / gain / CGT** → lots **carry over at original amount invested** (ATO-correct; no phantom gain on an internal move).
- **Return (IRR) flows** → valued at **market value on the transfer date** (the value that actually flowed through that account).

They coincide for every account that has no inter-tracked-account transfers. The `HoldingsCostLedger` records both amounts per move event so each consumer reads the right one.

---

## Terminology

Per `guides/BRAND_GUIDE.md` ("Plain-spoken… no jargon"), **"cost basis" is dropped** from user-facing copy:

- Chart baseline + tile → **"Amount invested"**
- Value − invested → **"Gain"**
- Annualised money-weighted return → **"Return"**

"Cost base" remains acceptable **internally** (code, this spec) and in the future tax-report context, where it is the correct ATO term. The chart legend's per-instrument label ("Cost basis") and aggregate label ("Invested amount") both converge to **"Amount invested"** since they now mean the same quantity.

---

## Account-type behaviour (falls out of the model)

- **Fiat savings** — no non-cash lots → value line only. Matches the unified-account-detail design intent.
- **Brokerage / crypto wallet / self-custody** — full baseline, gain, and return.

No explicit `showsPerformanceTiles`/account-type predicate is needed for the baseline: the presence of lots with remaining amount invested is the gate.

---

## Policy decisions (resolved)

1. **Opening-balance cost base (non-fiat)** → **market value on the opening date.** Limitation: the holding-period clock starts at the opening date, so a genuinely old holding may miss the 12-month discount and its pre-opening gain is not captured. Accepted; user-entered cost/date is future work.
2. **External-counterparty moves** → **ATO-strict.** Inbound external `.income` = acquisition at market value; outbound external `.expense` = disposal at market value. Correct for staking, airdrops, payments, and gas (the common cases). Limitation: a move to your *own untracked* wallet books phantom income/disposal until a future "mark as self-transfer" escape hatch exists. Accepted.
3. **Reference currency** → always `Profile.instrument` (AUD). All amount-invested and proceeds values convert to it on the event date via `InstrumentConversionService`, following `guides/INSTRUMENT_CONVERSION_GUIDE.md` (Rule 11: any failed conversion marks the dependent figure unavailable — never a partial sum).

---

## Testing

Engine / ledger (pure, no view harness):

- **Fiat account** — non-zero contributions historically but zero lots → baseline suppressed; no baseline rows / shading.
- **Negative-`contributions` crypto shape** (Trust-Ethereum replay: external on-chain receives + one boundary-crossing outflow) → aggregate baseline **≥ 0 at every point**; never negative.
- **Received/airdrop** — non-fiat `.income` → a lot at AUD market value on the receipt date; baseline reflects it.
- **Opening balance** — non-fiat `.openingBalance` → a lot at market value on the opening date, `acquiredDate` = opening date.
- **Tracked→tracked transfer** — `moveLots` preserves `costPerUnit` and `acquiredDate`; source account's remaining invested drops, destination's rises by the same amount; no realised gain emitted.
- **Crypto fee disposal** — ETH gas on a swap both raises the acquired asset's amount invested *and* consumes ETH lots (FIFO) realising ETH's gain/loss; no double-count.
- **Non-fiat `.expense` external send** → disposal at market value; lots consumed; realised gain emitted.
- **Return** — a self-custody wallet funded by receipts yields a finite, sensible IRR (regression against the old negative-contributions path).
- **Realised CGT** — `CapitalGainsResult` totals updated to include the new disposal sources (income-funded lots, spends); existing c2c and fiat-trade cases unchanged.

Zone-invariance: any date keying/formatting introduced follows `guides/DATE_TIME_GUIDE.md` (`Calendar.utc`, noon-UTC positioning tokens); assert in-process across zones.

---

## Affected code (pointers, pre-change)

- `Shared/CostBasisEngine.swift` — add account-tagged lots + `moveLots`.
- `Shared/TradeEventClassifier.swift` — reused for `.trade`; wrapped by the new event builder.
- `Shared/CapitalGainsCalculator.swift` — feed from the enriched event stream / cached ledger; realised events now include income/transfer/expense sources.
- `Shared/PositionsHistoryBuilder.swift` / `+Batch.swift` — consume per-account remaining-invested change-points from the cached ledger; drop `foldContributions` / `BuildState.contributions`. Per-account value-line quantity fold + batch conversion unchanged.
- `Shared/AccountCashFlows.swift` — **retire** (replaced by the event model).
- `Shared/AccountPerformanceCalculator.swift` — return/IRR flows come from the ledger, not `AccountCashFlows`.
- `Shared/ProfitLossCalculator.swift` — reconcile `accumulateInvested` with the shared ledger.
- `Shared/Views/Positions/PositionsChartBaselineResolver.swift` — aggregate + per-instrument baselines both read remaining amount invested; single suppression rule.
- `Shared/Views/Positions/PositionsChartLegendRow.swift`, `PositionsChart.swift`, `AccountPerformanceTiles.swift`, `AccountPerformanceTileLabels.swift` — relabel to "Amount invested" / "Gain" / "Return".
- `Backends/GRDB/` — **new** repository method returning the SQL-filtered key-event legs (only transactions touching a non-fiat instrument), `instrument.kind` joined; paired EXPLAIN-plan-pinning test. Follows `fetchIncomeAndExpenseAggregation` / `subtotalsAfterPage` patterns.
- `Features/Reports/ReportingStore.swift` — build + cache the profile-wide ledger behind the existing `reportGeneration` seam; **replaces `loadAllLegTransactions()`**; consumes the richer `CapitalGainsResult` (tax-report-ready) and exposes the ledger to the account-detail stores.
- New: `CostBasisEventBuilder`, `HoldingsCostLedger`, the GRDB key-event query, a cached ledger provider (working names).

## Migration & risks

- **Blast radius includes the tax calculators.** Realised-CGT numbers will *change* (become more accurate) because disposals now include income-funded lots and spends. Existing `CapitalGainsCalculator` tests must be updated deliberately, not force-passed.
- **Performance — SQL-sourced, built once, cached.** The ledger is built from a SQL key-event query (only non-fiat-touching transactions leave SQLite; the pure-fiat bulk never materialises), with conversions deduped to `(instrument, day)` and batched. It is built **once per load** and cached behind the `ReportingStore` generation seam, shared across all account views and the tax path — never rebuilt per account open. Ship the query with an EXPLAIN-plan-pinning test and re-check first-open timing against the analysis reload-storm / transaction-list-perf baselines. Retiring `loadAllLegTransactions()` should *improve* the tax path.
- **Cross-account carryover requires the profile-wide (not per-view) ledger** — viewing a transfer's destination account must see the source's acquisition history, which is why the ledger is profile-global and queries filter by account rather than being built per account.
- **Implementation is multi-PR.** Suggested ordering for the plan: (1) account-aware engine + `moveLots`; (2) enriched event builder + `CostBasisEvent`; (3) SQL key-event query in GRDB (+ EXPLAIN test) and the `HoldingsCostLedger` FIFO pass over it; (4) cached profile-wide ledger provider at the `ReportingStore` seam + `CapitalGainsCalculator`/`ProfitLoss` cutover (replace `loadAllLegTransactions`); (5) `PositionsHistoryBuilder` baseline cutover; (6) return/IRR cutover + retire `AccountCashFlows`; (7) relabelling + baseline-suppression UI. Each gated through the AI review agents (incl. `@database-code-review` / `@database-schema-review` for the query).
