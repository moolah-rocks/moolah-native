# Unified Account-Detail Layout — Increment 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the unification. Fold `.calculatedFromTrades` **investment** accounts onto the same shared path (`TransactionListView(...).multiInstrumentPositionsSplit(...)` → `PositionsChartTransactionsSplit`) the crypto / exchange / standard / group accounts already use, and collapse the five per-type detail-view dispatch bodies into **one** unified `AccountDetailView`. After this increment there is a single account-detail layout: a data-driven `[Transactions | Positions | Chart]` container with an optional synced-account header slot above it. Delete the now-redundant per-type views (`CryptoWalletAccountView`, `ExchangeAccountView`, `StandardAccountView`'s struct, `GroupDetailView`, the `InvestmentAccountView.positionTrackedLayout` branch) and the legacy `PositionsTransactionsSplit` container once nothing references them. `.recordedValue` (manual-valuation) investment accounts are **out of scope** — deprecated and being removed; they keep their existing `InvestmentAccountView.legacyValuationsLayout` / `RecordedValueInvestmentLayout`, so `InvestmentAccountView` survives but ONLY for the `.recordedValue` branch.

**Architecture:** Incremental. This plan fully specifies **Increment 4** — seven independent, individually-shippable PRs. It builds on Increments 1, 2, and 3 (denser chart, inline sync-error caption, all-instrument value/balance history, the unified `PositionsChartTransactionsSplit` tab/split container, and per-account performance tiles for crypto/exchange/standard/group), which are already implemented on this branch and are treated as present. This is the final increment; there is no Increment 5.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, Swift Testing (`@Suite`/`@Test`), XCUITest (`MoolahUITests_macOS`), GRDB (unaffected here). Design spec: `plans/2026-07-05-unified-account-detail-layout-design.md` (§"Deduplication / Dispatch"; phasing steps 5–6). Increment 2 plan: `plans/2026-07-05-unified-account-detail-layout-increment-2-plan.md`. Increment 3 plan: `plans/2026-07-05-unified-account-detail-layout-increment-3-plan.md`.

## Global Constraints

- Tests use **Swift Testing** (`@Suite`, `@Test`, `#expect`), not XCTest, except UI tests under `MoolahUITests_macOS/` (XCUITest — those import **only** `XCTest`, drive the app through screen drivers, use 10s positive waits and deterministic seeds).
- One extension per protocol conformance; thin views (logic lives in testable helpers) — `guides/AI_ARCHITECTURE_GUIDE.md`.
- Money math via `InstrumentAmount`; **never `abs()` a signed leg or P&L** — `guides/INSTRUMENT_CONVERSION_GUIDE.md`. Partial-availability = `nil` fields (Rule 11): never a partial sum, a phantom zero, or a phantom gain.
- Timezoneless calendar values via `Calendar.utc`; chart x-tokens anchor at noon-UTC — `guides/DATE_TIME_GUIDE.md`.
- The positions valuator + performance compute is **async** and runs inside the existing valuator `.task` on `MultiInstrumentPositionsSplitModifier`; honour `Task.isCancelled` guards like the rest of `valuatePositions`/`buildHistoryInput`, and keep every new type `Sendable`.
- `just` test filters are **positional**, not `FILTER=` — e.g. `just test-mac AccountDetailFullSurfaceGateTests`, `just test-ui AccountDetailUnifiedLayoutTests`.
- Run `just build-mac` and `just format-check` after every task; fix all findings. Run the relevant AI reviewer agents (`@code-review`, `@ui-review`, `@concurrency-review`, `@instrument-conversion-review`, `@ui-test-review`) before committing and fix every finding — `guides/AI_REVIEW_GATE_GUIDE.md`.
- Each task = one PR, landed via the `landing-prs` skill. Never `git push origin main`.
- Test wait helpers default to 10s; never pass short positive timeouts — memory `feedback_test_wait_timeouts_10s`.
- **Deletion safety:** delete a per-type view only AFTER the dispatch routes its account type through the unified path and the build + tests are green. Sequence so each task is independently shippable and green.

## File Structure

**Created:**
- `Features/Accounts/Views/AccountDetailView.swift` — the single unified account-detail view: an optional synced-account header slot above `TransactionListView(...).multiInstrumentPositionsSplit(...)`. Replaces `CryptoWalletAccountView`, `ExchangeAccountView`, `StandardAccountView`, `GroupDetailView`, and the `.calculatedFromTrades` branch of `InvestmentAccountView`. Carries a pure `static func showsSyncedHeader(for:)`. (Task 2)
- `Features/Accounts/AccountGroupPositions.swift` — the `aggregatedGroupPositions(across:in:)` free function relocated verbatim out of `GroupDetailView.swift` so its unit tests survive that file's deletion. (Task 4)
- `MoolahTests/Views/Positions/AccountDetailFullSurfaceGateTests.swift` — unit tests for `AccountDetailLayout.showsFullSurface(alwaysShowsFullSurface:otherwiseShows:)`. (Task 1)
- `MoolahTests/Features/Accounts/AccountDetailViewHeaderTests.swift` — unit tests for `AccountDetailView.showsSyncedHeader(for:)` (crypto-with-chain / exchange → true; standard / bank / crypto-without-chain → false). (Task 2)
- `MoolahTests/Shared/AccountPerformanceInvestmentEquivalenceTests.swift` — unit tests proving `compute(accountId:)` and `computeMultiInstrument([id])` agree on a funded investment fixture, and documenting the one intentional divergence (no-external-flow). (Task 5)
- `MoolahUITests_macOS/Tests/AccountDetailUnifiedLayoutTests.swift` — macOS UI regression: crypto renders header + unified split; a funded investment `.calculatedFromTrades` account renders pinned positions + performance tiles + working `[Transactions | Chart]` toggle. (Task 7)

**Modified:**
- `Shared/Views/Positions/AccountDetailLayout.swift` — add `static func showsFullSurface(alwaysShowsFullSurface:otherwiseShows:)`. (Task 1)
- `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift` — add a `alwaysShowsFullSurface: Bool` stored property (defaulting to `false` at the `View` extension) and thread it through `hasPositions`, `computePerformance`, `buildHistoryInput`'s context, and the two loading/empty `PositionsViewInput` seeds. (Task 1)
- `App/ContentView+AccountDetail.swift` — replace the per-type `switch` with: `.recordedValue` investment → `InvestmentAccountView`; every other type → `AccountDetailView`. (Tasks 2, 3, 4, 5)
- `App/ContentView+GroupDetail.swift` — route the group host through `AccountDetailView` (plural `accountIds`, no header). (Task 4)
- `Features/Accounts/Views/StandardAccountView.swift` — delete the `StandardAccountView` struct + its preview; **keep** `AllTransactionsView` (unrelated sibling in the same file). (Task 3)
- `Features/Investments/Views/InvestmentAccountView.swift` — collapse to the `.recordedValue` path only: drop `positionTrackedLayout`, the `account.valuationMode` `switch`, and the position-tracked `@State`/`.task` machinery. (Task 5)
- `Features/Investments/Views/InvestmentAccountView+Loading.swift` — drop the position-tracked helpers (`reloadPositions`, `maybeAutoWidenRange`); keep the recordedValue load path. (Task 5)
- `MoolahTests/Features/Exchange/ExchangeAccountViewRoutingTests.swift` — repoint the compile-guard at `AccountDetailView` (or delete; see Task 3). (Task 3)

**Deleted:**
- `Features/Crypto/CryptoWalletAccountView.swift` — folded into `AccountDetailView`. (Task 2)
- `Features/Exchange/ExchangeAccountView.swift` — folded into `AccountDetailView`. (Task 3)
- `Features/Accounts/Views/GroupDetailView.swift` — folded into `AccountDetailView`; its `aggregatedGroupPositions` moves to `AccountGroupPositions.swift`. (Task 4)
- `Shared/Views/Positions/PositionsTransactionsSplit.swift` — the legacy two-builder container; last caller (`InvestmentAccountView.positionTrackedLayout`) removed in Task 5. (Task 6)
- `Shared/Views/Positions/PositionsView.swift` — **conditional**: after the fold its only production caller is gone (grep-verified in Task 6). Delete iff nothing references it; otherwise leave and note. See Task 6 + the flagged ambiguity in the Self-Review. (Task 6)

