# Multi-Instrument History Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the value/profit-loss history chart at the top of the positions surface for every multi-instrument host (crypto accounts, account groups, standard multi-currency accounts, exchange accounts) — the same chart investment accounts already get.

**Architecture:** The chart is gated by `PositionsViewInput.showsChart`, which needs a non-empty `historicalValue` series *and* either `shouldHide` or at least one row with a cost basis. Today the investment path (`InvestmentStore.positionsViewInput`) builds both via `PositionsHistoryBuilder` + a cost-basis snapshot, while the shared `multiInstrumentPositionsSplit()` modifier hardcodes `historicalValue: nil` and `costBasis: [:]`. We extract the investment path's cost-basis-and-history assembly into a store-independent helper, generalize `PositionsHistoryBuilder` from a single `accountId` to a `Set<UUID>` (so account groups aggregate), and call the shared helper from the modifier — fetching transactions via `session.backend.transactions` and re-firing on range changes.

**Tech Stack:** Swift, SwiftUI, GRDB-backed `TransactionRepository`, `InstrumentConversionService` (crypto/stock/FX price caches), Swift Testing, `just` toolchain.

## Global Constraints

- **Git:** `main` is protected. Work happens on branch `crypto-pl-chart` in worktree `/Users/aj/Documents/code/moolah-project/moolah-native.crypto-pl-chart`. Ship via PR. Use `git -C <path>`, never `cd && git`.
- **Build/test/format:** Use `just` targets only (`just build-mac`, `just test-mac <filters>`, `just format`, `just format-check`). Never raw `swift`/`swiftlint`/`swift-format`/`xcodebuild`. Capture test output to `.agent-tmp/`.
- **TDD:** Write the failing test before implementation. Tests use Swift Testing (`@Test`/`@Suite`/`#expect`/`#require`), not XCTest. One `extension` per protocol conformance (no inline conformances).
- **Concurrency:** Follow `guides/CONCURRENCY_GUIDE.md`. Stores/UI-bound types `@MainActor`; cross-actor types `Sendable`. `PositionsHistoryBuilder` is already `@concurrent`/`Sendable`.
- **Instrument safety:** Mismatched-instrument arithmetic traps. Never `abs()` monetary amounts — preserve sign. Never display a partial aggregate: a single failed conversion marks the whole total unavailable (Rule 11, `guides/INSTRUMENT_CONVERSION_GUIDE.md`).
- **Dates:** Historical conversions use the snapshot date; "now" uses `Date()`. Day bucketing must be zone-stable (`guides/DATE_TIME_GUIDE.md`). `PositionsHistoryBuilder` already keys days via `Calendar(identifier: .gregorian)` startOfDay — keep that exact behavior.
- **Thin views:** Business logic lives in the shared helper, not the `ViewModifier` body. The modifier's `.task` is allowed to *call* the helper (mirrors the existing `valuatePositions()` pattern).
- **Lint:** No SwiftLint baseline. Fix violations by splitting files/types/functions, not by suppressing. Run `just format-check` at the end of every task.
- **TODOs:** Any `TODO`/`FIXME` must be `TODO(#N): … — https://github.com/moolah-rocks/moolah-native/issues/N`.

---

## File Structure

