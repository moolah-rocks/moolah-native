# Merge Transactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user combine two or more selected transactions (same date, same payee) into one transaction whose legs are the union of the sources' legs, via a right-click "Merge Transactions" command and an AppleScript `combine txns` verb.

**Architecture:** A pure `TransactionMergeBuilder` performs the validation + leg-union transform (no I/O), so both the UI store method (`TransactionStore.mergeTransactions`) and the AppleScript service (`AutomationService.combineTransactions`) share one validity authority and reuse the existing atomic `TransactionRepository.replace(deletingIds:creating:)`. A cheap `Transaction.canMerge` gate drives menu enablement across the three UI surfaces (menu bar, context menu, focused action), mirroring the existing `canManualMerge` transfer-merge machinery.

**Tech Stack:** Swift 6, SwiftUI (macOS), Swift Testing (`@Suite`/`@Test`), GRDB via `TransactionRepository`, AppleScript scripting bridge (`.sdef` + `NSScriptCommand`), `just` build/test tooling.

## Global Constraints

- Swift Testing only (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`) — the project is not XCTest for unit tests. UI tests under `MoolahUITests_macOS/` use XCTest.
- One protocol conformance per extension (project convention); one clear responsibility per file.
- Thin views: gate predicates live on the model/leaf, orchestration lives in the store/service — never in `body`.
- Legs are carried through **unchanged**: never `abs()` a quantity, never re-sign by position, never drop `externalId` / `counterpartyAddress` / `categoryId` / `earmarkId` / leg `id`.
- Same-day comparison uses the existing `Date.isSameDay(as:)` (`Shared/Extensions/Date+SameDay.swift`) — do not redefine calendar logic.
- Menu-bar merge commands have no keyboard shortcut and no destructive role (UI_GUIDE §14; matches "Merge as Transfer").
- Build: `just build-mac`. Unit tests: `just test-mac <Filter>`. UI tests: `just test-ui <Filter>`. Formatting: `just format-check` (run after every task; fix via the `fixing-format-check` skill).
- AppleScript command codes are unique 8-char `Mool____`; `Moolmgtx` is taken (transfer merge). The new verb uses `Moolcbtx`.
- AI review gate is mandatory: after implementation, run the reviewers named in each task and in the spec's "Review gates" section, fix every finding, and re-review until clean, before the PR.

---

### Task 1: `TransactionMergeError` + `TransactionMergeBuilder` (pure transform)

**Files:**
- Create: `Shared/TransactionMerge/TransactionMergeError.swift`
- Create: `Shared/TransactionMerge/TransactionMergeBuilder.swift`
- Test: `MoolahTests/Shared/TransactionMergeBuilderTests.swift`

**Interfaces:**
- Consumes: `Transaction`, `TransactionLeg` (`Domain/Models/`), `Date.isSameDay(as:)` (`Shared/Extensions/Date+SameDay.swift`).
- Produces:
  - `enum TransactionMergeError: Error, Equatable, Sendable { case tooFewTransactions, differentDays, differentPayees, containsScheduled }`
  - `struct TransactionMergeBuilder: Sendable { func merged(_ transactions: [Transaction]) throws -> Transaction }`

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Shared/TransactionMergeBuilderTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionMergeBuilder merge")
struct TransactionMergeBuilderTests {
  private let builder = TransactionMergeBuilder()

  // 2024-01-10 12:00:00 UTC.
  private let baseDate = Date(timeIntervalSince1970: 1_704_888_000)

  private func tx(
    id: UUID = UUID(),
    date: Date,
    payee: String?,
    notes: String? = nil,
    legs: [TransactionLeg],
    recurPeriod: RecurPeriod? = nil
  ) -> Transaction {
    Transaction(id: id, date: date, payee: payee, notes: notes, recurPeriod: recurPeriod, legs: legs)
  }

  private func leg(
    id: UUID = UUID(),
    account: UUID = UUID(),
    quantity: Decimal,
    type: TransactionType = .expense,
    externalId: String? = nil,
    counterpartyAddress: String? = nil,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil
  ) -> TransactionLeg {
    TransactionLeg(
      id: id, accountId: account, instrument: .defaultTestInstrument, quantity: quantity,
      externalId: externalId, counterpartyAddress: counterpartyAddress, type: type,
      categoryId: categoryId, earmarkId: earmarkId)
  }

  @Test("merged transaction unions all legs unchanged")
  func unionsLegs() throws {
    let a = leg(quantity: -10)
    let b = leg(quantity: -20)
    let c = leg(quantity: -30)
    let merged = try builder.merged([
      tx(date: baseDate, payee: "Acme", legs: [a, b]),
      tx(date: baseDate, payee: "Acme", legs: [c]),
    ])
    #expect(merged.legs == [a, b, c])
  }

  @Test("merged transaction preserves each leg's identity fields")
  func preservesLegFields() throws {
    let cat = UUID()
    let mark = UUID()
    let a = leg(
      quantity: -10, externalId: "ext-a", counterpartyAddress: "0xabc",
      categoryId: cat, earmarkId: mark)
    let merged = try builder.merged([
      tx(date: baseDate, payee: "Acme", legs: [a]),
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -5)]),
    ])
    let carried = try #require(merged.legs.first { $0.id == a.id })
    #expect(carried.externalId == "ext-a")
    #expect(carried.counterpartyAddress == "0xabc")
    #expect(carried.categoryId == cat)
    #expect(carried.earmarkId == mark)
    #expect(carried.quantity == -10)
  }

  @Test("merged transaction takes the earliest date and a fresh id")
  func earliestDateFreshId() throws {
    let later = baseDate.addingTimeInterval(3_600)
    let txA = tx(date: later, payee: "Acme", legs: [leg(quantity: -10)])
    let txB = tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -20)])
    let merged = try builder.merged([txA, txB])
    #expect(merged.date == baseDate)
    #expect(merged.id != txA.id)
    #expect(merged.id != txB.id)
  }

  @Test("merged transaction keeps the shared payee and drops importOrigin")
  func sharedPayeeNilOrigin() throws {
    let merged = try builder.merged([
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)]),
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -20)]),
    ])
    #expect(merged.payee == "Acme")
    #expect(merged.importOrigin == nil)
    #expect(merged.recurPeriod == nil)
  }

  @Test("notes are newline-joined with duplicate lines dropped in order")
  func notesDedupJoined() throws {
    let merged = try builder.merged([
      tx(date: baseDate, payee: "Acme", notes: "shared\nfirst-only", legs: [leg(quantity: -10)]),
      tx(date: baseDate, payee: "Acme", notes: "shared\nsecond-only", legs: [leg(quantity: -20)]),
    ])
    #expect(merged.notes == "shared\nfirst-only\nsecond-only")
  }

  @Test("all-nil notes produce nil notes")
  func nilNotes() throws {
    let merged = try builder.merged([
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)]),
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -20)]),
    ])
    #expect(merged.notes == nil)
  }

  @Test("three-way merge unions all legs")
  func threeWay() throws {
    let merged = try builder.merged([
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)]),
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -20)]),
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -30)]),
    ])
    #expect(merged.legs.count == 3)
  }

  @Test("fewer than two transactions throws tooFewTransactions")
  func tooFew() {
    #expect(throws: TransactionMergeError.tooFewTransactions) {
      try builder.merged([tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)])])
    }
  }

  @Test("different payees throw differentPayees")
  func differentPayees() {
    #expect(throws: TransactionMergeError.differentPayees) {
      try builder.merged([
        tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)]),
        tx(date: baseDate, payee: "Other", legs: [leg(quantity: -20)]),
      ])
    }
  }

  @Test("different calendar days throw differentDays")
  func differentDays() {
    #expect(throws: TransactionMergeError.differentDays) {
      try builder.merged([
        tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)]),
        tx(date: baseDate.addingTimeInterval(86_400 * 3), payee: "Acme", legs: [leg(quantity: -20)]),
      ])
    }
  }

  @Test("a scheduled transaction in the selection throws containsScheduled")
  func scheduled() {
    #expect(throws: TransactionMergeError.containsScheduled) {
      try builder.merged([
        tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)], recurPeriod: .monthly),
        tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -20)]),
      ])
    }
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test-mac TransactionMergeBuilderTests`
Expected: FAIL — `cannot find 'TransactionMergeBuilder'` / `TransactionMergeError` in scope.

- [ ] **Step 3: Write `TransactionMergeError`**

Create `Shared/TransactionMerge/TransactionMergeError.swift`:

```swift
import Foundation

/// General transaction-merge validation failure. Distinct from
/// `TransferMergeError` / `ManualMergeError`, which govern the
/// two-leg transfer merge. Cases carry no payload, so `Sendable`
/// is trivially satisfied for crossing actor boundaries.
enum TransactionMergeError: Error, Equatable, Sendable {
  case tooFewTransactions  // fewer than two transactions supplied
  case differentDays  // not all on the same calendar day
  case differentPayees  // payees are not all equal
  case containsScheduled  // a scheduled / recurring transaction was included
}
```

- [ ] **Step 4: Write `TransactionMergeBuilder`**

Create `Shared/TransactionMerge/TransactionMergeBuilder.swift`:

```swift
import Foundation

/// Pure merge transform combining two or more transactions into one.
/// No I/O.
///
/// The N source transactions must share the same calendar day and the
/// same payee, and none may be scheduled/recurring. Every leg of every
/// source is carried through unchanged (identity fields intact); the
/// merged transaction takes the earliest source date, the shared payee,
/// and the sources' notes newline-joined with duplicate lines dropped.
/// `importOrigin` is dropped — it has no meaning across N arbitrary
/// transactions, and each leg keeps its own `externalId` so sync dedup
/// (`(accountId, externalId)`) stays correct. The merge is one-way; no
/// per-source provenance is recorded.
struct TransactionMergeBuilder: Sendable {
  func merged(_ transactions: [Transaction]) throws -> Transaction {
    guard transactions.count >= 2 else { throw TransactionMergeError.tooFewTransactions }
    let first = transactions[0]
    guard transactions.allSatisfy({ $0.payee == first.payee }) else {
      throw TransactionMergeError.differentPayees
    }
    guard transactions.allSatisfy({ $0.date.isSameDay(as: first.date) }) else {
      throw TransactionMergeError.differentDays
    }
    guard transactions.allSatisfy({ $0.recurPeriod == nil }) else {
      throw TransactionMergeError.containsScheduled
    }

    return Transaction(
      date: transactions.map(\.date).min() ?? first.date,
      payee: first.payee,
      notes: mergedNotes(transactions.map(\.notes)),
      legs: transactions.flatMap(\.legs))
  }

  /// Splits each note into lines, drops duplicate lines, and re-joins
  /// with newlines in the supplied order. Mirrors
  /// `TransferMergeBuilder.mergedNotes` generalised to N inputs.
  private func mergedNotes(_ notes: [String?]) -> String? {
    let present = notes.compactMap { $0 }
    guard !present.isEmpty else { return nil }
    var seen: Set<String> = []
    let lines = present.flatMap { $0.components(separatedBy: "\n") }
    let deduped = lines.filter { seen.insert($0).inserted }
    return deduped.joined(separator: "\n")
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test-mac TransactionMergeBuilderTests`
Expected: PASS (all cases).

- [ ] **Step 6: Format-check and commit**

```bash
just format-check
git add Shared/TransactionMerge/ MoolahTests/Shared/TransactionMergeBuilderTests.swift
git commit -m "feat(transactions): TransactionMergeBuilder pure N-way merge transform"
```

---

### Task 2: `Transaction.canMerge` gate predicate

**Files:**
- Create: `Domain/Models/Transaction+Merge.swift`
- Test: `MoolahTests/Domain/TransactionCanMergeTests.swift`

**Interfaces:**
- Consumes: `Transaction`, `Date.isSameDay(as:)`.
- Produces: `static func Transaction.canMerge(_ transactions: [Transaction]) -> Bool`.

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Domain/TransactionCanMergeTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.canMerge")
struct TransactionCanMergeTests {
  private let baseDate = Date(timeIntervalSince1970: 1_704_888_000)

  private func tx(
    date: Date, payee: String?, recurPeriod: RecurPeriod? = nil
  ) -> Transaction {
    Transaction(
      date: date, payee: payee, recurPeriod: recurPeriod,
      legs: [TransactionLeg(accountId: UUID(), instrument: .defaultTestInstrument,
        quantity: -10, type: .expense)])
  }

  @Test("two same-day same-payee transactions can merge")
  func happyPath() {
    #expect(Transaction.canMerge([tx(date: baseDate, payee: "Acme"), tx(date: baseDate, payee: "Acme")]))
  }

  @Test("a single transaction cannot merge")
  func single() {
    #expect(!Transaction.canMerge([tx(date: baseDate, payee: "Acme")]))
  }

  @Test("different payees cannot merge")
  func payees() {
    #expect(!Transaction.canMerge([tx(date: baseDate, payee: "Acme"), tx(date: baseDate, payee: "Other")]))
  }

  @Test("different days cannot merge")
  func days() {
    #expect(!Transaction.canMerge([
      tx(date: baseDate, payee: "Acme"),
      tx(date: baseDate.addingTimeInterval(86_400 * 2), payee: "Acme"),
    ]))
  }

  @Test("a scheduled transaction blocks the merge")
  func scheduled() {
    #expect(!Transaction.canMerge([
      tx(date: baseDate, payee: "Acme", recurPeriod: .monthly),
      tx(date: baseDate, payee: "Acme"),
    ]))
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test-mac TransactionCanMergeTests`
Expected: FAIL — `type 'Transaction' has no member 'canMerge'`.

- [ ] **Step 3: Write the predicate**

Create `Domain/Models/Transaction+Merge.swift`:

```swift
import Foundation

