# Group transaction filter — multi-account scope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Applying a filter while viewing an account group must keep the list scoped to the group's accounts, and the filter dialog's account control must support multiple accounts scoped to the current view.

**Architecture:** The `TransactionFilter` model already carries `accountIds: Set<UUID>` and the GRDB fetch layer already honours it — the bug is that `TransactionFilterView.applyFilter()` drops the field. We introduce a pure resolution helper that maps a scope-aware picker selection back into `accountIds` (empty selection = "all in scope", never widening past the group), a reusable `AccountMultiSelectPicker` mirroring the existing `CategoryMultiSelectPicker`, and wire both into the dialog with the scope universe passed down from `TransactionListView`.

**Tech Stack:** Swift, SwiftUI, Swift Testing (`@Suite`/`@Test`), GRDB, XCUITest (macOS).

## Global Constraints

- **Thin views:** business/scope logic lives in pure, testable helpers, not inside SwiftUI view bodies (`guides/AI_ARCHITECTURE_GUIDE.md`).
- **Money/instrument rules:** unchanged — this work touches only account-id set logic, no `InstrumentAmount` arithmetic.
- **Picker convention (matches `CategoryMultiSelectPicker`):** a multi-select bound to `Set<UUID>` uses **empty = all available**.
- **macOS popover propagation:** inside a macOS popover, mutate a `@Binding var selectedIds: Set<UUID>` by **whole-value reassignment** (read-modify-write a local `var`), never `insert`/`remove` on the binding projection — the mutating form does not propagate (issue #781).
- **Test commands:** unit — `just test-mac <ClassName>` or `<ClassName>/<method>`; UI — `just test-ui <ClassName>`.
- **Review gate:** run the relevant AI reviewers (`@code-review`, `@ui-review`, `@ui-test-review`) before committing and fix every finding (`guides/AI_REVIEW_GATE_GUIDE.md`).
- **Format:** run `just format-check` after each task; it must pass before commit.

## File Structure

- `Domain/Models/TransactionFilter.swift` — add `static func resolveScopedAccountIds(...)`.
- `MoolahTests/Domain/TransactionFilterTests.swift` — add resolution tests to the existing suite.
- `Features/Transactions/Views/AccountMultiSelectPicker.swift` — **new** view + `static func selectionSummary(...)`.
- `MoolahTests/Features/AccountMultiSelectPickerSummaryTests.swift` — **new** summary tests.
- `Features/Transactions/Views/TransactionFilterView.swift` — scope-aware account section, seed from `accountIds`, fixed `applyFilter()`.
- `Features/Transactions/Views/TransactionListView+List.swift` — derive and pass `scopeAccountIds` from `baseFilter`.
- `UITestSupport/UITestIdentifiers.swift` — add filter-dialog identifiers.
- `UITestSupport/UITestFixtures.swift` — **new** seed family: a group with two members (each with a transaction) plus a non-member account with a transaction, all in one date window.
- `MoolahUITests_macOS/Tests/Transactions/GroupTransactionFilterScopeMacTests.swift` — **new** end-to-end test.

---

### Task 1: Pure scope-resolution helper

The single source of truth for "what `accountIds` do we store, given the picker selection, the view's scope, and the accounts offered." Empty selection (or all-available selected) resolves to the scope so a group filter can never widen to all accounts; a strict subset narrows.

**Files:**
- Modify: `Domain/Models/TransactionFilter.swift` (append an extension method)
- Test: `MoolahTests/Domain/TransactionFilterTests.swift`

**Interfaces:**
- Produces: `static func TransactionFilter.resolveScopedAccountIds(selection: Set<UUID>, scope: Set<UUID>, available: Set<UUID>) -> Set<UUID>`
  - `selection`: the picker's selected ids (empty = "all available", picker convention).
  - `scope`: the navigation scope's account ids (empty = global / all accounts).
  - `available`: the ids actually offered in the picker.

- [ ] **Step 1: Write the failing tests**

Append to `MoolahTests/Domain/TransactionFilterTests.swift`, inside the `TransactionFilterTests` struct:

```swift
  // MARK: - resolveScopedAccountIds

  @Test("Empty selection in a group resolves to the whole group scope")
  func testEmptySelectionResolvesToScope() {
    let a = UUID(), b = UUID(), c = UUID()
    let scope: Set<UUID> = [a, b, c]
    let resolved = TransactionFilter.resolveScopedAccountIds(
      selection: [], scope: scope, available: scope)
    #expect(resolved == scope)
  }

  @Test("Selecting every available account resolves to the scope (treated as all)")
  func testAllSelectedResolvesToScope() {
    let a = UUID(), b = UUID(), c = UUID()
    let scope: Set<UUID> = [a, b, c]
    let resolved = TransactionFilter.resolveScopedAccountIds(
      selection: [a, b, c], scope: scope, available: scope)
    #expect(resolved == scope)
  }

  @Test("A strict subset narrows to that subset")
  func testSubsetSelectionNarrows() {
    let a = UUID(), b = UUID(), c = UUID()
    let scope: Set<UUID> = [a, b, c]
    let resolved = TransactionFilter.resolveScopedAccountIds(
      selection: [a], scope: scope, available: scope)
    #expect(resolved == [a])
  }

  @Test("Empty selection in the global list stays empty (all accounts)")
  func testEmptySelectionGlobalStaysEmpty() {
    let a = UUID(), b = UUID()
    let resolved = TransactionFilter.resolveScopedAccountIds(
      selection: [], scope: [], available: [a, b])
    #expect(resolved.isEmpty)
  }

  @Test("A subset in the global list narrows to that subset")
  func testSubsetSelectionGlobalNarrows() {
    let a = UUID(), b = UUID()
    let resolved = TransactionFilter.resolveScopedAccountIds(
      selection: [a], scope: [], available: [a, b])
    #expect(resolved == [a])
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-mac TransactionFilterTests`
Expected: FAIL — `type 'TransactionFilter' has no member 'resolveScopedAccountIds'`.

- [ ] **Step 3: Implement the helper**

Append to `Domain/Models/TransactionFilter.swift` (new extension at end of file):

```swift
extension TransactionFilter {
  /// Resolves a scope-aware account-picker selection into the `accountIds`
  /// set to store on the filter.
  ///
  /// `selection` follows the multi-select convention where an empty set
  /// means "all available". Both an empty selection and a selection that
  /// covers every available account resolve to `scope` — so applying a
  /// filter inside an account group can never widen the result past the
  /// group's members. A global view (empty `scope`) resolves the same
  /// "all" cases back to an empty set, i.e. all accounts. A strict subset
  /// is stored verbatim.
  static func resolveScopedAccountIds(
    selection: Set<UUID>,
    scope: Set<UUID>,
    available: Set<UUID>
  ) -> Set<UUID> {
    if selection.isEmpty || selection == available {
      return scope
    }
    return selection
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `just test-mac TransactionFilterTests`
Expected: PASS (all cases).

- [ ] **Step 5: Format, review, commit**

Run: `just format-check` (must pass). Then run `@code-review` on the changed files and fix findings.

```bash
git -C . add Domain/Models/TransactionFilter.swift MoolahTests/Domain/TransactionFilterTests.swift
git -C . commit -m "feat(transactions): scope-aware account-id resolution helper"
```

---

### Task 2: `AccountMultiSelectPicker` view + selection summary

A searchable, checkbox multi-select over a supplied list of accounts, mirroring `CategoryMultiSelectPicker` (including the #781 whole-value-reassignment pattern). Ships with a pure `selectionSummary` used both for the trigger label and in tests.

**Files:**
- Create: `Features/Transactions/Views/AccountMultiSelectPicker.swift`
- Test: `MoolahTests/Features/AccountMultiSelectPickerSummaryTests.swift`

**Interfaces:**
- Consumes: `Account` (`.id`, `.name`), from `Domain/Models/Account.swift`.
- Produces:
  - `struct AccountMultiSelectPicker: View` with `let accounts: [Account]` and `@Binding var selectedIds: Set<UUID>`.
  - `static func AccountMultiSelectPicker.selectionSummary(for selectedIds: Set<UUID>, available: [Account]) -> String` → `"All accounts"` (empty), the account name (one), `"N accounts"` (many).

- [ ] **Step 1: Write the failing summary tests**

Create `MoolahTests/Features/AccountMultiSelectPickerSummaryTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountMultiSelectPicker selection summary")
struct AccountMultiSelectPickerSummaryTests {
  private func account(_ name: String, _ id: UUID) -> Account {
    Account(
      id: id, name: name, type: .bank, instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 0)])
  }

  @Test("Empty selection reads All accounts")
  func testEmptyIsAllAccounts() {
    let a = account("Checking", UUID())
    #expect(
      AccountMultiSelectPicker.selectionSummary(for: [], available: [a])
        == "All accounts")
  }

  @Test("Single selection reads the account name")
  func testSingleIsName() {
    let id = UUID()
    let a = account("Checking", id)
    let b = account("Savings", UUID())
    #expect(
      AccountMultiSelectPicker.selectionSummary(for: [id], available: [a, b])
        == "Checking")
  }

  @Test("Multiple selection reads N accounts")
  func testManyIsCount() {
    let idA = UUID(), idB = UUID()
    let a = account("Checking", idA)
    let b = account("Savings", idB)
    #expect(
      AccountMultiSelectPicker.selectionSummary(for: [idA, idB], available: [a, b])
        == "2 accounts")
  }

  @Test("Selection counts only ids present in the available list")
  func testCountsOnlyPresent() {
    let idA = UUID()
    let a = account("Checking", idA)
    #expect(
      AccountMultiSelectPicker.selectionSummary(
        for: [idA, UUID()], available: [a]) == "Checking")
  }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `just test-mac AccountMultiSelectPickerSummaryTests`
