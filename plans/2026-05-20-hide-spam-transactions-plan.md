# Hide Spam-Token Transactions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task is self-contained; per-task verify is **build + tests + `just format-check`** per project memory `feedback_format_check_per_plan_step.md`.

**Spec:** `plans/2026-05-20-hide-spam-transactions-design.md` (committed `97c0585e`).

**Goal:** Hide transactions whose every leg references a spam-flagged instrument from every `TransactionListView` by default, with a macOS View menu item and an iOS toolbar item to flip the preference.

**Architecture:** `@AppStorage("showSpamTransactions")` is the durable preference (default `false`). On macOS, `SidebarView` owns the storage and republishes it via `.focusedSceneValue(\.showSpamTransactions, …)` so a `ShowSpamTransactionsCommands` struct in the View menu can bind to it (verb-pair button label, per UI_GUIDE §14). On iOS, `TransactionListView` owns the same `@AppStorage` key (UserDefaults keeps it in sync) and exposes a toolbar toggle. `TransactionListView` mirrors the `@AppStorage` + `\.spamInstruments` environment into `TransactionStore.showSpam` / `TransactionStore.spamInstruments`; the store keeps an internal unfiltered list and republishes a filtered `transactions` view whenever either input changes. This deliberately mirrors the established `accountStore.showHidden` precedent at `Features/Accounts/AccountStore.swift:232-247`.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite` / `@Test`), `@Observable @MainActor` stores, `TestBackend` (CloudKitBackend + in-memory SwiftData).

---

## File Structure

**Create:**

- `MoolahTests/Domain/TransactionIsAllSpamTests.swift` — unit tests for the new `Transaction.isAllSpam(in:)` predicate. Mirrors `TransactionIsTradeTests.swift`.
- `MoolahTests/Features/TransactionStoreSpamFilterTests.swift` — store-level tests for the spam-filter behaviour (6 cases from spec + change-of-set + change-of-flag).

**Modify:**

- `Domain/Models/Transaction.swift` — add `func isAllSpam(in:)` in a new extension at the bottom of the file (CODE_GUIDE.md: one extension per purpose).
- `Features/Transactions/TransactionStore.swift` — add `showSpam`, `spamInstruments`, `unfilteredTransactions`, `setSpamInstruments(_:)`; rewrite `setTransactions(_:)` to route through `publishFilteredTransactions()`.
- `Shared/FocusedValues.swift` — add `ShowSpamTransactionsKey` and the `FocusedValues` accessor.
- `App/MoolahDomainCommands.swift` — add `ShowSpamTransactionsCommands: Commands`.
- `App/MoolahApp.swift` — register `ShowSpamTransactionsCommands()` in both `.commands` blocks (lines 169-180 and 230-233 area), immediately after `ShowHiddenCommands()`.
- `Features/Navigation/SidebarView.swift` — add `@AppStorage("showSpamTransactions") private var showSpam = false` and a `.focusedSceneValue(\.showSpamTransactions, $showSpam)` modifier next to the existing `showHiddenAccounts` modifier.
- `Features/Transactions/Views/TransactionListView.swift` — add `@AppStorage("showSpamTransactions")`, an `@Environment(\.spamInstruments)`, `.onAppear` / `.onChange` blocks to push both into `transactionStore`, and an iOS-only toolbar `Button` toggling the preference.

**Out of scope (verified):**

- No CloudKit schema change.
- No change to the row-level "⚠️ Spam" indicator in `TransactionRowView+Icon.swift` (still `any leg`, by design — see spec §"Definition").
- No change to `TransactionFilter`, `TransactionRepository`, or any database code.

---

## Task 1 — Add `Transaction.isAllSpam(in:)` predicate

**Files:**

- Create: `MoolahTests/Domain/TransactionIsAllSpamTests.swift`
- Modify: `Domain/Models/Transaction.swift`

### Steps

- [ ] **Step 1: Write the failing test file.**

Create `MoolahTests/Domain/TransactionIsAllSpamTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.isAllSpam(in:)")
struct TransactionIsAllSpamTests {
  let aud = Instrument.AUD
  let usd = Instrument.fiat(code: "USD")
  let spamA = Instrument.crypto(symbol: "SPAM", chain: "ethereum", address: "0xspamA")
  let spamB = Instrument.crypto(symbol: "SCAM", chain: "ethereum", address: "0xspamB")
  let account = UUID()

