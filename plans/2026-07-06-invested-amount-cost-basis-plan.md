# Amount Invested & Cost Basis Model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `contributions`-driven "invested amount" baseline with a single profile-global, account-aware cost-basis model so the chart baseline, gain/return tiles, and realised-CGT figures all derive from one definition — the AUD value of an asset when it entered your holdings — fixing fiat-shows-a-baseline and crypto-shows-negative-invested by construction.

**Architecture:** A profile-global `HoldingsCostLedger` runs an enriched `CostBasisEventBuilder` (wrapping the existing `TradeEventClassifier`) through one **account-aware** `CostBasisEngine`, producing three shared outputs: per-(account, instrument) remaining-amount-invested change-points (chart baseline), realised `CapitalGainEvent`s (tax), and per-account market-valued flows (IRR return). **SQL does the heavy lifting; Swift does only the FIFO over the reduced set.** A new GRDB key-event query (`fetchCostBasisEventLegs`) returns only the legs of transactions that touch at least one non-fiat instrument — the pure-fiat bulk of the ~20k-row table never leaves SQLite. `HoldingsCostLedger.build(legRows:)` groups those legs back into per-transaction inputs, dedupes the needed conversions to distinct `(instrument, day)` pairs resolved in **one** `convertResultBatch` warm call, then runs the classifier + engine once. Remaining amount invested is a **step function that only changes on cost-basis events**, so the ledger emits change-points (not a row per calendar day); consumers carry forward the latest change-point at-or-before a day. Building over the *whole* profile — not the viewed account's subset — is a correctness requirement: a tracked→tracked transfer's `moveLots` can only carry a lot forward if the **source** account's earlier acquisitions are present in the same pass. Because rebuilding this on every account view would regress first-open performance, the ledger is **built once per data load and cached** behind a profile-scoped provider (`HoldingsCostLedgerStore`, owned by `ProfileSession`), which every consumer queries and which **invalidates** on the profile's transaction/instrument change seams (never on rate ticks), and returns `.empty` while `isMigratingCrossChainIdentity`. `PositionsHistoryBuilder`'s value-line/quantity fold **stays per-viewed-account**; `AccountPerformanceCalculator`, `CapitalGainsCalculator`, and `ProfitLossCalculator` read the same shared ledger. `AccountCashFlows`, `BuildState.contributions`, and `ReportingStore.loadAllLegTransactions()` are retired.

**Tech Stack:** Swift, SwiftUI, Swift Testing, GRDB, xcodegen; macOS/iOS.

## Global Constraints

- Reference currency for all amount-invested / proceeds / flow values = `Profile.instrument` (AUD), always; convert on the event date via `InstrumentConversionService`.
- "Cost basis" is dropped from user-facing copy: chart baseline + tile → **"Amount invested"**, value − invested → **"Gain"**, annualised money-weighted return → **"Return"**. "Cost base" stays acceptable in code/comments and the future tax-report context.
- Rule 11 (`guides/INSTRUMENT_CONVERSION_GUIDE.md`): any failed conversion marks the dependent figure unavailable — never a partial sum. A failed ledger build degrades the whole ledger to `.empty` (no baseline anywhere), never a partial ledger. `InstrumentAmount` arithmetic traps on instrument mismatch.
- Remaining amount invested is **≥ 0 by construction** (sum of remaining lot costs) → negative invested is impossible; a fiat-only account holds no lots → invested is 0 → no baseline.
- Tests use **Swift Testing** (`@Test`/`@Suite`/`#expect`), NOT XCTest. One **extension per protocol conformance** (no inline conformance lists) — `guides/CODE_GUIDE.md`.
- Thin views; money/instrument arithmetic via `InstrumentAmount`.
- Dates via `Calendar.utc`; timezoneless carriers (chart x-positions) at noon-UTC — `guides/DATE_TIME_GUIDE.md`. Assert zone-invariance in-process.
- Raw SQL follows `guides/DATABASE_CODE_GUIDE.md`: `Row.fetchAll(db, sql:, arguments:)` with bound arguments; enum raw-value lists may be interpolated (never user input); every new query ships an EXPLAIN-QUERY-PLAN-pinning test (`guides/DATABASE_CODE_GUIDE.md:383-398`). Reuse `TransactionLegRow` / `InstrumentAmount(storageValue:instrument:)` for the `quantity INTEGER` Decimal×10^8 scale — never hand-roll it.
- Concurrency per `guides/CONCURRENCY_GUIDE.md`: keep `@concurrent`/`nonisolated` where the current code uses it; the ledger build is a pure `async` static that hops the conversion actor only for conversions.
- Realised-CGT numbers **will change** (become more accurate: income-funded lots, opening balances, crypto spends now realise). Existing `CapitalGainsCalculator` tests are updated **deliberately** to the new correct numbers, never force-passed.
- Build: `just build-mac`. Unit tests: `just test-mac <FILTER>` (e.g. `just test-mac CostBasisEngine`). Format: `just format-check` / `just format`. Run `just format` + the relevant `@code-review`/`@concurrency-review`/`@instrument-conversion-review`/`@datetime-review` agents before every commit (plus `@database-code-review`/`@database-schema-review` for the SQL task); fix all findings.

---

## File Structure

**Created**

- `Domain/Models/CostBasisEvent.swift` — the `CostBasisEvent` enum + supporting value types (`HoldingsFlowEntry`, `InvestedSnapshot`).
- `Shared/CostBasisEventBuilder.swift` — pure classifier that maps one transaction's legs (given the tracked-account set) to `[CostBasisEvent]` (acquisition / disposal / move), each valued in AUD on the transaction date; wraps `TradeEventClassifier` for `.trade` legs.
- `Domain/Models/CostBasisEventLegRow.swift` — small Sendable carrier the SQL key-event query returns: one reduced `transaction_leg` row with its parent transaction date and a resolved `Instrument`. Consumed by `HoldingsCostLedger.build(legRows:)`.
- `Backends/GRDB/Repositories/GRDBTransactionRepository+CostBasisEvents.swift` — the SQL key-event query (`fetchCostBasisEventLegs`): returns, ordered by `(date, transaction_id, sort_order)`, the legs of only transactions touching ≥1 non-fiat instrument. Follows the `fetchIncomeAndExpenseAggregation` / `subtotalsAfterPage` raw-SQL patterns.
- `Shared/HoldingsCostLedger.swift` — profile-global pass over the reduced key-event legs through one account-aware `CostBasisEngine`; exposes remaining-invested change-point queries, realised events, open lots, and market-valued flows. Queried per-account, so one profile-wide build serves every viewed-account slice.
- `Shared/HoldingsCostLedgerStore.swift` — profile-scoped provider that builds the ledger **once per data load** from the SQL query, caches it, single-flights concurrent builds, returns `.empty` while `isMigratingCrossChainIdentity`, and invalidates on the transaction/instrument change seams. Owned by `ProfileSession`; injected into `InvestmentStore`/`ReportingStore`; reached by `MultiInstrumentPositionsSplitModifier` via the environment session.
- `MoolahTests/Shared/CostBasisEngineAccountTests.swift` — account-tagged lots + `moveLots` tests.
- `MoolahTests/Shared/CostBasisEventBuilderTests.swift` — event-mapping tests.
- `MoolahTests/Backends/GRDB/CostBasisEventLegsPlanPinningTests.swift` — EXPLAIN-QUERY-PLAN-pinning for `fetchCostBasisEventLegs` (index usage; no full-table scan).
- `MoolahTests/Backends/GRDB/GRDBCostBasisEventLegsTests.swift` — behavioural test of the query (only non-fiat-touching transactions returned; fiat bulk excluded; scale + ordering correct).
- `MoolahTests/Shared/HoldingsCostLedgerTests.swift` — ledger integration tests (fiat suppression, negative-contributions crypto shape, income/opening/expense, transfer nuance, flows).
- `MoolahTests/Shared/HoldingsCostLedgerStoreTests.swift` — provider tests (built once + cached across calls without a change; invalidated + rebuilt after a transaction-change notification; `.empty` while migrating).

**Modified**

- `Domain/Models/CostBasisLot.swift` — add `account: UUID?` holding-account tag.
- `Shared/CostBasisEngine.swift` — account-aware buckets; `account:` on `processBuy`/`processSell`, new `moveLots(...)`, new `openLots(for:account:)`.
- `Domain/Repositories/TransactionRepository.swift` — add `func fetchCostBasisEventLegs() async throws -> [CostBasisEventLegRow]`.
- `Shared/CapitalGainsCalculator.swift` — drive realised events from the ledger; gains a `compute(ledger:sellDateRange:)` entry so `ReportingStore` can pass the shared profile-wide ledger (the `computeWithConversion(transactions:…)` entry stays as a thin ledger-building wrapper for unit tests).
- `Shared/ProfitLossCalculator.swift` — `totalInvested` reconciled with the shared ledger's cumulative acquisitions; gains a `compute(ledger:asOfDate:)` entry so `ReportingStore` reuses the shared ledger.
- `Domain/Models/HistoricalValueSeries.swift` — rename `Point.contributions` → `Point.invested` (aggregate remaining amount invested).
- `Shared/PositionsHistoryBuilder.swift` / `Shared/PositionsHistoryBuilder+Batch.swift` — consume the profile-wide ledger's remaining-invested change-points (queried per viewed account); delete `foldContributions`, `BuildState.contributions`, `BuildState.engine`; `build(...)` gains a `ledger:` parameter. The quantity fold still takes the **viewed** transactions.
- `Shared/MultiInstrumentPositionsAssembler.swift` — `assemble` gains a `ledger:` parameter (the shared profile-wide ledger, passed in by the caller); it no longer builds its own. The per-viewed-account `fetchTransactions` (for quantities) is unchanged.
- `Shared/AccountPerformanceCalculator.swift` — flows come from `ledger.cashFlows(accountIds:)`; `compute`/`computeMultiInstrument` gain a `ledger:` parameter; retire `extractFlows`/`extractGroupFlows`.
- `App/ProfileSession.swift` — own the `holdingsCostLedgerStore`; assign it from `makeDomainStores`; cancel its observation on teardown.
- `App/ProfileSession+Factories.swift` — construct `HoldingsCostLedgerStore` in `makeDomainStores` from `backend.transactions` + `backend.conversionService` + `profile.instrument` + the change seams + the migration guard; add it to `DomainStores`; inject it into `InvestmentStore` and `ReportingStore`.
- `Features/Investments/InvestmentStore.swift` — store the injected `holdingsCostLedger` (used by `+Positions`).
- `Features/Investments/InvestmentStore+Positions.swift` — get the shared ledger from `holdingsCostLedger.ledger()` before `AccountPerformanceCalculator.compute` (no per-view build).
- `Features/Reports/ReportingStore.swift` — inject `holdingsCostLedger`; source the profile-wide ledger from it and pass to the calculators (no per-call build). **Retires `loadAllLegTransactions()`.**
- `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift` — obtain the shared ledger from `session.holdingsCostLedgerStore.ledger()`; pass to `assembler.assemble` and `computePerformance`.
- `Shared/Views/Positions/PositionsChartBaselineResolver.swift` / `PositionsChart.swift` / `PositionsChartMode.swift` — `invested` replaces `contributions`; single suppression rule.
- `Shared/Views/Positions/PositionsChartLegendRow.swift` — baseline label → "Amount invested".
- `Shared/Views/Positions/AccountPerformanceTiles.swift` / `AccountPerformanceTileLabels.swift` — "Profit / Loss" → "Gain", "Annualised Return" → "Return", "Invested" → "Amount invested".

**Deleted**

- `Shared/AccountCashFlows.swift` + `MoolahTests/Shared/AccountCashFlowsTests.swift` — replaced by the event model (deleted in Task 6, after its last consumer is cut over).

---

## Task 1 — Account-aware `CostBasisEngine` (+ `moveLots`)

Give each lot a holding-account tag and let the engine buy/sell/move per account, preserving `costPerUnit` + `acquiredDate` on a move. Existing callers pass no account (default `nil`), so behaviour is unchanged for them.

**Files**
- Modify: `Domain/Models/CostBasisLot.swift`
- Modify: `Shared/CostBasisEngine.swift`
- Test: `MoolahTests/Shared/CostBasisEngineAccountTests.swift` (new); existing `MoolahTests/Shared/CostBasisEngineTests.swift` must keep passing unchanged.

**Interfaces**
- Produces:
  - `CostBasisLot(id:instrument:acquiredDate:costPerUnit:originalQuantity:remainingQuantity:account:)` with `let account: UUID?` (init default `nil`).
  - `mutating func CostBasisEngine.processBuy(instrument: Instrument, quantity: Decimal, costPerUnit: Decimal, date: Date, account: UUID? = nil)`
  - `mutating func CostBasisEngine.processSell(instrument: Instrument, quantity: Decimal, proceedsPerUnit: Decimal, date: Date, account: UUID? = nil) -> [CapitalGainEvent]`
  - `mutating func CostBasisEngine.moveLots(instrument: Instrument, quantity: Decimal, from source: UUID?, to destination: UUID?, date: Date)`
  - `func CostBasisEngine.openLots(for instrument: Instrument, account: UUID?) -> [CostBasisLot]`
  - Unchanged: `openLots(for:)` (all accounts), `allOpenLots()`.
- Consumes: `CapitalGainEvent` (unchanged shape).

**Steps**