- **`Shared/PositionsHistoryBuilder.swift`** (modify) — generalize `accountId: UUID` → `accountIds: Set<UUID>` throughout; keep a single-account convenience overload so existing callers are untouched.
- **`Shared/MultiInstrumentPositionsAssembler.swift`** (create) — store-independent helper that fetches transactions for a set of accounts, computes the cost-basis snapshot, overlays cost basis onto valued rows, builds the history series, and returns a fully-populated `PositionsViewInput`. This is the single home for the logic currently inlined in `InvestmentStore+PositionsInput.swift`.
- **`Features/Investments/InvestmentStore+PositionsInput.swift`** (modify) — refactor `positionsViewInput` to delegate cost-basis snapshot + history assembly to the new helper (no behavior change; existing tests stay green). `fetchAllTransactions`, `costBasisSnapshot`, `hasAnyTradeLeg` move to the helper as static/free functions; the store keeps thin wrappers if other code references them.
- **`Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`** (modify) — accept `accountIds: [UUID]`; in the valuation task, call the assembler to produce a `PositionsViewInput` with `historicalValue` + cost-bearing rows; add `positionsRange` to the task key so the chart rebuilds on range change.
- **Call sites** (modify): `Features/Crypto/CryptoWalletAccountView.swift`, `Features/Accounts/Views/GroupDetailView.swift`, `Features/Accounts/Views/StandardAccountView.swift`, `Features/Exchange/ExchangeAccountView.swift` — pass `accountIds`.
- **Tests** (create): `MoolahTests/Shared/PositionsHistoryBuilderMultiAccountTests.swift`, `MoolahTests/Shared/MultiInstrumentPositionsAssemblerTests.swift`.

---

## Task 1: Generalize `PositionsHistoryBuilder` to multiple accounts

**Files:**
- Modify: `Shared/PositionsHistoryBuilder.swift`
- Test: `MoolahTests/Shared/PositionsHistoryBuilderMultiAccountTests.swift` (create)

**Interfaces:**
- Produces:
  - `func build(transactions:[Transaction], accountIds: Set<UUID>, hostCurrency: Instrument, range: PositionsTimeRange, now: Date = Date()) async -> HistoricalValueSeries`
  - Convenience kept for existing callers: `func build(transactions:[Transaction], accountId: UUID, hostCurrency: Instrument, range: PositionsTimeRange, now: Date = Date()) async -> HistoricalValueSeries` → calls the set-based version with `[accountId]`.
- Internals change: `BuildContext.accountId: UUID` → `accountIds: Set<UUID>`; the txn filter `legs.contains { $0.accountId == accountId }` → `legs.contains { accountIds.contains($0.accountId) }`; in `apply`, `legs.filter { $0.accountId == accountId }` → `legs.filter { accountIds.contains($0.accountId) }`. `AccountCashFlows.flowAmounts(for:accountId:…)` is called per-member in a loop (see Step 3) because its boundary predicate is single-account.

**Why a Set:** account groups aggregate holdings across members (`aggregatedGroupPositions`). With all member accounts in `accountIds`, an internal same-instrument transfer between two members appears as `[+q (memberB), −q (memberA)]` in `accountLegs`, so quantities net to zero on that day — the value line is correct without special-casing transfers.

- [ ] **Step 1: Write failing tests**

Create `MoolahTests/Shared/PositionsHistoryBuilderMultiAccountTests.swift`. Use the project's existing history-builder test as the reference for harness setup (a deterministic in-memory conversion service / fixed `now`). Cover:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("PositionsHistoryBuilder multi-account")
struct PositionsHistoryBuilderMultiAccountTests {
  // Two accounts each holding the same instrument: the aggregate value
  // line equals the sum of both holdings converted on each day.
  @Test func aggregatesHoldingsAcrossTwoAccounts() async {
    // Build txns: account A buys 1 BTC, account B buys 2 BTC.
    // build(..., accountIds: [A, B], hostCurrency: .AUD, range: .all, now: fixedNow)
    // #expect aggregate total on the last day == convert(3 BTC) on that day.
  }

  // An internal transfer of the SAME instrument between two members nets to
  // zero quantity change for the group — the group's value line is flat
  // across the transfer date (no phantom buy/sell).
  @Test func internalTransferBetweenMembersNetsOut() async {
    // A buys 1 BTC on day0; on day1 A sends 1 BTC to B (one txn, two legs).
    // accountIds: [A, B] → quantity held by the group is 1 BTC before and
    // after; #expect the aggregate value on day1 == convert(1 BTC) on day1
    // (NOT 0, NOT 2).
  }

