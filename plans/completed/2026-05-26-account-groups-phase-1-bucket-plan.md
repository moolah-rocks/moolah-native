# Account Groups — Phase 1 Implementation Plan: `AccountBucket`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `AccountType.isInvestmentLike` and `AccountType.isCurrent` with a first-class `AccountBucket` enum, exposed as a single `.bucket` accessor on both `AccountType` and `Account`. Single API, no deprecated forwarders, no two ways to ask "which sidebar bucket".

**Architecture:** New `AccountBucket` enum in `Domain/Models/`. Computed `bucket` property on `AccountType` (single switch). Forwarding `bucket` on `Account`. Mechanical callsite sweep replaces `.type.isInvestmentLike` with `.bucket == .investments` and `.type.isCurrent` with `.bucket == .current`. Old boolean properties deleted at the end.

**Tech Stack:** Swift, Swift Testing (`import Testing`, `@Test`), `just` build/test/format targets, GRDB unaffected (no schema change in this phase).

**Spec:** `plans/2026-05-26-account-groups-design.md` — see "Model" and "Reports, aggregations, callsite sweep".

---

## Worktree setup

- [ ] **Step 1: Create a worktree on a feature branch off main**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track \
  .worktrees/account-bucket -b account-bucket origin/main
```

The `--no-track` flag is mandatory per the project's stacked-PR policy in `CLAUDE.md` — without it, the first push targets `origin/main`. The worktree path is `.worktrees/account-bucket`.

- [ ] **Step 2: Switch the working directory to the worktree for the remainder of this plan**

From here on, every shell command runs from `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket`. Use `just -d <worktree>` for any `just` invocation if needed; this plan assumes the agent's working directory is the worktree.

- [ ] **Step 3: Generate the Xcode project for the worktree**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket \
     --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket/justfile generate
```

Required because `Moolah.xcodeproj` is gitignored and per-worktree (see project `CLAUDE.md`).

---

## Task 1: Add the `AccountBucket` enum

**Files:**
- Create: `Domain/Models/AccountBucket.swift`
- Create: `MoolahTests/Domain/AccountBucketTests.swift`

- [ ] **Step 1: Write the failing test file**

Create `MoolahTests/Domain/AccountBucketTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountBucket")
struct AccountBucketTests {
  @Test
  func rawValuesAreStableTokens() {
    #expect(AccountBucket.current.rawValue == "current")
    #expect(AccountBucket.investments.rawValue == "investments")
  }

  @Test
  func allCasesIsExhaustive() {
    #expect(AccountBucket.allCases == [.current, .investments])
  }

  @Test
  func roundTripsThroughCodable() throws {
    let original: [AccountBucket] = [.current, .investments]
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode([AccountBucket].self, from: data)
    #expect(restored == original)
  }

  @Test
  func decodesFromStableTokens() throws {
    let json = Data(#"["current","investments"]"#.utf8)
    let buckets = try JSONDecoder().decode([AccountBucket].self, from: json)
    #expect(buckets == [.current, .investments])
  }

  @Test
  func throwsOnUnknownRawValue() {
    let json = Data(#""savings""#.utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(AccountBucket.self, from: json)
    }
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
just test AccountBucketTests 2>&1 | tee .agent-tmp/test-bucket-1.txt
```

Expected: build failure with "Cannot find 'AccountBucket' in scope" or similar. Test does not yet run.

- [ ] **Step 3: Create the `AccountBucket` enum**

Create `Domain/Models/AccountBucket.swift`:

```swift
import Foundation

/// Sidebar bucket that an account (or group of accounts) lives in.
///
/// Designed for future extension: additional cases (`.savings`,
/// `.retirement`, `.liabilities`) can be added when the product wants
/// them; the raw-value tokens are stable wire identifiers and must not
/// be renamed. Long-term, this may become a value type referencing
/// user-defined buckets — adding the abstraction now is YAGNI.
enum AccountBucket: String, Codable, Sendable, CaseIterable {
  case current
  case investments
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
just test AccountBucketTests 2>&1 | tee .agent-tmp/test-bucket-1.txt
grep -i 'failed\|error:' .agent-tmp/test-bucket-1.txt || echo "OK"
```

Expected: all 5 tests pass; grep prints `OK`.

- [ ] **Step 5: Format-check**

```bash
just format-check
```

Expected: exits 0.