extension Transaction {
  /// `true` iff `transactions` form a valid general-merge selection:
  /// two or more, all on the same calendar day, all with the same
  /// payee, and none scheduled/recurring. This is the cheap
  /// menu-enable gate shared by the menu bar, context menu, and the
  /// focused action; `TransactionMergeBuilder.merged(_:)` re-validates
  /// authoritatively and throws `TransactionMergeError` for anything
  /// this gate lets through. Distinct from `canManualMerge`, which
  /// gates the two-leg transfer merge.
  static func canMerge(_ transactions: [Transaction]) -> Bool {
    guard transactions.count >= 2 else { return false }
    let first = transactions[0]
    return transactions.allSatisfy { $0.payee == first.payee }
      && transactions.allSatisfy { $0.date.isSameDay(as: first.date) }
      && transactions.allSatisfy { $0.recurPeriod == nil }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test-mac TransactionCanMergeTests`
Expected: PASS.

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git add Domain/Models/Transaction+Merge.swift MoolahTests/Domain/TransactionCanMergeTests.swift
git commit -m "feat(transactions): Transaction.canMerge selection gate"
```

---

### Task 3: `TransactionStore.mergeTransactions` store method

**Files:**
- Create: `Features/Transactions/TransactionStore+Merge.swift`
- Test: `MoolahTests/Features/TransactionStoreMergeTests.swift`

**Interfaces:**
- Consumes: `TransactionMergeBuilder.merged(_:)`, `TransactionStore.repository` (`TransactionRepository`), `TransactionStore.setError(_:)`, `TransactionRepository.replace(deletingIds:creating:)`.
- Produces: `func TransactionStore.mergeTransactions(_ transactions: [Transaction]) async`.

Note the existing test `TransactionStoreManualMergeTests` uses `TestBackend.create()` + `TransactionFilter()` + seeding via `TestBackend.seed`. Follow that pattern. The store here does **not** need the transfer coordinator wired, so construct it with only the repository (see `makeStore` below).

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Features/TransactionStoreMergeTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/Merge")
@MainActor
struct TransactionStoreMergeTests {
  private func makeStore(backend: CloudKitBackend) -> TransactionStore {
    TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
  }

  private func tx(
    account: UUID, quantity: Decimal, payee: String, on date: Date
  ) -> Transaction {
    Transaction(
      date: date, payee: payee,
      legs: [TransactionLeg(accountId: account, instrument: .defaultTestInstrument,
        quantity: quantity, type: quantity < 0 ? .expense : .income)])
  }

  @Test
  func mergeCombinesSelectionAndRemovesSources() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let account = UUID()
    let a = tx(account: account, quantity: -10, payee: "Acme", on: date)
    let b = tx(account: account, quantity: -20, payee: "Acme", on: date)
    TestBackend.seed(transactions: [a, b], in: database)
    let store = makeStore(backend: backend)

    await store.mergeTransactions([a, b])

    #expect(store.error == nil)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 1)
    let merged = try #require(all.first)
    #expect(merged.legs.count == 2)
    #expect(all.contains { $0.id == a.id } == false)
    #expect(all.contains { $0.id == b.id } == false)
  }

  @Test
  func mergeInvalidSelectionSurfacesErrorWithoutMutating() async throws {
    let (backend, database) = try TestBackend.create()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let account = UUID()
    let a = tx(account: account, quantity: -10, payee: "Acme", on: date)
    let b = tx(account: account, quantity: -20, payee: "Other", on: date)
    TestBackend.seed(transactions: [a, b], in: database)
    let store = makeStore(backend: backend)

    await store.mergeTransactions([a, b])

    #expect(store.error != nil)
    let all = try await backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }
}
```

If `TransactionStore.init` requires arguments beyond those shown (verify against `Features/Transactions/TransactionStore.swift` — the transfer-suggestion argument is optional and omitted here), match the real initializer; `conversionService`/`targetInstrument` are shown for parity with `TransactionStoreManualMergeTests.makeStore`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test-mac TransactionStoreMergeTests`
Expected: FAIL — `value of type 'TransactionStore' has no member 'mergeTransactions'`.

- [ ] **Step 3: Write the store method**

Create `Features/Transactions/TransactionStore+Merge.swift`:

```swift
import Foundation

// General N-way transaction merge for the transaction list. Distinct
// from the transfer-merge pass-throughs in
// `TransactionStore+TransferDetection.swift`: a general merge has no
// `TransferSuggestion` to delete, so it does not route through
// `TransferDetectionCoordinator`. It builds the combined transaction
// with the shared `TransactionMergeBuilder` and swaps sources → merged
// in one atomic `replace`, surfacing any failure on the store's own
// `error` channel (same shape as the `delete` / `update` mutations).
extension TransactionStore {
  /// Combines two or more transactions (same day, same payee, none
  /// scheduled) into one whose legs are the union of the sources'
  /// legs, deleting the sources and creating the merged transaction in
  /// one atomic write. On an invalid selection the builder throws a
  /// `TransactionMergeError`, which is surfaced on `error` and leaves
  /// the store unmutated. The list gate (`Transaction.canMerge`) means
  /// the throw path is defensive in normal use.
  func mergeTransactions(_ transactions: [Transaction]) async {
    setError(nil)
    do {
      let merged = try TransactionMergeBuilder().merged(transactions)
      _ = try await repository.replace(
        deletingIds: transactions.map(\.id), creating: [merged])
      logger.debug("Merged \(transactions.count) transactions into \(merged.id)")
    } catch {
      logger.error("Failed to merge transactions: \(error.localizedDescription)")
      setError(error)
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test-mac TransactionStoreMergeTests`
Expected: PASS.

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git add Features/Transactions/TransactionStore+Merge.swift MoolahTests/Features/TransactionStoreMergeTests.swift
git commit -m "feat(transactions): TransactionStore.mergeTransactions atomic N-way merge"
```

---

### Task 4: Focused-value key for the menu-bar action

**Files:**
- Modify: `Shared/FocusedValues.swift` (add key next to `MergeAsTransferActionKey` ~line 83; add accessor next to `mergeAsTransferAction` ~line 217)

**Interfaces:**
- Produces: `FocusedValues.mergeTransactionsAction: (() -> Void)?` and `struct MergeTransactionsActionKey: FocusedValueKey { typealias Value = () -> Void }`.

- [ ] **Step 1: Add the key**

In `Shared/FocusedValues.swift`, immediately after the `MergeAsTransferActionKey` struct (the one whose doc mentions "Merge as Transfer"), add:

```swift
/// Trigger action for Transaction > Merge Transactions. Published by
/// the transaction-list leaf only when its multi-selection is two or
/// more transactions that share a calendar day and payee and are not
/// scheduled (`Transaction.canMerge`); `nil` otherwise, which disables
/// the menu item. Distinct from `MergeAsTransferActionKey`, which gates
/// the two-leg transfer merge.
struct MergeTransactionsActionKey: FocusedValueKey {
  typealias Value = () -> Void
}
```

- [ ] **Step 2: Add the accessor**

In the same file, immediately after the `mergeAsTransferAction` computed accessor, add:

```swift
var mergeTransactionsAction: MergeTransactionsActionKey.Value? {
  get { self[MergeTransactionsActionKey.self] }
  set { self[MergeTransactionsActionKey.self] = newValue }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `just build-mac`
Expected: build succeeds (the key is not yet referenced elsewhere; this just confirms the additions parse).

- [ ] **Step 4: Format-check and commit**

```bash
just format-check
git add Shared/FocusedValues.swift
git commit -m "feat(transactions): mergeTransactionsAction focused value"
```

---

### Task 5: UI-test identifier for the context-menu item

**Files:**
- Create: `UITestSupport/UITestIdentifiers+TransactionMerge.swift`

**Interfaces:**
- Produces: `UITestIdentifiers.TransactionMerge.merge(_ id: UUID) -> String`.

- [ ] **Step 1: Add the identifier namespace**

Create `UITestSupport/UITestIdentifiers+TransactionMerge.swift`:

```swift
import Foundation

extension UITestIdentifiers {
  // MARK: - TransactionMerge

  /// Identifiers for the general "Merge Transactions" command (distinct
  /// from `TransferDetection.merge`, which is the transfer merge).
  public enum TransactionMerge {
    /// The "Merge Transactions" context-menu item shown on a row that is
    /// part of a valid multi-selection. `id` is that row's UUID,
    /// lowercased.
    public static func merge(_ id: UUID) -> String {
      "transactionmerge.merge.\(id.uuidString.lowercased())"
    }
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `just build-mac`
Expected: build succeeds.

- [ ] **Step 3: Format-check and commit**

```bash
just format-check
git add UITestSupport/UITestIdentifiers+TransactionMerge.swift
git commit -m "feat(transactions): UITest identifier for Merge Transactions"
```

---

### Task 6: List UI — `mergeSelection` resolver, context-menu item, focused action, menu-bar item

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView+List.swift` (add `mergeSelection` near `manualMergePair` ~line 38; add context-menu button in `rowContextMenu` ~line 354, after the transfer-merge button)
- Modify: `Features/Transactions/Views/TransactionListView.swift` (publish focused action next to the `mergeAsTransferAction` publish ~line 194)
- Modify: `App/MoolahDomainCommands.swift` (add `@FocusedValue` ~line 127 and menu button after "Merge as Transfer" ~line 155)

**Interfaces:**
- Consumes: `Transaction.canMerge(_:)`, `TransactionStore.mergeTransactions(_:)`, `FocusedValues.mergeTransactionsAction`, `UITestIdentifiers.TransactionMerge.merge(_:)`, existing `transferMergeSelection` state.
- Produces: `TransactionListView.mergeSelection: [Transaction]?`.

This task is UI wiring with no unit test; it is verified by `just build-mac` and the UI test in Task 7. Keep `body` thin — the gate lives in `mergeSelection`.

- [ ] **Step 1: Add the `mergeSelection` resolver**

In `Features/Transactions/Views/TransactionListView+List.swift`, directly after the `manualMergePair` computed property (which ends ~line 46), add:

```swift
/// The two-or-more transactions the user has multi-selected for a
/// general merge, resolved from the loaded projection, or `nil` when
/// the selection is not a valid merge candidate (fewer than two, mixed
/// day/payee, or scheduled). Shared by the row context menu and the
/// menu-bar focused action so the gate is not duplicated;
/// `Transaction.canMerge` is the single predicate.
var mergeSelection: [Transaction]? {
  guard transferMergeSelection.count >= 2 else { return nil }
  let selected = transactionStore.transactions
    .map(\.transaction)
    .filter { transferMergeSelection.contains($0.id) }
  guard selected.count == transferMergeSelection.count else { return nil }
  guard Transaction.canMerge(selected) else { return nil }
  return selected
}
```

- [ ] **Step 2: Add the context-menu button**

In the same file, in `rowContextMenu(for:isScheduled:)`, directly after the existing transfer-merge `if let pair = manualMergePair … { Button("Merge as Transfer" …) }` block (ends ~line 359), add:

```swift
if let selection = mergeSelection, selection.contains(where: { $0.id == transaction.id }) {
  Button("Merge Transactions", systemImage: "arrow.triangle.merge") {
    Task { await transactionStore.mergeTransactions(selection) }
  }
  .accessibilityIdentifier(UITestIdentifiers.TransactionMerge.merge(transaction.id))
}
```

- [ ] **Step 3: Publish the focused action**

In `Features/Transactions/Views/TransactionListView.swift`, directly after the `.focusedSceneValue(\.mergeAsTransferAction, …)` modifier (ends ~line 199), add:

```swift
.focusedSceneValue(
  \.mergeTransactionsAction,
  mergeSelection.map { selection in
    { Task { await transactionStore.mergeTransactions(selection) } }
  }
)
```

- [ ] **Step 4: Add the menu-bar command**

In `App/MoolahDomainCommands.swift`:

(a) After `@FocusedValue(\.mergeAsTransferAction) private var mergeAsTransferAction` (~line 127), add:

```swift
@FocusedValue(\.mergeTransactionsAction) private var mergeTransactionsAction
```

(b) In the `CommandMenu("Transaction")` body, directly after the `Button("Merge as Transfer") …` (~line 155), add:

```swift
Button("Merge Transactions") { mergeTransactionsAction?() }
  .disabled(mergeTransactionsAction == nil)
```

- [ ] **Step 5: Verify it compiles**

Run: `just build-mac`
Expected: build succeeds.

- [ ] **Step 6: Format-check and commit**

```bash
just format-check
git add Features/Transactions/Views/TransactionListView+List.swift Features/Transactions/Views/TransactionListView.swift App/MoolahDomainCommands.swift
git commit -m "feat(transactions): Merge Transactions menu, context menu, focused action"
```

---

### Task 7: macOS UI test — merge two rows via the context menu

> **SKIPPED (2026-07-03, user decision):** No multi-select/context-menu driver exists in `MoolahUITests_macOS`, and the sibling list "Merge as Transfer" (`manualMergePair`) has no UI test — it is store-tested only. The merge is covered by 20 store/unit tests (builder 11, canMerge 5, store 2, automation 2). Building command-click + context-menu driver infrastructure for one happy-path test was judged over-investment inconsistent with the codebase. Revisit if the list gains other UI tests that establish the drivers.

**Files:**
- Test: `MoolahUITests_macOS/TransactionMergeUITests.swift`
- Possibly modify: `UITestSupport/UITestSeeds.swift` (only if no existing seed yields two same-day/same-payee rows in one account; prefer reusing an existing seed)

**Interfaces:**
- Consumes: the `UITestIdentifiers.TransactionMerge.merge(_:)` element from Task 6, the transaction-list screen driver, and a UI-test seed with at least two same-day, same-payee transactions.

Before writing, invoke the **`writing-ui-tests`** skill and follow the screen-driver rule (tests import only XCTest; interact through the existing transaction-list screen driver; wait on post-conditions; no element caching). Inspect `MoolahUITests_macOS/Helpers/Screens/` for the transaction-list driver and `UITestSupport/UITestSeeds.swift` for a suitable seed. If an existing test already Command-clicks two rows (the transfer-merge UI test is the closest precedent — find it via `grep -rl "Merge as Transfer" MoolahUITests_macOS`), mirror its multi-select mechanics exactly.

- [ ] **Step 1: Identify the seed and driver**

Run: `grep -rl "Merge as Transfer" MoolahUITests_macOS` and read that test plus the driver it uses. Confirm a seed exists with two same-day, same-payee transactions on one account (or add one to `UITestSeeds.swift` following the existing seed style, keeping seeds deterministic).

- [ ] **Step 2: Write the UI test**

Create `MoolahUITests_macOS/TransactionMergeUITests.swift`. Structure (fill selectors/driver calls from the precedent found in Step 1 — the driver API, not raw `XCUIElement` queries, per the screen-driver rule):

```swift
import XCTest

final class TransactionMergeUITests: XCTestCase {
  // Launch with the seed identified in Step 1; open the account whose
  // list holds the two same-day/same-payee rows.
  //
  // 1. Command-click both rows (mirror the transfer-merge test's
  //    multi-select mechanics).
  // 2. Right-click one selected row to open its context menu.
  // 3. Tap the item resolved by
  //    UITestIdentifiers.TransactionMerge.merge(<that row's id>).
  // 4. Wait on the post-condition: the two source rows collapse to one
  //    merged row (assert the list's row count dropped by one, or the
  //    merged row shows both legs), never a fixed sleep.
}
```

- [ ] **Step 3: Run the UI test**

Run: `just test-ui TransactionMergeUITests`
Expected: PASS. If the local UI host is wedged, per memory `feedback_pr_ci_gate_when_ui_host_blocked` gate on the PR's CI "UI Test" job instead — but first attempt locally.

- [ ] **Step 4: Format-check and commit**

```bash
just format-check
git add MoolahUITests_macOS/TransactionMergeUITests.swift UITestSupport/UITestSeeds.swift
git commit -m "test(transactions): UI test for Merge Transactions context menu"
```

---

### Task 8: AppleScript service — `AutomationService.combineTransactions`

**Files:**
- Create: `Automation/AutomationService+CombineTransactions.swift`
- Test: `MoolahTests/Automation/AutomationServiceCombineTransactionsTests.swift`

**Interfaces:**
- Consumes: `AutomationService.resolveSession(for:)`, `session.backend.transactions` (`fetchAll` / `replace`), `TransactionMergeBuilder`, `AutomationError`.
- Produces: `func AutomationService.combineTransactions(profileIdentifier: String, ids: [UUID]) async throws -> Transaction`.

Mirror `Automation/AutomationService+TransferMerge.swift` (structure, `resolveSession`, id-resolution via a fetched snapshot, `AutomationError.operationFailed` wrapping) and `MoolahTests/Automation/AutomationServiceMergeTransactionsTests.swift` (session/seed helpers).

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Automation/AutomationServiceCombineTransactionsTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Combine Transactions")
@MainActor
struct AutomationServiceCombineTransactionsTests {
  private struct OpenSessionFailed: Error {}

  private func makeServiceWithSession() async throws -> (AutomationService, ProfileSession) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(
      containerManager: containerManager,
      profileIndexRepository: containerManager.profileIndexRepositoryForTesting)
    let profile = Profile(label: "Test", currencyCode: "AUD", financialYearStartMonth: 7)
    guard case .ready(let session) = await sessionManager.session(for: profile) else {
      Issue.record("expected .ready")
      throw OpenSessionFailed()
    }
    try await session.accountStore.waitForFirstEmission()
    return (AutomationService(sessionManager: sessionManager), session)
  }

  private func makeSingleLeg(
    session: ProfileSession, accountId: UUID, quantity: Decimal, payee: String,
    on date: Date
  ) async throws -> Transaction {
    let transaction = Transaction(
      id: UUID(), date: date, payee: payee,
      legs: [TransactionLeg(accountId: accountId, instrument: session.profile.instrument,
        quantity: quantity, type: quantity < 0 ? .expense : .income)])
    return try await session.backend.transactions.create(transaction)
  }

  @Test("combines three same-day same-payee transactions into one")
  func combinesThree() async throws {
    let (service, session) = try await makeServiceWithSession()
    let account = try await service.createAccount(
      profileIdentifier: "Test", name: "Checking", type: .bank)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let a = try await makeSingleLeg(session: session, accountId: account.id, quantity: -10, payee: "Acme", on: date)
    let b = try await makeSingleLeg(session: session, accountId: account.id, quantity: -20, payee: "Acme", on: date)
    let c = try await makeSingleLeg(session: session, accountId: account.id, quantity: -30, payee: "Acme", on: date)

    let merged = try await service.combineTransactions(
      profileIdentifier: "Test", ids: [a.id, b.id, c.id])

    #expect(merged.legs.count == 3)
    let all = try await session.backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 1)
  }