  // The single-account convenience overload still produces the same series
  // as the pre-change single-account API.
  @Test func singleAccountConvenienceMatches() async {
    // build(transactions:accountId:…) == build(transactions:accountIds:[id]:…)
  }
}
```

Fill the bodies using the existing builder test's fixtures (read `MoolahTests` for the current `PositionsHistoryBuilder` test to copy the deterministic conversion-service stub and `Transaction`/`TransactionLeg` builders). Assert exact host-currency quantities, never a currency symbol.

- [ ] **Step 2: Run tests, verify they fail to compile**

Run: `just test-mac PositionsHistoryBuilderMultiAccountTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: compile failure — `build(transactions:accountIds:…)` does not exist yet.

- [ ] **Step 3: Implement the generalization**

In `Shared/PositionsHistoryBuilder.swift`:
- Change `BuildContext.accountId: UUID` to `accountIds: Set<UUID>`.
- In `build`, rename the parameter and update the txn filter:
  ```swift
  func build(
    transactions: [Transaction],
    accountIds: Set<UUID>,
    hostCurrency: Instrument,
    range: PositionsTimeRange,
    now: Date = Date()
  ) async -> HistoricalValueSeries {
    …
    let sortedTxns = transactions
      .filter { $0.legs.contains { accountIds.contains($0.accountId) } }
      .sorted { $0.date < $1.date }
    …
    let context = BuildContext(
      sortedTxns: sortedTxns, accountIds: accountIds,
      hostCurrency: hostCurrency, calendar: calendar)
    …
  }
  ```
- Add the single-account convenience overload:
  ```swift
  func build(
    transactions: [Transaction],
    accountId: UUID,
    hostCurrency: Instrument,
    range: PositionsTimeRange,
    now: Date = Date()
  ) async -> HistoricalValueSeries {
    await build(
      transactions: transactions, accountIds: [accountId],
      hostCurrency: hostCurrency, range: range, now: now)
  }
  ```
- In `preFoldHistory`/`applyTransactions`, replace `accountId: context.accountId` with `accountIds: context.accountIds`.
- In `apply`, change the signature to take `accountIds: Set<UUID>` and:
  ```swift
  let accountLegs = transaction.legs.filter { accountIds.contains($0.accountId) }
  ```
- **Contributions:** `AccountCashFlows.flowAmounts(for:accountId:hostCurrency:service:)` is single-account and its predicate is "crosses this account's boundary". For a group, an internal member↔member transfer must NOT count as a contribution. Compute contributions as the sum over members, then subtract flows whose counterpart leg is also in `accountIds`. Simplest correct implementation: call `flowAmounts` once per member id and only keep a flow if the transaction has **no** other leg inside `accountIds` (i.e. it crosses the *group* boundary, not just a member boundary). Implement a small helper:
  ```swift
  // A flow counts for the group only if the txn touches exactly one member
  // of `accountIds` (single member → external counterpart). Touching ≥2
  // members means an internal transfer → excluded.
  let membersTouched = Set(transaction.legs.compactMap(\.accountId)).intersection(accountIds)
  guard membersTouched.count == 1, let member = membersTouched.first else {
    // internal transfer (or none) — no contribution
    return  // after the quantity/cost-basis fold above
  }
  let amounts = try await AccountCashFlows.flowAmounts(
    for: transaction, accountId: member,
    hostCurrency: hostCurrency, service: conversionService)
  ```
  Keep the existing sticky-latch semantics for the contributions accumulator unchanged.

- [ ] **Step 4: Run tests, verify pass**

Run: `just test-mac PositionsHistoryBuilderMultiAccountTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: PASS (3 tests).

- [ ] **Step 5: Verify existing history-builder tests still pass + format**

Run: `just test-mac PositionsHistoryBuilderTests 2>&1 | tee .agent-tmp/t1b.txt` (use the exact existing suite type name — confirm via grep) then `just format-check`.
Expected: existing suite green; format-check clean.

- [ ] **Step 6: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native.crypto-pl-chart add Shared/PositionsHistoryBuilder.swift MoolahTests/Shared/PositionsHistoryBuilderMultiAccountTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native.crypto-pl-chart commit -m "feat(positions): generalize PositionsHistoryBuilder to multiple accounts"
```

