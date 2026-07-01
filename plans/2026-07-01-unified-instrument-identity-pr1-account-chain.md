# Unified Instrument Identity — PR1: chain-of-holding from the account

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the source of a holding's chain from `instrument.chainId` to the owning account's chain, so a later PR can unify cross-chain instruments without losing the per-chain breakdown. **No identity change in this PR.**

**Architecture:** Add `accountChainId: Int?` to `ValuedPosition` (defaulted `nil` via an explicit init so existing construction sites are untouched). Populate it at the per-account valuation sites. Switch `AssetHolding.fold` to source `contributingChainIds`/`chainId` from `accountChainId` and dedupe `contributingInstrumentIds`. Switch the block-explorer link to the leg's account chain.

**Tech Stack:** Swift 6, Swift Testing (`@Suite`/`@Test`/`#expect`), GRDB (unchanged here), SwiftUI.

**Parent spec:** `plans/2026-07-01-unified-cross-chain-instrument-identity-design.md` (§2). This is PR1 of the suggested PR sequence.

## Global Constraints

- Swift Testing only (`import Testing`), never XCTest, for new tests. `@Suite` per file; keep files under the 250-line `type_body_length` limit.
- No `abs()` on trade-leg signs; preserve entered signs (CLAUDE.md).
- Money never crosses instruments without conversion; the fold's `sum` seeds with `hostCurrency` — do not touch that invariant.
- After each task: `just -d <worktree> --justfile <worktree>/justfile format-check` and the relevant reviewer agents (`@code-review`; `@instrument-conversion-review` for the fold; `@ui-review` for the block-explorer view) must pass with zero findings before commit.
- Build/test from the worktree: `just -d <worktree> --justfile <worktree>/justfile build-mac` and `... test-mac <FILTER>`.
- This PR must not change any instrument id, any CloudKit record, or any migration. Pure in-memory/display wiring.

---

## File Structure

- `Domain/Models/ValuedPosition.swift` — add `accountChainId: Int?` + explicit init (default `nil`).
- `Domain/Models/AssetHolding+Fold.swift` — source chain ids from `accountChainId`; dedupe `contributingInstrumentIds`.
- `Shared/PositionsValuator.swift`, `Shared/MultiInstrumentPositionsAssembler.swift`, `Features/Investments/InvestmentStore+Positions.swift` — pass the owning account's `chainId` when building per-account `ValuedPosition`s.
- `Features/Transactions/Views/Detail/TransactionDetailBlockExplorerSection.swift` — use the leg's account chain, not `leg.instrument.chainId`.
- Tests: `MoolahTests/Domain/ValuedPositionAccountChainTests.swift`, extend the existing `AssetHolding` fold suite, and a block-explorer test.

---

### Task 1: `ValuedPosition.accountChainId` with a defaulted explicit init

**Files:**
- Modify: `Domain/Models/ValuedPosition.swift`
- Test: `MoolahTests/Domain/ValuedPositionAccountChainTests.swift` (create)

**Interfaces:**
- Produces: `ValuedPosition(instrument:quantity:unitPrice:costBasis:value:accountChainId:)` where `accountChainId: Int? = nil` is the trailing, defaulted parameter. New stored property `let accountChainId: Int?`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("ValuedPosition.accountChainId")
struct ValuedPositionAccountChainTests {
  @Test("Defaults to nil when omitted (existing call sites unaffected)")
  func defaultsNil() {
    let p = ValuedPosition(
      instrument: .crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      quantity: 1, unitPrice: nil, costBasis: nil, value: nil)
    #expect(p.accountChainId == nil)
  }