**NOT touched (backward-compatibility invariants):**
- `Features/Accounts/Views/StandardAccountView.swift` → `AllTransactionsView` — the "All Transactions" sidebar leaf. Structurally unrelated to the fold; stays exactly as-is.
- `Shared/AccountPerformanceCalculator.swift` — `compute(accountId:)`, `computeMultiInstrument(...)`, and `computeLegacy(...)` are all unchanged. Task 5 only *consumes* `computeMultiInstrument` via the shared modifier and *adds* an equivalence test.
- `Features/Investments/**` recordedValue surface (`legacyValuationsLayout`, `RecordedValueInvestmentLayout`, `InvestmentChartView`, valuations list, `InvestmentStore.loadAllData`/`computeLegacy`) — the manual-valuation path stays fully functional.
- `Shared/Views/Positions/PositionsChartPane.swift`, `PositionsPane.swift`, `PositionsChartTransactionsSplit.swift`, `MultiInstrumentPositionsAssembler.swift` — the shared container + assembler already carry everything the fold needs; no change.

## Key decisions (locked)

- **Investment performance source = the shared `computeMultiInstrument([id])`, not `InvestmentStore.compute(accountId:)`.** The fold routes investment through `.multiInstrumentPositionsSplit`, so performance is computed inside `MultiInstrumentPositionsSplitModifier.computePerformance` exactly like every other account — `InvestmentStore` no longer participates in `.calculatedFromTrades` *display*. This is verified equivalent (Task 5): for a single-account host, `extractGroupFlows` reduces to `extractFlows` (the `membersTouched.count == 1` gate never excludes anything when `accountIds == {id}`, and both delegate the per-leg amount to the same `AccountCashFlows.flowAmounts(for:accountId:hostCurrency:service:)`), and both call the same private `assemble(...)` (Modified Dietz / IRR). Cost-basis snapshot and chart series are identical because both paths go through `MultiInstrumentPositionsAssembler.assemble(...)` (same `costBasisSnapshot` + `PositionsHistoryBuilder`). **One intentional divergence:** the *no-external-flow* edge — an investment account funded solely by single-account income legs (no opening balance, no transfer-in) — degrades to `AccountPerformance.currentValueOnly(...)` (P&L / return nil) under `computeMultiInstrument`, where the legacy single-account `compute` returned `profitLoss = currentValue` ("entire value is gain"). We accept the `currentValueOnly` shape: it is the honest Rule-11 result (an income-only balance is not investment *gain*), it is a rare/pathological funding pattern for a trade-valued account, and every normally-funded investment account (opening balance or transfer-in) has non-empty flows and is bit-identical between the two paths. Task 5 asserts the equivalence on a funded fixture and documents the divergence with a second test.
- **Always-full-surface mechanism = a `alwaysShowsFullSurface: Bool` threaded through the modifier, OR-ing into both surface gates.** Investment `.calculatedFromTrades` must show its performance tiles + chart + positions even when every holding is sold (only cash/host remains), where the Increment-3 gates (`AccountDetailLayout.showsPerformanceTiles` and `hasNonHostHoldings`) would both hide them. The dispatch passes `alwaysShowsFullSurface: account.type == .investment`. In the modifier: the Positions-pane gate becomes `showsFullSurface(alwaysShowsFullSurface:, otherwiseShows: hasNonHostHoldings(...))` and the perf-compute gate becomes `showsFullSurface(alwaysShowsFullSurface:, otherwiseShows: showsPerformanceTiles(...))`. The flag is also carried into `PositionsAssemblyContext.alwaysShowsFullSurface` (and thus the assembled `PositionsViewInput`) for consistency, though the unified panes (`PositionsChartPane` / `PositionsPane`) render unconditionally and read the surface decision from the container's `hasPositions` bool + `input.performance != nil`, not from `input.rendersNothing`. `showsFullSurface` is a trivial pure helper on `AccountDetailLayout` so the OR-logic is unit-tested once (Task 1). Every non-investment host passes `false` (default) → behaviour identical to Increment 3.
- **Header slot = an optional synced-account header computed inside `AccountDetailView` from `account.type` + `ProfileSession`, not a per-type leaf.** `AccountDetailView` renders `VStack(spacing: 0) { header; TransactionListView(...).multiInstrumentPositionsSplit(...) }`. The header is a `@ViewBuilder` gated by the pure `static func showsSyncedHeader(for:)`: `.crypto` with a resolvable `ChainConfig` → header; `.exchange` → header; everything else → empty. It renders `SyncedAccountHeaderView(account:syncStore:cryptoTokenStore:exchangeTokenStore:)` from `session.cryptoSyncStore` / `session.cryptoTokenStore` (exactly what `CryptoWalletAccountView`/`ExchangeAccountView` did today). This preserves **both** the crypto and the exchange headers (the spec named crypto; exchange has the identical slot and must not be lost). The group host and standard/investment hosts pass `syncedHeaderAccount: nil` → no header.
- **Group vs single-account host is a dispatch-time difference only.** `AccountDetailView` takes the *resolved* split inputs (`title`, `transactionFilter`, `positions`, `hostCurrency`, `accountIds`, …), never an `Account` or an `AccountViewContext`. The single-account dispatch builds them from the `Account`; the group dispatch builds them from the `AccountViewContext` (plural `accountIds`, `aggregatedGroupPositions`, `displayInstrument`). The modifier already supports plural `accountIds: [UUID]`, so a group host and a single-account host share one code path (a 1-element `accountIds` collapses to the single-account rules).
- **Transaction inspector uniformity.** `AccountDetailView` uses the 6-argument `TransactionListView(title:filter:accounts:categories:earmarks:transactionStore:)` — the self-managed-inspector form the crypto/exchange/standard/group leaves use today. The investment `.calculatedFromTrades` leaf previously used the `selectedTransaction:`-binding form + `.transactionInspector`; folding it aligns it with the others (the inspector still works, driven by `TransactionListView` internally). This is a deliberate simplification, not a regression.
- **`InvestmentAccountView` survives for `.recordedValue` only.** The dispatch routes `.recordedValue` investment accounts to `InvestmentAccountView` and every other type (including `.calculatedFromTrades` investment) to `AccountDetailView`. `InvestmentAccountView` is trimmed to the legacy path: the `account.valuationMode` `switch`, `positionTrackedLayout`, and the position-tracked `@State`/`.task`/loading helpers are removed; its load `.task` calls `investmentStore.loadAllData(account:profileCurrency:)` directly for the valuations list / legacy chart / legacy `AccountPerformanceTiles`. The historical mode-flip crash guard (`initialLoadComplete`, `focusAnchor`) is retained in simplified form because a sync-driven mode flip now swaps `InvestmentAccountView` ↔ `AccountDetailView` at the dispatch boundary (a clean teardown/mount under `ContentView.detail`'s `.id(selection)` wrap) rather than flipping layouts inside one view.

---

## Task 1: Thread `alwaysShowsFullSurface` through the shared modifier

Add the always-full-surface mechanism to `MultiInstrumentPositionsSplitModifier` so a caller (the investment fold in Task 5) can force the performance tiles + positions pane on even when the account holds only host currency. Pure OR-logic, unit-tested via a trivial `AccountDetailLayout` helper. Default `false` at the `View` extension, so the four existing call sites are behaviourally unchanged — shippable on its own.

**Files:**
- Modify: `Shared/Views/Positions/AccountDetailLayout.swift`
- Modify: `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`
- Create: `MoolahTests/Views/Positions/AccountDetailFullSurfaceGateTests.swift`

**Interfaces produced:**
- `AccountDetailLayout.showsFullSurface(alwaysShowsFullSurface: Bool, otherwiseShows base: Bool) -> Bool`
- `MultiInstrumentPositionsSplitModifier` gains `let alwaysShowsFullSurface: Bool`; `multiInstrumentPositionsSplit(...)` gains `alwaysShowsFullSurface: Bool = false`.

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Views/Positions/AccountDetailFullSurfaceGateTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountDetailLayout.showsFullSurface")
struct AccountDetailFullSurfaceGateTests {
  @Test("always-full forces the surface on even when the base gate is false")
  func alwaysForcesOn() {
    #expect(
      AccountDetailLayout.showsFullSurface(alwaysShowsFullSurface: true, otherwiseShows: false))
  }

  @Test("without always-full, the base gate decides")
  func fallsThroughToBase() {
    #expect(
      AccountDetailLayout.showsFullSurface(alwaysShowsFullSurface: false, otherwiseShows: true))
    #expect(
      !AccountDetailLayout.showsFullSurface(alwaysShowsFullSurface: false, otherwiseShows: false))
  }

  @Test("always-full and a true base still show")
  func bothTrue() {
    #expect(
      AccountDetailLayout.showsFullSurface(alwaysShowsFullSurface: true, otherwiseShows: true))
  }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `just test-mac AccountDetailFullSurfaceGateTests`