---

## Task 2: Extract the cost-basis + input assembly into a shared helper

**Files:**
- Create: `Shared/MultiInstrumentPositionsAssembler.swift`
- Modify: `Features/Investments/InvestmentStore+PositionsInput.swift`
- Test: `MoolahTests/Shared/MultiInstrumentPositionsAssemblerTests.swift` (create)

**Interfaces:**
- Consumes: `PositionsHistoryBuilder.build(transactions:accountIds:…)` (Task 1).
- Produces:
  ```swift
  struct MultiInstrumentPositionsAssembler: Sendable {
    let conversionService: any InstrumentConversionService

    // Page through all transactions touching any of `accountIds`.
    func fetchTransactions(
      repository: any TransactionRepository, accountIds: Set<UUID>) async throws -> [Transaction]

    // Open-lot remaining cost per instrument id (host currency Decimal).
    // Instruments whose classification failed are omitted (cost unavailable,
    // not zero) — Rule 11. accountIds-aware: only legs in `accountIds` drive
    // the engine, so internal transfers net out.
    func costBasisSnapshot(
      transactions: [Transaction], accountIds: Set<UUID>, hostCurrency: Instrument
    ) async -> [String: Decimal]

    // Build the full input: overlays cost basis on `valuedRows`, builds the
    // history series, sets hasAnyHistoricalActivity. `alwaysShowsFullSurface`
    // defaults false (multi-instrument hosts collapse when shouldHide);
    // investment caller passes true.
    func assemble(
      title: String, hostCurrency: Instrument, accountIds: Set<UUID>,
      valuedRows: [ValuedPosition], transactions: [Transaction],
      range: PositionsTimeRange, assetKeysByInstrumentId: [String: String],
      performance: AccountPerformance?, alwaysShowsFullSurface: Bool
    ) async -> PositionsViewInput

    static func hasAnyTradeLeg(
      in transactions: [Transaction], accountIds: Set<UUID>, hostCurrency: Instrument) -> Bool
  }
  ```
  `costBasisSnapshot` must classify with the **account-scoped** legs (`legs.filter { accountIds.contains($0.accountId) }`) to match the builder's internal-transfer netting, but pass the txn date and host currency exactly as the current `InvestmentStore.costBasisSnapshot` does. The current investment behavior is the single-account case of this, so existing investment cost-basis tests must remain green.

- [ ] **Step 1: Write failing tests**

Create `MoolahTests/Shared/MultiInstrumentPositionsAssemblerTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("MultiInstrumentPositionsAssembler")
struct MultiInstrumentPositionsAssemblerTests {
  // A crypto account holding a non-host token with a buy history produces an
  // input whose showsChart == true (non-empty series + a cost-bearing row).
  @Test func cryptoAccountInputShowsChart() async throws {
    // Seed a deterministic conversion service with daily prices for the token.
    // valuedRows = [ValuedPosition(token, qty, unitPrice, costBasis: nil, value)]
    // transactions = a single buy of the token in the account.
    // assemble(... alwaysShowsFullSurface: false ...)
    // #expect(input.historicalValue != nil)
    // #expect(input.showsChart == true)
    // #expect(input.showsPLPill == true)   // cost basis present
  }

  // hasAnyTradeLeg is true when any account in the set has a non-host trade leg.
  @Test func hasAnyTradeLegAcrossAccounts() { /* assert true/false cases */ }

  // costBasisSnapshot omits an instrument whose classification fails
  // (unavailable, not zero).
  @Test func costBasisOmitsUnclassifiableInstrument() async { /* … */ }
}
```

Fill bodies using the deterministic conversion-service stub from Task 1's tests and the existing `TestBackend`/`Transaction` builders.