  @Test("throws on an invalid (different-payee) selection without mutating")
  func throwsOnInvalid() async throws {
    let (service, session) = try await makeServiceWithSession()
    let account = try await service.createAccount(
      profileIdentifier: "Test", name: "Checking", type: .bank)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let a = try await makeSingleLeg(session: session, accountId: account.id, quantity: -10, payee: "Acme", on: date)
    let b = try await makeSingleLeg(session: session, accountId: account.id, quantity: -20, payee: "Other", on: date)

    await #expect(throws: (any Error).self) {
      _ = try await service.combineTransactions(profileIdentifier: "Test", ids: [a.id, b.id])
    }
    let all = try await session.backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(all.count == 2)
  }
}
```

Verify `session.profile.instrument`, `createAccount`, and `waitForFirstEmission` against `AutomationServiceMergeTransactionsTests.swift` — copy the exact spellings from there if any differ.

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test-mac AutomationServiceCombineTransactionsTests`
Expected: FAIL — `value of type 'AutomationService' has no member 'combineTransactions'`.

- [ ] **Step 3: Write the service method**

Create `Automation/AutomationService+CombineTransactions.swift`:

```swift
import Foundation

// General N-way transaction merge for `AutomationService`: collapse two
// or more same-day, same-payee transactions into one whose legs are the
// union of the sources' legs. The AppleScript counterpart to the list's
// "Merge Transactions" command; distinct from `mergeTransactions`, which
// is the two-transaction transfer merge. Reuses `TransactionMergeBuilder`
// so both surfaces enforce identical validity rules. The member is
// `@MainActor` via the containing class.
extension AutomationService {
  /// Combines the referenced transactions into one merged transaction.
  ///
  /// Every id is resolved from the authoritative repository snapshot.
  /// The selection must be a valid general merge (two or more, same
  /// calendar day, same payee, none scheduled) or the merge throws. The
  /// sources are deleted and the merged transaction inserted atomically.
  ///
  /// Each leg is carried through unchanged, including its `externalId`
  /// (the dedup key the wallet/exchange apply pass matches on
  /// `(accountId, externalId)`), so a merged sync-owned leg is not
  /// re-imported as a duplicate on the next sync.
  func combineTransactions(
    profileIdentifier: String,
    ids: [UUID]
  ) async throws -> Transaction {
    let session = try resolveSession(for: profileIdentifier)

    let transactions = try await session.backend.transactions.fetchAll(filter: TransactionFilter())
    let sources = try ids.map { try Self.transaction(id: $0, in: transactions) }

    let merged: Transaction
    do {
      merged = try TransactionMergeBuilder().merged(sources)
    } catch {
      throw AutomationError.operationFailed("Cannot merge: \(error.localizedDescription)")
    }

    do {
      let created = try await session.backend.transactions.replace(
        deletingIds: ids, creating: [merged])
      guard let result = created.first else {
        throw AutomationError.operationFailed("Merge produced no transaction")
      }
      return result
    } catch let error as AutomationError {
      throw error
    } catch {
      throw AutomationError.operationFailed(
        "Failed to merge transactions: \(error.localizedDescription)")
    }
  }
}
```