- [ ] **Step 1: Add the `account` tag to `CostBasisLot`.** No test needed (compile-guarded by Step 2's failing test). Edit `Domain/Models/CostBasisLot.swift`:
  ```swift
  struct CostBasisLot: Sendable, Hashable, Identifiable {
    let id: UUID
    let instrument: Instrument
    let acquiredDate: Date
    let costPerUnit: Decimal
    let originalQuantity: Decimal
    var remainingQuantity: Decimal
    /// Holding-account tag. `nil` for the legacy single-bucket callers
    /// (`CapitalGainsCalculator`, `MultiInstrumentPositionsAssembler`)
    /// that do not yet segregate lots by account.
    let account: UUID?

    init(
      id: UUID, instrument: Instrument, acquiredDate: Date, costPerUnit: Decimal,
      originalQuantity: Decimal, remainingQuantity: Decimal, account: UUID? = nil
    ) {
      self.id = id
      self.instrument = instrument
      self.acquiredDate = acquiredDate
      self.costPerUnit = costPerUnit
      self.originalQuantity = originalQuantity
      self.remainingQuantity = remainingQuantity
      self.account = account
    }

    var totalCost: Decimal { originalQuantity * costPerUnit }
    var remainingCost: Decimal { remainingQuantity * costPerUnit }
  }
  ```

- [ ] **Step 2: Failing test — a buy tagged to an account is only visible to that account.** Add to new `CostBasisEngineAccountTests.swift`:
  ```swift
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("CostBasisEngine account tagging")
  struct CostBasisEngineAccountTests {
    private let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    private let accountA = UUID()
    private let accountB = UUID()
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400) }

    @Test
    func buyTaggedToAccount_visibleOnlyToThatAccount() {
      var engine = CostBasisEngine()
      engine.processBuy(instrument: eth, quantity: 1, costPerUnit: 2_000, date: day(0), account: accountA)
      #expect(engine.openLots(for: eth, account: accountA).count == 1)
      #expect(engine.openLots(for: eth, account: accountB).isEmpty)
      #expect(engine.openLots(for: eth).count == 1)  // aggregate across accounts
    }
  }
  ```
  Run `just test-mac CostBasisEngineAccountTests` — expect a **compile failure** (`openLots(for:account:)` does not exist).

- [ ] **Step 3: Minimal implementation — account buckets.** Rewrite `CostBasisEngine`'s storage to key by `(instrumentId, account)` while keeping the existing API. In `Shared/CostBasisEngine.swift`:
  ```swift
  struct CostBasisEngine: Sendable {
    private struct BucketKey: Hashable {
      let instrumentId: String
      let account: UUID?
    }
    private var buckets: [BucketKey: [CostBasisLot]] = [:]

    mutating func processBuy(
      instrument: Instrument, quantity: Decimal, costPerUnit: Decimal,
      date: Date, account: UUID? = nil
    ) {
      let lot = CostBasisLot(
        id: UUID(), instrument: instrument, acquiredDate: date, costPerUnit: costPerUnit,
        originalQuantity: quantity, remainingQuantity: quantity, account: account)
      buckets[BucketKey(instrumentId: instrument.id, account: account), default: []].append(lot)
    }

    func openLots(for instrument: Instrument, account: UUID?) -> [CostBasisLot] {
      buckets[BucketKey(instrumentId: instrument.id, account: account)] ?? []
    }

    func openLots(for instrument: Instrument) -> [CostBasisLot] {
      buckets.filter { $0.key.instrumentId == instrument.id }.flatMap(\.value)
    }

    func allOpenLots() -> [CostBasisLot] { buckets.values.flatMap { $0 } }
  }
  ```
  Run `just test-mac CostBasisEngine` — expect **pass** for Step 2, but `processSell` is now missing → migrate it in Step 4.

- [ ] **Step 4: Re-add account-aware `processSell` (FIFO within the account's bucket).** Keep the existing FIFO + holding-days logic, now scoped to one bucket. Add to `CostBasisEngine`:
  ```swift
  mutating func processSell(
    instrument: Instrument, quantity: Decimal, proceedsPerUnit: Decimal,
    date: Date, account: UUID? = nil
  ) -> [CapitalGainEvent] {
    let key = BucketKey(instrumentId: instrument.id, account: account)
    var remaining = quantity
    var events: [CapitalGainEvent] = []
    let calendar = Calendar(identifier: .gregorian)
    while remaining > 0 {
      guard var lots = buckets[key], !lots.isEmpty else { break }
      var lot = lots[0]
      let consumed = min(remaining, lot.remainingQuantity)
      let holdingDays = calendar.dateComponents([.day], from: lot.acquiredDate, to: date).day ?? 0
      events.append(
        CapitalGainEvent(
          instrument: instrument, sellDate: date, acquiredDate: lot.acquiredDate,
          quantity: consumed, costBasis: consumed * lot.costPerUnit,
          proceeds: consumed * proceedsPerUnit, holdingDays: holdingDays))
      lot.remainingQuantity -= consumed
      remaining -= consumed
      if lot.remainingQuantity <= 0 { lots.removeFirst() } else { lots[0] = lot }
      buckets[key] = lots
    }
    return events
  }
  ```
  Run `just test-mac CostBasisEngine` — expect **all pass** (existing `CostBasisEngineTests` now route through the `nil` bucket unchanged). Commit: `feat(cost-basis): tag CostBasisEngine lots by holding account`.

- [ ] **Step 5: Failing test — `moveLots` preserves cost + acquired date, emits no gain.** Add to `CostBasisEngineAccountTests`:
  ```swift
  @Test
  func moveLots_preservesCostAndDate_shiftsRemainingInvested() {
    var engine = CostBasisEngine()
    engine.processBuy(instrument: eth, quantity: 2, costPerUnit: 2_000, date: day(0), account: accountA)
    engine.moveLots(instrument: eth, quantity: 2, from: accountA, to: accountB, date: day(100))

    #expect(engine.openLots(for: eth, account: accountA).isEmpty)
    let moved = engine.openLots(for: eth, account: accountB)
    #expect(moved.count == 1)
    #expect(moved[0].costPerUnit == 2_000)          // cost preserved
    #expect(moved[0].acquiredDate == day(0))         // 12-month clock NOT reset
    #expect(moved[0].remainingQuantity == 2)
    // Source remaining invested drops to 0; destination rises by the same 4000.
    #expect(engine.openLots(for: eth, account: accountA).reduce(Decimal(0)) { $0 + $1.remainingCost } == 0)
    #expect(moved.reduce(Decimal(0)) { $0 + $1.remainingCost } == 4_000)
  }

  @Test
  func moveLots_partial_movesFIFOAndLeavesRemainder() {
    var engine = CostBasisEngine()
    engine.processBuy(instrument: eth, quantity: 1, costPerUnit: 2_000, date: day(0), account: accountA)
    engine.processBuy(instrument: eth, quantity: 1, costPerUnit: 3_000, date: day(10), account: accountA)
    engine.moveLots(instrument: eth, quantity: dec("1.5"), from: accountA, to: accountB, date: day(50))

    // FIFO: whole 2000-lot + 0.5 of the 3000-lot move; 0.5 of the 3000-lot stays.
    #expect(engine.openLots(for: eth, account: accountB).count == 2)
    let remainA = engine.openLots(for: eth, account: accountA)
    #expect(remainA.count == 1)
    #expect(remainA[0].remainingQuantity == dec("0.5"))
    #expect(remainA[0].costPerUnit == 3_000)
  }
  ```
  Add the `dec(_:)` helper (mirror `CostBasisEngineTests`: `private func dec(_ s: String) -> Decimal { Decimal(string: s)! }`). Run — expect **compile failure** (`moveLots` missing).

- [ ] **Step 6: Implement `moveLots`.** Consume source-bucket lots FIFO; re-append to the destination bucket with fresh ids but original `costPerUnit`/`acquiredDate`; emit nothing.
  ```swift
  mutating func moveLots(
    instrument: Instrument, quantity: Decimal, from source: UUID?, to destination: UUID?, date: Date
  ) {
    let sourceKey = BucketKey(instrumentId: instrument.id, account: source)
    let destKey = BucketKey(instrumentId: instrument.id, account: destination)
    var remaining = quantity
    while remaining > 0 {
      guard var lots = buckets[sourceKey], !lots.isEmpty else { break }
      var lot = lots[0]
      let moved = min(remaining, lot.remainingQuantity)
      buckets[destKey, default: []].append(
        CostBasisLot(
          id: UUID(), instrument: instrument, acquiredDate: lot.acquiredDate,
          costPerUnit: lot.costPerUnit, originalQuantity: moved, remainingQuantity: moved,
          account: destination))
      lot.remainingQuantity -= moved
      remaining -= moved
      if lot.remainingQuantity <= 0 { lots.removeFirst() } else { lots[0] = lot }
      buckets[sourceKey] = lots
    }
  }
  ```
  Run `just test-mac CostBasisEngine` — expect **all pass**. Run reviewers, `just format`, commit: `feat(cost-basis): add CostBasisEngine.moveLots for tracked transfers`.

---

## Task 2 — Enriched event builder + `CostBasisEvent` types

Map every leg to acquisition / disposal / move (valued in AUD on the event date). This task defines the event types and the pure per-transaction classifier only; the profile-wide FIFO pass over the SQL-reduced legs lands in Task 3.

**Files**
- Create: `Domain/Models/CostBasisEvent.swift`
- Create: `Shared/CostBasisEventBuilder.swift`
- Test: `MoolahTests/Shared/CostBasisEventBuilderTests.swift`

**Interfaces**
- Consumes: `CostBasisEngine` (Task 1); `TradeEventClassifier.classify(legs:on:hostCurrency:conversionService:)`; `InstrumentConversionService.convert`.
- Produces:
  - `enum CostBasisEvent: Sendable, Equatable` with:
    - `case acquisition(instrument: Instrument, quantity: Decimal, costPerUnit: Decimal, account: UUID?)`
    - `case disposal(instrument: Instrument, quantity: Decimal, proceedsPerUnit: Decimal, account: UUID?)`
    - `case move(instrument: Instrument, quantity: Decimal, from: UUID?, to: UUID?, marketValue: Decimal)`
  - `struct HoldingsFlowEntry: Sendable, Equatable { let date: Date; let account: UUID?; let instrument: Instrument; let amount: Decimal; let counterpartyAccount: UUID? }` (sign: `+` = capital into the account, `−` = out). `instrument` lets `ProfitLossCalculator` attribute `totalInvested` per instrument (Task 4).
  - `struct InvestedSnapshot: Sendable, Equatable { let date: Date; let account: UUID?; let instrument: Instrument; let remainingInvested: Decimal }`
  - `enum CostBasisEventBuilder { static func events(legs: [TransactionLeg], on date: Date, trackedAccountIds: Set<UUID>, referenceCurrency: Instrument, conversionService: any InstrumentConversionService) async throws -> [CostBasisEvent] }`

**Steps**

- [ ] **Step 1: Define the event value types.** Create `Domain/Models/CostBasisEvent.swift` with `CostBasisEvent`, `HoldingsFlowEntry`, `InvestedSnapshot` exactly as in Interfaces (each conformance in its own `extension`, e.g. `extension CostBasisEvent: Equatable {}`). No test yet — types are exercised by Steps 2–3. Compile with `just build-mac`.

- [ ] **Step 2: Failing test — a fiat-paired buy maps to one acquisition.** New `CostBasisEventBuilderTests.swift`:
  ```swift
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("CostBasisEventBuilder")
  struct CostBasisEventBuilderTests {
    private let aud = Instrument.AUD
    private let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    private let account = UUID()
    private let day = Date(timeIntervalSince1970: 1_700_000_000)
    private func leg(_ i: Instrument, _ q: Decimal, _ t: TransactionType) -> TransactionLeg {
      TransactionLeg(accountId: account, instrument: i, quantity: q, type: t)
    }
    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    @Test
    func fiatPairedBuy_mapsToAcquisition() async throws {
      let legs = [leg(aud, -2_000, .trade), leg(eth, 1, .trade)]
      let events = try await CostBasisEventBuilder.events(
        legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
        conversionService: FakeConversionService.fixedRates([:]))
      #expect(events == [.acquisition(instrument: eth, quantity: 1, costPerUnit: 2_000, account: account)])
    }
  }
  ```
  Run — expect **compile failure** (`CostBasisEventBuilder` missing).

- [ ] **Step 3: Implement `CostBasisEventBuilder`.** Delegate `.trade` legs to `TradeEventClassifier`, then add income/opening/transfer/non-fiat-expense mapping. Create `Shared/CostBasisEventBuilder.swift`:
  ```swift
  import Foundation

  /// Maps one transaction's legs to `CostBasisEvent`s, each valued in AUD
  /// on `date`. `.trade` legs reuse `TradeEventClassifier` verbatim (buy →
  /// acquisition, sell → disposal, fees folded into per-unit). Non-fiat
  /// `.income`/`.openingBalance` → acquisition at market value; tracked→tracked
  /// `.transfer` → move (cost carries in the engine, market value recorded for
  /// return); non-fiat `.expense` → disposal at market value (crypto spend /
  /// gas). Fiat legs that are not attached trade fees are non-events.
  enum CostBasisEventBuilder {
    static func events(
      legs: [TransactionLeg], on date: Date, trackedAccountIds: Set<UUID>,
      referenceCurrency: Instrument, conversionService: any InstrumentConversionService
    ) async throws -> [CostBasisEvent] {
      var events: [CostBasisEvent] = []

      // 1. `.trade` legs → classifier (fees already folded into per-unit).
      let classification = try await TradeEventClassifier.classify(
        legs: legs, on: date, hostCurrency: referenceCurrency, conversionService: conversionService)
      for buy in classification.buys {
        events.append(.acquisition(
          instrument: buy.instrument, quantity: buy.quantity,
          costPerUnit: buy.costPerUnit, account: accountFor(buy.instrument, in: legs)))
      }
      for sell in classification.sells {
        events.append(.disposal(
          instrument: sell.instrument, quantity: sell.quantity,
          proceedsPerUnit: sell.proceedsPerUnit, account: accountFor(sell.instrument, in: legs)))
      }

      // 2. Non-fiat `.income` / `.openingBalance` → acquisition @ market value.
      for leg in legs where leg.instrument.kind != .fiatCurrency
        && (leg.type == .income || leg.type == .openingBalance) && leg.quantity > 0 {
        let value = try await marketValue(leg.quantity, of: leg.instrument, on: date,
          in: referenceCurrency, using: conversionService)
        events.append(.acquisition(
          instrument: leg.instrument, quantity: leg.quantity,
          costPerUnit: value / leg.quantity, account: leg.accountId))
      }

      // 3. Non-fiat `.expense` (gas / spend / send-out) → disposal @ market value.
      for leg in legs where leg.instrument.kind != .fiatCurrency
        && leg.type == .expense && leg.quantity < 0 {
        let qty = -leg.quantity
        let value = try await marketValue(qty, of: leg.instrument, on: date,
          in: referenceCurrency, using: conversionService)
        events.append(.disposal(
          instrument: leg.instrument, quantity: qty,
          proceedsPerUnit: value / qty, account: leg.accountId))
      }

      // 4. Tracked→tracked `.transfer` → move (cost carries; market value for return).
      events.append(contentsOf: try await transferMoves(
        legs: legs, on: date, trackedAccountIds: trackedAccountIds,
        referenceCurrency: referenceCurrency, conversionService: conversionService))

      return events
    }

    /// A transfer transaction has a negative (source) and positive (dest)
    /// `.transfer` leg of the same instrument, both tracked. Value the move
    /// at the destination quantity's market value on `date`.
    private static func transferMoves(
      legs: [TransactionLeg], on date: Date, trackedAccountIds: Set<UUID>,
      referenceCurrency: Instrument, conversionService: any InstrumentConversionService
    ) async throws -> [CostBasisEvent] {
      let transfers = legs.filter { $0.type == .transfer && $0.instrument.kind != .fiatCurrency }
      guard let source = transfers.first(where: { $0.quantity < 0 }),
        let dest = transfers.first(where: { $0.quantity > 0 }),
        source.instrument == dest.instrument,
        let from = source.accountId, let to = dest.accountId,
        trackedAccountIds.contains(from), trackedAccountIds.contains(to)
      else { return [] }
      let qty = dest.quantity
      let market = try await marketValue(qty, of: dest.instrument, on: date,
        in: referenceCurrency, using: conversionService)
      return [.move(instrument: dest.instrument, quantity: qty, from: from, to: to, marketValue: market)]
    }

    private static func marketValue(
      _ quantity: Decimal, of instrument: Instrument, on date: Date,
      in referenceCurrency: Instrument, using service: any InstrumentConversionService
    ) async throws -> Decimal {
      if instrument == referenceCurrency { return quantity }
      return try await service.convert(quantity, from: instrument, to: referenceCurrency, on: date)
    }

    private static func accountFor(_ instrument: Instrument, in legs: [TransactionLeg]) -> UUID? {
      legs.first { $0.instrument == instrument && $0.type == .trade }?.accountId
    }
  }
  ```
  Run `just test-mac CostBasisEventBuilder` — expect Step-2 **pass**.

- [ ] **Step 4: Tests — income, opening, expense, transfer, crypto-fee.** Add to `CostBasisEventBuilderTests`:
  ```swift
  @Test
  func nonFiatIncome_mapsToAcquisitionAtMarketValue() async throws {
    let legs = [leg(eth, dec("0.5"), .income)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]))  // 1 ETH = 4000 AUD
    #expect(events == [.acquisition(instrument: eth, quantity: dec("0.5"), costPerUnit: 4_000, account: account)])
  }

  @Test
  func nonFiatOpeningBalance_mapsToAcquisitionAtMarketValue() async throws {
    let legs = [leg(eth, 2, .openingBalance)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 3_000]))
    #expect(events == [.acquisition(instrument: eth, quantity: 2, costPerUnit: 3_000, account: account)])
  }

  @Test
  func fiatLegs_areNonEvents() async throws {
    let legs = [leg(aud, 1_000, .income), leg(aud, -50, .expense)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    #expect(events.isEmpty)
  }

  @Test
  func trackedTransfer_mapsToMove() async throws {
    let b = UUID()
    let legs = [
      TransactionLeg(accountId: account, instrument: eth, quantity: -1, type: .transfer),
      TransactionLeg(accountId: b, instrument: eth, quantity: 1, type: .transfer)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account, b], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 5_000]))
    #expect(events == [.move(instrument: eth, quantity: 1, from: account, to: b, marketValue: 5_000)])
  }

  @Test
  func cryptoGasFeeOnSwap_disposesFeeAssetAndFoldsIntoBuyCost() async throws {
    // Swap AUD->ETH with a small ETH gas fee attached: buy ETH (fee folded into
    // cost via classifier) AND dispose the ETH gas leg at market value.
    let legs = [
      leg(aud, -2_000, .trade), leg(eth, 1, .trade), leg(eth, dec("-0.01"), .expense)]
    let events = try await CostBasisEventBuilder.events(
      legs: legs, on: day, trackedAccountIds: [account], referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 2_000]))
    // One acquisition (ETH bought) + one disposal (ETH gas consumed).
    #expect(events.contains { if case .acquisition(let i, _, _, _) = $0 { return i == eth }; return false })
    #expect(events.contains { if case .disposal(let i, let q, _, _) = $0 { return i == eth && q == dec("0.01") }; return false })
  }
  ```
  Run — expect **pass** (fix the builder if any case fails). Run reviewers (`@instrument-conversion-review` for the market-value conversions, `@code-review`), `just format`, commit: `feat(cost-basis): add CostBasisEventBuilder mapping legs to cost-basis events`.

---

## Task 3 — SQL key-event query + profile-global `HoldingsCostLedger`

Add the GRDB query that returns only the legs of transactions touching a non-fiat instrument (the pure-fiat bulk stays in SQLite), then run the enriched builder + account-aware engine once over that reduced set to produce the three shared outputs. Remaining amount invested is emitted as change-points; queries carry forward the latest change-point at-or-before a day.

**Files**
- Create: `Domain/Models/CostBasisEventLegRow.swift`
- Modify: `Domain/Repositories/TransactionRepository.swift` (add `fetchCostBasisEventLegs()`)
- Create: `Backends/GRDB/Repositories/GRDBTransactionRepository+CostBasisEvents.swift`
- Create: `Shared/HoldingsCostLedger.swift`
- Test: `MoolahTests/Backends/GRDB/CostBasisEventLegsPlanPinningTests.swift`, `MoolahTests/Backends/GRDB/GRDBCostBasisEventLegsTests.swift`, `MoolahTests/Shared/HoldingsCostLedgerTests.swift`
- Modify (stubs): every existing `TransactionRepository` test double / conformer must gain a `fetchCostBasisEventLegs()` stub (search `: TransactionRepository` — e.g. `MoolahTests/Support/CancellablePagingTransactionRepository.swift`, `CloudKitTransactionRepository`); non-GRDB backends can `throw BackendError` / `fatalError("unused")` per their existing unsupported-method convention, or return `[]` where a real bulk path is expected.

**Interfaces**
- Consumes: `instrumentResolver.instrumentMap()`, `database.read`, `Row.fetchAll(db, sql:, arguments:)`, `Instrument.fiat(code:)`, `InstrumentAmount(storageValue:instrument:)` (`Domain/Models/InstrumentAmount.swift:103`), `TransactionType(rawValue:)`; `CostBasisEventBuilder.events(...)` (Task 2); `CostBasisEngine` (Task 1); `BatchConversionRequest` / `convertResultBatch` (`Domain/Services/InstrumentConversionService.swift:7-31,79-81`).
- Produces:
  - `struct CostBasisEventLegRow: Sendable, Equatable { let transactionId: UUID; let date: Date; let accountId: UUID?; let instrument: Instrument; let quantity: Decimal; let type: TransactionType; let sortOrder: Int }`
  - `TransactionRepository.fetchCostBasisEventLegs() async throws -> [CostBasisEventLegRow]`
  - `struct HoldingsCostLedger: Sendable, Equatable` with:
    - `let investedSnapshots: [InvestedSnapshot]`
    - `let realisedEvents: [CapitalGainEvent]`
    - `let flows: [HoldingsFlowEntry]`
    - `let openLots: [CostBasisLot]`
    - `static var empty: HoldingsCostLedger`
    - `static func build(legRows: [CostBasisEventLegRow], referenceCurrency: Instrument, conversionService: any InstrumentConversionService) async throws -> HoldingsCostLedger` — primary (SQL-sourced) entry.
    - `static func build(transactions: [Transaction], referenceCurrency: Instrument, conversionService: any InstrumentConversionService) async throws -> HoldingsCostLedger` — convenience that flattens `[Transaction]` → `[CostBasisEventLegRow]` for unit-test call sites.
    - `func remainingInvested(accountIds: Set<UUID>, onOrBefore day: Date) -> Decimal`
    - `func remainingInvested(accountIds: Set<UUID>, instrument: Instrument, onOrBefore day: Date) -> Decimal`
    - `func cashFlows(accountIds: Set<UUID>) -> [CashFlow]` (filters flows to the set, drops internal moves, sorts by date)

**Steps**

- [ ] **Step 1: Define `CostBasisEventLegRow` + the protocol method.** Create `Domain/Models/CostBasisEventLegRow.swift`:
  ```swift
  import Foundation

  /// One reduced `transaction_leg` row returned by the cost-basis key-event
  /// query, carrying its parent transaction's date and a resolved
  /// `Instrument` (via the injected instrument map). `HoldingsCostLedger`
  /// groups these back into per-transaction event inputs. Only legs of
  /// transactions touching at least one non-fiat instrument are produced —
  /// the pure-fiat bulk of the table never leaves SQLite.
  struct CostBasisEventLegRow: Sendable, Equatable {
    let transactionId: UUID
    let date: Date
    let accountId: UUID?
    let instrument: Instrument
    /// Signed leg quantity in `instrument` units (already de-scaled from the
    /// `INTEGER` Decimal×10^8 storage form via `InstrumentAmount`).
    let quantity: Decimal
    let type: TransactionType
    let sortOrder: Int
  }
  ```
  In `Domain/Repositories/TransactionRepository.swift` add to the protocol:
  ```swift
  /// Returns the legs of every transaction that touches at least one
  /// non-fiat instrument, ordered by `(date, transaction_id, sort_order)`,
  /// for the profile-wide cost-basis pass. Pure-fiat transactions (the
  /// bulk of the table) never leave SQLite; each returned leg's instrument
  /// is resolved via the same map `fetch`/`fetchAll` use.
  func fetchCostBasisEventLegs() async throws -> [CostBasisEventLegRow]
  ```
  Add a stub to every existing conformer/double (see Files). Run `just build-mac` — expect **clean** once stubs compile.

- [ ] **Step 2: Failing test — the query returns only non-fiat-touching transactions' legs, correctly scaled + ordered.** New `GRDBCostBasisEventLegsTests.swift` (mirror an existing `GRDBTransactionRepository` test's setup — in-memory `DatabaseQueue`, seeded instrument registry with ETH registered + AUD ambient). Seed: (a) a pure-fiat income txn (AUD only), (b) an AUD→ETH trade, (c) a crypto `.income` receive. Assert the pure-fiat txn's legs are **absent**, both legs of the trade are **present**, the ETH quantity round-trips through the `10^8` scale, and rows are ordered by `(date, transaction_id, sort_order)`:
  ```swift
  @Test
  func returnsOnlyNonFiatTouchingLegs_scaledAndOrdered() async throws {
    let repo = try makeRepository()  // local helper mirroring existing GRDB repo tests
    _ = try await repo.create(fiatOnlyIncome)      // AUD income — excluded
    _ = try await repo.create(audToEthTrade)       // AUD + ETH legs — both included
    _ = try await repo.create(ethReceive)          // ETH .income — included

    let rows = try await repo.fetchCostBasisEventLegs()
    #expect(!rows.contains { $0.transactionId == fiatOnlyIncome.id })
    #expect(rows.filter { $0.transactionId == audToEthTrade.id }.count == 2)
    let ethLeg = try #require(rows.first { $0.instrument == eth && $0.type == .trade })
    #expect(ethLeg.quantity == 1)   // survived the Int64 ×10^8 round-trip
    #expect(rows == rows.sorted { ($0.date, $0.transactionId.uuidString, $0.sortOrder)
                                < ($1.date, $1.transactionId.uuidString, $1.sortOrder) })
  }
  ```
  Run `just test-mac GRDBCostBasisEventLegs` — expect **compile failure** (`fetchCostBasisEventLegs` unimplemented on GRDB repo).

- [ ] **Step 3: Implement `fetchCostBasisEventLegs` (raw SQL + reuse the scale mapping).** Create `Backends/GRDB/Repositories/GRDBTransactionRepository+CostBasisEvents.swift`, mirroring `fetchAll` (resolve the instrument map before the read snapshot) and `fetchIncomeAndExpenseAggregation` (raw `Row.fetchAll`):
  ```swift
  // Backends/GRDB/Repositories/GRDBTransactionRepository+CostBasisEvents.swift

  import Foundation
  import GRDB

  extension GRDBTransactionRepository {
    /// See `TransactionRepository.fetchCostBasisEventLegs()`. The membership
    /// subquery inner-joins `instrument` so only legs whose transaction has
    /// at least one *registered non-fiat* instrument qualify (unregistered
    /// fiat has no `instrument` row → naturally excluded). Ordered
    /// `(date, transaction_id, sort_order)` so each transaction's legs stay
    /// contiguous and transactions stay in date order. Plan-pinned by
    /// `CostBasisEventLegsPlanPinningTests`.
    func fetchCostBasisEventLegs() async throws -> [CostBasisEventLegRow] {
      let instruments = try await instrumentResolver.instrumentMap()
      return try await database.read { database -> [CostBasisEventLegRow] in
        let rows = try Row.fetchAll(database, sql: Self.costBasisEventLegsSQL)
        return rows.compactMap { row in Self.mapCostBasisEventLegRow(row, instruments: instruments) }
      }
    }

    static func mapCostBasisEventLegRow(
      _ row: Row, instruments: [String: Instrument]
    ) -> CostBasisEventLegRow? {
      guard
        let transactionId: UUID = row["transaction_id"],
        // GRDB decodes the `"transaction".date` TEXT column straight to
        // `Date` via the same DatabaseValueConvertible path `TransactionRow`
        // (`var date: Date`, `Backends/GRDB/Records/TransactionRow.swift:79`)
        // uses on `fetch`/`fetchAll` — no hand-rolled formatter.
        let date: Date = row["date"],
        let instrumentId: String = row["instrument_id"],
        let storage: Int64 = row["quantity"],
        let typeRaw: String = row["type"],
        let type = TransactionType(rawValue: typeRaw),
        let sortOrder: Int = row["sort_order"]
      else { return nil }
      let instrument = instruments[instrumentId] ?? Instrument.fiat(code: instrumentId)
      return CostBasisEventLegRow(
        transactionId: transactionId,
        date: date,
        accountId: row["account_id"],
        instrument: instrument,
        // Reuse the sanctioned Decimal×10^8 de-scaling — never hand-roll it.
        quantity: InstrumentAmount(storageValue: storage, instrument: instrument).quantity,
        type: type,
        sortOrder: sortOrder)
    }
  }

  /// Raw SQL for the cost-basis key-event legs. Plan shape (index usage,
  /// no full-table scan of the outer leg alias) is pinned by
  /// `CostBasisEventLegsPlanPinningTests`; structural changes here should be
  /// reflected there. `t.recur_period IS NULL` excludes scheduled templates,
  /// matching every other analysis query.
  private let costBasisEventLegsSQL = """
    SELECT
        leg.transaction_id  AS transaction_id,
        t.date              AS date,
        leg.account_id      AS account_id,
        leg.instrument_id   AS instrument_id,
        leg.quantity        AS quantity,
        leg.type            AS type,
        leg.sort_order      AS sort_order
    FROM transaction_leg leg
    JOIN "transaction" t ON leg.transaction_id = t.id
    WHERE t.recur_period IS NULL
      AND leg.transaction_id IN (
          SELECT nf.transaction_id
          FROM transaction_leg nf
          JOIN instrument i ON nf.instrument_id = i.id
          WHERE i.kind != 'fiatCurrency'
      )
    ORDER BY t.date ASC, leg.transaction_id ASC, leg.sort_order ASC
    """
  ```
  (`row["date"]` uses GRDB's built-in `Date` decode — the same conversion `TransactionRow`'s `var date: Date` relies on — so there is no formatter to introduce.) Run `just test-mac GRDBCostBasisEventLegs` — expect **pass**.

- [ ] **Step 4: EXPLAIN-plan-pinning test.** New `CostBasisEventLegsPlanPinningTests.swift`, mirroring `CountNeedsReviewPlanPinningTests` (uses `PlanPinningTestHelpers.makeDatabase()` / `planDetail(_:query:)` / `planHasFullTableScanOf(_:alias:)`):
  ```swift
  @Suite("fetchCostBasisEventLegs plan-pinning")
  struct CostBasisEventLegsPlanPinningTests {
    private let query = /* the exact costBasisEventLegsSQL string */

    @Test("date ordering rides transaction_by_date; no bare leg scan")
    func usesIndexesNoScan() throws {
      let database = try PlanPinningTestHelpers.makeDatabase()
      let detail = try PlanPinningTestHelpers.planDetail(database, query: query)
      #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
      #expect(detail.contains("transaction_by_date"))
    }
  }
  ```
  **Verify empirically before finalising the assertions:** run the test, read the emitted plan, and pin the indexes SQLite *actually* chooses (expected: `transaction_by_date` for the ORDER BY, `leg_by_transaction` for the outer `transaction_id IN (…)` probe, and an index-driven membership subquery — adjust the `contains(...)` targets to the real plan). If a bare `SCAN` of the outer `leg` alias appears, do **not** silently accept it: raise it with the controller — an added covering index is a schema migration requiring `@database-schema-review`, out of this task's read-only scope. Run reviewers on the commit: `@database-code-review` + `@database-schema-review` (the raw SQL + plan pinning), `@code-review`. `just format`, commit: `feat(cost-basis): add SQL key-event leg query for the cost-basis pass`.

- [ ] **Step 5: Failing test — ledger suppresses a fiat account and never goes negative.** New `HoldingsCostLedgerTests.swift` (uses the `build(transactions:)` convenience so the tests stay transaction-shaped):
  ```swift
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("HoldingsCostLedger")
  struct HoldingsCostLedgerTests {
    private let aud = Instrument.AUD
    private let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    private func day(_ n: Int) -> Date {
      Calendar.utc.date(from: DateComponents(year: 2024, month: 1, day: 1 + n))!
    }
    private func leg(_ acc: UUID?, _ i: Instrument, _ q: Decimal, _ t: TransactionType) -> TransactionLeg {
      TransactionLeg(accountId: acc, instrument: i, quantity: q, type: t)
    }

    @Test
    func fiatOnlyAccount_hasZeroInvested_noBaseline() async throws {
      let a = UUID()
      let txns = [
        Transaction(date: day(0), legs: [leg(a, aud, 10_000, .openingBalance)]),
        Transaction(date: day(5), legs: [leg(a, aud, 500, .income)])]
      let ledger = try await HoldingsCostLedger.build(
        transactions: txns, referenceCurrency: aud,
        conversionService: FakeConversionService.fixedRates([:]))
      #expect(ledger.remainingInvested(accountIds: [a], onOrBefore: day(30)) == 0)
    }

    @Test
    func selfCustodyReceivesThenSendsOut_investedNeverNegative() async throws {
      // Trust-Ethereum replay shape: external on-chain receives (.income) then
      // one boundary-crossing outflow (.expense). Old contributions went negative.
      let a = UUID()
      let txns = [
        Transaction(date: day(0), legs: [leg(a, eth, 2, .income)]),
        Transaction(date: day(10), legs: [leg(a, eth, 3, .income)]),
        Transaction(date: day(20), legs: [leg(a, eth, -4, .expense)])]
      let ledger = try await HoldingsCostLedger.build(
        transactions: txns, referenceCurrency: aud,
        conversionService: FakeConversionService.fixedRates([eth.id: 5_000]))
      for n in 0...30 {
        #expect(ledger.remainingInvested(accountIds: [a], onOrBefore: day(n)) >= 0)
      }
      // After sending 4 of 5 ETH, 1 ETH remains @ its acquisition value (5000).
      #expect(ledger.remainingInvested(accountIds: [a], onOrBefore: day(30)) == 5_000)
    }
  }
  ```
  Run — expect **compile failure** (`HoldingsCostLedger` missing).

- [ ] **Step 6: Implement `HoldingsCostLedger` — the two build entries + the pass.** Create `Shared/HoldingsCostLedger.swift`:
  ```swift
  import Foundation

  /// Profile-global cost pass. Groups the SQL-reduced key-event legs back
  /// into per-transaction inputs, warms the needed `(instrument, day)` rates
  /// in one batch, then runs `CostBasisEventBuilder` in date order through
  /// one account-aware `CostBasisEngine`, producing the shared outputs every
  /// consumer reads: per-(account, instrument) remaining-amount-invested
  /// change-points (baseline), realised `CapitalGainEvent`s (tax), open lots,
  /// and market-valued flows (return).
  struct HoldingsCostLedger: Sendable {
    let investedSnapshots: [InvestedSnapshot]
    let realisedEvents: [CapitalGainEvent]
    let flows: [HoldingsFlowEntry]
    let openLots: [CostBasisLot]

    /// Primary (SQL-sourced) entry: consumes the reduced key-event legs
    /// (already ordered `(date, transaction_id, sort_order)`).
    static func build(
      legRows: [CostBasisEventLegRow], referenceCurrency: Instrument,
      conversionService: any InstrumentConversionService
    ) async throws -> HoldingsCostLedger {
      // 1. Group legs back into per-transaction inputs, preserving the query's
      //    order so each transaction's legs stay contiguous and transactions
      //    stay in date order.
      var order: [UUID] = []
      var byTxn: [UUID: (date: Date, legs: [TransactionLeg])] = [:]
      for row in legRows {
        if byTxn[row.transactionId] == nil {
          order.append(row.transactionId)
          byTxn[row.transactionId] = (row.date, [])
        }
        byTxn[row.transactionId]?.legs.append(
          TransactionLeg(
            accountId: row.accountId, instrument: row.instrument,
            quantity: row.quantity, type: row.type))
      }

      // 2. Warm the needed rates in ONE batch so the classifier pass below
      //    hits a warm conversion cache instead of N serial provider hops.
      //    Dedupe to distinct (non-reference instrument, transaction-date)
      //    pairs — the daily rate is identical for every event that day.
      struct RateKey: Hashable { let instrumentId: String; let date: Date }
      var seen: Set<RateKey> = []
      var warm: [BatchConversionRequest] = []
      for id in order {
        guard let entry = byTxn[id] else { continue }
        for leg in entry.legs where leg.instrument != referenceCurrency {
          guard seen.insert(RateKey(instrumentId: leg.instrument.id, date: entry.date)).inserted
          else { continue }
          warm.append(BatchConversionRequest(
            amount: InstrumentAmount(quantity: 1, instrument: leg.instrument),
            target: referenceCurrency, date: entry.date))
        }
      }
      _ = try await conversionService.convertResultBatch(warm)

      // 3. Single FIFO pass over the reduced, rate-warm event stream.
      let tracked = Set(legRows.compactMap(\.accountId))
      var engine = CostBasisEngine()
      var snapshots: [InvestedSnapshot] = []
      var realised: [CapitalGainEvent] = []
      var flows: [HoldingsFlowEntry] = []

      for id in order {
        guard let entry = byTxn[id] else { continue }
        try Task.checkCancellation()
        let events = try await CostBasisEventBuilder.events(
          legs: entry.legs, on: entry.date, trackedAccountIds: tracked,
          referenceCurrency: referenceCurrency, conversionService: conversionService)
        // Disposals + moves before acquisitions so a same-txn buy is not
        // immediately consumed.
        var touched: Set<TouchKey> = []
        for event in events.sorted(by: Self.disposalsFirst) {
          switch event {
          case .disposal(let i, let q, let p, let account):
            realised.append(contentsOf: engine.processSell(
              instrument: i, quantity: q, proceedsPerUnit: p, date: entry.date, account: account))
            flows.append(HoldingsFlowEntry(
              date: entry.date, account: account, instrument: i,
              amount: -(q * p), counterpartyAccount: nil))
            touched.insert(TouchKey(account: account, instrumentId: i.id))
          case .move(let i, let q, let from, let to, let market):
            engine.moveLots(instrument: i, quantity: q, from: from, to: to, date: entry.date)
            flows.append(HoldingsFlowEntry(
              date: entry.date, account: from, instrument: i, amount: -market, counterpartyAccount: to))
            flows.append(HoldingsFlowEntry(
              date: entry.date, account: to, instrument: i, amount: market, counterpartyAccount: from))
            touched.insert(TouchKey(account: from, instrumentId: i.id))
            touched.insert(TouchKey(account: to, instrumentId: i.id))
          case .acquisition(let i, let q, let c, let account):
            engine.processBuy(
              instrument: i, quantity: q, costPerUnit: c, date: entry.date, account: account)
            flows.append(HoldingsFlowEntry(
              date: entry.date, account: account, instrument: i, amount: q * c, counterpartyAccount: nil))
            touched.insert(TouchKey(account: account, instrumentId: i.id))
          }
        }
        for key in touched {
          guard let instrument = Self.instrument(forId: key.instrumentId, in: entry.legs) else { continue }
          let invested = engine.openLots(for: instrument, account: key.account)
            .reduce(Decimal(0)) { $0 + $1.remainingCost }
          snapshots.append(InvestedSnapshot(
            date: entry.date, account: key.account, instrument: instrument, remainingInvested: invested))
        }
      }
      return HoldingsCostLedger(
        investedSnapshots: snapshots, realisedEvents: realised, flows: flows,
        openLots: engine.allOpenLots())
    }

    /// Convenience for unit-test / pure call sites: flattens `[Transaction]`
    /// to `[CostBasisEventLegRow]` (mirroring the SQL query's ordering) then
    /// runs the primary build. Production sources `legRows` from
    /// `TransactionRepository.fetchCostBasisEventLegs()`.
    static func build(
      transactions: [Transaction], referenceCurrency: Instrument,
      conversionService: any InstrumentConversionService
    ) async throws -> HoldingsCostLedger {
      let legRows =
        transactions
        .flatMap { txn in
          txn.legs.enumerated().map { index, leg in
            CostBasisEventLegRow(
              transactionId: txn.id, date: txn.date, accountId: leg.accountId,
              instrument: leg.instrument, quantity: leg.quantity, type: leg.type, sortOrder: index)
          }
        }
        .sorted {
          ($0.date, $0.transactionId.uuidString, $0.sortOrder)
            < ($1.date, $1.transactionId.uuidString, $1.sortOrder)
        }
      return try await build(
        legRows: legRows, referenceCurrency: referenceCurrency, conversionService: conversionService)
    }

    private struct TouchKey: Hashable { let account: UUID?; let instrumentId: String }

    private static func disposalsFirst(_ lhs: CostBasisEvent, _ rhs: CostBasisEvent) -> Bool {
      func rank(_ e: CostBasisEvent) -> Int {
        switch e {
        case .disposal: return 0
        case .move: return 1
        case .acquisition: return 2
        }
      }
      return rank(lhs) < rank(rhs)
    }

    private static func instrument(forId id: String, in legs: [TransactionLeg]) -> Instrument? {
      legs.first { $0.instrument.id == id }?.instrument
    }
  }

  extension HoldingsCostLedger: Equatable {}

  extension HoldingsCostLedger {
    /// The degraded/no-data ledger: every query returns 0 / empty. Used by
    /// consumers when a build is unavailable (Rule 11) or while the
    /// cross-chain identity migration is running, so a failed/gated ledger
    /// never partially sums.
    static var empty: HoldingsCostLedger {
      HoldingsCostLedger(investedSnapshots: [], realisedEvents: [], flows: [], openLots: [])
    }
  }
  ```
  Run `just test-mac HoldingsCostLedger` — still failing (queries missing) → Step 7.

- [ ] **Step 7: Implement the remaining-invested + cashFlows queries.** Latest change-point per (account, instrument) at-or-before `day` (compare start-of-day UTC so a same-day transaction counts). Add in a second `extension HoldingsCostLedger`:
  ```swift
  extension HoldingsCostLedger {
    func remainingInvested(accountIds: Set<UUID>, onOrBefore day: Date) -> Decimal {
      latestLevels(accountIds: accountIds, instrumentId: nil, onOrBefore: day)
    }

    func remainingInvested(accountIds: Set<UUID>, instrument: Instrument, onOrBefore day: Date) -> Decimal {
      latestLevels(accountIds: accountIds, instrumentId: instrument.id, onOrBefore: day)
    }

    private func latestLevels(accountIds: Set<UUID>, instrumentId: String?, onOrBefore day: Date) -> Decimal {
      struct Key: Hashable { let account: UUID?; let instrumentId: String }
      var latest: [Key: (date: Date, value: Decimal)] = [:]
      for snap in investedSnapshots {
        guard let account = snap.account, accountIds.contains(account) else { continue }
        if let want = instrumentId, snap.instrument.id != want { continue }
        guard Calendar.utc.startOfDay(for: snap.date) <= day else { continue }
        let key = Key(account: account, instrumentId: snap.instrument.id)
        if let existing = latest[key], existing.date >= snap.date { continue }
        latest[key] = (snap.date, snap.remainingInvested)
      }
      return latest.values.reduce(Decimal(0)) { $0 + $1.value }
    }

    /// Market-valued flows for the viewed account set, as `CashFlow`s: drop
    /// internal moves (both endpoints in the set net to zero), keep external
    /// buys/sells/income/spends and moves to/from accounts outside the set.
    func cashFlows(accountIds: Set<UUID>) -> [CashFlow] {
      flows
        .filter { entry in
          guard let account = entry.account, accountIds.contains(account) else { return false }
          if let counterparty = entry.counterpartyAccount, accountIds.contains(counterparty) {
            return false  // internal transfer within the viewed set
          }
          return true
        }
        .sorted { $0.date < $1.date }
        .map { CashFlow(date: $0.date, amount: $0.amount) }
    }
  }
  ```
  Run `just test-mac HoldingsCostLedger` — expect Step-5 **pass**.

- [ ] **Step 8: Tests — transfer nuance, expense disposal, realised events, zone-invariance.** Add to `HoldingsCostLedgerTests`:
  ```swift
  @Test
  func transferBetweenTrackedAccounts_noRealisedGain_investedMoves() async throws {
    let a = UUID(); let b = UUID()
    let txns = [
      Transaction(date: day(0), legs: [leg(a, eth, 1, .income)]),
      Transaction(date: day(5), legs: [
        leg(a, eth, -1, .transfer), leg(b, eth, 1, .transfer)])]
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]))
    #expect(ledger.realisedEvents.isEmpty)                                   // move is not a CGT event
    #expect(ledger.remainingInvested(accountIds: [a], onOrBefore: day(10)) == 0)      // source drained
    #expect(ledger.remainingInvested(accountIds: [b], onOrBefore: day(10)) == 4_000)  // dest holds original invested
    // Aggregate over {a,b}: the move nets out of cashFlows, leaving only the income inflow.
    #expect(ledger.cashFlows(accountIds: [a, b]).count == 1)
  }

  @Test
  func externalExpenseSend_realisesGain() async throws {
    let a = UUID()
    let txns = [
      Transaction(date: day(0), legs: [leg(a, eth, 1, .income)]),             // acquired @ 2000
      Transaction(date: day(400), legs: [leg(a, eth, -1, .expense)])]         // spent @ 2000 (flat fake)
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 2_000]))
    #expect(ledger.realisedEvents.count == 1)
    #expect(ledger.realisedEvents[0].instrument == eth)
    #expect(ledger.remainingInvested(accountIds: [a], onOrBefore: day(400)) == 0)
  }
  ```
  Add a zone-invariance case (`guides/DATE_TIME_GUIDE.md`): build a ledger whose only snapshot is on `day(0)` and assert `remainingInvested(..., onOrBefore: day(0))` is identical when the test process runs under `TimeZone(identifier: "Pacific/Kiritimati")` vs `"Pacific/Pago_Pago")` — the `Calendar.utc.startOfDay` comparison must not drift. (If the suite has a shared zone-override helper, reuse it; otherwise assert the two `latestLevels` results are equal in-process.) Run — expect **pass**. Run reviewers (`@concurrency-review` for the `async`/`Task.checkCancellation` pass, `@instrument-conversion-review` for the batch warm + market-value conversions, `@datetime-review` for the start-of-day comparison + date parsing), `just format`, commit: `feat(cost-basis): add profile-global HoldingsCostLedger over the key-event legs`.

---

## Task 4 — Cached ledger provider + `CapitalGainsCalculator` / `ProfitLoss` cutover

Introduce the single home that builds the profile-wide `HoldingsCostLedger` **once per data load** from the SQL query, caches it, single-flights concurrent builds, returns `.empty` while `isMigratingCrossChainIdentity`, and invalidates when transactions or instrument identities change. Then feed realised CGT + P&L from the shared ledger so disposals now include income-funded lots, opening balances, and crypto spends. `ReportingStore` sources the ledger from the provider (replacing `loadAllLegTransactions()`) and passes it to the calculators.

**Files**
- Create: `Shared/HoldingsCostLedgerStore.swift`
- Create test: `MoolahTests/Shared/HoldingsCostLedgerStoreTests.swift`
- Modify: `Shared/CapitalGainsCalculator.swift`, `Shared/ProfitLossCalculator.swift`
- Modify: `App/ProfileSession+Factories.swift`, `App/ProfileSession.swift`
- Modify: `Features/Investments/InvestmentStore.swift`, `Features/Reports/ReportingStore.swift`
- Modify tests: `CapitalGainsCalculatorTests.swift`, `CapitalGainsCalculatorTestsMore.swift`, `CapitalGainsCalculatorTestsMoreExtra.swift`, `ProfitLossCalculatorTests.swift`, `ProfitLossCalculatorTestsMore.swift`, plus any `ReportingStore`/`InvestmentStore` construction site (tests, previews) that must now pass a provider.

**Interfaces**
- Consumes: `HoldingsCostLedger.build(legRows:…)` / `.build(transactions:…)` (Task 3); `TransactionRepository.fetchCostBasisEventLegs()` (Task 3); `observeAll(filter:)` (`Domain/Repositories/TransactionRepository.swift:32`); `BackendProvider.instrumentChangeObserver?.observeChanges()` (`Domain/Repositories/InstrumentChangeObserving.swift`); `UnifiedInstrumentIdentityMigration.isComplete(in:)` (`App/UnifiedInstrumentIdentityMigration.swift:44`); `InstrumentConversionService`.
- Produces:
  - `@MainActor final class HoldingsCostLedgerStore` with `func ledger() async throws -> HoldingsCostLedger`, `func invalidate()`, and `var hasCachedLedger: Bool` (internal, for tests).
  - `CapitalGainsCalculator.compute(ledger: HoldingsCostLedger, sellDateRange: ClosedRange<Date>? = nil) -> CapitalGainsResult` + the retained `computeWithConversion(transactions:…)` wrapper.
  - `ProfitLossCalculator.compute(ledger: HoldingsCostLedger, asOfDate: Date) -> [InstrumentProfitLoss]` + the retained `compute(transactions:…)` wrapper.

**Steps**

- [ ] **Step 1: Failing tests — provider builds once + cached, invalidates on change, `.empty` while migrating.** New `HoldingsCostLedgerStoreTests.swift`. A counting double stands in for the repository (only `fetchCostBasisEventLegs` is exercised; the rest of `TransactionRepository` traps — mirror `CancellablePagingTransactionRepository`):
  ```swift
  import Foundation
  import Testing

  @testable import Moolah

  private actor CountingTransactionRepository: TransactionRepository {
    private var legRows: [CostBasisEventLegRow]
    private(set) var fetchCount = 0
    init(legRows: [CostBasisEventLegRow]) { self.legRows = legRows }
    func setLegRows(_ rows: [CostBasisEventLegRow]) { legRows = rows }

    func fetchCostBasisEventLegs() async throws -> [CostBasisEventLegRow] {
      fetchCount += 1
      return legRows
    }
    nonisolated func observeAll(filter: TransactionFilter) -> AsyncStream<[Transaction]> { .finished }
    nonisolated func observeErrors() -> AsyncStream<any Error> { .finished }
    // Remaining TransactionRepository requirements are unused here — stub
    // each as `fatalError("unused")`, mirroring
    // `CancellablePagingTransactionRepository`.
  }

  @Suite("HoldingsCostLedgerStore")
  @MainActor
  struct HoldingsCostLedgerStoreTests {
    private let aud = Instrument.AUD
    private let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    private let account = UUID()
    private let day = Date(timeIntervalSince1970: 1_700_000_000)
    private func row() -> CostBasisEventLegRow {
      CostBasisEventLegRow(
        transactionId: UUID(), date: day, accountId: account, instrument: eth,
        quantity: 1, type: .income, sortOrder: 0)
    }

    @Test
    func ledger_builtOnce_reusedAcrossCallsWithoutChange() async throws {
      let repo = CountingTransactionRepository(legRows: [row()])
      let store = HoldingsCostLedgerStore(
        transactionRepository: repo,
        conversionService: FakeConversionService.fixedRates([eth.id: 4_000]),
        referenceCurrency: aud)
      let first = try await store.ledger()
      let second = try await store.ledger()
      #expect(await repo.fetchCount == 1)   // one build served both calls
      #expect(first == second)
    }

    @Test
    func ledger_isEmpty_whileMigrating() async throws {
      let repo = CountingTransactionRepository(legRows: [row()])
      let store = HoldingsCostLedgerStore(
        transactionRepository: repo,
        conversionService: FakeConversionService.fixedRates([eth.id: 4_000]),
        referenceCurrency: aud, isMigrating: { true })
      #expect(try await store.ledger() == .empty)
      #expect(await repo.fetchCount == 0)   // never queried while gated
    }

    /// (a) manual edit/create/delete — arrives on the `observeAll()` seam
    /// (the app's own GRDB connection). The provider fully rebuilds.
    @Test
    func ledger_rebuilds_afterTransactionEdit() async throws {
      let (changes, continuation) = AsyncStream<[Transaction]>.makeStream()
      let repo = CountingTransactionRepository(legRows: [row()])
      let store = HoldingsCostLedgerStore(
        transactionRepository: repo,
        conversionService: FakeConversionService.fixedRates([eth.id: 4_000]),
        referenceCurrency: aud, transactionChanges: changes)
      _ = try await store.ledger()
      #expect(await repo.fetchCount == 1)

      await repo.setLegRows([row(), row()])         // a transaction mutated
      continuation.yield([])                        // observeAll() fires
      for _ in 0..<1_000 where store.hasCachedLedger { await Task.yield() }
      #expect(store.hasCachedLedger == false)       // invalidated (full rebuild pending)

      _ = try await store.ledger()
      #expect(await repo.fetchCount == 2)           // rebuilt from scratch, not stale
    }

    /// (b) sync/import write through a *separate* GRDB connection —
    /// `observeAll()` never fires for it (`AccountGroupStore.swift:35-42`);
    /// the import backstop is the instrument-registry `observeChanges()` seam
    /// an import always pings. The provider must rebuild off *that* seam too.
    @Test
    func ledger_rebuilds_afterSeparateConnectionImport() async throws {
      let (instrumentChanges, continuation) = AsyncStream<Void>.makeStream()
      let repo = CountingTransactionRepository(legRows: [row()])
      let store = HoldingsCostLedgerStore(
        transactionRepository: repo,
        conversionService: FakeConversionService.fixedRates([eth.id: 4_000]),
        referenceCurrency: aud, instrumentChanges: instrumentChanges)
      _ = try await store.ledger()
      #expect(await repo.fetchCount == 1)

      await repo.setLegRows([row(), row()])         // import committed on its own connection
      continuation.yield(())                        // observeChanges() (import backstop) fires
      for _ in 0..<1_000 where store.hasCachedLedger { await Task.yield() }
      #expect(store.hasCachedLedger == false)       // invalidated

      _ = try await store.ledger()
      #expect(await repo.fetchCount == 2)           // rebuilt — import reflected, not stale
    }
  }
  ```
  Run `just test-mac HoldingsCostLedgerStore` — expect **compile failure** (`HoldingsCostLedgerStore` missing).

  **Test expressibility.** Both invalidation tests are fully expressible at the unit level with the actor stub + the two injected `AsyncStream`s — no real backend needed, because the provider's contract *is* "rebuild when either seam fires." That an in-app import through a separate `DatabaseQueue` genuinely pings `observeChanges()` (and that a manual edit genuinely fires `observeAll()`) is a repository/import-layer guarantee already covered by the #1149 regression suites (`MoolahTests/Features/Accounts/AccountGroupStoreSyncRefreshTests.swift`, `AccountGroupStoreRegistryRefreshTests.swift`); this task only asserts the provider reacts to those seams.

- [ ] **Step 2: Implement `HoldingsCostLedgerStore`.** Cache + single-flight + supersession-guarded **full rebuild** on the import-inclusive dual change seam, mirroring `CryptoTokenStore`'s observation task and nonisolated deinit cancel. `build()` is `nonisolated` so the fold runs off the main actor (it only hops the conversion actor for conversions). **Full rebuild, never incremental:** any data change drops the whole cached ledger and the next `ledger()` re-runs the SQL query + FIFO pass from scratch — there is no incremental recompute (FIFO across accounts makes partial patching unsafe). Create `Shared/HoldingsCostLedgerStore.swift`:
  ```swift
  import Foundation

  /// Profile-scoped provider for the profile-wide `HoldingsCostLedger`.
  ///
  /// Builds the ledger **once per data load** from the SQL key-event query
  /// (`fetchCostBasisEventLegs` — only non-fiat-touching transactions leave
  /// SQLite) and caches it; concurrent callers during a build share the
  /// single in-flight build. Returns `.empty` while
  /// `isMigratingCrossChainIdentity` (lots may still be split across retired
  /// + canonical ids).
  ///
  /// **Invalidation is a full rebuild on the import-inclusive dual seam.**
  /// Two streams both drop the cache: (a) `transactionChanges` =
  /// `repository.observeAll()` — the app's own GRDB connection, catching
  /// manual creates/edits/deletes; and (b) `instrumentChanges` =
  /// `instrumentChangeObserver.observeChanges()` — the **import/sync
  /// backstop**. An in-app import holds its *own* `DatabaseQueue` over the
  /// same file, so its writes never fire `observeAll()`; the importer always
  /// pings the instrument-registry stream before its per-profile write, so
  /// wiring both seams is the same belt-and-suspenders fix #1149 gave
  /// `AccountGroupStore` (`Features/Accounts/AccountGroupStore.swift:35-42`)
  /// — and the fix the un-wired `CategoryStore` still lacks. Not invalidated
  /// on rate ticks — the value-line batch-conversion path is unchanged.
  ///
  /// **Supersession, not stacking.** A monotonic `generation` (mirroring
  /// `AccountGroupStore.snapshotGeneration:53` / `ReportingStore.reportGeneration`)
  /// is bumped on every `invalidate()`. A build captures the generation it
  /// started under and refuses to publish its result if a later invalidate
  /// superseded it, so a burst of sync ticks coalesces to a single rebuild
  /// rather than stacking N — the single-flight discipline the analysis
  /// reload-storm fix (#1164) established.
  @MainActor
  final class HoldingsCostLedgerStore {
    private nonisolated let transactionRepository: any TransactionRepository
    private nonisolated let conversionService: any InstrumentConversionService
    private nonisolated let referenceCurrency: Instrument
    private nonisolated let isMigrating: @Sendable () -> Bool

    private var cached: HoldingsCostLedger?
    private var buildTask: Task<HoldingsCostLedger, any Error>?
    private var observationTask: Task<Void, Never>?
    /// Bumped on every `invalidate()`; a build that started under an older
    /// value drops its (now-stale) result instead of caching it.
    private var generation: UInt64 = 0

    var hasCachedLedger: Bool { cached != nil }

    init(
      transactionRepository: any TransactionRepository,
      conversionService: any InstrumentConversionService,
      referenceCurrency: Instrument,
      isMigrating: @escaping @Sendable () -> Bool = { false },
      transactionChanges: AsyncStream<[Transaction]>? = nil,
      instrumentChanges: AsyncStream<Void>? = nil
    ) {
      self.transactionRepository = transactionRepository
      self.conversionService = conversionService
      self.referenceCurrency = referenceCurrency
      self.isMigrating = isMigrating
      guard transactionChanges != nil || instrumentChanges != nil else { return }
      self.observationTask = Task { [weak self] in
        await withTaskGroup(of: Void.self) { group in
          if let transactionChanges {
            group.addTask { for await _ in transactionChanges { await self?.invalidate() } }
          }
          if let instrumentChanges {
            group.addTask { for await _ in instrumentChanges { await self?.invalidate() } }
          }
        }
      }
    }

    /// The profile-wide ledger: `.empty` while migrating, the cached instance
    /// if valid, otherwise built once. Concurrent callers during a build
    /// await the same `buildTask`. If an `invalidate()` supersedes the build
    /// mid-flight, the stale result is dropped and a fresh build is issued —
    /// the cache is never written behind a newer generation.
    func ledger() async throws -> HoldingsCostLedger {
      if isMigrating() { return .empty }
      if let cached { return cached }
      if let inFlight = buildTask { return try await inFlight.value }
      let requested = generation
      let task = Task { try await self.build() }
      buildTask = task
      let built = try await task.value            // throws if a burst cancelled it
      guard requested == generation else {         // superseded → don't cache; rebuild
        return try await ledger()
      }
      cached = built
      buildTask = nil
      return built
    }

    /// Full-rebuild invalidation: bumps the generation, drops the cached
    /// ledger, and cancels any in-flight build. The next `ledger()` re-runs
    /// the SQL query + FIFO pass from scratch. Called from both change-stream
    /// drains (edit seam + import backstop).
    func invalidate() {
      generation &+= 1
      cached = nil
      buildTask?.cancel()
      buildTask = nil
    }

    private nonisolated func build() async throws -> HoldingsCostLedger {
      let legRows = try await transactionRepository.fetchCostBasisEventLegs()
      return try await HoldingsCostLedger.build(
        legRows: legRows, referenceCurrency: referenceCurrency,
        conversionService: conversionService)
    }

    deinit {
      // Same reasoning as `CryptoTokenStore`: the only deallocation path is
      // `ProfileSession` (`@MainActor`) releasing its last strong reference on
      // the main actor, so the isolation assumption holds.
      MainActor.assumeIsolated { observationTask?.cancel() }
    }
  }
  ```
  Run `just test-mac HoldingsCostLedgerStore` — expect **all pass**. Run `@concurrency-review` (the `nonisolated build`, the task-group drain, the deinit cancel) + `@code-review`, `just format`, commit: `feat(cost-basis): add cached SQL-sourced HoldingsCostLedgerStore`.

- [ ] **Step 3: Own the provider on `ProfileSession` and inject it into the stores.** In `App/ProfileSession+Factories.swift`, add `let holdingsCostLedger: HoldingsCostLedgerStore` to `DomainStores`, construct it in `makeDomainStores` from the backend seams + migration guard, and pass it to `InvestmentStore` and `ReportingStore`:
  ```swift
  let holdingsCostLedger = HoldingsCostLedgerStore(
    transactionRepository: backend.transactions,
    conversionService: backend.conversionService,
    referenceCurrency: profile.instrument,
    isMigrating: { !UnifiedInstrumentIdentityMigration.isComplete() },
    transactionChanges: backend.transactions.observeAll(filter: TransactionFilter()),
    instrumentChanges: instrumentChanges?.observeChanges())
  let investment = InvestmentStore(
    repository: backend.investments,
    transactionRepository: backend.transactions,
    conversionService: backend.conversionService,
    instrumentChanges: instrumentChanges,
    instrumentRegistry: backend.instrumentRegistry,
    holdingsCostLedger: holdingsCostLedger)
  let reporting = ReportingStore(
    transactionRepository: backend.transactions,
    analysisRepository: backend.analysis,
    conversionService: backend.conversionService,
    profileCurrency: profile.instrument,
    holdingsCostLedger: holdingsCostLedger)
  ```
  Add `holdingsCostLedger` to the `DomainStores(...)` initialiser. In `App/ProfileSession.swift` add `let holdingsCostLedgerStore: HoldingsCostLedgerStore` and assign it from `stores.holdingsCostLedger`. Wiring **both** seams is deliberate and load-bearing: `transactionChanges: backend.transactions.observeAll(filter:)` catches manual edits on the app's own connection, and `instrumentChanges: instrumentChanges?.observeChanges()` is the import/sync backstop for separate-connection writes `observeAll()` cannot see — the exact pairing #1149 gave `AccountGroupStore` (`Domain/Repositories/BackendProvider.swift:47`, `Domain/Repositories/InstrumentChangeObserving.swift:17`). (`instrumentChanges` is the `backend.instrumentChangeObserver` already bound in `makeDomainStores`; `observeChanges()` is `@MainActor` and `makeDomainStores` is `@MainActor`-isolated, so the call is in-context.) Run `just build-mac` — fix construction sites.

- [ ] **Step 4: Add the injected refs on the two stores.** In `Features/Investments/InvestmentStore.swift` add `holdingsCostLedger: HoldingsCostLedgerStore` to `init` and store it as a `let` (used in Task 6). In `Features/Reports/ReportingStore.swift` add `holdingsCostLedger: HoldingsCostLedgerStore` to `init` and store it (used in Step 8 below). Update every other `InvestmentStore(...)`/`ReportingStore(...)` construction site (tests, previews) to pass a provider (construct a `HoldingsCostLedgerStore` over a stub repo). Run `just build-mac` + `just test-mac InvestmentStore ReportingStore` — expect **clean build, suite green**. Run reviewers, `just format`, commit: `feat(cost-basis): own HoldingsCostLedgerStore on ProfileSession and inject into stores`.

- [ ] **Step 5: Failing test — a received (income) crypto lot, later sold, realises a gain.** Add to `CapitalGainsCalculatorTests`:
  ```swift
  @Test
  func receivedCrypto_thenSold_realisesGainFromMarketValueCostBase() async throws {
    let eth = cryptoInstrument("ETH")
    let account = UUID()
    let received = LegTransaction(
      date: date(0),
      legs: [TransactionLeg(accountId: account, instrument: eth, quantity: 1, type: .income)])
    let sold = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(accountId: account, instrument: aud, quantity: 6_000, type: .trade),
        TransactionLeg(accountId: account, instrument: eth, quantity: -1, type: .trade)])
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [received, sold], profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]))  // receipt @ 4000
    // Cost base = market value on receipt (4000); proceeds = 6000 → gain 2000, long-term.
    #expect(result.events.count == 1)
    #expect(result.events[0].costBasis == 4_000)
    #expect(result.events[0].proceeds == 6_000)
    #expect(result.events[0].gain == 2_000)
    #expect(result.events[0].isLongTerm == true)
  }
  ```
  Run — expect **fail** (today income contributes 0 lots → the sell finds nothing → no event / wrong cost base).

- [ ] **Step 6: Split `CapitalGainsCalculator` into a pure `compute(ledger:)` entry + a ledger-building wrapper.** In `Shared/CapitalGainsCalculator.swift`:
  ```swift
  /// Pure realised-CGT projection from a pre-built profile-wide ledger.
  /// `ReportingStore` passes the shared ledger so the tax path does not
  /// rebuild it.
  static func compute(
    ledger: HoldingsCostLedger, sellDateRange: ClosedRange<Date>? = nil
  ) -> CapitalGainsResult {
    let events = ledger.realisedEvents.filter {
      sellDateRange.map { range in range.contains($0.sellDate) } ?? true
    }
    return CapitalGainsResult(events: events, openLots: ledger.openLots)
  }

  /// Retained convenience for unit-test call sites: builds a ledger from
  /// `LegTransaction`s then projects. Production (`ReportingStore`) uses
  /// `compute(ledger:)` with the shared `HoldingsCostLedgerStore` ledger.
  static func computeWithConversion(
    transactions: [LegTransaction], profileCurrency: Instrument,
    conversionService: any InstrumentConversionService,
    sellDateRange: ClosedRange<Date>? = nil
  ) async throws -> CapitalGainsResult {
    let txns = transactions.map { Transaction(date: $0.date, legs: $0.legs) }
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: profileCurrency, conversionService: conversionService)
    return compute(ledger: ledger, sellDateRange: sellDateRange)
  }
  ```
  (Confirm `CapitalGainsResult(events:openLots:)`'s exact initialiser against the current type; adapt if it derives `openLots` differently.) Run `just test-mac CapitalGainsCalculator` — expect Step-5 **pass**; other cases likely need value updates (Step 7).

- [ ] **Step 7: Deliberately update the changed CGT expectations.** Re-run the full `CapitalGains*` suites; for each failure, hand-verify the new number against the model (income/opening/expense now realise; transfers do not) and update the `#expect` with a one-line comment citing why (e.g. `// income-funded lot now has a market-value cost base`). Do NOT delete cases to make them pass. Run `just test-mac CapitalGainsCalculator` — expect **all pass**.

- [ ] **Step 8: Failing test + reconcile `ProfitLossCalculator.totalInvested`.** Add to `ProfitLossCalculatorTests`:
  ```swift
  @Test
  func totalInvested_includesReceivedCryptoAtMarketValue() async throws {
    let eth = cryptoInstrument("ETH")
    let account = UUID()
    let txns = [LegTransaction(
      date: date(0),
      legs: [TransactionLeg(accountId: account, instrument: eth, quantity: 1, type: .income)])]
    let results = try await ProfitLossCalculator.compute(
      transactions: txns, profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]), asOfDate: date(10))
    let row = try #require(results.first { $0.instrument == eth })
    #expect(row.totalInvested == 4_000)  // was 0 under the fiat-only accumulate
  }
  ```
  Run — expect **fail**. Then split `compute` into a pure `compute(ledger: HoldingsCostLedger, asOfDate: Date) -> [InstrumentProfitLoss]` plus a thin `compute(transactions:profileCurrency:conversionService:asOfDate:)` wrapper (mirroring Step 6). Derive `totalInvested` per instrument from `ledger.flows` (acquisition flows: `counterpartyAccount == nil && amount > 0`, attributed by `entry.instrument`), and read `ledger.realisedEvents` / `ledger.openLots` for the rest (build the ledger once; drop the internal `CapitalGainsCalculator.computeWithConversion` call):
  ```swift
  static func compute(ledger: HoldingsCostLedger, asOfDate: Date) -> [InstrumentProfitLoss] {
    var investedByInstrument: [String: Decimal] = [:]
    for entry in ledger.flows where entry.counterpartyAccount == nil && entry.amount > 0 {
      investedByInstrument[entry.instrument.id, default: 0] += entry.amount
    }
    // ... assemble rows from ledger.openLots + investedByInstrument + realisedEvents ...
  }
  ```
  Run `just test-mac ProfitLossCalculator CapitalGainsCalculator` — expect **all pass** (update any deliberately-changed P&L expectation per Step 7's discipline). Run `@instrument-conversion-review` + `@code-review`, `just format`, commit: `refactor(cost-basis): drive realised CGT and totalInvested from HoldingsCostLedger`.

- [ ] **Step 9: Source the shared ledger in `ReportingStore`; retire `loadAllLegTransactions()`.** In `Features/Reports/ReportingStore.swift`, `loadCapitalGains` / `loadProfitLoss` obtain the profile-wide ledger from the injected `holdingsCostLedger` and call the pure entries — one build now serves both, cached across a load and shared with the positions/performance passes:
  ```swift
  // loadProfitLoss:
  let ledger = try await holdingsCostLedger.ledger()
  let result = ProfitLossCalculator.compute(ledger: ledger, asOfDate: Date())
  guard generation == reportGeneration else { return }
  profitLoss = result

  // loadCapitalGains (after the FY range is computed):
  let ledger = try await holdingsCostLedger.ledger()
  let result = CapitalGainsCalculator.compute(ledger: ledger, sellDateRange: fyStart...fyEnd)
  ```
  Keep the existing `reportGeneration` bump-then-capture guard around each publish (the `ledger()` fetch is a suspension point — re-check the captured generation before writing). Keep the `isMigratingCrossChainIdentity` early-return at the top of `loadCapitalGains` (belt-and-suspenders with the provider's own gate). **Delete `loadAllLegTransactions()`** — it now has no caller. Run `just test-mac ReportingStore` — expect **pass** (update any expectation that assumed the old `.trade`-only realised set, per Step 7's discipline). Run reviewers, `just format`, commit: `refactor(reports): source realised CGT / P&L from the shared HoldingsCostLedger; retire loadAllLegTransactions`.

---

## Task 5 — `PositionsHistoryBuilder` baseline cutover + retire `contributions`

The builder stops running its own engine + folding contributions; it reads remaining amount invested from the shared ledger. `Point.contributions` → `Point.invested`. Single suppression rule stays (both modes: show iff remaining invested non-zero).

**Files**
- Modify: `Domain/Models/HistoricalValueSeries.swift`
- Modify: `Shared/PositionsHistoryBuilder.swift`, `Shared/PositionsHistoryBuilder+Batch.swift`
- Modify: `Shared/MultiInstrumentPositionsAssembler.swift` — `assemble` accepts the shared `ledger:` (no longer builds its own).
- Modify: `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift` — obtain the shared ledger from `session.holdingsCostLedgerStore.ledger()` and pass it to `assembler.assemble`.
- Modify: `Shared/Views/Positions/PositionsChartBaselineResolver.swift`, `PositionsChartMode.swift`, `PositionsChart.swift`
- Modify tests: `PositionsHistoryBuilderTests.swift`, `PositionsHistoryBuilderBatchTests.swift`, `PositionsHistoryBuilderCashTests.swift`, `PositionsHistoryBuilderMultiAccountTests.swift`, `PositionsHistoryBuilderZoneTests.swift`, and any `PositionsChartBaselineResolver` test.

**Interfaces**
- Consumes: `HoldingsCostLedger.remainingInvested(accountIds:onOrBefore:)`, `HoldingsCostLedger.remainingInvested(accountIds:instrument:onOrBefore:)` (Task 3); `HoldingsCostLedgerStore.ledger()` (Task 4, at the split-modifier call site).
- Produces:
  - `HistoricalValueSeries.Point(date:value:cost:invested:)` — `invested: Decimal?` replaces `contributions`.
  - `PositionsHistoryBuilder.build(transactions: [Transaction], accountIds: Set<UUID>, hostCurrency: Instrument, range: PositionsTimeRange, ledger: HoldingsCostLedger, now: Date = Date()) async -> HistoricalValueSeries` (+ single-account overload with `ledger:`). `transactions` is the **viewed** subset (drives the quantity fold); `ledger` is the **profile-wide** ledger (drives `invested`, queried per viewed account).
  - `MultiInstrumentPositionsAssembler.assemble(context:valuedRows:transactions:range:ledger:now:)` — `ledger:` added; the assembler no longer builds one.

**Steps**

- [ ] **Step 1: Rename `Point.contributions` → `Point.invested`.** Edit `HistoricalValueSeries.swift`: rename the field and its doc-comment ("Aggregate remaining amount invested for the account set in `hostCurrency`; `nil` = not applicable (per-instrument) or unavailable (Rule 11)"). Update `series(forInstrumentIds:)` to pass `invested: nil`. Run `just build-mac` — expect **compile errors** at every `contributions:` call site; fix mechanically in the next steps. This is the driver for the rename.

- [ ] **Step 2: Failing test — builder baseline reads the ledger's remaining invested.** Update a representative `PositionsHistoryBuilderTests` case (or add one) that funds an account by `.income` crypto and asserts the aggregate baseline follows remaining invested, not contributions:
  ```swift
  @Test
  func aggregateBaseline_followsLedgerRemainingInvested() async throws {
    let eth = Instrument.crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "ETH", decimals: 18)
    let a = UUID()
    let txns = [Transaction(
      date: day(0), legs: [TransactionLeg(accountId: a, instrument: eth, quantity: 1, type: .income)])]
    let service = FakeConversionService.fixedRates([eth.id: 4_000])
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: .AUD, conversionService: service)
    let series = await PositionsHistoryBuilder(conversionService: service).build(
      transactions: txns, accountIds: [a], hostCurrency: .AUD,
      range: .all, ledger: ledger, now: day(5))
    #expect(series.total.last?.invested == 4_000)  // received lot at market value
  }
  ```
  Run — expect **compile failure** (`build` has no `ledger:` parameter).

- [ ] **Step 3: Thread the ledger into `build`; drop the engine + contributions fold.** In `PositionsHistoryBuilder.swift`:
  - Add `ledger: HoldingsCostLedger` to both `build` overloads (single-account forwards it).
  - Store `ledger` on `BuildContext`.
  - Delete `BuildState.engine`, `BuildState.contributions`, the whole `foldContributions` extension, and the `TradeEventClassifier.classify` block in `apply` (quantities-only fold remains). `apply` becomes non-throwing except cancellation and no longer touches cost.
  Run `just build-mac` — cost/invested recording now moves to `+Batch` (Step 4).

- [ ] **Step 4: Record `cost`/`invested` from the ledger in the batch pass.** In `PositionsHistoryBuilder+Batch.swift`:
  - `recordDailyPoints(for:state:)` gains the `accountIds`/`ledger` it needs; for each held instrument set `cost = ledger.remainingInvested(accountIds:instrument:onOrBefore: day)`; for the day set `invested = ledger.remainingInvested(accountIds:onOrBefore: day)`.
  - `PendingDay.contributions` → `PendingDay.invested`.
  - `assemble` writes `HistoricalValueSeries.Point(date:value:cost:invested:)`, using `pendingDay.invested` on the aggregate point and `entry.cost` on the per-instrument points.
  ```swift
  func recordDailyPoints(
    for day: Date, state: BuildState, accountIds: Set<UUID>, ledger: HoldingsCostLedger
  ) -> PendingDay {
    let pointDate = Calendar.utc.date(byAdding: .hour, value: 12, to: day) ?? day
    var entries: [PendingEntry] = []
    for (instrument, qty) in state.quantities where qty != 0 {
      let cost = ledger.remainingInvested(accountIds: accountIds, instrument: instrument, onOrBefore: day)
      entries.append(PendingEntry(instrument: instrument, quantity: qty, cost: cost))
    }
    let invested = ledger.remainingInvested(accountIds: accountIds, onOrBefore: day)
    return PendingDay(day: day, pointDate: pointDate, invested: invested, entries: entries)
  }
  ```
  Run `just test-mac PositionsHistoryBuilder` — expect Step-2 **pass**; fix other builder tests (they no longer see `contributions`; update to `invested` and the new baseline semantics — a fiat-only account now has `invested == 0`). The `PositionsHistoryBuilderCashTests` "fiat contributions" cases become "fiat → invested 0 → suppressed" cases.

- [ ] **Step 5: Accept the shared ledger in `assemble`; obtain it from the provider at the call site.** `MultiInstrumentPositionsAssembler.assemble` takes `ledger:` as a parameter (built once, profile-wide) and threads it into the history build; keep `costBasisSnapshot` as-is. It does **not** build its own ledger — that would re-derive it per view from the *viewed* subset, which cannot see a transfer's source lots.
  ```swift
  func assemble(
    context: PositionsAssemblyContext, valuedRows: [ValuedPosition],
    transactions: [Transaction], range: PositionsTimeRange,
    ledger: HoldingsCostLedger, now: Date = Date()
  ) async -> PositionsViewInput {
    let series = await PositionsHistoryBuilder(conversionService: conversionService).build(
      transactions: transactions, accountIds: context.accountIds, hostCurrency: context.hostCurrency,
      range: range, ledger: ledger, now: now)
    // ... unchanged concurrent costBasisSnapshot ...
  }
  ```
  In `MultiInstrumentPositionsSplitModifier.buildHistoryInput`, obtain the **profile-wide** ledger from the environment session's provider (built once per load, cached) and pass it to `assemble` alongside the already-fetched viewed `txns`:
  ```swift
  let ledger = (try? await session?.holdingsCostLedgerStore.ledger()) ?? .empty
  let input = await assembler.assemble(
    context: context, valuedRows: valuedRows, transactions: txns, range: range, ledger: ledger)
  ```
  (If the provider's build is unavailable, `.empty` degrades to no baseline rather than a partial sum — Rule 11.) The same `ledger` local is reused by the performance pass in Task 6, so the profile-wide ledger is fetched exactly once per view. Run `just build-mac`.

- [ ] **Step 6: Update the resolver + mode doc + chart to `invested`.** In `PositionsChartBaselineResolver.swift`, `showsBaseline`/`resolve` read `point.invested` for `.aggregate` (unchanged logic, renamed field). In `PositionsChartMode.swift` update the doc comment ("`invested` for aggregate — remaining amount invested — `cost` for per-instrument"). In `PositionsChart.swift` replace the two `point.contributions` reads (lines ~313, ~348) with `point.invested`. Run `just test-mac PositionsChartBaselineResolver PositionsHistoryBuilder` — expect **all pass**. Run reviewers (`@datetime-review` on the noon-UTC `pointDate` + start-of-day query, `@concurrency-review` on the `@concurrent build`), `just format`, commit: `refactor(positions): drive chart baseline from HoldingsCostLedger remaining invested`.

> `AccountCashFlows` is still referenced by `AccountPerformanceCalculator` at this point, so the file stays until Task 6. This task only removes the builder's use of it (`foldContributions`).

---

## Task 6 — Return / IRR cutover in `AccountPerformanceCalculator`

Money-weighted return flows come from the ledger's market-valued flows (received tokens = inflow at market), so self-custody wallets get a finite IRR. Retire `AccountCashFlows`.

**Files**
- Modify: `Shared/AccountPerformanceCalculator.swift`
- Modify: `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`, `Features/Investments/InvestmentStore+Positions.swift`
- Delete: `Shared/AccountCashFlows.swift`, `MoolahTests/Shared/AccountCashFlowsTests.swift`
- Modify tests: `AccountPerformanceCalculatorTests.swift`, `AccountPerformanceCalculatorMultiInstrumentTests.swift`, `AccountPerformanceEdgeCaseTests.swift`, `AccountPerformanceInvestmentEquivalenceTests.swift`

**Interfaces**
- Consumes: `HoldingsCostLedger.cashFlows(accountIds:)` (Task 3), `HoldingsCostLedgerStore.ledger()` (Task 4, at the two call sites), `IRRSolver.annualisedReturn`, `AccountPerformance`, `CashFlow`.
- Produces:
  - `AccountPerformanceCalculator.computeMultiInstrument(accountIds: Set<UUID>, valuedPositions: [ValuedPosition], profileCurrency: Instrument, ledger: HoldingsCostLedger, now: Date = Date()) async throws -> AccountPerformance` (transactions/conversionService drop out — flows come from the ledger).
  - `AccountPerformanceCalculator.compute(accountId: UUID, valuedPositions: [ValuedPosition], profileCurrency: Instrument, ledger: HoldingsCostLedger, now: Date = Date()) async throws -> AccountPerformance`.

**Steps**

- [ ] **Step 1: Failing test — a self-custody wallet funded by receives yields a finite IRR.** Add to `AccountPerformanceCalculatorMultiInstrumentTests`:
  ```swift
  @Test
  func selfCustodyWallet_receivesOnly_hasFiniteReturn() async throws {
    let eth = Instrument.crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "ETH", decimals: 18)
    let a = UUID()
    let service = FakeConversionService.fixedRates([eth.id: 4_000])
    let txns = [Transaction(
      date: day(-400), legs: [TransactionLeg(accountId: a, instrument: eth, quantity: 1, type: .income)])]
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: .AUD, conversionService: service)
    let rows = [ValuedPosition(
      instrument: eth, quantity: 1, unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: 6_000, instrument: .AUD), accountChainId: nil)]
    let performance = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [a], valuedPositions: rows, profileCurrency: .AUD, ledger: ledger, now: day(0))
    #expect(performance.currentValue == InstrumentAmount(quantity: 6_000, instrument: .AUD))
    #expect(performance.totalContributions == InstrumentAmount(quantity: 4_000, instrument: .AUD))
    #expect(performance.annualisedReturn != nil)   // was nil under the old contributions path
  }
  ```
  Run — expect **compile failure** (`computeMultiInstrument` still takes `transactions:conversionService:`).

- [ ] **Step 2: Cut the flow source over to the ledger.** In `AccountPerformanceCalculator.swift` replace `extractGroupFlows`/`extractFlows` with `ledger.cashFlows(accountIds:)`, and change the two public signatures to take `ledger:` instead of `transactions:`/`conversionService:`. `assemble` and the degraded-shape logic are unchanged (empty flows → `.currentValueOnly`, etc.):
  ```swift
  static func computeMultiInstrument(
    accountIds: Set<UUID>, valuedPositions: [ValuedPosition],
    profileCurrency: Instrument, ledger: HoldingsCostLedger, now: Date = Date()
  ) async throws -> AccountPerformance {
    let currentValue = aggregatedValue(of: valuedPositions, in: profileCurrency)
    let flows = ledger.cashFlows(accountIds: accountIds)
    guard !flows.isEmpty else { return .currentValueOnly(currentValue, in: profileCurrency) }
    return assemble(flows: flows, currentValue: currentValue, profileCurrency: profileCurrency, now: now)
  }
  ```
  Do the same for `compute(accountId:...)` (single-element set: `ledger.cashFlows(accountIds: [accountId])`). Delete `extractFlows`, `extractGroupFlows`. `computeLegacy` (manual valuation, no ledger) is untouched. Run `just build-mac` — expect **compile errors** at the two production call sites → Steps 3–4.

- [ ] **Step 3: Thread the shared ledger at the multi-instrument call site.** In `MultiInstrumentPositionsSplitModifier`, reuse the **same profile-wide ledger** already obtained from the provider in Task 5 Step 5 (`let ledger = (try? await session?.holdingsCostLedgerStore.ledger()) ?? .empty`) — do **not** build a second one from the viewed `txns`. Pass that `ledger` to both `assembler.assemble` (Task 5) and the performance call:
  ```swift
  return try await AccountPerformanceCalculator.computeMultiInstrument(
    accountIds: accountIds, valuedPositions: rows, profileCurrency: hostCurrency,
    ledger: ledger, now: Date())
  ```
  Update `computePerformance`'s parameter list to take the shared `ledger` rather than `transactions:`/`conversionService:`.

- [ ] **Step 4: Thread the ledger at the position-tracked call site.** In `InvestmentStore+Positions.refreshPositionTrackedPerformance`, get the shared ledger from the injected provider instead of building one from the per-account `txns`, then pass it to `AccountPerformanceCalculator.compute`:
  ```swift
  let ledger = try await holdingsCostLedger.ledger()
  let performance = try await AccountPerformanceCalculator.compute(
    accountId: accountId, valuedPositions: valuedPositions, profileCurrency: profileCurrency,
    ledger: ledger, now: Date())
  ```
  Keep the `snapshotGeneration` guard around `setAccountPerformance` (the `ledger()` fetch is another suspension point — re-check the captured generation before publishing). Run `just build-mac` — expect **clean build**.

- [ ] **Step 5: Delete `AccountCashFlows` + its tests; update performance tests.** Remove `Shared/AccountCashFlows.swift` and `MoolahTests/Shared/AccountCashFlowsTests.swift`. Update the performance suites to construct a `HoldingsCostLedger` instead of passing transactions+service; where a test asserted the old contributions-derived `totalContributions`, update to the market-valued flow total and add a one-line comment. Run `just test-mac AccountPerformance HoldingsCostLedger` — expect Step-1 **pass** and **all** performance suites green. Run reviewers, `just format`, commit: `refactor(performance): derive money-weighted return from HoldingsCostLedger; retire AccountCashFlows`.

---

## Task 7 — UI relabelling + baseline-suppression copy

Rename user-facing copy to "Amount invested" / "Gain" / "Return"; the legend's two labels converge. No new logic — the suppression rule already lives in the resolver (Task 5).

**Files**
- Modify: `Shared/Views/Positions/PositionsChartLegendRow.swift`
- Modify: `Shared/Views/Positions/AccountPerformanceTiles.swift`, `AccountPerformanceTileLabels.swift`
- Modify tests: `MoolahTests/Shared/AccountPerformanceTileLabelsTests.swift`

**Interfaces**
- Consumes: `AccountPerformance`, `PositionsChartRenderRow`, `PositionsChartMode` (unchanged).
- Produces: no new API — copy-only, plus label-helper strings the tile-label tests assert.

**Steps**

- [ ] **Step 1: Failing test — invested subtitle reads "Amount invested".** In `AccountPerformanceTileLabelsTests`, update/add:
  ```swift
  @Test
  func investedSubtitle_usesAmountInvestedCopy() {
    let perf = AccountPerformance(
      instrument: .AUD, currentValue: InstrumentAmount(quantity: 10, instrument: .AUD),
      totalContributions: InstrumentAmount(quantity: 8, instrument: .AUD),
      profitLoss: InstrumentAmount(quantity: 2, instrument: .AUD),
      profitLossPercent: nil, annualisedReturn: nil, firstFlowDate: Date())
    #expect(AccountPerformanceTileLabels.investedSubtitleText(perf)?.hasPrefix("Amount invested") == true)
  }
  ```
  Run — expect **fail** (current copy is `"Invested \(...)"`).

- [ ] **Step 2: Relabel the tile-label helper.** In `AccountPerformanceTileLabels.swift` change `"Invested \(contributions.formatted)"` → `"Amount invested \(contributions.formatted)"`, `"Invested —"` → `"Amount invested —"`, and the accessibility "Invested:" fragments → "Amount invested:". Run `just test-mac AccountPerformanceTileLabels` — expect **pass**.

- [ ] **Step 3: Relabel the tiles.** In `AccountPerformanceTiles.swift`: `Tile(label: "Profit / Loss")` → `Tile(label: "Gain")`; `Tile(label: "Annualised Return")` → `Tile(label: "Return")`; update the P/L and return accessibility labels ("Profit and Loss" → "Gain", "Annualised Return" → "Return") and the `sinceText`/tooltip copy to match. (Keep the sign/`%` formatting and colour logic.) Verify with `mcp__xcode__RenderPreview` on the existing `#Preview`s per `reviewing-ui-with-preview` (do NOT launch the app).

- [ ] **Step 4: Converge the legend labels.** In `PositionsChartLegendRow.swift` replace `let baselineLabel = (mode == .aggregate) ? "Invested amount" : "Cost basis"` with `let baselineLabel = "Amount invested"` (both modes now mean the same quantity). Keep the `showBaseline` gating and the dashed-line accessibility cue. Run `just build-mac`, run `@ui-review` + `@help-review` (brand voice: plain-spoken, no "cost basis" in UI), `just format`, commit: `feat(positions): relabel baseline/tiles to Amount invested, Gain, Return`.

- [ ] **Step 5: Full-suite regression + final review.** Run `just test-mac` (whole suite) and `just format-check`. Confirm the spec's Testing matrix is all green: fiat→no baseline, negative-contributions crypto→baseline ≥ 0, received/airdrop lot at market, opening-balance lot at market with `acquiredDate` = opening date, transfer `moveLots` preserves cost+date with no realised gain, crypto-fee disposal no double-count, external `.expense` disposal, self-custody finite IRR, realised-CGT totals updated. Run every relevant `@`-reviewer once more on the full diff; fix findings; commit any fixups.

---

## Self-review — spec coverage, placeholders, name consistency

- **Spec coverage.** Single definition + event model → Task 2 (`CostBasisEventBuilder`) & Task 1 (`moveLots`). Account-aware engine → Task 1. **SQL-sourced key-event query (only non-fiat-touching transactions leave SQLite) + `HoldingsCostLedger` FIFO pass with one batched `(instrument, day)` conversion + three change-point outputs → Task 3.** Crypto-to-crypto (unchanged) → reused `TradeEventClassifier` in Task 2 Step 3. Fees/incidental + crypto-fee disposal → Task 2 Steps 3–4. Cached profile-wide provider (built once per load from the SQL query, invalidated on transaction/instrument change, `.empty` while migrating) → Task 4 (`HoldingsCostLedgerStore`). Derived surfaces: value line unchanged (Task 5 keeps the per-viewed-account quantity fold + batch conversion); baseline → Task 5; gain/return tiles → Tasks 6–7; realised CGT / P&L → Task 4 (consuming the shared ledger, replacing `loadAllLegTransactions`). Baseline suppression single rule → Task 5 Step 6. Return works for self-custody → Task 6 Step 1. Transfer nuance (cost carries, market for IRR; needs the source account's lots present, hence the profile-wide ledger) → Task 3 (`move` records both) + `cashFlows` netting + Task 4 profile-wide provider. Terminology → Task 7. Policy decisions (opening = market on opening date; external moves ATO-strict; AUD reference) → Task 2 event mapping.
- **SQL sourcing & performance.** The heavy lifting is in SQL: `fetchCostBasisEventLegs` (Task 3) filters to only the legs of transactions touching a non-fiat instrument via a `transaction_id IN (… JOIN instrument WHERE kind != 'fiatCurrency')` subquery, ordered `(date, transaction_id, sort_order)`, plan-pinned by an EXPLAIN test (Task 3 Step 4) — the pure-fiat bulk never materialises. Conversions are deduped to distinct `(instrument, day)` pairs and warmed in **one** `convertResultBatch` call, then the classifier + account-aware engine run once. The result is built **once per data load** and cached behind `HoldingsCostLedgerStore` (Task 4), single-flighting concurrent builds and serving the positions, performance, and tax passes from one instance. It invalidates only on the transaction (`observeAll`) and instrument-identity (`observeChanges`) change seams — **not** on rate ticks — and returns `.empty` while `isMigratingCrossChainIdentity`. Retiring `loadAllLegTransactions()` removes the whole-table Swift materialisation from the tax path.
- **No placeholders.** Every code step shows real Swift against the actual signatures found in the tree (`instrumentResolver.instrumentMap()`, `database.read`, `Row.fetchAll(db, sql:)`, `InstrumentAmount(storageValue:instrument:)`, `TransactionType(rawValue:)`, `Instrument.fiat(code:)`, `TransactionRepository.observeAll`, `BackendProvider.instrumentChangeObserver`, `UnifiedInstrumentIdentityMigration.isComplete`, `ProfileSession+Factories.makeDomainStores`, `CryptoTokenStore` observation/deinit, `TradeEventClassifier.classify`, `CostBasisEngine`, `convertResultBatch`/`BatchConversionRequest`, `HistoricalValueSeries.Point`, `AccountPerformance`, `FakeConversionService.fixedRates`, `Calendar.utc`, `PlanPinningTestHelpers`). Signatures verified against the tree: the `"transaction".date` column decodes straight to `Date` via GRDB (`TransactionRow.date: Date`, `Backends/GRDB/Records/TransactionRow.swift:79`) — no formatter; `CapitalGainsResult(events: [CapitalGainEvent], openLots: [CostBasisLot])` (`Shared/CapitalGainsCalculator.swift:10-12,77`); `InstrumentProfitLoss.totalInvested: Decimal` (`Domain/Models/InstrumentProfitLoss.swift:9`), `ProfitLossCalculator.compute(...) -> [InstrumentProfitLoss]` (`Shared/ProfitLossCalculator.swift:7-12`); the import-inclusive change seam is `InstrumentChangeObserving.observeChanges() -> AsyncStream<Void>` (`Domain/Repositories/InstrumentChangeObserving.swift:17`) exposed via `BackendProvider.instrumentChangeObserver` (`Domain/Repositories/BackendProvider.swift:47`), paired with `observeAll()` exactly as #1149 wired `AccountGroupStore` (`Features/Accounts/AccountGroupStore.swift:35-42,84-89`). The one item still to pin empirically is the exact EXPLAIN index names (Task 3 Step 4 — pin what the planner actually emits).
- **Name consistency.** `CostBasisEvent` (acquisition/disposal/move), `CostBasisEventBuilder.events(...)`, `CostBasisEventLegRow`, `fetchCostBasisEventLegs()`, `HoldingsCostLedger.build(legRows:)` / `.build(transactions:)` / `remainingInvested` / `cashFlows` / `openLots` / `.empty`, `HoldingsCostLedgerStore.ledger()`/`invalidate()`/`hasCachedLedger`, `HoldingsFlowEntry` (with `instrument`), `InvestedSnapshot`, `Point.invested`, `build(...ledger:)`, `compute*(...ledger:)` are used identically across every task that references them.
- **Known deviations (intentional, for compile-green PRs).** The spec's 7-step ordering is honoured: (1) engine, (2) event builder + types, (3) SQL key-event query + `HoldingsCostLedger` FIFO pass, (4) cached provider + CGT/`ProfitLoss` cutover, (5) `PositionsHistoryBuilder` baseline cutover, (6) return/IRR + retire `AccountCashFlows`, (7) UI relabelling + regression. The event-value types and the profile-global ledger live in **separate** tasks (2 and 3) so the SQL query and its EXPLAIN test land with the ledger that consumes it. `AccountCashFlows.swift` is physically deleted in **Task 6** (after its last consumer, `AccountPerformanceCalculator`, is cut over), not Task 5 — Task 5 only removes the builder's use of it. Every task leaves the tree building and the suite green.