- [ ] **Step 2: Run tests, verify they fail to compile**

Run: `just test-mac MultiInstrumentPositionsAssemblerTests 2>&1 | tee .agent-tmp/t2.txt`
Expected: compile failure — type does not exist.

- [ ] **Step 3: Implement the helper**

Create `Shared/MultiInstrumentPositionsAssembler.swift`. Move the bodies of `fetchAllTransactions`, `costBasisSnapshot`, and `hasAnyTradeLeg` from `InvestmentStore+PositionsInput.swift` into this type, generalizing `accountId`→`accountIds` (paging filter uses `TransactionFilter(accountIds: accountIds)`). `assemble` mirrors the tail of `positionsViewInput`:
```swift
func assemble(…) async -> PositionsViewInput {
  let costSnapshot = await costBasisSnapshot(
    transactions: transactions, accountIds: accountIds, hostCurrency: hostCurrency)
  let rowsWithCost = valuedRows.map { row in
    ValuedPosition(
      instrument: row.instrument, quantity: row.quantity, unitPrice: row.unitPrice,
      costBasis: costSnapshot[row.instrument.id].map {
        InstrumentAmount(quantity: $0, instrument: hostCurrency) },
      value: row.value)
  }
  let series = await PositionsHistoryBuilder(conversionService: conversionService).build(
    transactions: transactions, accountIds: accountIds,
    hostCurrency: hostCurrency, range: range)
  return PositionsViewInput(
    title: title, hostCurrency: hostCurrency, positions: rowsWithCost,
    historicalValue: series, assetKeysByInstrumentId: assetKeysByInstrumentId,
    performance: performance,
    hasAnyHistoricalActivity: Self.hasAnyTradeLeg(
      in: transactions, accountIds: accountIds, hostCurrency: hostCurrency),
    alwaysShowsFullSurface: alwaysShowsFullSurface)
}
```
Use a `Logger` consistent with the existing one. Keep `TransactionFilter(accountIds:)` paging at pageSize 200 with cancellation checks, identical to the original.

- [ ] **Step 4: Refactor `InvestmentStore.positionsViewInput` to delegate**

Replace the cost-basis/history tail of `positionsViewInput` with a call to `MultiInstrumentPositionsAssembler(conversionService: conversionService)`:
- `fetchTransactions(repository:accountIds:[accountId])`
- `assemble(title:…, accountIds:[accountId], valuedRows: valuedPositions, transactions: txns, range:, assetKeysByInstrumentId: assetKeysByInstrumentId, performance: accountPerformance, alwaysShowsFullSurface: true)`

Keep the `guard let transactionRepository else { … historicalValue: nil … }` early return as-is. If `fetchAllTransactions`/`costBasisSnapshot`/`hasAnyTradeLeg` are referenced elsewhere, leave thin forwarding wrappers; otherwise delete them. Behavior must be unchanged.

- [ ] **Step 5: Run assembler tests + full investment suite + format**

Run:
```bash
just test-mac MultiInstrumentPositionsAssemblerTests InvestmentStoreTests 2>&1 | tee .agent-tmp/t2.txt
just format-check
```
Expected: new tests PASS; all existing investment-store tests PASS (no behavior change); format-check clean. (Confirm exact existing suite type names via grep before running.)