  private func leg(_ instrument: Instrument, quantity: Decimal) -> TransactionLeg {
    TransactionLeg(
      accountId: account, instrument: instrument, quantity: quantity, type: .trade)
  }

  private func transaction(legs: [TransactionLeg]) -> Transaction {
    Transaction(date: Date(timeIntervalSince1970: 0), legs: legs)
  }

  @Test
  func singleSpamLegIsAllSpam() {
    let tx = transaction(legs: [leg(spamA, quantity: 100)])
    #expect(tx.isAllSpam(in: [spamA]))
  }

  @Test
  func multipleSpamLegsAllInSetIsAllSpam() {
    let tx = transaction(legs: [leg(spamA, quantity: -50), leg(spamB, quantity: 50)])
    #expect(tx.isAllSpam(in: [spamA, spamB]))
  }

  @Test
  func mixedSpamAndNonSpamIsNotAllSpam() {
    let tx = transaction(legs: [leg(spamA, quantity: -50), leg(usd, quantity: 100)])
    #expect(!tx.isAllSpam(in: [spamA]))
  }

  @Test
  func nonSpamOnlyIsNotAllSpam() {
    let tx = transaction(legs: [leg(usd, quantity: 100)])
    #expect(!tx.isAllSpam(in: [spamA]))
  }

  @Test
  func emptyLegsIsNotAllSpam() {
    let tx = transaction(legs: [])
    #expect(!tx.isAllSpam(in: [spamA]))
  }

  @Test
  func emptySpamSetIsNotAllSpam() {
    let tx = transaction(legs: [leg(spamA, quantity: 100)])
    #expect(!tx.isAllSpam(in: []))
  }

  @Test
  func spamLegOutsideSpamSetIsNotAllSpam() {
    let tx = transaction(legs: [leg(spamA, quantity: 100)])
    #expect(!tx.isAllSpam(in: [spamB]))
  }
}
```

> **Note on `Instrument.crypto(symbol:chain:address:)`:** if the actual initialiser signature in `Domain/Models/Instrument.swift` differs (e.g. uses different parameter names or an enum case), substitute the correct call but keep the test semantics identical. Inspect `Instrument.swift` first; do not invent a constructor.

- [ ] **Step 2: Run the new tests to confirm they fail.**

```bash
just test TransactionIsAllSpamTests 2>&1 | tee .agent-tmp/task1-fail.txt
grep -i 'isAllSpam' .agent-tmp/task1-fail.txt | head
```

Expected: compile error — `value of type 'Transaction' has no member 'isAllSpam'`.

- [ ] **Step 3: Add the extension on `Transaction`.**

Append to `Domain/Models/Transaction.swift`, after the closing brace of the existing `extension Transaction` blocks (so it sits as its own extension per CODE_GUIDE.md §"one extension per purpose"):

```swift
// MARK: - Spam Classification

extension Transaction {
  /// Whether every leg of this transaction references an instrument in
  /// the supplied spam set. Returns `false` for a transaction with zero
  /// legs — defensive, since an empty `allSatisfy` would otherwise
  /// return `true` and quietly hide an unexpected shape.
  ///
  /// This is deliberately *stricter* than the row-level "⚠️ Spam"
  /// indicator (`legs.contains { spamInstruments.contains($0.instrument) }`):
  /// the indicator informs the user that *any* leg touched spam, while
  /// this predicate gates the hide rule that *removes* the transaction
  /// from the list. Mixed-leg transactions affected a real balance and
  /// must remain visible. See
  /// `plans/2026-05-20-hide-spam-transactions-design.md` §"Definition".
  func isAllSpam(in spamInstruments: Set<Instrument>) -> Bool {
    !legs.isEmpty && legs.allSatisfy { spamInstruments.contains($0.instrument) }
  }
}
```

- [ ] **Step 4: Re-run the tests, expect green.**

```bash
just test TransactionIsAllSpamTests 2>&1 | tee .agent-tmp/task1-pass.txt
grep -E 'Test run|passed|failed' .agent-tmp/task1-pass.txt | tail
rm .agent-tmp/task1-*.txt
```

Expected: all seven tests pass.

- [ ] **Step 5: Format-check and build the macOS app.**

```bash
just format
just format-check
just build-mac
```

Expected: format-check exits 0; build-mac succeeds with no warnings.

- [ ] **Step 6: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/hide-spam-transactions add \
  Domain/Models/Transaction.swift \
  MoolahTests/Domain/TransactionIsAllSpamTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/hide-spam-transactions commit -m "feat(domain): Transaction.isAllSpam(in:) predicate

Strict 'every leg is spam' predicate. Distinct from the row-indicator
rule (any leg). Returns false for empty legs (defensive)."
```