Expected: FAIL — `cannot find 'AccountMultiSelectPicker' in scope`.

- [ ] **Step 3: Implement the view**

Create `Features/Transactions/Views/AccountMultiSelectPicker.swift`:

```swift
import SwiftUI

/// Searchable multi-select picker over a supplied list of accounts.
/// Empty selection means "all available" — the same convention as
/// `CategoryMultiSelectPicker`, which this view mirrors structurally.
struct AccountMultiSelectPicker: View {
  let accounts: [Account]
  @Binding var selectedIds: Set<UUID>

  @State private var searchText: String = ""

  /// `"All accounts"` when nothing is selected, the account's name when
  /// exactly one of the available accounts is selected, otherwise
  /// `"N accounts"`. Only ids present in `available` are counted.
  static func selectionSummary(
    for selectedIds: Set<UUID>, available: [Account]
  ) -> String {
    let present = available.filter { selectedIds.contains($0.id) }
    switch present.count {
    case 0: return "All accounts"
    case 1: return present[0].name
    default: return "\(present.count) accounts"
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      list
    }
    .searchable(text: $searchText, prompt: "Search accounts")
    #if os(iOS)
      .navigationTitle("Accounts")
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  // Inline header (not `.toolbar`): SwiftUI toolbar items don't render
  // inside a macOS popover, so a toolbar Clear would be invisible there.
  private var header: some View {
    HStack {
      #if os(macOS)
        Text("Accounts")
          .font(.headline)
      #endif
      Spacer()
      // Whole-value reassignment (see #781 note in CategoryMultiSelectPicker).
      Button("Clear") { selectedIds = [] }
        .disabled(selectedIds.isEmpty)
        .help("Clear all selected accounts")
        .accessibilityLabel("Clear selected accounts")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var visibleAccounts: [Account] {
    guard !searchText.isEmpty else { return accounts }
    return accounts.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
    }
  }

  private var list: some View {
    List {
      if accounts.isEmpty {
        ContentUnavailableView("No Accounts", systemImage: "building.columns")
      } else if visibleAccounts.isEmpty {
        ContentUnavailableView.search(text: searchText)
      } else {
        ForEach(visibleAccounts) { account in
          row(for: account)
        }
      }
    }
    .listStyle(.plain)
  }

  private func row(for account: Account) -> some View {
    Toggle(
      isOn: Binding(
        get: { selectedIds.contains(account.id) },
        set: { isOn in
          // Whole-value reassignment — mutating the binding projection
          // via insert/remove does not propagate inside a macOS popover
          // (issue #781). Mirrors CategoryMultiSelectPicker.
          var updated = selectedIds
          if isOn {
            updated.insert(account.id)
          } else {
            updated.remove(account.id)
          }
          selectedIds = updated
        }
      )
    ) {
      Text(account.name)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(.rect)
    .accessibilityLabel(account.name)
    .accessibilityIdentifier(
      UITestIdentifiers.TransactionFilter.account(account.id))
  }
}

#Preview {
  @Previewable @State var selected: Set<UUID> = []

  let accounts = [
    Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 100)]),
    Account(
      id: UUID(), name: "Savings", type: .bank, instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 200)]),
  ]

  return AccountMultiSelectPicker(accounts: accounts, selectedIds: $selected)
    .frame(width: 320, height: 420)
}
```