This calls `Self.transaction(id:in:)` — the `private static` helper already defined in `AutomationService+TransferMerge.swift`. Since both files are extensions on the same type in the same module, confirm the helper's access level allows use here; if `private` blocks cross-file use, change it to `static` (module-internal) in `AutomationService+TransferMerge.swift` as part of this task and note it in the commit.

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test-mac AutomationServiceCombineTransactionsTests`
Expected: PASS.

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git add Automation/AutomationService+CombineTransactions.swift MoolahTests/Automation/AutomationServiceCombineTransactionsTests.swift Automation/AutomationService+TransferMerge.swift
git commit -m "feat(automation): AutomationService.combineTransactions N-way merge"
```

---

### Task 9: AppleScript command + sdef verb `combine txns`

**Files:**
- Create: `Automation/AppleScript/Commands/CombineTransactionsCommand.swift`
- Modify: `Automation/AppleScript/Moolah.sdef` (add `combine txns` command after the `merge txns` block ~line 267; update the `merge txns` description to disambiguate)

**Interfaces:**
- Consumes: `AutomationService.combineTransactions(profileIdentifier:ids:)`, `ScriptingContext.automationService`, `ScriptableTransaction`, `AppLevelScriptCommand`.

No unit test (the scripting bridge is exercised manually / via release-script tests); verified by `just build-mac`. Mirror `MergeTransactionsCommand.swift` exactly for the error plumbing (`runBlockingWithError`, `resolveProfileName`, `fail`).

