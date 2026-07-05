# Unified Account-Detail Layout — Increment 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive the account-level performance computation for the crypto / exchange / standard / group account paths so the `AccountPerformanceTiles` strip (Increment 2 built the slot, but left `input.performance == nil` for these accounts) actually renders. Compute an `AccountPerformance` (current value, contributions, P&L, annualised return) in the unified multi-instrument path and thread it into `PositionsAssemblyContext.performance` — the exact slot `MultiInstrumentPositionsSplitModifier.buildHistoryInput` currently hard-codes to `nil`. Gate the tiles so **fiat-only accounts hide them** (fall back to the plain total header) while accounts with real invested/P&L data (crypto, exchange, mixed groups) show them. Degrade gracefully per Rule 11: a no-cost-basis wallet (transfer-in / airdrop only) shows current value only, with the P&L and return tiles hidden — never a crash, never a phantom zero, never a phantom gain. Investment (`.calculatedFromTrades`) accounts keep their own performance path untouched; Increment 4 folds them in.

**Architecture:** Incremental. This plan fully specifies **Increment 3** — three independent, individually-shippable PRs. It builds on Increments 1 and 2 (denser chart, inline sync-error caption, all-instrument value/balance history, and the unified `PositionsChartTransactionsSplit` tab/split container), which are already implemented on this branch and are treated as present. Increment 4 (fold `.calculatedFromTrades` investment accounts into the shared container + delete the redundant per-type views) gets its own plan. This increment does **not** change the investment `InvestmentStore` performance path, `AccountPerformanceCalculator.compute(accountId:...)`, or the legacy `PositionsTransactionsSplit` container.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, Swift Testing (`@Suite`/`@Test`), XCUITest (`MoolahUITests_macOS`), GRDB (unaffected here). Design spec: `plans/2026-07-05-unified-account-detail-layout-design.md` (§"Data Changes Enabling the Unified Layout" item 2 "Performance for all account types"). Increment 2 plan: `plans/2026-07-05-unified-account-detail-layout-increment-2-plan.md`.

## Global Constraints

- Tests use **Swift Testing** (`@Suite`, `@Test`, `#expect`), not XCTest, except UI tests under `MoolahUITests_macOS/` (XCUITest — those import **only** `XCTest`, drive the app through screen drivers, use 10s positive waits and deterministic seeds).
- One extension per protocol conformance; thin views (logic lives in testable helpers) — `guides/AI_ARCHITECTURE_GUIDE.md`.
- Money math via `InstrumentAmount`; **never `abs()` a signed leg or P&L** — `guides/INSTRUMENT_CONVERSION_GUIDE.md`. Partial-availability = `nil` fields (Rule 11): never a partial sum, a phantom zero, or a phantom gain.
- Timezoneless calendar values via `Calendar.utc`; chart x-tokens anchor at noon-UTC — `guides/DATE_TIME_GUIDE.md`.
- The performance compute is **async** (currency conversions) and runs inside the existing valuator `.task` on `MultiInstrumentPositionsSplitModifier`; honour `Task.isCancelled` guards like the rest of `valuatePositions`/`buildHistoryInput`, and keep every new type `Sendable`.
- `just` test filters are **positional**, not `FILTER=` — e.g. `just test-mac AccountPerformanceCalculatorMultiInstrumentTests`, `just test-ui AccountDetailPerformanceTilesTests`.
- Run `just format-check` after every task; fix all findings. Run the relevant AI reviewer agents (`@code-review`, `@instrument-conversion-review`, `@concurrency-review`, `@ui-review`, `@ui-test-review`) before committing and fix every finding — `guides/AI_REVIEW_GATE_GUIDE.md`.
- Each task = one PR, landed via the `landing-prs` skill. Never `git push origin main`.
- Test wait helpers default to 10s; never pass short positive timeouts — memory `feedback_test_wait_timeouts_10s`.

## File Structure