---

## Task 2 — Wire spam filter into `TransactionStore`

**Files:**

- Create: `MoolahTests/Features/TransactionStoreSpamFilterTests.swift`
- Modify: `Features/Transactions/TransactionStore.swift`

### Steps

- [ ] **Step 1: Write the failing test file.**

Create `MoolahTests/Features/TransactionStoreSpamFilterTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/SpamFilter")
@MainActor
struct TransactionStoreSpamFilterTests {
  private let accountId = UUID()
  private let spamA = Instrument.crypto(symbol: "SPAM", chain: "ethereum", address: "0xspamA")
  private let spamB = Instrument.crypto(symbol: "SCAM", chain: "ethereum", address: "0xspamB")
  private let usd = Instrument.fiat(code: "USD")

  private func makeStore() throws -> (TestBackend, TransactionStore) {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    return (backend, store)
  }

  private func leg(_ instrument: Instrument, quantity: Decimal) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId, instrument: instrument, quantity: quantity, type: .trade)
  }

  private func makeTransaction(legs: [TransactionLeg]) -> Transaction {
    Transaction(
      date: try! TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "test",
      legs: legs)
  }

  @Test
  func singleLegAllSpamIsHiddenByDefault() async throws {
    let (_, store) = try makeStore()
    store.setSpamInstruments([spamA])

    _ = await store.create(makeTransaction(legs: [leg(spamA, quantity: 100)]))
    try await store.awaitTransactionCount(0)

    #expect(store.transactions.isEmpty)
  }

  @Test
  func multiLegAllSpamIsHiddenByDefault() async throws {
    let (_, store) = try makeStore()
    store.setSpamInstruments([spamA, spamB])

    _ = await store.create(
      makeTransaction(legs: [leg(spamA, quantity: -50), leg(spamB, quantity: 50)]))
    try await store.awaitTransactionCount(0)

    #expect(store.transactions.isEmpty)
  }

  @Test
  func mixedLegTransactionIsAlwaysVisible() async throws {
    let (_, store) = try makeStore()
    store.setSpamInstruments([spamA])

    _ = await store.create(
      makeTransaction(legs: [leg(spamA, quantity: -50), leg(usd, quantity: 100)]))
    try await store.awaitTransactionCount(1)

    #expect(store.transactions.count == 1)
  }

  @Test
  func togglingShowSpamRepublishesHiddenRows() async throws {
    let (_, store) = try makeStore()
    store.setSpamInstruments([spamA])

    _ = await store.create(makeTransaction(legs: [leg(spamA, quantity: 100)]))
    try await store.awaitTransactionCount(0)
    #expect(store.transactions.isEmpty)

    store.showSpam = true
    #expect(store.transactions.count == 1)

    store.showSpam = false
    #expect(store.transactions.isEmpty)
  }

  @Test
  func changingSpamSetReFiltersLive() async throws {
    let (_, store) = try makeStore()
    // Start with empty spam set — transaction is visible.
    _ = await store.create(makeTransaction(legs: [leg(spamA, quantity: 100)]))
    try await store.awaitTransactionCount(1)
    #expect(store.transactions.count == 1)

    // User marks spamA as spam — transaction should disappear.
    store.setSpamInstruments([spamA])
    #expect(store.transactions.isEmpty)
  }

  @Test
  func transactionsWithEmptySpamSetAreAllVisible() async throws {
    let (_, store) = try makeStore()
    // spamInstruments defaults to empty.
    _ = await store.create(makeTransaction(legs: [leg(spamA, quantity: 100)]))
    _ = await store.create(makeTransaction(legs: [leg(usd, quantity: 200)]))
    try await store.awaitTransactionCount(2)

    #expect(store.transactions.count == 2)
  }
}
```

> **Note:** `awaitTransactionCount` is the existing helper at `MoolahTests/Support/TestableStoreObservation.swift`. It already waits for the published `transactions` count to reach the expected value. Since our filter pipeline replaces `transactions` synchronously inside `publishFilteredTransactions()`, the helper will resolve as soon as the relevant snapshot has been applied AND filtered. If the helper signature differs in the local tree, inspect it before invoking and adjust the call site (do **not** redefine the helper).