- [ ] **Step 1: Write the command class**

Create `Automation/AppleScript/Commands/CombineTransactionsCommand.swift`:

```swift
#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "CombineTransactionsCommand")

  /// Handles: `combine txns profile "X" ids {"uuid", "uuid", …}`
  ///
  /// Collapses the referenced transactions into one merged transaction
  /// whose legs are the union of the sources' legs (see
  /// `AutomationService.combineTransactions`). Distinct from
  /// `merge txns`, which merges two opposing sides into a transfer.
  class CombineTransactionsCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        return fail("Missing profile specifier")
      }
      guard let args = evaluatedArguments, let rawIds = args["ids"] as? [String] else {
        return fail("Missing required parameter: ids (list of transaction ids)")
      }
      guard rawIds.count >= 2 else {
        return fail("Provide at least two transaction ids to combine")
      }
      var ids: [UUID] = []
      for raw in rawIds {
        guard let id = UUID(uuidString: raw) else {
          return fail("Invalid transaction id '\(raw)'")
        }
        ids.append(id)
      }

      let result: ScriptableTransaction? = runBlockingWithError {
        @MainActor () async throws -> ScriptableTransaction in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        let merged = try await service.combineTransactions(
          profileIdentifier: profileName, ids: ids)
        let session = try service.resolveSession(for: profileName)
        return ScriptableTransaction(
          transaction: merged,
          profileName: profileName,
          accountStore: session.accountStore,
          categoryStore: session.categoryStore)
      }
      return result
    }

    private func fail(_ message: String) -> Any? {
      scriptErrorNumber = -10000
      scriptErrorString = message
      return nil
    }
  }
#endif
```