**Created:**
- `MoolahTests/Shared/AccountPerformanceCalculatorMultiInstrumentTests.swift` — unit tests for the new group-aware `computeMultiInstrument` (with cost basis → populated tiles; without cost basis → current value only; group internal transfer excluded; flow-conversion failure → current value only). (Task 1)
- `MoolahTests/Views/Positions/AccountDetailPerformanceGateTests.swift` — unit tests for the `AccountDetailLayout.showsPerformanceTiles` gate. Kept in its own file (not appended to `AccountDetailLayoutTests`) to avoid merge-queue conflicts and SwiftLint's `type_body_length` — memory `reference_insight_chart_test_file_splitting`. (Task 2)
- `MoolahUITests_macOS/Tests/AccountDetailPerformanceTilesTests.swift` — macOS UI tests (tiles present for the multi-instrument account's Chart pane; absent for fiat-only). (Task 3)

**Modified:**
- `Domain/Models/AccountPerformance.swift` — add the `static func currentValueOnly(_:in:)` factory (Rule-11 degraded shape: current value known, all other fields `nil`). (Task 1)
- `Shared/AccountPerformanceCalculator.swift` — add `static func computeMultiInstrument(accountIds:transactions:valuedPositions:profileCurrency:conversionService:now:)` + the private `extractGroupFlows(...)` helper. The single-account `compute(accountId:...)` and `computeLegacy(...)` are **unchanged**. (Task 1)
- `Shared/Views/Positions/AccountDetailLayout.swift` — add `static func showsPerformanceTiles(valuedRows:hostCurrency:)`. (Task 2)
- `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift` — compute performance in `buildHistoryInput` and pass it into `PositionsAssemblyContext(performance:)` (replacing the hard-coded `nil`), via a new private `computePerformance(...)` helper. (Task 2)
- `Shared/Views/Positions/AccountPerformanceTiles.swift` — add `.accessibilityIdentifier(UITestIdentifiers.AccountDetail.performanceTiles)` to the strip's root so a UI test can assert its presence/absence. (Task 3)
- `UITestSupport/UITestIdentifiers+AccountDetail.swift` — add the `performanceTiles` constant. (Task 3)
- `MoolahUITests_macOS/Helpers/Screens/AccountDetailScreen.swift` — add `expectPerformanceTiles()` / `expectNoPerformanceTiles()`. (Task 3)

**NOT touched (backward-compatibility invariants):**
- `Shared/AccountPerformanceCalculator.swift` — the single-account `compute(accountId:...)` and `computeLegacy(...)` are the investment / manual-valuation entry points and must stay behaviour-identical. Increment 3 only *adds* a new overload.
- `Features/Investments/**` (`InvestmentStore+Positions.swift` `refreshPositionTrackedPerformance`, `InvestmentStore+PositionsInput.swift`) — the investment path already computes + threads performance; out of scope. Increment 4 folds it onto the unified container.
- `Shared/MultiInstrumentPositionsAssembler.swift` — `assemble(...)` already carries `context.performance` verbatim into the `PositionsViewInput`; no change needed (it also independently builds the chart's contribution baseline, which agrees with the tiles because both route through `AccountCashFlows.flowAmounts`).
- `Shared/Views/Positions/PositionsChartPane.swift` — already renders `AccountPerformanceTiles` when `input.performance != nil`; no change needed.

## Key decisions (locked)

- **Perf-tile gate = "has a non-zero non-host-currency holding" (`AccountDetailLayout.showsPerformanceTiles(valuedRows:hostCurrency:)`).** The tiles show exactly when the account has at least one non-zero position in an instrument other than the host currency — i.e. the same predicate that gates the Positions pane, so **tiles and the pinned Positions pane appear together**. Rationale vs the alternatives: (a) gating on `profitLoss != nil` is *wrong* — it would hide the whole strip for a no-cost-basis crypto wallet, contradicting the requirement that "current value still shows"; the design wants the current-value tile visible with the P&L / return tiles individually hidden. (b) The gate reads the **valued** rows (post-valuation), so `.knownZero` / `.spam` crypto the valuator already dropped can't keep the tiles alive — this keeps it consistent with the assembled `PositionsViewInput.shouldHide` (hence the Positions pane) rather than the pre-valuation raw heuristic. Fiat-only accounts fail the gate → `performance` stays `nil` → `PositionsChartPane` falls back to the plain `PositionsHeader` (total only).
- **The gate is realised by passing `nil` performance, not by a second view branch.** Increment 2's `PositionsChartPane` already renders tiles iff `input.performance != nil`. Increment 3 therefore only decides *whether to compute + thread* an `AccountPerformance`; fiat-only accounts skip the compute entirely (they never pay for the flow conversions).
- **Compute integration point = `MultiInstrumentPositionsSplitModifier.buildHistoryInput`,** immediately before building `PositionsAssemblyContext`. That method already has everything the compute needs in scope: the fetched `txns`, the valued `rows`, `accountIdSet`, `hostCurrency`, and the `conversionService`. Performance is computed there (inside the existing valuator `.task`, honouring `Task.isCancelled`) and passed into `context.performance`. No new task, no new fetch.
- **Group boundary semantics = single-member-touch, mirroring `PositionsHistoryBuilder.foldContributions`.** A transaction contributes external cash flows only when it touches exactly one member of `accountIds` (one member ⇒ external counterparty; ≥2 members ⇒ internal transfer between group members, excluded). This makes the tiles' `totalContributions` agree with the chart's contribution baseline point-for-point. For a single-account host (`accountIds.count == 1`) this reduces to the existing single-account boundary-crossing predicate, so crypto / exchange / standard behave identically to a hypothetical single-account call.
- **No-cost-basis / conversion-failure degradation ≠ the single-account "entire value is gain" branch.** The single-account `compute`'s no-flow branch returns `profitLoss = currentValue` (correct for an investment account funded only by intra-account income). That is *wrong* for a wallet funded by external on-chain receives with unknown cost basis — it would paint the whole balance as profit. `computeMultiInstrument` therefore maps **both** "no external flows" **and** "flow conversion threw" to `AccountPerformance.currentValueOnly(...)`: current value known (aggregated from already-valued rows, no further conversion), everything else `nil`. `computeMultiInstrument` throws **only** `CancellationError`; every real failure degrades in place. Current value always shows (unless a row's own valuation was unavailable, in which case Rule 11 nils it too and the tile reads "Unavailable").
- **`AccountPerformanceTiles` needs a UI-test identifier — it has none today.** Increment 3 adds `.accessibilityIdentifier(UITestIdentifiers.AccountDetail.performanceTiles)` to the strip's root (Task 3), and a `performanceTiles` constant to the `UITestIdentifiers.AccountDetail` namespace created in Increment 2.
- **Progressive render deferred (MVP: tiles resolve with the chart input).** Performance is computed within `buildHistoryInput`, so the tiles appear when the assembled `PositionsViewInput` lands — the same moment the chart placeholder swaps to the chart. During loading the positions table and the total header are already on screen (Increment 2's stage-1 `loadingBaseInput`), so the user never faces a blank pane. A "value-first, P&L-when-flows-resolve" progression (seed a `currentValueOnly` performance into the stage-1 input, replace with the full one later) is a possible future refinement to avoid the brief header→tiles swap; it is intentionally out of scope here to keep the increment small.

---

## Task 1: Group-aware multi-instrument performance calculator

Add the account-type-agnostic performance computation for the unified path as a new overload on `AccountPerformanceCalculator`, reusing the existing Modified-Dietz / IRR `assemble(...)` (no reimplementation). It differs from the single-account `compute` in two ways: it applies the **group** boundary rule (single-member-touch), and it degrades a no-cost-basis / conversion-failed account to *current value only* rather than "entire value is gain". Pure and fully unit-testable; not yet wired to any view — shippable as tested library code.

**Files:**
- Modify: `Domain/Models/AccountPerformance.swift`
- Modify: `Shared/AccountPerformanceCalculator.swift`
- Create: `MoolahTests/Shared/AccountPerformanceCalculatorMultiInstrumentTests.swift`

**Interfaces produced:**
- `AccountPerformance.currentValueOnly(_ currentValue: InstrumentAmount?, in instrument: Instrument) -> AccountPerformance`
- `AccountPerformanceCalculator.computeMultiInstrument(accountIds: Set<UUID>, transactions: [Transaction], valuedPositions: [ValuedPosition], profileCurrency: Instrument, conversionService: any InstrumentConversionService, now: Date = Date()) async throws -> AccountPerformance`

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Shared/AccountPerformanceCalculatorMultiInstrumentTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountPerformanceCalculator.computeMultiInstrument")
struct AccountPerformanceCalculatorMultiInstrumentTests {
  let aud = Instrument.AUD
  let usd = Instrument.USD

  /// A cross-account deposit (external → wallet) establishes a contribution
  /// baseline, so contributions and P&L populate.
  @Test("cross-account funding populates contributions and signed P/L")
  func crossAccountFundingPopulatesPL() async throws {
    let wallet = UUID()
    let external = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    // A transfer from `external` (an AUD source) into `wallet` as USD:
    // touches exactly one member of {wallet} → external flow of 1,000 AUD
    // (USD→AUD at 1.0 for the fake service).
    let funding = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(accountId: wallet, instrument: usd, quantity: 1_000, type: .transfer),
        TransactionLeg(accountId: external, instrument: aud, quantity: -1_000, type: .transfer),
      ])
    let valued = [
      ValuedPosition(
        instrument: usd, quantity: 1_000, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_100, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [wallet],
      transactions: [funding],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: now)
    #expect(perf.currentValue == InstrumentAmount(quantity: 1_100, instrument: aud))
    #expect(perf.totalContributions == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 100, instrument: aud))
  }

  /// A wallet funded only by single-account on-chain receives (no boundary
  /// crossing, no opening balance) has no known cost basis: current value
  /// shows, but contributions / P&L / return are nil — NOT "entire value is
  /// gain". Rule 11: no phantom gain.
  @Test("no-cost-basis wallet shows current value only, P/L nil")
  func noCostBasisWalletCurrentValueOnly() async throws {
    let wallet = UUID()
    let receiveDate = Date(timeIntervalSinceReferenceDate: 0)
    let receive = Transaction(
      date: receiveDate,
      legs: [
        // Single-account receive (airdrop): no other accountId, not an
        // opening balance → not a flow.
        TransactionLeg(accountId: wallet, instrument: usd, quantity: 500, type: .income)
      ])
    let valued = [
      ValuedPosition(
        instrument: usd, quantity: 500, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 750, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [wallet],
      transactions: [receive],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: receiveDate.addingTimeInterval(30 * 86_400))
    #expect(perf.currentValue == InstrumentAmount(quantity: 750, instrument: aud))
    #expect(perf.totalContributions == nil)
    #expect(perf.profitLoss == nil)
    #expect(perf.profitLossPercent == nil)
    #expect(perf.annualisedReturn == nil)
    #expect(perf.firstFlowDate == nil)
  }

  /// A transfer BETWEEN two group members touches ≥2 members → internal
  /// transfer → excluded from contributions (mirrors the chart baseline).
  @Test("internal transfer between group members is not a contribution")
  func internalGroupTransferExcluded() async throws {
    let memberA = UUID()
    let memberB = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let opening = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(accountId: memberA, instrument: aud, quantity: 1_000, type: .openingBalance)
      ])
    // A→B internal move: touches both members → excluded.
    let internalMove = Transaction(
      date: openingDate.addingTimeInterval(86_400),
      legs: [
        TransactionLeg(accountId: memberA, instrument: aud, quantity: -400, type: .transfer),
        TransactionLeg(accountId: memberB, instrument: aud, quantity: 400, type: .transfer),
      ])
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 1_100, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_100, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [memberA, memberB],
      transactions: [opening, internalMove],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: now)
    // Only the opening balance counts as a contribution; the internal move
    // does not. So contributions = 1,000 and P/L = 1,100 − 1,000 = 100.
    #expect(perf.totalContributions == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 100, instrument: aud))
  }

  /// A flow-conversion failure degrades to current value only (which is known
  /// from the already-valued rows) rather than throwing or partial-summing.
  @Test("flow conversion failure degrades to current value only")
  func flowConversionFailureCurrentValueOnly() async throws {
    let wallet = UUID()
    let external = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let funding = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(accountId: wallet, instrument: usd, quantity: 1_000, type: .transfer),
        TransactionLeg(accountId: external, instrument: aud, quantity: -1_000, type: .transfer),
      ])
    let valued = [
      ValuedPosition(
        instrument: usd, quantity: 1_000, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_100, instrument: aud))
    ]
    // USD flow conversion fails → contributions unavailable.
    let failing = FakeConversionService.failingInstruments([usd.id])
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [wallet],
      transactions: [funding],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: failing,
      now: openingDate.addingTimeInterval(365 * 86_400))
    #expect(perf.currentValue == InstrumentAmount(quantity: 1_100, instrument: aud))
    #expect(perf.totalContributions == nil)
    #expect(perf.profitLoss == nil)
  }
}
```

> **Fake-service note:** the factory is `FakeConversionService.failingInstruments(_ failingInstrumentIds: Set<String> = [], rates: [String: Decimal] = [:])` — the first positional argument is the failing set, so `.failingInstruments([usd.id])` throws `FakeConversionError.instrumentUnavailable` whenever USD is either side of a conversion. (`setFailing(_:)` can toggle the set at runtime if a test needs it mid-run; not needed here.) The assertion (current value only) is what matters.

- [ ] **Step 2: Run the tests, verify they fail**

Run: `just test-mac AccountPerformanceCalculatorMultiInstrumentTests`
Expected: FAIL — `computeMultiInstrument` does not exist.

- [ ] **Step 3: Add the `currentValueOnly` factory**

In `Domain/Models/AccountPerformance.swift`, add to the existing `extension AccountPerformance` (below `unavailable(in:)`):

```swift
  /// Current value known, every other aggregate unavailable. Used by the
  /// unified multi-instrument path when the account has no cost basis (a
  /// wallet funded solely by on-chain receives / airdrops) or when the flow
  /// history cannot be converted: the current-value tile still shows while
  /// the P&L and annualised-return tiles hide — Rule 11 (no phantom zeros, no
  /// phantom gains). Distinct from `unavailable(in:)`, which nils the current
  /// value too.
  static func currentValueOnly(
    _ currentValue: InstrumentAmount?, in instrument: Instrument
  ) -> AccountPerformance {
    AccountPerformance(
      instrument: instrument,
      currentValue: currentValue,
      totalContributions: nil,
      profitLoss: nil,
      profitLossPercent: nil,
      annualisedReturn: nil,
      firstFlowDate: nil)
  }