> The row references `UITestIdentifiers.TransactionFilter.account(_:)`, which is added in Task 4. If executing tasks out of order and it doesn't yet exist, add the identifier block from Task 4 Step 1 first (it is self-contained).

- [ ] **Step 4: Run to verify the summary tests pass**

Run: `just test-mac AccountMultiSelectPickerSummaryTests`
Expected: PASS.

- [ ] **Step 5: Format, review, commit**

Run: `just format-check`. Then `@ui-review` on `AccountMultiSelectPicker.swift`; fix findings.

```bash
git -C . add Features/Transactions/Views/AccountMultiSelectPicker.swift MoolahTests/Features/AccountMultiSelectPickerSummaryTests.swift
git -C . commit -m "feat(transactions): reusable AccountMultiSelectPicker"
```

---

### Task 4: Filter-dialog UI-test identifiers

Adds the accessibility identifiers Task 2's picker rows and Task 5's driver reference. Small and self-contained, so it lands before the view wiring that consumes it.

**Files:**
- Modify: `UITestSupport/UITestIdentifiers.swift`

**Interfaces:**
- Produces: `UITestIdentifiers.TransactionFilter` with `accountPicker: String`, `dateToggle: String`, `apply: String`, and `account(_ id: UUID) -> String`.

- [ ] **Step 1: Add the identifiers**