- [ ] **Step 2: Add the sdef command**

In `Automation/AppleScript/Moolah.sdef`, directly after the closing `</command>` of the `merge txns` block (~line 267), add:

```xml
    <command name="combine txns" code="Moolcbtx" description="Merge two or more same-day, same-payee transactions into one whose legs are the union of the sources' legs (general merge; use 'merge txns' for the two-sided transfer merge).">
      <cocoa class="Moolah.CombineTransactionsCommand"/>
      <direct-parameter type="specifier" description="The profile containing the transactions."/>
      <parameter name="ids" code="Cbid" description="The ids of the transactions to combine (two or more).">
        <cocoa key="ids"/>
        <type type="text" list="yes"/>
      </parameter>
      <result type="txn" description="The merged txn."/>
    </command>
```

Then update the existing `merge txns` command's `description` attribute to disambiguate, e.g.: `"Merge two opposing single-account transactions into one cross-account transfer (use 'combine txns' for a general N-way merge)."`

- [ ] **Step 3: Verify it compiles**

Run: `just build-mac`
Expected: build succeeds. (The sdef is validated at app runtime; a malformed sdef surfaces as a scripting-dictionary load failure, so also sanity-check the XML is well-formed — `xmllint --noout Automation/AppleScript/Moolah.sdef` if available.)