```

- [ ] **Step 4: Add `computeMultiInstrument` + `extractGroupFlows`**

In `Shared/AccountPerformanceCalculator.swift`, add these two methods inside the `enum AccountPerformanceCalculator` body (they call the existing `private static` `aggregatedValue`, `assemble`, and `logger` — same-file access). Add after the `// MARK: - Manual valuation` section's `computeLegacy`:

```swift
  // MARK: - Multi-instrument (unified account-detail path)

  /// Computes account-level performance for the unified multi-instrument
  /// account-detail path (crypto / exchange / standard / group hosts), which
  /// carries a *set* of account ids rather than a single account.
  ///
  /// **Group boundary rule.** A transaction contributes external cash flows
  /// only when it touches exactly one member of `accountIds` (one member ⇒
  /// external counterparty; ≥2 members ⇒ an internal transfer between group
  /// members, excluded). This mirrors
  /// `PositionsHistoryBuilder.foldContributions`, so the tile's
  /// `totalContributions` and the chart's contribution baseline never
  /// disagree. For a single-account host (`accountIds.count == 1`) the rule
  /// reduces to the single-account boundary-crossing predicate.
  ///
  /// **Graceful degradation (Rule 11).** `currentValue` is aggregated from the
  /// already-valued `valuedPositions` (no further conversion), so it survives
  /// even when the flow history cannot be converted. Two degraded shapes both
  /// return `currentValue` with every other field `nil` — so the P&L and
  /// annualised-return tiles hide rather than mislead:
  ///   1. **No external flows** — a wallet funded solely by on-chain receives
  ///      / airdrops has no known cost basis. Unlike the single-account
  ///      `compute`, this path does NOT treat the whole balance as profit
  ///      (that would paint an airdrop wallet's entire value as gain).
  ///   2. **Flow conversion failed** — a rate lookup for a historical flow
  ///      threw; contributions are unavailable, but the current value is not.
  ///
  /// Throws only `CancellationError` (propagated so a superseded valuator pass
  /// abandons cleanly); every other failure degrades in place.
  static func computeMultiInstrument(
    accountIds: Set<UUID>,
    transactions: [Transaction],
    valuedPositions: [ValuedPosition],
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService,
    now: Date = Date()
  ) async throws -> AccountPerformance {
    let currentValue = aggregatedValue(of: valuedPositions, in: profileCurrency)
    let flows: [CashFlow]
    do {
      flows = try await extractGroupFlows(
        from: transactions,
        accountIds: accountIds,
        profileCurrency: profileCurrency,
        conversionService: conversionService)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      logger.warning(
        "Multi-instrument cash-flow conversion failed; showing current value only: \(error.localizedDescription, privacy: .public)"
      )
      return .currentValueOnly(currentValue, in: profileCurrency)
    }
    guard !flows.isEmpty else {
      return .currentValueOnly(currentValue, in: profileCurrency)
    }
    return assemble(
      flows: flows,
      currentValue: currentValue,
      profileCurrency: profileCurrency,
      now: now)
  }

  /// Group-aware cash-flow extraction: applies the single-member-touch rule
  /// (see `computeMultiInstrument`) then delegates the per-leg amount to the
  /// shared `AccountCashFlows.flowAmounts(for:)` so the boundary-crossing +
  /// on-date conversion logic lives in exactly one place. Per-leg `CashFlow`
  /// granularity is preserved; all legs of a transaction date at
  /// `transaction.date`.
  private static func extractGroupFlows(
    from transactions: [Transaction],
    accountIds: Set<UUID>,
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [CashFlow] {
    var flows: [CashFlow] = []
    let sorted = transactions.sorted { $0.date < $1.date }
    for transaction in sorted {
      let membersTouched = Set(transaction.legs.compactMap(\.accountId))
        .intersection(accountIds)
      guard membersTouched.count == 1, let member = membersTouched.first else { continue }
      let amounts = try await AccountCashFlows.flowAmounts(
        for: transaction,
        accountId: member,
        hostCurrency: profileCurrency,
        service: conversionService)
      for amount in amounts {
        flows.append(CashFlow(date: transaction.date, amount: amount))
      }
    }
    return flows
  }
```