- [ ] **Step 6: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket add \
  Domain/Models/AccountBucket.swift \
  MoolahTests/Domain/AccountBucketTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket commit -m "feat(domain): add AccountBucket enum

First-class bucket type extracted from AccountType.isInvestmentLike /
isCurrent. Two cases for v1 (current, investments) with stable raw
values; CaseIterable + Codable so it can serve as a stored field on
the upcoming AccountGroup record."
```

---

## Task 2: Add `bucket` property on `AccountType`

**Files:**
- Modify: `Domain/Models/Account.swift` (AccountType enum, around lines 4-47)
- Modify: `MoolahTests/Domain/AccountTypeTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `MoolahTests/Domain/AccountTypeTests.swift` (inside the existing `struct AccountTypeTests`):

```swift
  @Test
  func bucketMapsCurrentTypesToCurrent() {
    #expect(AccountType.bank.bucket == .current)
    #expect(AccountType.creditCard.bucket == .current)
    #expect(AccountType.asset.bucket == .current)
  }

  @Test
  func bucketMapsInvestmentTypesToInvestments() {
    #expect(AccountType.investment.bucket == .investments)
    #expect(AccountType.crypto.bucket == .investments)
    #expect(AccountType.exchange.bucket == .investments)
  }

  @Test
  func bucketCoversEveryAccountType() {
    // Regression guard: a new AccountType case must consciously pick a
    // bucket, mirroring how isSynced is enforced via exhaustive switch.
    let mapped = AccountType.allCases.map(\.bucket)
    #expect(mapped.count == AccountType.allCases.count)
  }
```

- [ ] **Step 2: Run the new tests to verify they fail**

```bash
just test AccountTypeTests 2>&1 | tee .agent-tmp/test-bucket-2.txt
```

Expected: build failure with "Value of type 'AccountType' has no member 'bucket'".

- [ ] **Step 3: Add the `bucket` property on `AccountType`**

In `Domain/Models/Account.swift`, immediately after the existing `var isSynced: Bool { … }` block (currently ending around line 35, before `var displayName: String`), add:

```swift
  /// Sidebar bucket this type belongs to. Exhaustive switch so a new
  /// `AccountType` case (a SyncBoundary change) is forced to make a
  /// bucket decision here.
  var bucket: AccountBucket {
    switch self {
    case .bank, .creditCard, .asset: return .current
    case .investment, .crypto, .exchange: return .investments
    }
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
just test AccountTypeTests 2>&1 | tee .agent-tmp/test-bucket-2.txt
grep -i 'failed\|error:' .agent-tmp/test-bucket-2.txt || echo "OK"
```