- [ ] **Step 4: Format-check and commit**

```bash
just format-check
git add Automation/AppleScript/Commands/CombineTransactionsCommand.swift Automation/AppleScript/Moolah.sdef
git commit -m "feat(automation): combine txns AppleScript verb for general merge"
```

---

### Task 10: Full-suite verification + AI review gate

**Files:** none (verification only).

- [ ] **Step 1: Build and run the full unit suite**

Run: `just build-mac && just test-mac`
Expected: build + all unit tests pass. Investigate any failure (note the known pre-existing `WalletSyncEngine` cancellation flake per memory — re-run once if only that fails and this branch does not touch it).

- [ ] **Step 2: Run the new UI test**

Run: `just test-ui TransactionMergeUITests`
Expected: PASS (or gate on PR CI if the local UI host is wedged).

- [ ] **Step 3: Format-check the whole tree**

Run: `just format-check`
Expected: clean.

- [ ] **Step 4: Run the mandatory AI reviewers and fix every finding**

Per `guides/AI_ASSISTANT_GUIDE.md` and `guides/AI_REVIEW_GATE_GUIDE.md`, run and clear:
- `code-review` — all new/changed Swift.
- `concurrency-review` — `TransactionStore+Merge.swift`, `AutomationService+CombineTransactions.swift`.
- `ui-review` — the menu / context-menu additions.
- `ui-test-review` — `TransactionMergeUITests.swift`.
- `datetime-review` — the `Date.isSameDay(as:)` gate in the builder and predicate.