- [ ] **Step 2: Run the new tests, expect compile or semantic failures.**

```bash
just test TransactionStoreSpamFilterTests 2>&1 | tee .agent-tmp/task2-fail.txt
grep -E 'error:|expected' .agent-tmp/task2-fail.txt | head
```

Expected: errors like `value of type 'TransactionStore' has no member 'setSpamInstruments'` and `… has no member 'showSpam'`.

- [ ] **Step 3: Add the spam-filter machinery to `TransactionStore`.**

In `Features/Transactions/TransactionStore.swift`:

**3a.** Immediately after the existing `private(set) var transactions: [TransactionWithBalance] = []` declaration (currently around line 8), add the backing storage plus new observable properties. The exact patch (replace the single existing `transactions` declaration with the block below):

```swift
  /// View-visible transactions list. Computed by
  /// `publishFilteredTransactions()` from `unfilteredTransactions`,
  /// `showSpam`, and `spamInstruments`. Views observe this property —
  /// writers must always go through `setTransactions(_:)` (data path)
  /// or `publishFilteredTransactions()` (toggle path), never assign
  /// directly. Per `plans/2026-05-20-hide-spam-transactions-design.md`.
  private(set) var transactions: [TransactionWithBalance] = []

  /// Unfiltered backing list. The observation pipeline writes here via
  /// `setTransactions(_:)`; `publishFilteredTransactions()` consumes it
  /// to recompute the spam-filtered `transactions`. Kept around so
  /// flipping `showSpam` or `spamInstruments` can re-publish without
  /// a re-fetch. Views must not read this directly.
  private var unfilteredTransactions: [TransactionWithBalance] = []

  /// Whether all-legs-spam transactions are visible in the published
  /// list. Bound to the `@AppStorage("showSpamTransactions")`
  /// preference by `SidebarView` (macOS) and `TransactionListView`
  /// (iOS). Default `false` (hidden). See
  /// `plans/2026-05-20-hide-spam-transactions-design.md` §"Persistence".
  var showSpam: Bool = false {
    didSet {
      guard oldValue != showSpam else { return }
      publishFilteredTransactions()
    }
  }

  /// Set of instruments currently flagged as spam. Sourced from
  /// `CryptoTokenStore.spamInstruments` via the `\.spamInstruments`
  /// environment value. Drives the all-legs-spam predicate. Written
  /// only by `setSpamInstruments(_:)` so the republish is coupled to
  /// the change.
  private(set) var spamInstruments: Set<Instrument> = []
```

**3b.** Replace the existing `setTransactions(_ rows:)` at line 388 with:

```swift
  func setTransactions(_ rows: [TransactionWithBalance]) {
    unfilteredTransactions = rows
    publishFilteredTransactions()
  }

  /// Updates `spamInstruments` and re-publishes the filtered
  /// `transactions` if the set actually changed. No-ops if the new
  /// value equals the current one (avoids spurious view re-renders).
  func setSpamInstruments(_ value: Set<Instrument>) {
    guard value != spamInstruments else { return }
    spamInstruments = value
    publishFilteredTransactions()
  }

  /// Recomputes `transactions` from `unfilteredTransactions` against
  /// the current `showSpam` / `spamInstruments` inputs. Cheap when
  /// `showSpam == true` or `spamInstruments.isEmpty` (no walk).
  private func publishFilteredTransactions() {
    if showSpam || spamInstruments.isEmpty {
      transactions = unfilteredTransactions
    } else {
      transactions = unfilteredTransactions.filter {
        !$0.transaction.isAllSpam(in: spamInstruments)
      }
    }
  }
```

- [ ] **Step 4: Re-run the new tests, expect green; run the existing transaction-store suite to catch regressions.**

```bash
just test TransactionStoreSpamFilterTests 2>&1 | tee .agent-tmp/task2-spam-pass.txt
just test-mac TransactionStoreCRUDTests TransactionStoreLoadingTests TransactionStoreRunningBalanceTests TransactionStorePayScheduledTests TransactionStoreLoadRaceTests TransactionStoreAccountBalanceTests TransactionStoreCategoryFilterTests TransactionStoreAutocompleteTests TransactionStoreManualMergeTests TransactionStoreTransferTests 2>&1 | tee .agent-tmp/task2-regression.txt
grep -i 'failed\|error:' .agent-tmp/task2-*.txt | head
rm .agent-tmp/task2-*.txt
```