Expected: FAIL — `showsFullSurface` does not exist.

- [ ] **Step 3: Add the helper**

In `Shared/Views/Positions/AccountDetailLayout.swift`, add to the `AccountDetailLayout` enum (below `showsPerformanceTiles`):

```swift
  /// Whether the host renders its full surface (performance tiles + a
  /// positions pane) regardless of current holdings. Investment
  /// `.calculatedFromTrades` hosts pass `alwaysShowsFullSurface: true` so a
  /// fully-sold account still shows its performance / chart / positions;
  /// every other host falls through to `base` — the per-element gate that
  /// answers "does the account actually hold something worth surfacing".
  static func showsFullSurface(
    alwaysShowsFullSurface: Bool, otherwiseShows base: Bool
  ) -> Bool {
    alwaysShowsFullSurface || base
  }
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `just test-mac AccountDetailFullSurfaceGateTests`
Expected: PASS.

- [ ] **Step 5: Thread the flag through the modifier**

In `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`:

1. Add the stored property after `accountChainId`:

```swift
  /// `true` for investment `.calculatedFromTrades` hosts: forces the
  /// performance tiles + positions pane on even when only host currency
  /// remains (every holding sold). Other hosts leave it `false` and gate
  /// each element on whether the account actually holds non-host positions.
  let alwaysShowsFullSurface: Bool
```

2. Replace `hasPositions`:

```swift
  private var hasPositions: Bool {
    AccountDetailLayout.showsFullSurface(
      alwaysShowsFullSurface: alwaysShowsFullSurface,
      otherwiseShows: AccountDetailLayout.hasNonHostHoldings(
        rawPositions: positions,
        hostCurrency: hostCurrency,
        positionsInput: positionsInput))
  }
```

3. In `computePerformance(...)`, replace the gate `guard` with:

```swift
    guard
      AccountDetailLayout.showsFullSurface(
        alwaysShowsFullSurface: alwaysShowsFullSurface,
        otherwiseShows: AccountDetailLayout.showsPerformanceTiles(
          valuedRows: rows, hostCurrency: hostCurrency))
    else { return nil }
```

4. In `buildHistoryInput(...)`, thread the flag into the context:

```swift
    let context = PositionsAssemblyContext(
      title: title,
      hostCurrency: hostCurrency,
      accountIds: accountIdSet,
      assetKeysByInstrumentId: assetKeys,
      performance: performance,
      alwaysShowsFullSurface: alwaysShowsFullSurface)
```

5. In `loadingBaseInput(...)`, add `alwaysShowsFullSurface: alwaysShowsFullSurface` to the `PositionsViewInput(...)` initialiser, and in `valuatePositions()`'s empty-seed early return add the same argument to its `PositionsViewInput(...)`:

```swift
      positionsInput = PositionsViewInput(
        title: title, hostCurrency: hostCurrency, positions: [], historicalValue: nil,
        alwaysShowsFullSurface: alwaysShowsFullSurface)
```

6. Update the `MultiInstrumentPositionsSplitModifier(...)` construction inside the `multiInstrumentPositionsSplit(...)` `View` extension and its signature to add `alwaysShowsFullSurface: Bool = false`:

```swift
  func multiInstrumentPositionsSplit(
    positions: [Position],
    hostCurrency: Instrument,
    title: String,
    conversionService: (any InstrumentConversionService)?,
    registrationsVersion: Int = 0,
    accountIds: [UUID] = [],
    accountChainId: Int? = nil,
    alwaysShowsFullSurface: Bool = false
  ) -> some View {
    modifier(
      MultiInstrumentPositionsSplitModifier(
        positions: positions,
        hostCurrency: hostCurrency,
        title: title,
        conversionService: conversionService,
        registrationsVersion: registrationsVersion,
        accountIds: accountIds,
        accountChainId: accountChainId,
        alwaysShowsFullSurface: alwaysShowsFullSurface))
  }
```

- [ ] **Step 6: Build, format, review**

Run: `just build-mac` (Expected: succeeds — the four existing call sites use the `alwaysShowsFullSurface` default, no edits). Then `just format-check` (Expected: clean). Run `@code-review` and `@concurrency-review` on the modifier; fix every finding and re-review until clean.

- [ ] **Step 7: Commit**

```bash
git -C . add Shared/Views/Positions/AccountDetailLayout.swift Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift MoolahTests/Views/Positions/AccountDetailFullSurfaceGateTests.swift
git -C . commit -m "feat(positions): thread always-full-surface flag through the unified split modifier"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 2: Introduce `AccountDetailView` and route crypto through it

Build the single unified account-detail view (header slot + split) and route the `.crypto` account type through it, deleting `CryptoWalletAccountView`. This proves the header slot end-to-end.

**Files:**
- Create: `Features/Accounts/Views/AccountDetailView.swift`
- Create: `MoolahTests/Features/Accounts/AccountDetailViewHeaderTests.swift`
- Modify: `App/ContentView+AccountDetail.swift`
- Delete: `Features/Crypto/CryptoWalletAccountView.swift`

**Interfaces produced:**
- `struct AccountDetailView: View`
- `AccountDetailView.showsSyncedHeader(for: Account) -> Bool` (pure, static)

- [ ] **Step 1: Write the failing header-gate test**

Create `MoolahTests/Features/Accounts/AccountDetailViewHeaderTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountDetailView.showsSyncedHeader")
struct AccountDetailViewHeaderTests {
  @Test("a crypto account with a known chain shows the synced header")
  func cryptoWithChainShowsHeader() {
    let account = Account(
      name: "Wallet", type: .crypto, instrument: .AUD,
      valuationMode: .calculatedFromTrades,
      walletAddress: "0x0000000000000000000000000000000000000000", chainId: 1)
    #expect(AccountDetailView.showsSyncedHeader(for: account))
  }

  @Test("a crypto account with no chain hides the header")
  func cryptoWithoutChainHidesHeader() {
    let account = Account(
      name: "Wallet", type: .crypto, instrument: .AUD,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc", chainId: nil)
    #expect(!AccountDetailView.showsSyncedHeader(for: account))
  }

  @Test("an exchange account shows the synced header")
  func exchangeShowsHeader() {
    let account = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      valuationMode: .calculatedFromTrades, exchangeProvider: .coinstash)
    #expect(AccountDetailView.showsSyncedHeader(for: account))
  }

  @Test("a bank account hides the header")
  func bankHidesHeader() {
    let account = Account(name: "Checking", type: .bank, instrument: .AUD)
    #expect(!AccountDetailView.showsSyncedHeader(for: account))
  }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `just test-mac AccountDetailViewHeaderTests`
Expected: FAIL — `AccountDetailView` does not exist.

- [ ] **Step 3: Implement `AccountDetailView`**

Create `Features/Accounts/Views/AccountDetailView.swift`:

```swift
import SwiftUI