- [ ] **Step 5: Run the tests, verify they pass**

Run: `just test-mac AccountPerformanceCalculatorMultiInstrumentTests` (Expected: PASS) and `just test-mac AccountPerformanceCalculator` (Expected: PASS — the existing single-account / legacy suites are untouched).

- [ ] **Step 6: Build, format, review**

Run: `just build-mac` (Expected: succeeds, no new warnings), then `just format-check` (Expected: clean). Run `@code-review` and `@instrument-conversion-review` on the two modified source files; fix every finding and re-review until clean.

- [ ] **Step 7: Commit**

```bash
git -C . add Domain/Models/AccountPerformance.swift Shared/AccountPerformanceCalculator.swift MoolahTests/Shared/AccountPerformanceCalculatorMultiInstrumentTests.swift
git -C . commit -m "feat(performance): group-aware multi-instrument AccountPerformance computation"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 2: Gate + thread performance into the unified split path

Add the pure perf-tile gate and wire `computeMultiInstrument` into `MultiInstrumentPositionsSplitModifier.buildHistoryInput`, replacing the hard-coded `performance: nil`. After this task, crypto / exchange / standard / mixed-group accounts render the `AccountPerformanceTiles` strip; fiat-only accounts keep the plain total header.

**Files:**
- Modify: `Shared/Views/Positions/AccountDetailLayout.swift`
- Modify: `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`
- Create: `MoolahTests/Views/Positions/AccountDetailPerformanceGateTests.swift`

**Interfaces produced:**
- `AccountDetailLayout.showsPerformanceTiles(valuedRows: [ValuedPosition], hostCurrency: Instrument) -> Bool`

- [ ] **Step 1: Write the failing gate tests**

Create `MoolahTests/Views/Positions/AccountDetailPerformanceGateTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountDetailLayout.showsPerformanceTiles")
struct AccountDetailPerformanceGateTests {
  let aud = Instrument.AUD
  let usd = Instrument.USD