- [ ] **Step 6: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native.crypto-pl-chart add Shared/MultiInstrumentPositionsAssembler.swift Features/Investments/InvestmentStore+PositionsInput.swift MoolahTests/Shared/MultiInstrumentPositionsAssemblerTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native.crypto-pl-chart commit -m "refactor(positions): extract shared cost-basis + history assembler"
```

---

## Task 3: Wire the assembler into `MultiInstrumentPositionsSplitModifier`

**Files:**
- Modify: `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`

**Interfaces:**
- Consumes: `MultiInstrumentPositionsAssembler` (Task 2), `session.backend.transactions` (a `TransactionRepository`).
- Produces: `multiInstrumentPositionsSplit(positions:hostCurrency:title:conversionService:accountIds:registrationsVersion:)` — adds `accountIds: [UUID]` (default `[]` so previews/callers without ids degrade gracefully to the current no-chart behavior).

- [ ] **Step 1: Add `accountIds` and range-aware history build**

- Add stored property `let accountIds: [UUID]` to `MultiInstrumentPositionsSplitModifier` and the `multiInstrumentPositionsSplit` extension (default `[]`).
- Add `positionsRange` to the task key so the chart rebuilds on range change:
  ```swift
  .task(id: PositionsTaskKey(
    positions: positions, registrationsVersion: registrationsVersion, range: positionsRange))
  ```
  and add `let range: PositionsTimeRange` to `PositionsTaskKey`.
- In `valuatePositions()`, after computing `rows` and `assetKeys`, build the full input via the assembler **when** `accountIds` is non-empty and a transaction repository is available; otherwise keep the current `historicalValue: nil` input (back-compat for preview/no-id callers):
  ```swift
  if !accountIds.isEmpty, let repository = session?.backend.transactions {
    let assembler = MultiInstrumentPositionsAssembler(conversionService: conversionService)
    let txns: [Transaction]
    do {
      txns = try await assembler.fetchTransactions(
        repository: repository, accountIds: Set(accountIds))
    } catch is CancellationError { return } catch {
      Self.logger.warning("history txn fetch failed: \(error.localizedDescription, privacy: .public)")
      txns = []
    }
    guard !Task.isCancelled else { return }
    positionsInput = await assembler.assemble(
      title: title, hostCurrency: hostCurrency, accountIds: Set(accountIds),
      valuedRows: rows, transactions: txns, range: positionsRange,
      assetKeysByInstrumentId: assetKeys, performance: nil, alwaysShowsFullSurface: false)
    return
  }
  positionsInput = PositionsViewInput(
    title: title, hostCurrency: hostCurrency, positions: rows,
    historicalValue: nil, assetKeysByInstrumentId: assetKeys)
  ```
  Keep all existing `Task.isCancelled` guards. Note `range: positionsRange` flows from the `@State` so the rebuild reflects the user's selection.

- [ ] **Step 2: Build to verify it compiles**

Run: `just build-mac 2>&1 | tee .agent-tmp/t3.txt`
Expected: build succeeds, zero warnings.

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native.crypto-pl-chart add Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native.crypto-pl-chart commit -m "feat(positions): build history series in multi-instrument split"
```

---

## Task 4: Pass `accountIds` from the four call sites

**Files:**
- Modify: `Features/Crypto/CryptoWalletAccountView.swift`
- Modify: `Features/Accounts/Views/GroupDetailView.swift`
- Modify: `Features/Accounts/Views/StandardAccountView.swift`
- Modify: `Features/Exchange/ExchangeAccountView.swift`

- [ ] **Step 1: Thread the ids**

- `CryptoWalletAccountView` (`.multiInstrumentPositionsSplit(...)`): add `accountIds: [account.id]`.
- `GroupDetailView`: add `accountIds: context.accountIds`.
- `StandardAccountView`: add `accountIds: [account.id]`.
- `ExchangeAccountView`: add `accountIds: [account.id]` (confirm the local property name for the account/id via grep first).

Leave previews as-is — they pass no `accountIds`, so they keep the current no-chart behavior and won't try to reach a real repository.

- [ ] **Step 2: Build**