  @Test("Round-trips the owning account chain when supplied")
  func carriesChain() {
    let p = ValuedPosition(
      instrument: .crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      quantity: 1, unitPrice: nil, costBasis: nil, value: nil, accountChainId: 10)
    #expect(p.accountChainId == 10)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just -d <worktree> --justfile <worktree>/justfile test-mac ValuedPositionAccountChainTests`
Expected: FAIL — `extra argument 'accountChainId' in call` (property/init not present yet).

- [ ] **Step 3: Add the property + explicit init**

Add `let accountChainId: Int?` to the struct and an explicit memberwise init whose final parameter is `accountChainId: Int? = nil`, assigning all stored properties. Keep the existing computed vars (`id`, `amount`, `hasCostBasis`, `gainLoss`, `gainLossPercent`) unchanged. The default preserves all ~26 existing `ValuedPosition(...)` call sites that don't pass the argument.

- [ ] **Step 4: Run test + full build to verify no call site broke**

Run: `just -d <worktree> ... test-mac ValuedPositionAccountChainTests` → PASS
Run: `just -d <worktree> ... build-mac` → BUILD SUCCEEDED (proves the defaulted init kept every existing construction site compiling).

- [ ] **Step 5: format-check, reviewers (`@code-review`), fix findings, commit**

```bash
git -C <worktree> add Domain/Models/ValuedPosition.swift MoolahTests/Domain/ValuedPositionAccountChainTests.swift
git -C <worktree> commit -m "feat(positions): add ValuedPosition.accountChainId (defaulted)"
```

---

### Task 2: fold sources chain ids from `accountChainId`; dedupe `contributingInstrumentIds`

**Files:**
- Modify: `Domain/Models/AssetHolding+Fold.swift:93,102,108-109`
- Test: extend the existing `AssetHolding.fold` Swift Testing suite (locate via `grep -rl "AssetHolding" MoolahTests`); add a new `@Suite` file if the existing one nears the line limit.

**Interfaces:**
- Consumes: `ValuedPosition.accountChainId` (Task 1).
- Produces: unchanged `AssetHolding.fold(_:assetKeys:hostCurrency:)` signature; only the internal chain-id source and `contributingInstrumentIds` dedupe change.

- [ ] **Step 1: Write the failing tests**

Cover three behaviours (write concrete `#expect`s):
1. Two same-asset crypto positions with `accountChainId: 10` and `8453` (both `assetKeys[id] = "ethereum"`, distinct instrument ids today) fold to one holding with `contributingChainIds == [10, 8453].sorted()` and `chainId == nil` (more than one chain).
2. A single crypto position with `accountChainId: 1` folds to `chainId == 1`, `contributingChainIds == [1]`.
3. An **exchange** ETH position (`instrument.chainId == 1` but `accountChainId == nil`) contributes **no** chain id: `contributingChainIds == []`, `chainId == nil`. (This is the intended semantic change — an exchange holding has no chain.)
4. Post-dedupe: two positions whose `instrument.id` are equal (simulating a future unified id) yield `contributingInstrumentIds == ["1:native"]` (deduped, not `["1:native","1:native"]`).

- [ ] **Step 2: Run to verify failure**

Run: `just -d <worktree> ... test-mac <FoldSuiteName>`
Expected: FAIL — current code reads `instrument.chainId` (so test 3 yields `[1]` not `[]`) and does not dedupe (test 4 yields duplicates).

- [ ] **Step 3: Implement**

In `merge(...)`:
- Line 93: `let chainIds = Set(group.compactMap { $0.accountChainId })`.
- Line 108: `contributingInstrumentIds: Array(Set(group.map { $0.instrument.id })).sorted()`.
- Lines 102/109 unchanged in shape (they already derive from `chainIds`).

- [ ] **Step 4: Run tests → PASS**; then `build-mac` → SUCCEEDED.

- [ ] **Step 5: format-check, `@code-review` + `@instrument-conversion-review` (fold touches aggregation), fix findings, commit**

```bash
git -C <worktree> add Domain/Models/AssetHolding+Fold.swift MoolahTests/<FoldSuite>.swift
git -C <worktree> commit -m "feat(positions): fold contributing chains from account, dedupe instrument ids"
```

---

### Task 3: populate `accountChainId` at the per-account valuation sites

**Files:**
- Modify: `Shared/PositionsValuator.swift:80,125,136`, `Shared/MultiInstrumentPositionsAssembler.swift:157`, `Features/Investments/InvestmentStore+Positions.swift:195,212,223`
- Test: a valuation-layer test asserting a per-account ETH position carries its account's chain into the folded holding.

**Interfaces:**
- Consumes: the owning `Account.chainId` available at each construction site.
- Produces: per-account `ValuedPosition`s now carry `accountChainId`. The many preview/table-helper sites (`Shared/Views/Positions/*`, `PositionsChart`, `PositionsHeader`, `PositionsTable`, `PositionsView`) keep the `nil` default — do not touch them.

- [ ] **Step 1: Write the failing test** — drive a per-account positions build (the assembler/valuator with a seeded OP crypto account holding ETH) and assert the resulting `AssetHolding.contributingChainIds` contains `10`. (Pick whichever of `PositionsValuator` / `MultiInstrumentPositionsAssembler` owns the per-account path; verify by reading which one receives `Account`/`chainId` context.)

- [ ] **Step 2: Run → FAIL** (accountChainId is nil, so the chain doesn't propagate).

- [ ] **Step 3: Implement** — at each of the three real per-account construction sites, pass `accountChainId:` from the owning account's `chainId`. Read each site to confirm the account is in scope; if the assembler groups by instrument across accounts, thread the account chain from where the per-account leg/position is known (do NOT invent an account where positions are already cross-account — those are exactly the pre-fold inputs and must remain per-account).

- [ ] **Step 4: Run → PASS; `build-mac` → SUCCEEDED.**

- [ ] **Step 5: format-check, `@code-review` + `@concurrency-review` (valuation actors) + `@instrument-conversion-review`, fix findings, commit.**

---

### Task 4: block-explorer link uses the leg's account chain

**Files:**
- Modify: `Features/Transactions/Views/Detail/TransactionDetailBlockExplorerSection.swift:55`
- Test: `MoolahTests/.../TransactionDetailBlockExplorerTests.swift` (or extend an existing one) asserting the URL uses the account chain, and no link renders when `accountId == nil`.

**Interfaces:**
- Consumes: the leg's account chain. The section has no account-store access today — thread the chain onto the leg view-model at assembly, or resolve `leg.accountId → account.chainId` at the section's data-provider. Read the surrounding view-model to pick the seam.

- [ ] **Step 1: Write the failing test** — an OP-wallet ETH leg (`instrument.chainId` currently 10; account chain 10) produces an Optimistic-Etherscan URL; assert via `BlockExplorerLink.transactionURL(chainId:externalId:)`. Add a case: `accountId == nil` (manual tx) → no URL. (Today the code reads `leg.instrument.chainId`; the test that pins "account chain drives it" fails once instrument identity unifies, which is the point — write it against the account chain now.)

- [ ] **Step 2: Run → FAIL** (section still reads `leg.instrument.chainId`).

- [ ] **Step 3: Implement** — switch the `chainId` source to the leg's account chain, falling back to `instrument.chainId` only when the instrument is still chain-scoped (no account chain available). Hide the link when `accountId == nil`.

- [ ] **Step 4: Run → PASS; `build-mac` → SUCCEEDED.**

- [ ] **Step 5: format-check, `@code-review` + `@ui-review`, fix findings, commit.**

---

### Task 5: PR wrap-up

- [ ] Run the full macOS suite: `just -d <worktree> ... test-mac` → all pass.
- [ ] `just -d <worktree> ... format-check` → clean.
- [ ] Open the PR titled `feat(positions): chain-of-holding from the account (unified-identity PR1)`, body linking the parent spec and stating "no identity/CloudKit/migration change; pure display wiring; prerequisite for the instrument-unification PRs."
- [ ] Land via the `landing-prs` skill.

---

## Self-Review notes

- **Spec coverage (§2):** `accountChainId` (Task 1), `contributingChainIds` source shift (Task 2), `contributingInstrumentIds` dedupe (Task 2), block-explorer account-chain switch (Task 4), valuation-layer wiring (Task 3). All of §2 covered.
- **Behavioural change to pin:** exchange holdings now contribute **no** chain id (Task 2, test 3) — intended.
- **No identity change:** every task is display/in-memory; no id, record, or migration touched — consistent with the PR sequence putting this first.
- **Deferred to later PRs:** the `nil`-default on `accountChainId` means the still-chain-scoped world keeps working; later PRs (identity unification) rely on Task 2/3 already sourcing chain from the account.