Expected: all six new tests pass; all existing TransactionStore tests still pass.

- [ ] **Step 5: Format-check and build.**

```bash
just format
just format-check
just build-mac
```

Expected: clean.

- [ ] **Step 6: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/hide-spam-transactions add \
  Features/Transactions/TransactionStore.swift \
  MoolahTests/Features/TransactionStoreSpamFilterTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/hide-spam-transactions commit -m "feat(transactions): TransactionStore spam-hiding filter

Adds showSpam + spamInstruments inputs and an unfiltered backing list.
publishFilteredTransactions() drops all-legs-spam rows unless showSpam
or the spam set is empty. Mirrors the accountStore.showHidden pattern."
```

---

## Task 3 — Declare the `ShowSpamTransactions` focused-value key

**Files:**

- Modify: `Shared/FocusedValues.swift`

### Steps

- [ ] **Step 1: Add the key struct + accessor.**

In `Shared/FocusedValues.swift`, immediately after the `ShowHiddenAccountsKey` declaration (line 34) insert:

```swift
/// Binding to the View > Show / Hide Spam Transactions toggle.
struct ShowSpamTransactionsKey: FocusedValueKey {
  typealias Value = Binding<Bool>
}
```

And in the `extension FocusedValues { ... }` block (after the `showHiddenAccounts` accessor at line 165), insert:

```swift
  var showSpamTransactions: ShowSpamTransactionsKey.Value? {
    get { self[ShowSpamTransactionsKey.self] }
    set { self[ShowSpamTransactionsKey.self] = newValue }
  }
```

- [ ] **Step 2: Build to verify the key compiles.**

```bash
just build-mac
```

Expected: no errors.

- [ ] **Step 3: Format-check.**

```bash
just format
just format-check
```

Expected: clean.

- [ ] **Step 4: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/hide-spam-transactions add Shared/FocusedValues.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/hide-spam-transactions commit -m "feat(focused-values): ShowSpamTransactionsKey

Focused-value key for the View > Show/Hide Spam Transactions menu
binding. Mirrors ShowHiddenAccountsKey."
```

---

## Task 4 — Bind the macOS preference from `SidebarView`

**Files:**

- Modify: `Features/Navigation/SidebarView.swift`

### Steps

- [ ] **Step 1: Add `@AppStorage` and `.focusedSceneValue`.**

Right after the existing `@AppStorage("showHiddenAccounts") private var showHidden = false` at line 29, add:

```swift
  @AppStorage("showSpamTransactions") private var showSpam = false
```

In the modifier chain on `body`, immediately after `.focusedSceneValue(\.showHiddenAccounts, $showHidden)` (currently line 57), add:

```swift
    .focusedSceneValue(\.showSpamTransactions, $showSpam)
```

> **Why nothing else:** `SidebarView` does not own `TransactionStore`. The store-sync happens in `TransactionListView` (Task 6) — the `@AppStorage` key is the single source of truth, so both views see the same value automatically via UserDefaults.

- [ ] **Step 2: Build.**

```bash
just build-mac
```

Expected: no errors.

- [ ] **Step 3: Format-check.**

```bash
just format
just format-check
```

Expected: clean.

- [ ] **Step 4: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/hide-spam-transactions add Features/Navigation/SidebarView.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/hide-spam-transactions commit -m "feat(sidebar): publish showSpamTransactions focused value

Reads the @AppStorage('showSpamTransactions') preference and republishes
it via focused scene value so the View menu command can bind to it."
```

---

## Task 5 — Add the macOS View menu command

**Files:**

- Modify: `App/MoolahDomainCommands.swift`
- Modify: `App/MoolahApp.swift`

### Steps

- [ ] **Step 1: Add the command struct.**

In `App/MoolahDomainCommands.swift`, immediately after the closing brace of `struct ShowHiddenCommands: Commands { … }` (around line 77), append:

```swift
/// View menu verb-pair for showing / hiding spam transactions.
/// Mirrors `ShowHiddenCommands` (per UI_GUIDE §14 "Toggle State") —
/// a Button whose label flips between "Show Spam Transactions" and
/// "Hide Spam Transactions" rather than a `Toggle` with a checkmark.
/// Stays visible when no window is focused; disabled per §14
/// "Disable, don't hide".
struct ShowSpamTransactionsCommands: Commands {
  @FocusedValue(\.showSpamTransactions) private var showSpam

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button(
        showSpam?.wrappedValue == true ? "Hide Spam Transactions" : "Show Spam Transactions"
      ) {
        showSpam?.wrappedValue.toggle()
      }
      .disabled(showSpam == nil)
    }
  }
}
```

> **Why `CommandGroup(after: .sidebar)`** — matches `ShowHiddenCommands`. The two will appear next to each other in the View menu in declaration order, which is what we want (Show Hidden Accounts first, Show Spam Transactions second).

- [ ] **Step 2: Register the command in `App/MoolahApp.swift`.**

In `App/MoolahApp.swift`, find both occurrences of `ShowHiddenCommands()` (currently lines 180 and 233) and insert `ShowSpamTransactionsCommands()` on the line immediately after each:

```swift
        ShowHiddenCommands()
        ShowSpamTransactionsCommands()