Expected: all `AccountTypeTests` pass (including the pre-existing `cryptoAndInvestmentBothInvestmentLike`, `cryptoIsNotIsCurrent`, etc. — they still work because `isInvestmentLike` / `isCurrent` haven't been removed yet).

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket add \
  Domain/Models/Account.swift \
  MoolahTests/Domain/AccountTypeTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket commit -m "feat(domain): add AccountType.bucket

Computed via exhaustive switch over AccountType. Parallel to the
existing isCurrent / isInvestmentLike booleans; those will be removed
in a follow-up commit once callsites have moved to .bucket."
```

---

## Task 3: Add `bucket` property on `Account`

**Files:**
- Modify: `Domain/Models/Account.swift` (Account extensions)
- Modify: `MoolahTests/Domain/AccountTypeTests.swift` (or create a sibling `AccountBucketAccessorTests.swift` — see step 1)

- [ ] **Step 1: Write the failing test**

Append to `MoolahTests/Domain/AccountTypeTests.swift` (same suite is fine — these tests live with the bucket concept):

```swift
  @Test
  func accountBucketForwardsToType() {
    let bank = Account(name: "Chequing", type: .bank, instrument: .AUD)
    let crypto = Account(
      name: "ETH Wallet", type: .crypto, instrument: .AUD,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1)
    let exchange = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    #expect(bank.bucket == .current)
    #expect(crypto.bucket == .investments)
    #expect(exchange.bucket == .investments)
  }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
just test AccountTypeTests/accountBucketForwardsToType 2>&1 | tee .agent-tmp/test-bucket-3.txt
```

Expected: build failure with "Value of type 'Account' has no member 'bucket'".

- [ ] **Step 3: Add the forwarding `bucket` property on `Account`**

In `Domain/Models/Account.swift`, immediately after the existing `extension Account: Sendable {}` line (currently line 94, just before `extension Account: Identifiable {}`), add a new extension:

```swift
extension Account {
  /// Sidebar bucket this account belongs to. Forwards to `type.bucket`
  /// today; intentionally a separate accessor so a future
  /// `bucketOverride: AccountBucket?` field can be introduced as a
  /// non-breaking change.
  var bucket: AccountBucket { type.bucket }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
just test AccountTypeTests 2>&1 | tee .agent-tmp/test-bucket-3.txt
grep -i 'failed\|error:' .agent-tmp/test-bucket-3.txt || echo "OK"
```

Expected: all `AccountTypeTests` pass.

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket add \
  Domain/Models/Account.swift \
  MoolahTests/Domain/AccountTypeTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket commit -m "feat(domain): add Account.bucket forwarding accessor

Forwards to type.bucket. Separate accessor so the future
bucketOverride field can be introduced without breaking callsites."
```

---

## Task 4: Sweep production callsites to use `.bucket`

**Files:**
- Modify: `Domain/Models/Accounts+SidebarOrdering.swift` (lines 34-39)
- Modify: `Features/Accounts/AccountStore.swift` (lines 243, 247)

Note: this task does not change behaviour — `bucket` is equivalent to the booleans. Existing tests must continue to pass without modification.

- [ ] **Step 1: Update `Accounts+SidebarOrdering.swift`**

Replace the body of the `for account in visible` loop (currently lines 33-39) with:

```swift
    for account in visible {
      switch account.bucket {
      case .current:
        current.append(account)
      case .investments:
        investment.append(account)
      }
    }
```

Why a switch instead of two if-else with `==`: exhaustive over `AccountBucket`, so a future `.savings` case forces the partitioner to make a placement decision.

- [ ] **Step 2: Update `AccountStore.swift`**

Replace lines 242-248 (the `currentAccounts` and `investmentAccounts` computed properties):

```swift
  var currentAccounts: [Account] {
    accounts.filter { $0.bucket == .current && (showHidden || !$0.isHidden) }
  }

  var investmentAccounts: [Account] {
    accounts.filter { $0.bucket == .investments && (showHidden || !$0.isHidden) }
  }
```

- [ ] **Step 3: Run the affected test suites to verify behaviour is unchanged**

```bash
just test AccountsSidebarOrderingTests AccountStoreMutationsTests 2>&1 | tee .agent-tmp/test-bucket-4.txt
grep -i 'failed\|error:' .agent-tmp/test-bucket-4.txt || echo "OK"
```

Expected: all tests pass with no modifications to test files. (The tests reference `isInvestmentLike` only in `@Test` annotation strings, which don't affect compilation.)

- [ ] **Step 4: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket add \
  Domain/Models/Accounts+SidebarOrdering.swift \
  Features/Accounts/AccountStore.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket commit -m "refactor(accounts): sweep production callsites to use .bucket

Sidebar partitioner uses an exhaustive switch over AccountBucket;
AccountStore.{current,investment}Accounts use .bucket == .X. Behaviour
unchanged. AccountType.isCurrent and .isInvestmentLike are now unused
in production; removed in a follow-up commit."
```

---

## Task 5: Sweep test callsites to use `.bucket`

**Files:**
- Modify: `MoolahTests/Domain/AccountTypeTests.swift` (remove the `isInvestmentLike` / `isCurrent` tests, since the properties will be deleted in Task 6)
- Modify: `MoolahTests/Domain/ExchangeAccountModelTests.swift` (lines 6-10)
- Modify: `MoolahTests/Domain/AccountsSidebarOrderingTests.swift` (line 37 — `@Test` annotation only)
- Modify: `MoolahTests/Features/AccountStoreMutationsTests.swift` (lines 101, 105 — `@Test` annotation + comment)

- [ ] **Step 1: Update `AccountTypeTests.swift` — replace the two property-specific tests with bucket equivalents**

In `MoolahTests/Domain/AccountTypeTests.swift`, **delete** the two existing tests:

```swift
  @Test
  func cryptoAndInvestmentBothInvestmentLike() {
    #expect(AccountType.crypto.isInvestmentLike)
    #expect(AccountType.investment.isInvestmentLike)
    #expect(!AccountType.bank.isInvestmentLike)
    #expect(!AccountType.creditCard.isInvestmentLike)
    #expect(!AccountType.asset.isInvestmentLike)
  }

  @Test
  func cryptoIsNotIsCurrent() {
    #expect(!AccountType.crypto.isCurrent)
  }
```

These are covered by the `bucketMapsCurrentTypesToCurrent` and `bucketMapsInvestmentTypesToInvestments` tests added in Task 2. No replacement needed.

- [ ] **Step 2: Update `ExchangeAccountModelTests.swift` — rewrite the bucket assertion using `.bucket`**

Replace the first test (currently lines 6-10):

```swift
  @Test
  func exchangeTypeIsSidebarGroupedWithInvestments() {
    #expect(AccountType.exchange.bucket == .investments)
  }
```

The `!isCurrent` half is now redundant — `.bucket == .investments` already excludes `.current`. Bucket is a single field, not two booleans that could disagree.

- [ ] **Step 3: Update `AccountsSidebarOrderingTests.swift` — refresh the `@Test` annotation string**

Line 37 currently reads:

```swift
  @Test("Crypto wallets land in the investment group (isInvestmentLike)")
```

Replace with:

```swift
  @Test("Crypto wallets land in the investments bucket")
```

The test body is unchanged.

- [ ] **Step 4: Update `AccountStoreMutationsTests.swift` — refresh the annotation + inline comment**

Line 101 currently reads:

```swift
  @Test("investmentAccounts includes crypto accounts (isInvestmentLike)")
```

Replace with:

```swift
  @Test("investmentAccounts includes crypto accounts (bucket == .investments)")
```

Lines 105-106's comment currently reads:

```swift
    // crypto wallets — the acceptance criterion is to use `isInvestmentLike`
    // so both kinds appear together.
```

Replace with:

```swift
    // crypto wallets — the acceptance criterion is .bucket == .investments
    // so both kinds appear together.
```

Preserve the rest of the test body (the seeding, the store construction, the emission-wait assertions) verbatim.

- [ ] **Step 5: Run the full affected test suites to verify**

```bash
just test AccountTypeTests ExchangeAccountModelTests AccountsSidebarOrderingTests AccountStoreMutationsTests 2>&1 | tee .agent-tmp/test-bucket-5.txt
grep -i 'failed\|error:' .agent-tmp/test-bucket-5.txt || echo "OK"
```

Expected: all tests pass.

- [ ] **Step 6: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket add \
  MoolahTests/Domain/AccountTypeTests.swift \
  MoolahTests/Domain/ExchangeAccountModelTests.swift \
  MoolahTests/Domain/AccountsSidebarOrderingTests.swift \
  MoolahTests/Features/AccountStoreMutationsTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket commit -m "test(domain): migrate isInvestmentLike/isCurrent tests to .bucket

Delete the boolean-property unit tests (covered by AccountBucket
mapping tests added in Task 2). Replace stale annotation strings and
comments. No behavioural change."
```

---

## Task 6: Remove the deprecated `isCurrent` and `isInvestmentLike` properties

**Files:**
- Modify: `Domain/Models/Account.swift` (lines 12-21 — the two computed properties)

- [ ] **Step 1: Confirm no production or test code still references the booleans**

```bash
grep -rn 'isInvestmentLike\|\.isCurrent' \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket \
  --include='*.swift' \
  | grep -v '\.worktrees/' | grep -v '/build/'
```

Expected: no output (the only matches should be the properties themselves on `Account.swift`, which we're about to delete; the grep filters out other worktrees). If anything else appears, stop and update that file before continuing.

- [ ] **Step 2: Delete the two computed properties**

In `Domain/Models/Account.swift`, delete lines 12-21 (the `isCurrent` and `isInvestmentLike` blocks, including the doc comment between them):

Currently:
```swift
  var isCurrent: Bool {
    self == .bank || self == .asset || self == .creditCard
  }

  /// Whether this type should be treated as an investment account for sidebar
  /// grouping and any query that filters investments. `true` for `.investment`,
  /// `.crypto`, and `.exchange`.
  var isInvestmentLike: Bool {
    self == .investment || self == .crypto || self == .exchange
  }

```

After deletion, the enum body proceeds directly from `case exchange` (line 10) to the `isSynced` doc comment (was line 23).

- [ ] **Step 3: Build to verify no callsites remain**

```bash
just build-mac 2>&1 | tee .agent-tmp/test-bucket-6.txt
grep -E 'error:' .agent-tmp/test-bucket-6.txt || echo "OK"
```

Expected: clean build, no errors. If a "Value of type 'AccountType' has no member 'isCurrent'" error appears, find the callsite, fix it to use `.bucket == .current`, and retry.

- [ ] **Step 4: Run the full test suite**

```bash
just test 2>&1 | tee .agent-tmp/test-bucket-6-full.txt
grep -i 'failed\|error:' .agent-tmp/test-bucket-6-full.txt || echo "OK"
```

Expected: every test passes on both iOS Simulator and macOS targets.

- [ ] **Step 5: Format-check**

```bash
just format-check
```

Expected: exits 0.

- [ ] **Step 6: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket add \
  Domain/Models/Account.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket commit -m "refactor(domain): remove AccountType.isCurrent and .isInvestmentLike

All callers now use the .bucket accessor introduced earlier in this
PR. Single API for sidebar partitioning."
```

---

## Task 7: Open the PR

- [ ] **Step 1: Push the branch**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-bucket \
    push origin account-bucket:account-bucket
```

Note the explicit `<src>:<dst>` form per `CLAUDE.md` — avoids any chance of pushing into a parent PR's branch.

- [ ] **Step 2: Create the PR**

```bash
gh pr create --base main --head account-bucket \
  --title "feat(domain): introduce AccountBucket; replace isInvestmentLike/isCurrent" \
  --body "$(cat <<'EOF'
## Summary

- Add `AccountBucket` enum (cases: `current`, `investments`) with stable raw values, `Codable`, `CaseIterable`.
- Add `bucket` accessor on `AccountType` (exhaustive switch) and forwarding `bucket` on `Account`.
- Sweep production callsites (`Accounts+SidebarOrdering.swift`, `AccountStore.swift`) and tests to use `.bucket`.
- Remove `AccountType.isCurrent` and `AccountType.isInvestmentLike`.

## Why

First phase of the Account Groups feature (spec: `plans/2026-05-26-account-groups-design.md`). The upcoming `AccountGroup` entity needs to expose a `bucket` that matches what individual accounts expose; making `bucket` first-class on `AccountType` now avoids two derivation paths.

## Test plan

- [x] `just test AccountBucketTests` — new enum tests pass
- [x] `just test AccountTypeTests` — bucket mapping + `Account.bucket` forwarding tests pass
- [x] `just test AccountsSidebarOrderingTests AccountStoreMutationsTests ExchangeAccountModelTests` — existing behaviour preserved
- [x] `just test` — full suite green on iOS + macOS
- [x] `just format-check` — clean

## Out of scope

This PR only paves the way. `AccountGroup` itself, sidebar grouping UX, and CloudKit schema land in subsequent phases — see the design doc.
EOF
)"
```

Expected: PR URL printed. Note it down for the user.

- [ ] **Step 3: Hand off to the user**

Tell the user the PR URL and confirm whether to add it to the merge queue. Per `feedback_no_auto_queue.md`, do NOT add it to the merge queue without explicit user approval.

---

## Acceptance criteria for Phase 1

- `AccountBucket` enum exists at `Domain/Models/AccountBucket.swift` with cases `.current` and `.investments`, stable raw values, `Codable + Sendable + CaseIterable` conformances.
- `AccountType` has a `bucket: AccountBucket` computed property via exhaustive switch.
- `Account` has a `bucket: AccountBucket` computed property forwarding to `type.bucket`.
- `AccountType.isCurrent` and `AccountType.isInvestmentLike` are removed entirely.
- All production callsites (search the worktree for `isInvestmentLike` and `\.isCurrent` — zero matches outside this plan).
- Full `just test` suite passes on both iOS and macOS.
- `just format-check` passes.
- PR opened against `main`; awaiting user approval before any merge-queue action.

---

## What's NOT in this phase

For reference, the next phases (each gets its own plan written just-in-time):

2. Inline-rename row component for Account, Earmark, Group rows.
3. `AccountGroup` model + CKDB record + GRDB table + DataFormatVersion bump.
4. Sidebar rendering with collapsed/expanded groups + drop semantics + creation flows.
5. `AccountViewContext` + thread through detail view.
6. Description-rendering generalisation + transaction list under group view.
7. Sync wiring (record convertibles, conflict handling, retry surface).
8. Local-only `account_group_ui` table for `isExpandedInSidebar`.