Fix each finding immediately and re-run the relevant reviewer until no findings remain.

- [ ] **Step 5: Open the PR**

Push the branch and open a PR (do not merge here — landing goes through the `landing-prs` skill per CLAUDE.md).

```bash
git push -u origin feat/merge-transactions
gh pr create --fill
```

---

## Self-Review Notes

- **Spec coverage:** builder (Task 1), gate (Task 2), store method (Task 3), focused value (Task 4), UI-test id (Task 5), three UI surfaces (Task 6), UI test (Task 7), AppleScript service + verb (Tasks 8–9), verification + review gate (Task 10). Notes dedup-join, min-date, fresh id, `importOrigin=nil`, legs-unchanged, one-way, same-day-via-`isSameDay` are each asserted in Task 1 tests. Coexistence with transfer merge is inherent (independent predicates; no shared enablement).
- **Type consistency:** `TransactionMergeBuilder.merged(_:)`, `Transaction.canMerge(_:)`, `TransactionStore.mergeTransactions(_:)`, `AutomationService.combineTransactions(profileIdentifier:ids:)`, `TransactionMergeError` cases, `mergeTransactionsAction`, `UITestIdentifiers.TransactionMerge.merge(_:)` are used consistently across tasks.
- **Verification caveats to honour during execution:** exact `TransactionStore.init` parameters (Task 3), the transfer-merge UI test's multi-select mechanics and a suitable seed (Task 7), `session.profile.instrument`/`createAccount` spellings (Task 8), and the access level of `AutomationService.transaction(id:in:)` (Task 8) must each be confirmed against the real files before finalising that task — flagged inline.