```

> **Note:** the `.commands { … }` builder has a 10-argument limit per the comment at `MoolahDomainCommands.swift:80`. If adding `ShowSpamTransactionsCommands()` pushes either site over the limit, fold both `ShowHiddenCommands` and `ShowSpamTransactionsCommands` into a single wrapper struct (e.g. `ViewMenuToggleCommands`). Check the count first; the existing layout has room.

- [ ] **Step 3: Build and run the macOS app to verify the menu item appears.**

```bash
just build-mac
just run-mac &
```

Then verify manually in the running app: View menu shows "Show Spam Transactions"; toggling it flips the label to "Hide Spam Transactions". (No persistence/sync check yet — those land in Task 6.) Quit the app after verification.

- [ ] **Step 4: Format-check.**

```bash
just format
just format-check
```

Expected: clean.

- [ ] **Step 5: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/hide-spam-transactions add \
  App/MoolahDomainCommands.swift \
  App/MoolahApp.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/hide-spam-transactions commit -m "feat(commands): View > Show/Hide Spam Transactions menu item

Verb-pair Button per UI_GUIDE §14 'Toggle State'. Bound to the
showSpamTransactions focused value published by SidebarView."
```

---

## Task 6 — Wire `TransactionListView` to push the preference into the store

**Files:**

- Modify: `Features/Transactions/Views/TransactionListView.swift`

### Steps

- [ ] **Step 1: Read the current top-of-view declarations.**

`Features/Transactions/Views/TransactionListView.swift` lines 1–60 hold the imports and the view's stored properties. Locate the existing `@State` block and the `body` opening.

- [ ] **Step 2: Add the storage and environment reads.**

In the property block of `TransactionListView`, add:

```swift
  @AppStorage("showSpamTransactions") private var showSpamTransactions = false
  @Environment(\.spamInstruments) private var spamInstruments
```

- [ ] **Step 3: Add the sync modifiers.**

Inside the view's modifier chain (just before the existing `.searchable` modifier is fine — any location after the list/scroll content works), add:

```swift
    .onAppear {
      transactionStore.showSpam = showSpamTransactions
      transactionStore.setSpamInstruments(spamInstruments)
    }
    .onChange(of: showSpamTransactions) { _, newValue in
      transactionStore.showSpam = newValue
    }
    .onChange(of: spamInstruments) { _, newValue in
      transactionStore.setSpamInstruments(newValue)
    }
```

> **Sequencing:** the order `showSpam` then `setSpamInstruments` in `onAppear` is deliberate — when both change in one render cycle, we'd rather show the (possibly stale) hide-all-spam set briefly than the inverted "all visible" set briefly. Either order is correct; this one matches the user expectation that "default state on launch is hidden".

- [ ] **Step 4: Add the iOS toolbar item.**

Inside the existing `.toolbar { … }` modifier (the project already has one in `TransactionListView+List.swift` based on the search above; if there is no `#if os(iOS)` branch yet, wrap the new item appropriately). Add:

```swift
    #if os(iOS)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showSpamTransactions.toggle()
          } label: {
            Image(systemName: showSpamTransactions ? "eye" : "eye.slash")
              .accessibilityLabel(
                showSpamTransactions ? "Hide Spam Transactions" : "Show Spam Transactions")
          }
          .help(showSpamTransactions ? "Hide Spam Transactions" : "Show Spam Transactions")
        }
      }
    #endif
```

> **If `TransactionListView` already has multiple `.toolbar` invocations on different platforms,** add this one alongside the existing iOS branch instead of introducing a duplicate `.toolbar` modifier — SwiftUI merges multiple `.toolbar` calls but a single iOS-scoped block is cleaner.