  @Test("a non-zero non-host holding shows the tiles")
  func nonHostHoldingShowsTiles() {
    let rows = [
      ValuedPosition(
        instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_000, instrument: aud)),
      ValuedPosition(
        instrument: usd, quantity: 200, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 304, instrument: aud)),
    ]
    #expect(AccountDetailLayout.showsPerformanceTiles(valuedRows: rows, hostCurrency: aud))
  }

  @Test("a host-only account hides the tiles (fiat-only)")
  func hostOnlyHidesTiles() {
    let rows = [
      ValuedPosition(
        instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_000, instrument: aud))
    ]
    #expect(!AccountDetailLayout.showsPerformanceTiles(valuedRows: rows, hostCurrency: aud))
  }

  @Test("an empty valued-rows set hides the tiles")
  func emptyHidesTiles() {
    #expect(!AccountDetailLayout.showsPerformanceTiles(valuedRows: [], hostCurrency: aud))
  }

  @Test("a zero-quantity non-host row does not show the tiles")
  func zeroQuantityNonHostHidesTiles() {
    let rows = [
      ValuedPosition(
        instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_000, instrument: aud)),
      ValuedPosition(
        instrument: usd, quantity: 0, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 0, instrument: aud)),
    ]
    #expect(!AccountDetailLayout.showsPerformanceTiles(valuedRows: rows, hostCurrency: aud))
  }

  @Test("a non-host holding shows the tiles even without a converted value")
  func nonHostHoldingShowsTilesEvenUnpriced() {
    // Rule-11 graceful degradation: the strip still renders (current value
    // reads "Unavailable") when the row's value could not be converted.
    let rows = [
      ValuedPosition(
        instrument: usd, quantity: 200, unitPrice: nil, costBasis: nil, value: nil)
    ]
    #expect(AccountDetailLayout.showsPerformanceTiles(valuedRows: rows, hostCurrency: aud))
  }
}
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `just test-mac AccountDetailPerformanceGateTests`
Expected: FAIL — `showsPerformanceTiles` does not exist.

- [ ] **Step 3: Add the gate helper**

In `Shared/Views/Positions/AccountDetailLayout.swift`, add to the `AccountDetailLayout` enum (below `hasNonHostHoldings`):