Run: `just build-mac 2>&1 | tee .agent-tmp/t4.txt`
Expected: build succeeds, zero warnings.

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native.crypto-pl-chart add Features/Crypto/CryptoWalletAccountView.swift Features/Accounts/Views/GroupDetailView.swift Features/Accounts/Views/StandardAccountView.swift Features/Exchange/ExchangeAccountView.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native.crypto-pl-chart commit -m "feat(positions): pass accountIds so crypto/group/standard/exchange chart history"
```

---

## Task 5: End-to-end store test through a backend

**Files:**
- Test: `MoolahTests/Shared/MultiInstrumentPositionsAssemblerTests.swift` (extend) or a new `@Suite` file if the type body would exceed the 250-line limit.

**Interfaces:** Consumes `TestBackend` (CloudKitBackend + in-memory GRDB) and a deterministic conversion service / seeded prices.

- [ ] **Step 1: Write the failing end-to-end test**

Through a `TestBackend`, seed: one crypto account holding a non-host token, a buy transaction, and daily prices spanning the range. Fetch via `assembler.fetchTransactions(repository: backend.transactions, accountIds:)`, valuate the rows with `PositionsValuator`, then `assemble(...)`. Assert:
- `input.historicalValue?.total` is non-empty and its last point's value equals `convert(qty, token, host, on: now)` (exact host quantity).
- `input.showsChart == true`.
- For a **group** of two accounts each holding the same token, the aggregate last-day value equals the summed holdings converted — and an internal transfer between the two members does not change the group's last-day value.

- [ ] **Step 2: Run, verify fail, implement nothing new, verify pass**

Run: `just test-mac MultiInstrumentPositionsAssemblerTests 2>&1 | tee .agent-tmp/t5.txt`
The behavior already exists from Tasks 1–2; this test pins it. If it fails, fix the helper, not the test. Expected after: PASS.

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native.crypto-pl-chart add MoolahTests/Shared/
git -C /Users/aj/Documents/code/moolah-project/moolah-native.crypto-pl-chart commit -m "test(positions): end-to-end crypto + group history chart"
```

---

## Task 6: Full verification, reviews, PR

- [ ] **Step 1: Full suite + format**

Run:
```bash
just format
just format-check
just test 2>&1 | tee .agent-tmp/full.txt
grep -iE 'failed|error:' .agent-tmp/full.txt || echo "clean"
```
Expected: 0 failures on iOS + macOS, format-check clean.

- [ ] **Step 2: Run review agents**

Dispatch `code-review`, `concurrency-review`, `instrument-conversion-review`, and `datetime-review` over the diff. Apply all Critical/Important/Minor findings (separate PR only if genuinely out of scope). The instrument-conversion and datetime agents matter most here (daily conversions over a date axis).

- [ ] **Step 3: Manual smoke via the running app (optional but recommended)**

Use the `automate-app` skill to open a real crypto account and an account group on the dev profile and confirm the chart renders. Do not touch the production profile.

- [ ] **Step 4: Open the PR**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native.crypto-pl-chart push origin crypto-pl-chart:crypto-pl-chart
gh pr create --title "Show value/P&L history chart for crypto, groups, standard & exchange accounts" --body "<summary + test plan>"
```
Then land via the `landing-prs` skill.

---

## Self-Review Notes

- **Spec coverage:** value chart for crypto ✅ (Task 4 + 1–3), account groups ✅ (Set<UUID> in Task 1, `context.accountIds` in Task 4, group test in Task 5), standard & exchange ✅ (Task 4). Cost basis / PL pill ✅ via the assembler (Task 2).
- **Chart gate:** `showsChart` needs a cost-bearing row when `shouldHide` is false — Task 2 supplies cost basis, so crypto accounts with open non-host positions clear the gate (verified in Task 2 Step 1 + Task 5).
- **Group internal transfers:** handled by the `Set<UUID>` netting in the builder (value line) and the group-boundary contributions guard (Task 1 Step 3); pinned by tests in Task 1 + Task 5.
- **Partial-sum safety:** unchanged — `PositionsHistoryBuilder` still omits aggregate points when any contributing conversion fails (Rule 11).
- **Open risk:** crypto accounts with many tokens × a long range = many daily conversion calls. Mitigated by the price caches (same path investments use). If Task 6 smoke shows a hang, add a perf note / consider sampling — but do not pre-optimize.