/// The single unified account-detail view for every account type except
/// `.recordedValue` investment accounts (deprecated; they keep
/// `InvestmentAccountView.legacyValuationsLayout`). Composes an optional
/// synced-account header above the shared
/// `TransactionListView(...).multiInstrumentPositionsSplit(...)` container —
/// which itself renders the data-driven `[Transactions | Positions | Chart]`
/// surface (chart + transactions always; positions + performance tiles
/// gated, or forced on for investment via `alwaysShowsFullSurface`).
///
/// Takes the *resolved* split inputs rather than an `Account` or an
/// `AccountViewContext`, so a single-account host and a group host share one
/// code path (the group dispatch supplies plural `accountIds` +
/// `aggregatedGroupPositions`). The synced header is derived from
/// `syncedHeaderAccount` + `ProfileSession`; group / standard / investment
/// hosts pass `syncedHeaderAccount: nil`.
///
/// This view must NOT contain its own `NavigationStack` — the enclosing
/// stack is provided by `ContentView.detail`'s `.id(selection)` wrap.
struct AccountDetailView: View {
  let title: String
  let transactionFilter: TransactionFilter
  let positions: [Position]
  let hostCurrency: Instrument
  let accountIds: [UUID]
  let conversionService: any InstrumentConversionService
  let registrationsVersion: Int
  let accountChainId: Int?
  let alwaysShowsFullSurface: Bool
  /// The account whose synced header rides above the split, when the type
  /// warrants one (`showsSyncedHeader`). `nil` for group / standard /
  /// investment hosts.
  let syncedHeaderAccount: Account?
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @Environment(ProfileSession.self) private var session: ProfileSession?

  var body: some View {
    VStack(spacing: 0) {
      header
      TransactionListView(
        title: title,
        filter: transactionFilter,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore
      )
      .multiInstrumentPositionsSplit(
        positions: positions,
        hostCurrency: hostCurrency,
        title: title,
        conversionService: conversionService,
        registrationsVersion: registrationsVersion,
        accountIds: accountIds,
        accountChainId: accountChainId,
        alwaysShowsFullSurface: alwaysShowsFullSurface)
    }
  }

  /// The type-specific synced-account header slot. Renders
  /// `SyncedAccountHeaderView` for a synced account (crypto with a known
  /// chain, or exchange) when a `cryptoSyncStore` is available; otherwise an
  /// empty slot. Derives the chain name from `chainId` internally, so the
  /// chain is not passed in.
  @ViewBuilder private var header: some View {
    if let account = syncedHeaderAccount,
      Self.showsSyncedHeader(for: account),
      let session,
      let syncStore = session.cryptoSyncStore
    {
      SyncedAccountHeaderView(
        account: account,
        syncStore: syncStore,
        cryptoTokenStore: session.cryptoTokenStore,
        exchangeTokenStore: ExchangeTokenStore(synchronizable: true))
    }
  }