```swift
  /// Whether the Chart pane shows the `AccountPerformanceTiles` strip
  /// (value / P&L / return) rather than the plain total-only
  /// `PositionsHeader`. `true` iff the account holds at least one non-zero
  /// position in an instrument other than the host currency — i.e. it has
  /// real invested / P&L data (crypto, exchange, mixed group). Fiat-only
  /// accounts fall back to the header.
  ///
  /// Reads the *valued* rows (post-valuation), so `.knownZero` / `.spam`
  /// crypto the valuator already dropped can't keep the tiles alive — this
  /// keeps the strip's presence aligned with the assembled input's
  /// `shouldHide`, hence with the pinned Positions pane: tiles and pane
  /// appear together.
  static func showsPerformanceTiles(
    valuedRows: [ValuedPosition], hostCurrency: Instrument
  ) -> Bool {
    valuedRows.contains { $0.quantity != 0 && $0.instrument != hostCurrency }
  }
```

- [ ] **Step 4: Run the gate tests, verify they pass**

Run: `just test-mac AccountDetailPerformanceGateTests`
Expected: PASS.

- [ ] **Step 5: Thread performance into `buildHistoryInput`**

In `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`, update `buildHistoryInput(conversionService:rows:assetKeys:repository:)`. After the `guard !Task.isCancelled else { return }` that follows the txn fetch, compute performance and pass it into the context (replace the `performance: nil` line):

```swift
    guard !Task.isCancelled else { return }
    let performance = await computePerformance(
      accountIds: accountIdSet,
      transactions: txns,
      rows: rows,
      conversionService: service)
    guard !Task.isCancelled else { return }
    let context = PositionsAssemblyContext(
      title: title,
      hostCurrency: hostCurrency,
      accountIds: accountIdSet,
      assetKeysByInstrumentId: assetKeys,
      performance: performance,
      alwaysShowsFullSurface: false)
```

Then add the private helper (place it directly below `buildHistoryInput`):

```swift
  /// Computes the account-level `AccountPerformance` that feeds the Chart
  /// pane's tiles. Gated so fiat-only accounts skip it (→ `nil` → the pane
  /// falls back to the plain `PositionsHeader`) and never pay for the flow
  /// conversions. Returns `nil` on cancellation so a superseding valuator
  /// pass owns the write. Reuses
  /// `AccountPerformanceCalculator.computeMultiInstrument` — no
  /// Modified-Dietz reimplementation here.
  private func computePerformance(
    accountIds: Set<UUID>,
    transactions: [Transaction],
    rows: [ValuedPosition],
    conversionService: any InstrumentConversionService
  ) async -> AccountPerformance? {
    guard
      AccountDetailLayout.showsPerformanceTiles(
        valuedRows: rows, hostCurrency: hostCurrency)
    else { return nil }
    do {
      return try await AccountPerformanceCalculator.computeMultiInstrument(
        accountIds: accountIds,
        transactions: transactions,
        valuedPositions: rows,
        profileCurrency: hostCurrency,
        conversionService: conversionService)
    } catch {
      // `computeMultiInstrument` throws only `CancellationError`: a
      // superseding pass owns the write now, so drop this one.
      return nil
    }
  }
```

- [ ] **Step 6: Build and preview**