Add a nested enum alongside the existing `TransactionList` enum in `UITestSupport/UITestIdentifiers.swift` (match the file's existing `public enum` style and access level):

```swift
  /// Identifiers for the transaction filter sheet (`TransactionFilterView`).
  public enum TransactionFilter {
    /// The account multi-select trigger (macOS popover / iOS NavigationLink).
    public static let accountPicker = "transactionFilter.accountPicker"
    /// The "Filter by Date" toggle.
    public static let dateToggle = "transactionFilter.dateToggle"
    /// The Apply button in the sheet toolbar.
    public static let apply = "transactionFilter.apply"

    /// A single account row inside the account multi-select.
    public static func account(_ id: UUID) -> String {
      "transactionFilter.account.\(id.uuidString)"
    }
  }
```

- [ ] **Step 2: Verify it compiles**

Run: `just build-mac`
Expected: build succeeds.

- [ ] **Step 3: Format, commit**

Run: `just format-check`.

```bash
git -C . add UITestSupport/UITestIdentifiers.swift
git -C . commit -m "test(transactions): identifiers for the filter dialog"
```

---

### Task 3: Wire the scope-aware account section into `TransactionFilterView` and pass scope from the list

Replaces the single-account `Picker` with the multi-select (shown only when more than one account is in scope), seeds it from the incoming filter, fixes `applyFilter()` to preserve scope via the Task 1 helper, and threads `scopeAccountIds` down from `TransactionListView`.

**Files:**
- Modify: `Features/Transactions/Views/TransactionFilterView.swift`
- Modify: `Features/Transactions/Views/TransactionListView+List.swift`

**Interfaces:**
- Consumes: `TransactionFilter.resolveScopedAccountIds(...)` (Task 1), `AccountMultiSelectPicker` + `.selectionSummary(...)` (Task 2), `UITestIdentifiers.TransactionFilter.*` (Task 4).
- Produces: `TransactionFilterView.init(filter:scopeAccountIds:accounts:categories:earmarks:onApply:)` — new required `scopeAccountIds: Set<UUID>` parameter, placed immediately after `filter`.

- [ ] **Step 1: Add the `scopeAccountIds` property, replace account state, seed from `accountIds`**

In `TransactionFilterView.swift`:

Add the stored property after `let filter: TransactionFilter` (line 4):

```swift
  let filter: TransactionFilter
  /// The navigation scope's account universe. Empty means the global
  /// transaction list (all accounts selectable). Non-empty (an account
  /// group, or a single account) constrains the account picker to those
  /// ids and is the fallback applied when the selection means "all".
  let scopeAccountIds: Set<UUID>
```

Replace the account state (line 10):

```swift
  @State private var selectedAccountIds: Set<UUID> = []
  @State private var showAccountPicker = false
```

Update the `init` signature and body — add the parameter and replace the `selectedAccountId` seeding:

```swift
  init(
    filter: TransactionFilter,
    scopeAccountIds: Set<UUID>,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    onApply: @escaping (TransactionFilter) -> Void
  ) {
    self.filter = filter
    self.scopeAccountIds = scopeAccountIds
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.onApply = onApply

    // Seed the picker from the incoming filter. When the filter's account
    // set equals the whole scope (the default group filter), seed empty so
    // the picker reads "All accounts"; a strict subset seeds that subset.
    let incoming = filter.accountIds
    _selectedAccountIds = State(
      initialValue: incoming == scopeAccountIds ? [] : incoming)
    _selectedEarmarkId = State(initialValue: filter.earmarkId)
    _selectedScheduled = State(initialValue: filter.scheduled)
    _dateRangeLowerBound = State(initialValue: filter.dateRange?.lowerBound)
    _dateRangeUpperBound = State(initialValue: filter.dateRange?.upperBound)
    _selectedCategoryIds = State(initialValue: filter.categoryIds)
    _payeeText = State(initialValue: filter.payee ?? "")
  }
```

- [ ] **Step 2: Add the available-accounts computed properties**

Add near the other computed vars in `TransactionFilterView.swift`:

```swift
  /// Accounts offered in the picker: the scope's members, or every account
  /// when the scope is global (empty).
  private var availableAccounts: [Account] {
    guard !scopeAccountIds.isEmpty else { return accounts.ordered }
    return accounts.ordered.filter { scopeAccountIds.contains($0.id) }
  }

  private var availableAccountIds: Set<UUID> {
    Set(availableAccounts.map(\.id))
  }
```

- [ ] **Step 3: Replace `scopeSection` with the scope-aware account row**

Replace `scopeSection` (lines 87-102) with:

```swift
  private var scopeSection: some View {
    Section("Scope") {
      // A single-account view has nothing to narrow, so the account
      // control only appears when more than one account is in scope.
      if availableAccounts.count > 1 {
        accountPickerRow
      }
      Picker("Earmark", selection: $selectedEarmarkId) {
        Text("All Earmarks").tag(nil as UUID?)
        ForEach(earmarks.ordered) { earmark in
          Text(earmark.name).tag(earmark.id as UUID?)
        }
      }
    }
  }

  @ViewBuilder private var accountPickerRow: some View {
    let summary = AccountMultiSelectPicker.selectionSummary(
      for: selectedAccountIds, available: availableAccounts)
    #if os(macOS)
      LabeledContent("Accounts") {
        Button {
          showAccountPicker = true
        } label: {
          HStack(spacing: 6) {
            Text(summary)
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Accounts")
        .accessibilityValue(summary)
        .accessibilityHint("Opens the account picker")
        .accessibilityIdentifier(UITestIdentifiers.TransactionFilter.accountPicker)
        .popover(isPresented: $showAccountPicker, arrowEdge: .trailing) {
          AccountMultiSelectPicker(
            accounts: availableAccounts,
            selectedIds: $selectedAccountIds
          )
          .frame(width: 320, height: 420)
        }
      }
    #else
      NavigationLink {
        AccountMultiSelectPicker(
          accounts: availableAccounts,
          selectedIds: $selectedAccountIds
        )
      } label: {
        LabeledContent("Accounts", value: summary)
      }
      .accessibilityIdentifier(UITestIdentifiers.TransactionFilter.accountPicker)
    #endif
  }
```

- [ ] **Step 4: Fix `applyFilter()`, `hasAnySelection`, `clearAll`**

Replace `hasAnySelection` (lines 77-85) — swap the `selectedAccountId` term:

```swift
  private var hasAnySelection: Bool {
    !selectedAccountIds.isEmpty
      || selectedEarmarkId != nil
      || selectedScheduled != .all
      || dateRangeLowerBound != nil
      || dateRangeUpperBound != nil
      || !selectedCategoryIds.isEmpty
      || !payeeText.isEmpty
  }
```

Replace `applyFilter()` (lines 214-230):

```swift
  private func applyFilter() {
    var dateRange: ClosedRange<Date>?
    if let lower = dateRangeLowerBound, let upper = dateRangeUpperBound {
      dateRange = lower...upper
    }

    let resolvedAccountIds = TransactionFilter.resolveScopedAccountIds(
      selection: selectedAccountIds,
      scope: scopeAccountIds,
      available: availableAccountIds)

    let newFilter = TransactionFilter(
      accountId: filter.accountId,
      accountIds: resolvedAccountIds,
      earmarkId: selectedEarmarkId,
      scheduled: selectedScheduled,
      dateRange: dateRange,
      categoryIds: selectedCategoryIds,
      payee: payeeText.isEmpty ? nil : payeeText
    )

    onApply(newFilter)
  }
```

Replace the account line in `clearAll()` (line 233) — clearing means "all in scope", which the empty set represents:

```swift
  private func clearAll() {
    selectedAccountIds = []
    selectedEarmarkId = nil
    selectedScheduled = .all
    dateRangeLowerBound = nil
    dateRangeUpperBound = nil
    selectedCategoryIds = []
    payeeText = ""
  }
```

- [ ] **Step 5: Tag the date toggle and Apply button; update the `#Preview`**

In `dateRangeSection`, add the identifier to the toggle (line 170):

```swift
      Toggle("Filter by Date", isOn: dateRangeEnabledBinding)
        .accessibilityIdentifier(UITestIdentifiers.TransactionFilter.dateToggle)
```

In `form`'s toolbar, tag the Apply button (line 68):

```swift
      ToolbarItem(placement: .confirmationAction) {
        Button("Apply") { applyFilter() }
          .accessibilityIdentifier(UITestIdentifiers.TransactionFilter.apply)
      }
```

Update the `#Preview` call (line 269) to pass the new parameter:

```swift
  TransactionFilterView(
    filter: TransactionFilter(),
    scopeAccountIds: [],
    accounts: accounts,
    categories: categories,
    earmarks: earmarks,
    onApply: { _ in }
  )
```

- [ ] **Step 6: Thread `scopeAccountIds` from the list**

In `TransactionListView+List.swift`, add a computed property (near the top of the extension, e.g. after `listSelectionBinding`):

```swift
  /// The account universe offered to the filter dialog, derived from the
  /// immutable navigation context (`baseFilter`) — not `activeFilter` — so
  /// the group's full member set stays available even after the user
  /// narrows the selection. Empty for the global transaction list.
  private var filterScopeAccountIds: Set<UUID> {
    var scope = baseFilter.accountIds
    if let id = baseFilter.accountId { scope.insert(id) }
    return scope
  }
```

Update the sheet's `TransactionFilterView(...)` call (lines 56-65) to pass it:

```swift
      TransactionFilterView(
        filter: activeFilter,
        scopeAccountIds: filterScopeAccountIds,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        onApply: { newFilter in
          activeFilter = newFilter
          showFilterSheet = false
        }
      )
```

- [ ] **Step 7: Build and run the unit suites**

Run: `just test-mac TransactionFilterTests` then `just test-mac TxnRepoAccountIdsFilterTests`
Expected: both PASS (existing fetch-union coverage still green; helper still green).

Run: `just build-mac`
Expected: build succeeds (confirms both call sites updated, no stray `selectedAccountId` references).

- [ ] **Step 8: Format, review, commit**

Run: `just format-check`. Then run `@code-review` and `@ui-review` on both changed files; fix every finding.

```bash
git -C . add Features/Transactions/Views/TransactionFilterView.swift Features/Transactions/Views/TransactionListView+List.swift
git -C . commit -m "fix(transactions): keep group scope when filtering; multi-account picker"
```

---

### Task 5: End-to-end UI test — group scope survives filtering

Proves the reported bug is fixed: open an account group, apply a filter, and the list stays scoped to the group's accounts (never shows the non-member account). Also exercises narrowing to one member.

**REQUIRED SUB-SKILL:** Use `writing-ui-tests` for the exact seed-hydrator, sidebar-navigation, and screen-driver conventions — this task states the scenario, fixtures, and assertions; the skill governs driver mechanics (trace logging, post-condition waits, single resolver, no element caching).

**Files:**
- Modify: `UITestSupport/UITestFixtures.swift` — add a `GroupFilterScope` fixture family.
- Modify: the seed hydrator that materialises fixtures into a profile (the file `UITestSeedHydrator` writes seeds from — locate via the `writing-ui-tests` skill) — register the new group, its two members, the non-member account, and one transaction per account.
- Create: `MoolahUITests_macOS/Tests/Transactions/GroupTransactionFilterScopeMacTests.swift`

**Interfaces:**
- Consumes: `UITestIdentifiers.TransactionFilter.*` (Task 4), `UITestIdentifiers.TransactionList.transaction(_:)` (existing), the sidebar/group navigation driver and transaction-list screen driver (per `writing-ui-tests`).

- [ ] **Step 1: Add the fixture family**

Add to `UITestSupport/UITestFixtures.swift` a new `public enum GroupFilterScope` under `UITestFixtures`, with fixed UUID literals (follow the file's `uuidLiteral(...)` pattern and the `A1000000-...` numbering style):

- a group `filterGroup` ("Filter Group") with two members;
- two member accounts `memberOne` ("Member One"), `memberTwo` ("Member Two");
- one non-member account `outsider` ("Outsider");
- one dated expense transaction in each of the three accounts, all inside a single month window (so a "last month"-style date filter matches all three if scope is lost, but only the two members if scope is preserved).

Include a comment block documenting the scenario (matching the existing `TradeBaseline` doc style).

- [ ] **Step 2: Register the fixtures in the seed hydrator**

Wire the new accounts, the group and its membership, and the three transactions into the seed the hydrator produces. Add a launch seed selector for this scenario if the harness keys scenarios by name (follow `writing-ui-tests`).

- [ ] **Step 3: Write the test**

Create `MoolahUITests_macOS/Tests/Transactions/GroupTransactionFilterScopeMacTests.swift`. Structure (fill in driver calls per `writing-ui-tests`):

```swift
import XCTest

/// Regression coverage for the group-filter scope bug: applying any filter
/// while viewing an account group must keep the list scoped to the group's
/// members and never surface a non-member account's transactions.
@MainActor
final class GroupTransactionFilterScopeMacTests: MoolahUITestCase {

  func testApplyingDateFilterKeepsGroupScope() throws {
    // Launch into the GroupFilterScope seed and open the group's detail.
    // (seed launch + sidebar → group navigation via the writing-ui-tests drivers)

    let list = app.transactionList  // or the group detail's list driver

    // Both members visible, outsider absent, before filtering.
    list.expectTransactionVisible(UITestFixtures.GroupFilterScope.memberOneTxnId)
    list.expectTransactionVisible(UITestFixtures.GroupFilterScope.memberTwoTxnId)
    list.expectTransactionAbsent(UITestFixtures.GroupFilterScope.outsiderTxnId)

    // Open the filter sheet, enable the date range (covers all three txns),
    // and apply.
    let filter = list.openFilter()
    filter.toggleDateFilter(on: true)
    filter.apply()

    // Scope preserved: still exactly the two members, outsider still absent.
    list.expectTransactionVisible(UITestFixtures.GroupFilterScope.memberOneTxnId)
    list.expectTransactionVisible(UITestFixtures.GroupFilterScope.memberTwoTxnId)
    list.expectTransactionAbsent(UITestFixtures.GroupFilterScope.outsiderTxnId)
  }

  func testNarrowingToOneMemberShowsOnlyThatMember() throws {
    // Launch + open group detail as above.
    let list = app.transactionList
    let filter = list.openFilter()

    // Narrow to Member One via the account multi-select, then apply.
    filter.selectAccount(UITestFixtures.GroupFilterScope.memberOneId)
    filter.apply()

    list.expectTransactionVisible(UITestFixtures.GroupFilterScope.memberOneTxnId)
    list.expectTransactionAbsent(UITestFixtures.GroupFilterScope.memberTwoTxnId)
    list.expectTransactionAbsent(UITestFixtures.GroupFilterScope.outsiderTxnId)
  }
}
```

Implement any missing driver methods (`openFilter`, `toggleDateFilter`, `apply`, `selectAccount`, `expectTransactionVisible/Absent`) on the relevant screen drivers, using the `UITestIdentifiers.TransactionFilter.*` and `UITestList.transaction(_:)` identifiers, following the driver invariants from `writing-ui-tests` (trace logs, post-condition waits, single resolver).

- [ ] **Step 4: Run the UI test**

Run: `just test-ui GroupTransactionFilterScopeMacTests`
Expected: both tests PASS. If the local UI host is wedged, follow the memory note "PR CI gate when UI host blocked" and gate on the PR's UI Test CI job instead.

- [ ] **Step 5: Review, format, commit**

Run `@ui-test-review` on the new test + driver changes; fix findings. Run `just format-check`.

```bash
git -C . add UITestSupport/UITestFixtures.swift MoolahUITests_macOS/Tests/Transactions/GroupTransactionFilterScopeMacTests.swift
# plus the seed-hydrator file and any driver files touched
git -C . commit -m "test(transactions): e2e — group scope survives filtering"
```

---

## Self-Review

**Spec coverage:**
- "Applying a filter in a group never widens beyond the group" → Task 1 helper + Task 3 `applyFilter` + Task 5 test. ✓
- "Account control supports multiple accounts" → Task 2 picker + Task 3 wiring. ✓
- "Options scoped to context; default all" → Task 3 `availableAccounts` + seeding; global/single-account handled (single-account hides the control). ✓
- "Empty selection = all accounts in the group" → Task 1 (`selection.isEmpty → scope`) + Task 3 seeding round-trip. ✓
- Non-goal "no model change" honoured — only an extension method is added. ✓
- Tests: unit (Task 1, Task 2), fetch regression (existing `TxnRepoAccountIdsFilterTests`, re-run in Task 3), XCUITest (Task 5). ✓

**Placeholder scan:** Task 5 intentionally delegates driver/seed mechanics to the `writing-ui-tests` skill (the repo's seed hydrator and screen drivers are the source of truth for those conventions); the scenario, fixtures, identifiers, and assertions are all specified concretely. Tasks 1–4 contain complete code.

**Type consistency:** `resolveScopedAccountIds(selection:scope:available:)`, `AccountMultiSelectPicker(accounts:selectedIds:)` + `selectionSummary(for:available:)`, `TransactionFilterView.init(filter:scopeAccountIds:accounts:categories:earmarks:onApply:)`, and `UITestIdentifiers.TransactionFilter.*` are used consistently across tasks.