  /// Whether `account` warrants a synced-account header. Pure so the routing
  /// rule is unit-testable without instantiating the view. Crypto shows a
  /// header only when its chain resolves to a `ChainConfig`; exchange always
  /// shows one; every other type shows none.
  static func showsSyncedHeader(for account: Account) -> Bool {
    switch account.type {
    case .crypto:
      guard let chainId = account.chainId else { return false }
      return ChainConfig.config(for: chainId) != nil
    case .exchange:
      return true
    default:
      return false
    }
  }
}
```

> **Signature check during implementation:** confirm `SyncedAccountHeaderView.init` still takes `(account:syncStore:cryptoTokenStore:exchangeTokenStore:)` (verified against `Features/Sync/SyncedAccountHeaderView.swift`), that `ProfileSession.cryptoSyncStore` / `.cryptoTokenStore` are optional, and that `ExchangeTokenStore(synchronizable:)` and `ChainConfig.config(for:)` exist as used by the deleted `CryptoWalletAccountView`. If `Account.type` has no `default`-reachable non-crypto/exchange cases beyond what the `switch` handles, keep the `default` arm.

- [ ] **Step 4: Run the header test, verify it passes**

Run: `just test-mac AccountDetailViewHeaderTests`
Expected: PASS.

- [ ] **Step 5: Route crypto through `AccountDetailView`, delete `CryptoWalletAccountView`**

In `App/ContentView+AccountDetail.swift`, replace the `case .crypto:` arm with an `AccountDetailView` construction:

```swift
      case .crypto:
        AccountDetailView(
          title: account.name,
          transactionFilter: TransactionFilter(accountId: account.id),
          positions: accountStore.positions(for: account.id),
          hostCurrency: account.instrument,
          accountIds: [account.id],
          conversionService: session.backend.conversionService,
          registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0,
          accountChainId: account.chainId,
          alwaysShowsFullSurface: false,
          syncedHeaderAccount: account,
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
```

Then delete `Features/Crypto/CryptoWalletAccountView.swift`:

```bash
git -C . rm Features/Crypto/CryptoWalletAccountView.swift
```

- [ ] **Step 6: Build, preview, format, review**

Run: `just build-mac` (Expected: succeeds; `CryptoWalletAccountView` has no remaining references — grep to confirm: `grep -rn "CryptoWalletAccountView" .` returns only removed lines). Use `reviewing-ui-with-preview` on `AccountDetailView.swift` (add a `#Preview` mirroring the old `CryptoWalletAccountView` preview: an in-memory `ProfileSession.preview()` whose crypto wiring is nil, so the header is empty and the split renders) to confirm the split still renders. Run `just format-check`; fix. Run `@code-review`, `@ui-review`, `@concurrency-review` on `AccountDetailView.swift` and the dispatch; fix every finding and re-review until clean.

- [ ] **Step 7: Commit**

```bash
git -C . add Features/Accounts/Views/AccountDetailView.swift MoolahTests/Features/Accounts/AccountDetailViewHeaderTests.swift App/ContentView+AccountDetail.swift
git -C . rm Features/Crypto/CryptoWalletAccountView.swift
git -C . commit -m "feat(accounts): unify crypto account detail onto AccountDetailView"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 3: Route exchange through `AccountDetailView`, delete `ExchangeAccountView`

Fold the `.exchange` type onto `AccountDetailView` (its header is the same `SyncedAccountHeaderView` slot, already handled by `showsSyncedHeader`), delete `ExchangeAccountView`, and repoint its compile-guard routing test.

**Files:**
- Modify: `App/ContentView+AccountDetail.swift`
- Modify: `MoolahTests/Features/Exchange/ExchangeAccountViewRoutingTests.swift`
- Delete: `Features/Exchange/ExchangeAccountView.swift`

- [ ] **Step 1: Route exchange through `AccountDetailView`**

In `App/ContentView+AccountDetail.swift`, replace the `case .exchange:` arm with an `AccountDetailView` construction identical to the `.crypto` arm from Task 2 except `accountChainId: nil` (exchange accounts are not chain-scoped):

```swift
      case .exchange:
        AccountDetailView(
          title: account.name,
          transactionFilter: TransactionFilter(accountId: account.id),
          positions: accountStore.positions(for: account.id),
          hostCurrency: account.instrument,
          accountIds: [account.id],
          conversionService: session.backend.conversionService,
          registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0,
          accountChainId: nil,
          alwaysShowsFullSurface: false,
          syncedHeaderAccount: account,
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
```

- [ ] **Step 2: Repoint the routing compile-guard test**

`MoolahTests/Features/Exchange/ExchangeAccountViewRoutingTests.swift` is a build/compile guard that constructs `ExchangeAccountView`. Repoint it to construct `AccountDetailView` for an `.exchange` account and assert `AccountDetailView.showsSyncedHeader(for:)` returns `true` — proving exchange still composes the shared header. Rewrite the body:

```swift
import Testing

@testable import Moolah

/// Build/compile guard for the exchange routing: an `.exchange` account
/// composes the unified `AccountDetailView` with the shared synced-account
/// header. `ContentView.accountDetail(id:)`'s switch is private and SwiftUI
/// views aren't unit-testable, so this pins the construction + the header
/// routing rule; end-to-end routing is covered by
/// `AccountDetailUnifiedLayoutTests` (Task 7).
@Suite("Exchange account routing — AccountDetailView")
@MainActor
struct ExchangeAccountViewRoutingTests {
  @Test
  func exchangeAccountRoutesToUnifiedViewWithHeader() throws {
    let account = Account(
      name: "Coinstash", type: .exchange,
      instrument: .AUD, valuationMode: .calculatedFromTrades,
      exchangeProvider: .coinstash)
    #expect(AccountDetailView.showsSyncedHeader(for: account))
    let session = try ProfileSession.preview()
    _ = AccountDetailView(
      title: account.name,
      transactionFilter: TransactionFilter(accountId: account.id),
      positions: [],
      hostCurrency: account.instrument,
      accountIds: [account.id],
      conversionService: session.backend.conversionService,
      registrationsVersion: 0,
      accountChainId: nil,
      alwaysShowsFullSurface: false,
      syncedHeaderAccount: account,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: session.transactionStore)
  }
}
```

(If the file's suite name should live under a renamed file, keep the file name — renaming risks merge-queue churn; the suite string is what matters.)

- [ ] **Step 3: Delete `ExchangeAccountView`**

```bash
git -C . rm Features/Exchange/ExchangeAccountView.swift
```

Confirm no other references: `grep -rn "ExchangeAccountView" .` returns only the removed lines (and the now-repointed test's history). Check `Features/Sync/SyncedAccountHeaderView+Previews.swift` (it appeared in the deletion-reference grep) — if it constructs `ExchangeAccountView`, repoint or drop that preview; if it only mentions it in a comment, update the comment.

- [ ] **Step 4: Build, run, format, review**

Run: `just build-mac` (Expected: succeeds). Run: `just test-mac ExchangeAccountViewRoutingTests` (Expected: PASS). Run `just format-check`; fix. Run `@code-review` on the dispatch + test; fix every finding.

- [ ] **Step 5: Commit**

```bash
git -C . add App/ContentView+AccountDetail.swift MoolahTests/Features/Exchange/ExchangeAccountViewRoutingTests.swift
git -C . rm Features/Exchange/ExchangeAccountView.swift
git -C . commit -m "feat(accounts): unify exchange account detail onto AccountDetailView"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 4: Route standard + group through `AccountDetailView`, delete `StandardAccountView` + `GroupDetailView`

Fold the `default:` (standard) account arm and the group host onto `AccountDetailView` (no header). Delete the `StandardAccountView` struct (keep `AllTransactionsView`) and `GroupDetailView`, relocating `aggregatedGroupPositions` so its tests survive.

**Files:**
- Create: `Features/Accounts/AccountGroupPositions.swift`
- Modify: `App/ContentView+AccountDetail.swift`
- Modify: `App/ContentView+GroupDetail.swift`
- Modify: `Features/Accounts/Views/StandardAccountView.swift` (delete the `StandardAccountView` struct + its preview; keep `AllTransactionsView`)
- Delete: `Features/Accounts/Views/GroupDetailView.swift`

- [ ] **Step 1: Relocate `aggregatedGroupPositions`**

Create `Features/Accounts/AccountGroupPositions.swift`, moving the free function **verbatim** from `GroupDetailView.swift` (lines 1–26), with its doc comment:

```swift
import Foundation

/// Sums per-instrument quantities across the supplied account ids,
/// preserving first-seen order. Members holding the same instrument
/// coalesce to one row; multi-instrument groups expose a row per
/// instrument. Pure (no actor isolation) so it can be unit-tested
/// without instantiating the SwiftUI view.
func aggregatedGroupPositions(
  across accountIds: [UUID], in accounts: Accounts
) -> [Position] {
  var sums: [Instrument: Decimal] = [:]
  var order: [Instrument] = []
  for id in accountIds {
    guard let account = accounts.by(id: id) else { continue }
    for position in account.positions {
      if sums[position.instrument] == nil {
        order.append(position.instrument)
      }
      sums[position.instrument, default: 0] += position.quantity
    }
  }
  return order.compactMap { instrument in
    guard let quantity = sums[instrument] else { return nil }
    return Position(instrument: instrument, quantity: quantity)
  }
}
```

`MoolahTests/Features/GroupAggregatedPositionsTests.swift` (which calls `aggregatedGroupPositions`) needs no change — same symbol, same module.

- [ ] **Step 2: Route the standard (`default`) arm**

In `App/ContentView+AccountDetail.swift`, replace the `default:` arm's `StandardAccountView(...)` with:

```swift
      default:
        AccountDetailView(
          title: account.name,
          transactionFilter: TransactionFilter(accountId: account.id),
          positions: accountStore.positions(for: account.id),
          hostCurrency: account.instrument,
          accountIds: [account.id],
          conversionService: session.backend.conversionService,
          registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0,
          accountChainId: nil,
          alwaysShowsFullSurface: false,
          syncedHeaderAccount: nil,
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
```

- [ ] **Step 3: Route the group host**

In `App/ContentView+GroupDetail.swift`, replace the `GroupDetailView(...)` construction with an `AccountDetailView` built from the `AccountViewContext` (plural `accountIds`, aggregated positions, no header):

```swift
      AccountDetailView(
        title: context.displayName,
        transactionFilter: TransactionFilter(accountIds: Set(context.accountIds)),
        positions: aggregatedGroupPositions(across: context.accountIds, in: accountStore.accounts),
        hostCurrency: context.displayInstrument,
        accountIds: context.accountIds,
        conversionService: session.backend.conversionService,
        registrationsVersion: 0,
        accountChainId: nil,
        alwaysShowsFullSurface: false,
        syncedHeaderAccount: nil,
        accounts: accountStore.accounts,
        categories: categoryStore.categories,
        earmarks: earmarkStore.earmarks,
        transactionStore: transactionStore)
```

Leave the `else { ContentUnavailableView(...) }` and `groupSyncStatuses(for:)` helper unchanged.

> **Note:** `groupSyncStatuses(for:)` was passed into `AccountViewContextBuilder.build(... syncStatuses:)`, not into `GroupDetailView`; it stays. Confirm during implementation that nothing else consumed `GroupDetailView`'s per-member sync statuses (the group host shows no synced header by design — a group aggregates members and has no single wallet address).

- [ ] **Step 4: Delete the folded views**

- In `Features/Accounts/Views/StandardAccountView.swift`, delete the `StandardAccountView` struct (its doc comment + body) and the `#Preview` + `seedStandardAccountPreview` helper that exercise it. **Keep** `AllTransactionsView` and the file header comment (trim the header's "Two thin per-leaf wrappers" wording to describe just `AllTransactionsView`).
- Delete `GroupDetailView.swift`:

```bash
git -C . rm Features/Accounts/Views/GroupDetailView.swift
```

Confirm no dangling references: `grep -rn "StandardAccountView\|GroupDetailView" .` returns only removed lines. Check `MoolahUITests_macOS/Helpers/Screens/SidebarScreen+GroupNavigation.swift` (appeared in the reference grep) — if it references `GroupDetailView` only in a comment/identifier, update the comment; it should not construct the type.

- [ ] **Step 5: Build, run, format, review**

Run: `just build-mac` (Expected: succeeds). Run: `just test-mac GroupAggregatedPositionsTests` (Expected: PASS — the relocated function is behaviour-identical). Run `just format-check`; fix. Run `@code-review` and `@ui-review` on the two dispatch files + `AccountGroupPositions.swift` + the trimmed `StandardAccountView.swift`; fix every finding.

- [ ] **Step 6: Commit**

```bash
git -C . add Features/Accounts/AccountGroupPositions.swift App/ContentView+AccountDetail.swift App/ContentView+GroupDetail.swift Features/Accounts/Views/StandardAccountView.swift
git -C . rm Features/Accounts/Views/GroupDetailView.swift
git -C . commit -m "feat(accounts): unify standard + group account detail onto AccountDetailView"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 5: Fold `.calculatedFromTrades` investment accounts onto `AccountDetailView`

Route position-tracked investment accounts through the unified path with `alwaysShowsFullSurface: true`, trim `InvestmentAccountView` to the `.recordedValue` legacy path only, and lock the performance equivalence (design tension #1) with a unit test.

**Files:**
- Create: `MoolahTests/Shared/AccountPerformanceInvestmentEquivalenceTests.swift`
- Modify: `App/ContentView+AccountDetail.swift`
- Modify: `Features/Investments/Views/InvestmentAccountView.swift`
- Modify: `Features/Investments/Views/InvestmentAccountView+Loading.swift`

- [ ] **Step 1: Write the failing equivalence test**

Create `MoolahTests/Shared/AccountPerformanceInvestmentEquivalenceTests.swift`. Prove that for a *funded* single investment account (opening balance + a trade), `compute(accountId:)` and `computeMultiInstrument([id])` produce identical performance, and document the intentional no-flow divergence:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountPerformance — investment path equivalence")
struct AccountPerformanceInvestmentEquivalenceTests {
  let aud = Instrument.AUD

  /// A normally-funded investment account (opening balance is an external
  /// flow) yields identical performance from the legacy single-account
  /// `compute` and the unified `computeMultiInstrument([id])`. Locks the fold:
  /// routing investment through the shared modifier does not change the tiles.
  @Test("funded investment account: single-account and multi-instrument agree")
  func fundedAccountAgrees() async throws {
    let account = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let opening = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(accountId: account, instrument: aud, quantity: 1_000, type: .openingBalance)
      ])
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 1_200, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_200, instrument: aud))
    ]
    let service = FakeConversionService.fixedRates([:])
    let single = try await AccountPerformanceCalculator.compute(
      accountId: account, transactions: [opening], valuedPositions: valued,
      profileCurrency: aud, conversionService: service, now: now)
    let multi = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [account], transactions: [opening], valuedPositions: valued,
      profileCurrency: aud, conversionService: service, now: now)
    #expect(single.currentValue == multi.currentValue)
    #expect(single.totalContributions == multi.totalContributions)
    #expect(single.profitLoss == multi.profitLoss)
    #expect(single.profitLossPercent == multi.profitLossPercent)
    #expect(single.annualisedReturn == multi.annualisedReturn)
    #expect(single.firstFlowDate == multi.firstFlowDate)
  }

  /// The one intentional divergence: an account funded solely by
  /// single-account income (no opening balance, no transfer-in) has no
  /// external flows. Legacy `compute` paints the whole value as gain;
  /// the unified path degrades to current-value-only (Rule 11: no phantom
  /// gain). The fold accepts the latter.
  @Test("no-external-flow account: unified path degrades to current value only")
  func noFlowDivergence() async throws {
    let account = UUID()
    let date = Date(timeIntervalSinceReferenceDate: 0)
    let income = Transaction(
      date: date,
      legs: [TransactionLeg(accountId: account, instrument: aud, quantity: 500, type: .income)])
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 500, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 500, instrument: aud))
    ]
    let service = FakeConversionService.fixedRates([:])
    let now = date.addingTimeInterval(30 * 86_400)
    let single = try await AccountPerformanceCalculator.compute(
      accountId: account, transactions: [income], valuedPositions: valued,
      profileCurrency: aud, conversionService: service, now: now)
    let multi = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [account], transactions: [income], valuedPositions: valued,
      profileCurrency: aud, conversionService: service, now: now)
    #expect(single.profitLoss == InstrumentAmount(quantity: 500, instrument: aud))
    #expect(multi.profitLoss == nil)
    #expect(multi.currentValue == InstrumentAmount(quantity: 500, instrument: aud))
  }
}
```

> **Fixture check during implementation:** verify `FakeConversionService.fixedRates(_:)` and the `Transaction`/`TransactionLeg`/`ValuedPosition` initialisers against source (they match the Increment-3 test fixtures). If `AccountPerformance` gains an `Equatable` conformance later, the field-by-field asserts can collapse to `#expect(single == multi)`; field-by-field is used here to avoid depending on that.

- [ ] **Step 2: Run the test, verify it passes**

Run: `just test-mac AccountPerformanceInvestmentEquivalenceTests`
Expected: PASS immediately — no production change yet; this test *documents and pins* the existing calculator behaviour that the fold relies on. (It is the safety net, not a red-then-green step.)

- [ ] **Step 3: Route `.calculatedFromTrades` investment through `AccountDetailView`**

In `App/ContentView+AccountDetail.swift`, change the `case .investment:` arm to branch on valuation mode — `.recordedValue` keeps `InvestmentAccountView`; `.calculatedFromTrades` routes to `AccountDetailView` with `alwaysShowsFullSurface: true`:

```swift
      case .investment:
        if account.valuationMode == .recordedValue {
          InvestmentAccountView(
            account: account,
            accounts: accountStore.accounts,
            categories: categoryStore.categories,
            earmarks: earmarkStore.earmarks,
            investmentStore: investmentStore,
            transactionStore: transactionStore)
        } else {
          AccountDetailView(
            title: account.name,
            transactionFilter: TransactionFilter(accountId: account.id),
            positions: accountStore.positions(for: account.id),
            hostCurrency: account.instrument,
            accountIds: [account.id],
            conversionService: session.backend.conversionService,
            registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0,
            accountChainId: nil,
            alwaysShowsFullSurface: true,
            syncedHeaderAccount: nil,
            accounts: accountStore.accounts,
            categories: categoryStore.categories,
            earmarks: earmarkStore.earmarks,
            transactionStore: transactionStore)
        }
```

> **Positions source parity:** `accountStore.positions(for:)` sums non-scheduled `transaction_leg` rows per `(account_id, instrument_id)` (see `GRDBAccountRepository.computePositions`), which is what `InvestmentStore.loadPositions` computed from the same legs. The unified modifier re-valuates them via `PositionsValuator` and assembles cost basis + history via the same `MultiInstrumentPositionsAssembler` the investment path used — so rows, cost basis, and chart series match. Verify against a real position-tracked account (Test Profile → a brokerage) that the positions, tiles, and chart populate.

- [ ] **Step 4: Trim `InvestmentAccountView` to the recordedValue path**

In `Features/Investments/Views/InvestmentAccountView.swift`:
1. Delete `positionTrackedLayout` (the `PositionsTransactionsSplit { … PositionsView … }` computed property) and `makeAccountTransactionList`'s only remaining consumer is now `legacyValuationsLayout` — keep `makeAccountTransactionList`.
2. Remove the position-tracked `@State`: `positionsInput`, `positionsRange`, `isLoadingPositions`.
3. Replace the `body`'s inner `switch account.valuationMode { … }` with the legacy layout directly (the dispatch guarantees `.recordedValue` here), keeping the `initialLoadComplete` gate:

```swift
    Group {
      if !initialLoadComplete {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityLabel("Loading account data")
      } else {
        legacyValuationsLayout
      }
    }
```

4. Replace the position-tracked load `.task(id: LoadKey(...))` body and delete the `.task(id: positionsRange)` and the `.onChange(of: account.valuationMode)`/`.refreshable { reloadPositions() }` position-tracked plumbing. The load `.task` becomes a direct legacy load:

```swift
    .task(id: LoadKey(id: account.id, mode: account.valuationMode)) {
      initialLoadComplete = false
      await investmentStore.loadAllData(
        account: account, profileCurrency: session.profile.instrument)
      initialLoadComplete = true
      focusAnchor = .content
    }
    .refreshable {
      await investmentStore.loadAllData(
        account: account, profileCurrency: session.profile.instrument)
    }
```

Keep the `.transactionInspector`, `.profileNavigationTitle`, `.sheet(isPresented: $showingAddValue)`, `.accessibilityFocused`, and the `LoadKey`/`focusAnchor`/`showingAddValue`/`selectedTransaction` members — the recordedValue layout still uses them.

In `Features/Investments/Views/InvestmentAccountView+Loading.swift`, delete `reloadPositions` and `maybeAutoWidenRange` (position-tracked only). Keep `profileCurrencyInstrument` if the legacy `.task` still reads it (it now inlines `session.profile.instrument`; if nothing else uses `profileCurrencyInstrument`, delete it too — grep to confirm).

> **Load-path check during implementation:** confirm `InvestmentStore.loadAllData(account:profileCurrency:)` populates `values`, `chartDataPoints`, and `accountPerformance` (via `computeLegacy`) that `legacyValuationsLayout` / `legacySummary` read. `loadAndBuildPositionsInput` called `loadAllData` then `positionsViewInput`; the recordedValue layout only needs the `loadAllData` half. Run the recordedValue regression (Step 5) to confirm.

- [ ] **Step 5: Build, run, preview, format, review**

Run: `just build-mac` (Expected: succeeds — `PositionsTransactionsSplit` and `PositionsView` still exist; Task 6 removes them). Then:
- `just test-mac AccountPerformanceInvestmentEquivalenceTests` (Expected: PASS).
- `just test-mac InvestmentStore` and `just test-mac ValuationMode` (Expected: PASS — recordedValue + valuation-mode paths unaffected).
- Use `reviewing-ui-with-preview` (or launch Test Profile → a `.calculatedFromTrades` brokerage) to confirm: pinned Positions pane + `[Transactions | Chart]` toggle; the Chart tab shows the performance tiles + the dense chart; a fully-sold brokerage still shows tiles + positions (the `alwaysShowsFullSurface` path). Confirm a `.recordedValue` account still shows the legacy valuations list + legacy chart + "Record Value".

Run `just format-check`; fix. Run `@code-review`, `@ui-review`, `@concurrency-review`, and `@instrument-conversion-review` on the modified investment view + dispatch + the equivalence test; fix every finding.

- [ ] **Step 6: Commit**

```bash
git -C . add App/ContentView+AccountDetail.swift Features/Investments/Views/InvestmentAccountView.swift Features/Investments/Views/InvestmentAccountView+Loading.swift MoolahTests/Shared/AccountPerformanceInvestmentEquivalenceTests.swift
git -C . commit -m "feat(investments): fold calculatedFromTrades accounts onto the unified AccountDetailView"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 6: Delete the legacy `PositionsTransactionsSplit` (and orphaned `PositionsView`)

With the investment fold merged, the legacy two-builder container has no caller. Delete it. Then grep-verify whether `PositionsView` is now orphaned and delete it too (its chart-pane / positions-pane halves are used directly by the unified container, so only the composed wrapper is affected).

**Files:**
- Delete: `Shared/Views/Positions/PositionsTransactionsSplit.swift`
- Delete (conditional): `Shared/Views/Positions/PositionsView.swift`

- [ ] **Step 1: Confirm `PositionsTransactionsSplit` is unused**

Run: `grep -rn "PositionsTransactionsSplit(" . | grep "\.swift"` — expect only the struct definition + its two `#Preview`s inside `PositionsTransactionsSplit.swift` itself (all other call sites removed by Task 5). If any production call site remains, STOP — an earlier task didn't fully route its type; fix that first.

- [ ] **Step 2: Delete it**

```bash
git -C . rm Shared/Views/Positions/PositionsTransactionsSplit.swift
```

Check `Shared/EnvironmentValues+TransactionScrollCollapse.swift` (referenced `PositionsTransactionsSplit` in the deletion-reference grep) — the `TransactionScrollCollapse` environment value is also used by the new `PositionsChartTransactionsSplit`, so the env value stays; only update any doc comment that named the deleted container.

- [ ] **Step 3: Check whether `PositionsView` is now orphaned**

Run: `grep -rn "PositionsView(" . | grep "\.swift"` (note the trailing `(` to match construction, not `PositionsViewInput` / `PositionsChartPane` / etc.). If the only hits are inside `PositionsView.swift` (its own `#Preview`s), it is orphaned by the investment fold — delete it:

```bash
git -C . rm Shared/Views/Positions/PositionsView.swift
```

If any production caller remains, **do not** delete `PositionsView`; leave it and note the remaining caller in the PR description. (`PositionsChartPane` and `PositionsPane` are consumed directly by `MultiInstrumentPositionsSplitModifier` and must NOT be deleted regardless.)

- [ ] **Step 4: Build, run, format, review**

Run: `just build-mac` (Expected: succeeds). Run: `just test-mac PositionsAssembler` and `just test-mac PositionsViewInput` (Expected: PASS — the input model + assembler are untouched). Run `just format-check`; fix. Run `@code-review` on the diff; fix every finding.

- [ ] **Step 5: Commit**

```bash
git -C . rm Shared/Views/Positions/PositionsTransactionsSplit.swift
# plus PositionsView.swift if Step 3 confirmed it orphaned
git -C . commit -m "refactor(positions): delete legacy PositionsTransactionsSplit (unified path is the only layout)"
```

Then open a PR and land via the `landing-prs` skill.

---

## Task 7: macOS UI regression — every account type renders the unified layout

Lock the fold end-to-end: a crypto account renders its synced header AND the unified split; a funded investment `.calculatedFromTrades` account renders the pinned Positions pane + performance tiles + a working `[Transactions | Chart]` toggle. Reuse existing seeds and drivers (`AccountDetailScreen`, `SyncedAccountHeaderScreen`, the `.walletHeaderSyncError` + trade-baseline seeds) — no new seed unless a funded brokerage isn't already seeded.

**Files:**
- Create: `MoolahUITests_macOS/Tests/AccountDetailUnifiedLayoutTests.swift`

**Interfaces consumed (from Increments 2–3, verified present):** `MoolahApp.accountDetail` → `AccountDetailScreen.{expectPositionsPanePinned, expectNoPositionsPane, expectTransactionsDefault, toggleToChart, expectPerformanceTiles}`; `MoolahApp.syncedAccountHeader` → `SyncedAccountHeaderScreen`; `SidebarScreen.SidebarAccount.{walletWithSyncError, tradeReadyBrokerage}`.

- [ ] **Step 1: Write the UI tests**

Create `MoolahUITests_macOS/Tests/AccountDetailUnifiedLayoutTests.swift`:

```swift
import XCTest

/// macOS UI regression for Increment 4 — every account type now renders the
/// single unified `AccountDetailView` (header slot + `PositionsChartTransactionsSplit`).
/// Crypto retains its synced header above the split; a funded position-tracked
/// investment account retains its performance tiles + pinned positions after
/// being folded off the old `PositionsTransactionsSplit` path.
@MainActor
final class AccountDetailUnifiedLayoutTests: MoolahUITestCase {
  /// A crypto wallet shows the synced-account header AND the unified split.
  func testCryptoAccountShowsHeaderAndUnifiedSplit() throws {
    let app = launch(seed: .walletHeaderSyncError)
    app.sidebar.switchToAccount(.walletWithSyncError)
    app.syncedAccountHeader.expectErrorCaptionVisible()
    app.accountDetail.expectTransactionsDefault()
  }

  /// A funded investment `.calculatedFromTrades` account, folded onto the
  /// unified path, still pins its positions pane and shows the performance
  /// tiles on the Chart pane.
  func testInvestmentAccountShowsPinnedPositionsAndPerformanceTiles() throws {
    let app = launch(seed: .tradeReady)
    app.sidebar.switchToAccount(.tradeReadyBrokerage)
    app.accountDetail.expectPositionsPanePinned()
    app.accountDetail.toggleToChart()
    app.accountDetail.expectPerformanceTiles()
  }
}
```

> **Seed / account confirmation during implementation:** confirm the seed enum case that yields a funded `.calculatedFromTrades` brokerage with a non-host holding and external funding (so the positions pane + performance tiles both populate) — `.tradeReady` / `.tradeReadyBrokerage` per `UITestFixtures.TradeReady`, or `.tradesBrokerage` per `UITestFixtures.TradeBaseline`. Pick whichever seeds an account with holdings + an opening-balance / transfer-in (non-empty flows → P&L tiles). If neither does, extend the closest seed's hydrator with a funded brokerage (follow the `writing-ui-tests` skill), rather than weakening the assertion. The crypto seed `.walletHeaderSyncError` already drives `SyncedAccountHeaderTests`; reuse it.

- [ ] **Step 2: Run the UI tests, verify they pass**

Run: `just test-ui AccountDetailUnifiedLayoutTests`
Expected: PASS (2 tests). If element resolution flakes, follow the `writing-ui-tests` driver invariants and keep the 10s waits. If the local UI host is wedged, gate on the PR's CI (UI Test job) per memory `feedback_pr_ci_gate_when_ui_host_blocked`.

- [ ] **Step 3: Format and review**

Run: `just format-check` (Expected: clean). Run `@ui-test-review` on the tests (and any seed/hydrator change); fix every finding and re-review until clean.

- [ ] **Step 4: Commit**

```bash
git -C . add MoolahUITests_macOS/Tests/AccountDetailUnifiedLayoutTests.swift
# plus any seed/hydrator files touched in Step 1
git -C . commit -m "test(accounts): UI regression that every account type renders the unified layout"
```

Then open a PR and land via the `landing-prs` skill.

---

## Self-Review

- **Spec coverage (vs Increment 4 scope — design phasing steps 5–6):**
  - Fold `.calculatedFromTrades` investment accounts onto the shared unified container → dispatch routes them to `AccountDetailView` with `alwaysShowsFullSurface: true` (Task 5); `alwaysShowsFullSurface` mechanism (Task 1). ✓
  - Delete the redundant per-type views: `CryptoWalletAccountView` (Task 2), `ExchangeAccountView` (Task 3), `StandardAccountView` struct (Task 4), `GroupDetailView` (Task 4), the `positionTrackedLayout` branch of `InvestmentAccountView` (Task 5), and the legacy `PositionsTransactionsSplit` (Task 6). ✓
  - Collapse the per-type dispatch into the unified path → `ContentView+AccountDetail.swift` + `ContentView+GroupDetail.swift` route every type except `.recordedValue` to `AccountDetailView` (Tasks 2–5). ✓
  - `.recordedValue` OUT OF SCOPE, keeps its legacy layout, `InvestmentAccountView` survives for it only → Task 5 branches the dispatch on `valuationMode` and trims `InvestmentAccountView` to legacy. ✓
- **Design tensions resolved (with justification, per the brief):**
  1. *Investment performance source* → the shared `computeMultiInstrument([id])`; verified equivalent to `compute(accountId:)` for a funded single account (single-member gate reduces, same `assemble`, same assembler for cost basis + chart), with the one intentional no-external-flow divergence (`currentValueOnly` vs whole-value-gain) accepted and pinned by `AccountPerformanceInvestmentEquivalenceTests` (Task 5, Key decisions). ✓
  2. *`alwaysShowsFullSurface` / always-show-tiles for investment* → a `alwaysShowsFullSurface: Bool` threaded through the modifier that OR-forces both the Positions-pane gate and the perf-compute gate via `AccountDetailLayout.showsFullSurface(...)`, plus carried into the assembly context; dispatch sets it `true` for investment only (Task 1 + Task 5, Key decisions). ✓
  3. *Crypto wallet-header slot* → an optional header computed inside `AccountDetailView` from `account.type` + `ProfileSession`, gated by the pure `showsSyncedHeader(for:)`; preserves BOTH crypto and exchange headers; group/standard/investment pass `nil` (Task 2, Key decisions). ✓
  4. *Group vs single-account host* → `AccountDetailView` takes resolved split inputs (plural `accountIds`), never an `Account`/context; group dispatch supplies `aggregatedGroupPositions` + `Set(accountIds)` filter (Task 4, Key decisions). ✓
  5. *Deletion safety / ordering* → each type is routed and green BEFORE its view is deleted; legacy container deleted only after its last caller is gone (Task 6 greps to confirm); every task independently shippable. ✓
- **Money / Rule 11 / concurrency / thin views / Swift Testing vs XCTest / identifiers:** performance flows through `InstrumentAmount` with no `abs()`; no-flow / conversion-failure degrade to nil fields; the added compute path reuses the existing cancellation-guarded valuator `.task`; view logic (`showsSyncedHeader`, `showsFullSurface`, `aggregatedGroupPositions`) lives in pure testable helpers; unit tests use Swift Testing, the one UI file imports only `XCTest`; UI assertions reuse existing `UITestIdentifiers.AccountDetail.*` from Increments 2–3 (no new identifiers needed). ✓
- **Placeholder scan:** every code step carries complete, compiling code — no `TBD`/`...`-as-content. Signatures verified against source: `SyncedAccountHeaderView(account:syncStore:cryptoTokenStore:exchangeTokenStore:)`, `TransactionListView(title:filter:accounts:categories:earmarks:transactionStore:)` (6-arg self-managed-inspector form used by the deleted crypto/exchange/standard/group leaves), `multiInstrumentPositionsSplit(positions:hostCurrency:title:conversionService:registrationsVersion:accountIds:accountChainId:alwaysShowsFullSurface:)`, `PositionsAssemblyContext(title:hostCurrency:accountIds:assetKeysByInstrumentId:performance:alwaysShowsFullSurface:)`, `PositionsViewInput(title:hostCurrency:positions:historicalValue:…alwaysShowsFullSurface:)`, `AccountPerformanceCalculator.compute(accountId:transactions:valuedPositions:profileCurrency:conversionService:now:)` / `computeMultiInstrument(accountIds:…)`, `InvestmentStore.loadAllData(account:profileCurrency:)`, `accountStore.positions(for:)`, `AccountViewContext.{displayName,displayInstrument,accountIds}`. ✓
- **Type / name consistency across tasks:** `AccountDetailLayout.showsFullSurface(alwaysShowsFullSurface:otherwiseShows:)` (Task 1) is consumed by the modifier (Task 1). `AccountDetailView` (+ `showsSyncedHeader(for:)`) (Task 2) is consumed by all four dispatch arms (Tasks 2–5) and the repointed routing test (Task 3). `aggregatedGroupPositions(across:in:)` (relocated Task 4) is consumed by the group dispatch (Task 4) and `GroupAggregatedPositionsTests` (unchanged). UI drivers/screens (`accountDetail`, `syncedAccountHeader`) and seed cases reused from Increments 2–3 (Task 7). ✓
- **Ambiguities resolved / flagged:**
  - *(resolved)* `PositionsView` becomes orphaned by the investment fold (its only production caller was `positionTrackedLayout`); Task 6 deletes it **conditionally on a grep** so a reviewer sees the confirmation. The prompt listed `PositionsView` as "still used by investment" and did NOT list it for deletion — that statement stops being true after Task 5. **Flag for the user:** if you want `PositionsView` kept (e.g. as a composed convenience for a future view), skip the conditional deletion in Task 6 Step 3; nothing else references it and it will sit unused. `PositionsChartPane` / `PositionsPane` are NOT affected — the unified container uses them directly.
  - *(resolved)* Transaction-inspector form: investment `.calculatedFromTrades` moves from the `selectedTransaction:`-binding `TransactionListView` + `.transactionInspector` to the 6-arg self-managed form the other types use — a deliberate alignment (Key decisions), not a regression.
  - *(resolved)* Exchange header preserved even though the brief named only crypto: exchange has the identical `SyncedAccountHeaderView` slot, so `showsSyncedHeader` returns `true` for `.exchange` too.
  - **Needs user input (non-blocking):** the investment fold moves the value chart from *always visible in the top pane* (old `PositionsView` layout, `initialTopHeight: 540`) to *behind the `[Transactions | Chart]` toggle in the bottom pane* with the perf tiles at its top — the unified structure the design mandates. This is the intended unification but a visible behaviour change for investment users; confirm you're happy with the chart living behind the toggle (Task 5 Step 5 verifies it against a real brokerage before landing).