Run: `just build-mac` (Expected: succeeds, no new warnings). Use `reviewing-ui-with-preview` on `MultiInstrumentPositionsSplitModifier.swift`'s `#Preview("Split shown — multi-instrument")`: the Chart pane's top now shows the three-tile `AccountPerformanceTiles` strip (current value at minimum; the preview backend's conversions determine whether P&L populates) rather than the single-row header. Confirm `#Preview("Chart + transactions — fiat only (no positions pane)")` still shows the plain total header on its Chart pane (no tiles). Toggle to the Chart tab in each preview to see the pane.

- [ ] **Step 7: Format and review**

Run: `just format-check` (Expected: clean). Run `@code-review`, `@concurrency-review` (the valuator `.task` gained an async compute — verify the cancellation guards), and `@ui-review` on the modifier; fix every finding and re-review until clean.

- [ ] **Step 8: Commit**

```bash
git -C . add Shared/Views/Positions/AccountDetailLayout.swift Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift MoolahTests/Views/Positions/AccountDetailPerformanceGateTests.swift
git -C . commit -m "feat(positions): render performance tiles for crypto/exchange/standard/group accounts"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 3: macOS UI test — performance tiles present for multi-instrument, absent for fiat-only

Add a UI-test identifier to `AccountPerformanceTiles` (it has none) and lock the tile gate end-to-end through the existing `.accountDetailLayout` seed: the multi-currency account's Chart pane shows the tiles; the fiat-only account's Chart pane does not.

**Files:**
- Modify: `Shared/Views/Positions/AccountPerformanceTiles.swift`
- Modify: `UITestSupport/UITestIdentifiers+AccountDetail.swift`
- Modify: `MoolahUITests_macOS/Helpers/Screens/AccountDetailScreen.swift`
- Create: `MoolahUITests_macOS/Tests/AccountDetailPerformanceTilesTests.swift`

**Interfaces produced:**
- `UITestIdentifiers.AccountDetail.performanceTiles`
- `AccountDetailScreen.expectPerformanceTiles(timeout:)` / `expectNoPerformanceTiles(timeout:)`

> **Seed reuse:** the `.accountDetailLayout` seed (Increment 2) already provides a **Multi-Currency** account holding a USD position (→ tiles) and an **Everyday** AUD-only account (→ no tiles). No new seed. The USD position's *converted value* may read "Unavailable" in the offline UI-test environment — that is fine: the assertions check the strip's **presence / absence** (the identifier), which is driven by the holding, not by whether USD priced. (Optionally, during implementation, confirm whether the UI-test conversion path resolves USD→AUD; if a real current-value number is wanted in the tile, seed a deterministic rate — not required for these tests.)

- [ ] **Step 1: Add the identifier constant**

In `UITestSupport/UITestIdentifiers+AccountDetail.swift`, add to the `AccountDetail` enum (below `chartSegmentLabel`):

```swift
    /// The `AccountPerformanceTiles` strip (value / P&L / return) at the top
    /// of the Chart pane. Present only when the account has invested / P&L
    /// data (crypto, exchange, mixed group); absent for fiat-only accounts.
    public static let performanceTiles = "accountDetail.performanceTiles"
```

- [ ] **Step 2: Tag the tiles view**

In `Shared/Views/Positions/AccountPerformanceTiles.swift`, add the identifier to the root `VStack`'s modifier chain (after `.dynamicTypeSize(...DynamicTypeSize.accessibility2)`):

```swift
    .accessibilityIdentifier(UITestIdentifiers.AccountDetail.performanceTiles)
```

(`UITestIdentifiers` is already linked into the app target — `PositionsChartTransactionsSplit` references `UITestIdentifiers.AccountDetail` from the same Shared views layer.)

- [ ] **Step 3: Extend the screen driver**

In `MoolahUITests_macOS/Helpers/Screens/AccountDetailScreen.swift`, add:

```swift
  /// Asserts the performance-tiles strip is present within `timeout` seconds.
  /// The Chart pane must be showing first (call `toggleToChart()` on macOS).
  /// Expected for accounts with non-host holdings (crypto / exchange / mixed).
  func expectPerformanceTiles(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let tiles = app.element(for: UITestIdentifiers.AccountDetail.performanceTiles)
    if !tiles.waitForExistence(timeout: timeout) {
      Trace.recordFailure("performance tiles did not appear")
      XCTFail(
        "Performance tiles did not appear within \(timeout)s on the Chart pane for a "
          + "multi-instrument account. Check computePerformance feeds a non-nil "
          + "AccountPerformance into PositionsAssemblyContext.")
    }
  }

  /// Asserts the performance-tiles strip is absent (fiat-only account shows
  /// the plain total header instead). The Chart pane must be showing first,
  /// so the pane has rendered before asserting the strip's absence.
  func expectNoPerformanceTiles(timeout: TimeInterval = 10) {
    Trace.record(#function)
    let chart = app.element(for: UITestIdentifiers.AccountDetail.chartPane)
    if !chart.waitForExistence(timeout: timeout) {
      Trace.recordFailure("chart pane did not appear")
      XCTFail("Chart pane did not appear within \(timeout)s")
      return
    }
    XCTAssertFalse(
      app.element(for: UITestIdentifiers.AccountDetail.performanceTiles).exists,
      "Performance tiles should be absent for a fiat-only account (no invested / P&L data).")
  }
```

- [ ] **Step 4: Write the failing UI tests**

Create `MoolahUITests_macOS/Tests/AccountDetailPerformanceTilesTests.swift`:

```swift
import XCTest

/// macOS UI tests for Increment 3 — the `AccountPerformanceTiles` strip in the
/// unified account-detail Chart pane. Seeded via `.accountDetailLayout`:
/// a multi-currency account (holds USD → tiles) and a fiat-only checking
/// (AUD only → no tiles).
@MainActor
final class AccountDetailPerformanceTilesTests: MoolahUITestCase {
  /// A multi-instrument account shows the performance tiles on its Chart pane.
  func testMultiInstrumentAccountShowsPerformanceTiles() throws {
    let app = launch(seed: .accountDetailLayout)
    app.sidebar.switchToAccount(.multiCurrency)
    app.accountDetail.expectPositionsPanePinned()
    app.accountDetail.toggleToChart()
    app.accountDetail.expectPerformanceTiles()
  }

  /// A fiat-only account shows no performance tiles — the plain total header
  /// rides at the top of its Chart pane instead.
  func testFiatOnlyAccountShowsNoPerformanceTiles() throws {
    let app = launch(seed: .accountDetailLayout)
    app.sidebar.switchToAccount(.everydayFiat)
    app.accountDetail.expectNoPositionsPane()
    app.accountDetail.toggleToChart()
    app.accountDetail.expectNoPerformanceTiles()
  }
}
```

- [ ] **Step 5: Run the UI tests, verify they pass**

Run: `just test-ui AccountDetailPerformanceTilesTests`
Expected: PASS (2 tests). If element resolution flakes, follow the `writing-ui-tests` driver invariants and `feedback_pr_ci_gate_when_ui_host_blocked`; do not shorten the 10s waits. If the local UI host is wedged, gate on the PR's CI (UI Test job) per that memory.

- [ ] **Step 6: Format and review**

Run: `just format-check` (Expected: clean). Run `@ui-test-review` on the driver + tests and `@ui-review` on the tagged `AccountPerformanceTiles`; fix every finding and re-review until clean.

- [ ] **Step 7: Commit**

```bash
git -C . add Shared/Views/Positions/AccountPerformanceTiles.swift UITestSupport/UITestIdentifiers+AccountDetail.swift MoolahUITests_macOS/Helpers/Screens/AccountDetailScreen.swift MoolahUITests_macOS/Tests/AccountDetailPerformanceTilesTests.swift
git -C . commit -m "test(positions): UI coverage for performance tiles gate (multi-instrument vs fiat-only)"
```

Then open a PR and land via the `landing-prs` skill.

---

## Self-Review

- **Spec coverage (vs Increment 3 scope):**
  - Compute `AccountPerformance` (value, contributions, P&L, annualised return) for the multi-instrument path and set it on `PositionsAssemblyContext.performance` (was `performance: nil`) → `computeMultiInstrument` (Task 1) + `buildHistoryInput` wiring (Task 2). ✓
  - Reuse `AccountPerformanceCalculator` (Modified Dietz / IRR via the existing private `assemble`), not a reimplementation → Task 1 delegates to `assemble`; the new code only adds group flow extraction + degradation. ✓
  - Uses the real `compute` shape — the new overload's signature mirrors `compute(accountId:transactions:valuedPositions:profileCurrency:conversionService:now:)` with `accountIds: Set<UUID>`, matching the split path's plural ids. ✓
  - Graceful degradation: no-cost-basis wallet → current value only, P&L/contributions/return nil; no crash, no phantom zeros/gains → `currentValueOnly` + the no-flow / conversion-failure branches, unit-tested (Task 1). ✓
  - Fiat-only accounts hide the tiles; the exact gate is specified + justified → `showsPerformanceTiles` = "has a non-zero non-host holding" (Key decisions + Task 2), unit-tested including the zero-quantity and unpriced edges. ✓
  - Investment `.calculatedFromTrades` untouched → single-account `compute` / `InvestmentStore` explicitly in the NOT-touched list; Increment 4 deferred. ✓
  - Money / Rule 11: `InstrumentAmount`, no `abs()` on signed P&L (P&L flows straight from `assemble`, which preserves sign), partial-availability = nil fields → Task 1 tests assert signed P&L and nil-not-zero degradation. ✓
  - Async compute runs in the existing valuator task, honours `Task.isCancelled`, stays `Sendable` → `computePerformance` inside `buildHistoryInput` with a post-compute cancellation guard; `computeMultiInstrument` throws only `CancellationError`; `@concurrency-review` gated (Task 2 Step 7). ✓
  - Group-account aggregation semantics → single-member-touch rule mirroring `PositionsHistoryBuilder.foldContributions`, so tiles agree with the chart baseline; unit-tested via the internal-transfer case. ✓
  - `AccountPerformanceTiles` needs an identifier → checked (it had none); added `performanceTiles` + `.accessibilityIdentifier` (Task 3). ✓
  - UI test asserts tiles appear for a multi-instrument account and not for fiat-only → Task 3, reusing the `.accountDetailLayout` seed. ✓
- **Placeholder scan:** every code step carries complete, compiling code — no `TBD` / `...`-as-content. The only ellipsis is the existing `.dynamicTypeSize(...DynamicTypeSize.accessibility2)` range operator quoted for placement context. The one flagged uncertainty (the `FakeConversionService.failingInstruments` factory argument shape in Task 1 Step 1) is called out explicitly with a concrete fallback (`.fixedRates([:])` + `setFailing`) so the implementer resolves it against the real factory file without a design gap.
- **Type / name consistency across tasks:** `AccountPerformance.currentValueOnly(_:in:)` (Task 1) is the sole degraded-shape constructor. `AccountPerformanceCalculator.computeMultiInstrument(accountIds:transactions:valuedPositions:profileCurrency:conversionService:now:)` (Task 1) is consumed verbatim by `computePerformance` (Task 2). `AccountDetailLayout.showsPerformanceTiles(valuedRows:hostCurrency:)` (Task 2) is consumed by `computePerformance` (Task 2). `UITestIdentifiers.AccountDetail.performanceTiles` (Task 3) is consumed by the driver + tagged on the view (Task 3). Signatures verified against source: `AccountCashFlows.flowAmounts(for:accountId:hostCurrency:service:)`, `PositionsAssemblyContext(title:hostCurrency:accountIds:assetKeysByInstrumentId:performance:alwaysShowsFullSurface:)`, `ValuedPosition(instrument:quantity:unitPrice:costBasis:value:)`, `Transaction(date:legs:)`, `TransactionLeg(accountId:instrument:quantity:type:)`, `FakeConversionService.fixedRates(_:knownZero:)`, and the `MultiInstrumentPositionsSplitModifier.buildHistoryInput` locals (`txns`, `rows`, `accountIdSet`, `service`, `assetKeys`). ✓
- **Ambiguities resolved:** (a) *No-flow behaviour* — the scope says a no-cost-basis wallet "yields nil contributions/profitLoss", but the existing single-account `compute` returns `profitLoss = currentValue` for the no-flow case; resolved by NOT reusing that branch — `computeMultiInstrument` maps no-flow to `currentValueOnly` (Key decisions), matching the scope and avoiding a phantom gain. (b) *Plural account ids* — the calculator's `compute` takes a single `accountId` but the split path carries a `Set`; resolved with a group-aware overload using the `foldContributions` single-member rule, so single-account hosts are unchanged and group hosts net internal transfers. (c) *Perf gate vs Positions-pane gate* — resolved by reading the *valued* rows so the two gates agree (tiles and pane appear together). (d) *Progressive render* — the scope says "consider"; resolved as: MVP computes within `buildHistoryInput` (tiles land with the chart input, table + header already visible during load), with value-first progression noted as a future refinement. **Needs user input:** none blocking — but flag for review: in the offline UI-test environment the multi-currency account's USD current-value tile may read "Unavailable" (the assertion only checks strip presence); if a seeded USD→AUD rate for a real number is preferred, say so and Task 3 will add it.