- [ ] **Step 5: Build for both platforms.**

```bash
just build-mac
just build-ios
```

Expected: clean for both.

- [ ] **Step 6: Run the macOS app and verify end-to-end.**

```bash
just run-mac &
```

Manual check:

1. Open the All Transactions list. Spam-token transactions (if any seeded in your active profile) should not appear.
2. View menu → "Show Spam Transactions". Spam transactions appear; the menu label flips to "Hide Spam Transactions".
3. Toggle again. Spam disappears.
4. Quit and relaunch. The preference state survives (UserDefaults).
5. Mark a new token as spam in Settings → Spam Tokens. With the preference off (default), any transaction whose every leg is in the spam set should immediately disappear from the open list.

Quit the app after verification.

- [ ] **Step 7: Format-check.**

```bash
just format
just format-check
```

Expected: clean.

- [ ] **Step 8: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/hide-spam-transactions add \
  Features/Transactions/Views/TransactionListView.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/hide-spam-transactions commit -m "feat(transactions): hide spam transactions in the list

Pushes the @AppStorage('showSpamTransactions') preference and the
\\.spamInstruments environment value into TransactionStore on appear
and on change. iOS gets a toolbar eye/eye.slash toggle with a flipped
accessibility label; macOS is driven from the View menu (Task 5)."
```

---

## Task 7 — Final regression sweep

**Files:** none modified.

### Steps

- [ ] **Step 1: Run the full mac test suite and capture output.**

```bash
mkdir -p .agent-tmp
just test-mac 2>&1 | tee .agent-tmp/full-mac.txt
grep -i 'failed\|error:' .agent-tmp/full-mac.txt | head
```

Expected: no failures.

- [ ] **Step 2: Run the iOS test suite and capture output.**

```bash
just test-ios 2>&1 | tee .agent-tmp/full-ios.txt
grep -i 'failed\|error:' .agent-tmp/full-ios.txt | head
```

Expected: no failures.

> **If the iOS simulator host wedges** (per memory `reference_macos_test_runner_hang.md`), `pkill` stale `Moolah` / `xctest` processes (including from other worktrees and Xcode) before retrying.

- [ ] **Step 3: One last format-check + macOS build, to be absolutely sure the merged branch state is clean.**

```bash
just format-check
just build-mac
```

- [ ] **Step 4: Clean up temp output.**

```bash
rm -f .agent-tmp/full-mac.txt .agent-tmp/full-ios.txt
```

- [ ] **Step 5: No new commit — Task 7 is a verify pass only.**

---

## Spec Coverage Check (self-review)

| Spec Section | Implemented In |
|---|---|
| Definition: all-legs-spam predicate | Task 1 |
| macOS View menu item, flipped label | Task 5 (command) + Task 4 (binding) |
| iOS toolbar item with eye/eye.slash + a11y | Task 6 |
| `@AppStorage("showSpamTransactions")` persistence | Task 4 (sidebar) + Task 6 (list view) |
| Filter runs in `TransactionStore` | Task 2 |
| `spamInstruments` change re-filters live | Task 2 (test #5), Task 6 (`.onChange`) |
| Applies to account-detail + search results | Task 2 (filter at store; all consumers see the filtered list) |
| Account balances / totals unaffected | Out of scope, no code path changed |
| Row-level "⚠️ Spam" indicator unchanged | Verified: `TransactionRowView+Icon.swift` untouched |
| Six store-level tests | Task 2 |
| Optional UI test | Not in scope; deferred until host stability per `feedback_pr_ci_gate_when_ui_host_blocked.md` |
| Open question: `isAllSpam(in:)` on Transaction extension vs free helper | Resolved: extension on Transaction (Task 1) |
| Open question: keyboard shortcut | Resolved: no shortcut this iteration (spec) |

## Placeholder & Consistency Scan

- No TBDs, no TODOs left in plan text.
- Property names used consistently: `showSpam`, `spamInstruments`, `setSpamInstruments(_:)`, `unfilteredTransactions`, `publishFilteredTransactions`, `isAllSpam(in:)`.
- The `@AppStorage` key is `"showSpamTransactions"` everywhere (SidebarView, TransactionListView, focused-value docs). Not `showSpam`, not `hideSpamTransactions`.
- macOS menu label text is exactly `"Show Spam Transactions"` / `"Hide Spam Transactions"`; iOS a11y label matches.
