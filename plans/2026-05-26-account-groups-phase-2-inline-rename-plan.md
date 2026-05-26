# Account Groups — Phase 2 Implementation Plan: Inline rename in the sidebar

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring inline rename (Finder-style) to the sidebar's account and earmark rows. Same row component, same triggers (double-click, right-click → Rename, Return when selected), same commit/cancel semantics. Builds the rename infrastructure that Phase 4 will reuse for group rows; nothing about groups themselves lands in this PR.

**Architecture:** Extend the shared `SidebarRowView` to support an optional inline-rename mode (no behavioural change when the caller doesn't opt in). Drive editing state from the sidebar (`SidebarView` owns "which row is being renamed"). Add dedicated `rename(id:to:)` mutations on `AccountStore` and `EarmarkStore` — a thin layer over the existing `update(_:)` pass-throughs that handles trim, no-op detection, and an empty-name revert. Add a "Rename" item to the account context menu, and a new earmark context menu containing the same item. Wire Return-key entry via `.onKeyPress(.return)` on the sidebar list.

**Tech Stack:** SwiftUI (macOS 14+ `.onKeyPress`, `@FocusState`, `TextField`); Swift Testing for store mutation tests.

**Spec:** `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-groups-design/plans/2026-05-26-account-groups-design.md` — see "Sidebar UX" / "Inline rename — applied across sidebar entity types".

**Phase ordering note:** This phase depends on **nothing** in Phase 1 (the `AccountBucket` work). The two PRs can land in either order. If Phase 1 hasn't merged when this plan executes, branch off `origin/main` rather than off Phase 1's branch.

---

## Worktree setup

- [ ] **Step 1: Create a worktree on a feature branch off main**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track \
  .worktrees/sidebar-inline-rename -b sidebar-inline-rename origin/main
```

`--no-track` is mandatory per the project's stacked-PR policy in `CLAUDE.md`.

- [ ] **Step 2: Generate the Xcode project for the worktree**

```bash
just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename \
     --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename/justfile generate
```

- [ ] **Step 3: From here on, every shell command runs from the worktree path**

`/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename` is the working directory for the remainder of the plan.

---

## Task 1: Add `AccountStore.rename(id:to:)`

**Files:**
- Modify: `Features/Accounts/AccountStore+Mutations.swift` (after the existing `update(_:)` block, around line 58)
- Modify: `MoolahTests/Features/AccountStoreMutationsTests.swift` (append a new `@Suite` or section)

- [ ] **Step 1: Write the failing tests**

Append to `MoolahTests/Features/AccountStoreMutationsTests.swift`:

```swift
  @Test("rename updates the account's name")
  func renameUpdatesName() async throws {
    let (backend, database) = try TestBackend.create()
    let original = AccountStoreTestSupport.seedAccount(
      name: "Old", type: .bank, balance: 0, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let result = try await store.rename(id: original.id, to: "New")

    #expect(result?.name == "New")
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: original.id)?.name == "New" },
      description: "rename observed"
    )
  }

  @Test("rename trims surrounding whitespace before persisting")
  func renameTrimsWhitespace() async throws {
    let (backend, database) = try TestBackend.create()
    let original = AccountStoreTestSupport.seedAccount(
      name: "Old", type: .bank, balance: 0, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let result = try await store.rename(id: original.id, to: "  Spaced  ")

    #expect(result?.name == "Spaced")
  }

  @Test("rename to empty / whitespace-only string reverts (returns current account)")
  func renameToEmptyReverts() async throws {
    let (backend, database) = try TestBackend.create()
    let original = AccountStoreTestSupport.seedAccount(
      name: "Old", type: .bank, balance: 0, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let result = try await store.rename(id: original.id, to: "   ")

    // Returns the existing account unchanged; no write happens.
    #expect(result?.name == "Old")
    #expect(store.accounts.by(id: original.id)?.name == "Old")
  }

  @Test("rename to the same name is a no-op (no write, returns current)")
  func renameToSameNameIsNoOp() async throws {
    let (backend, database) = try TestBackend.create()
    let original = AccountStoreTestSupport.seedAccount(
      name: "Stable", type: .bank, balance: 0, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let result = try await store.rename(id: original.id, to: "Stable")

    #expect(result?.name == "Stable")
  }

  @Test("rename of unknown id returns nil without surfacing an error")
  func renameOfUnknownIdReturnsNil() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let result = try await store.rename(id: UUID(), to: "Whatever")

    #expect(result == nil)
    #expect(store.error == nil)
  }
```

- [ ] **Step 2: Run the new tests to verify they fail**

```bash
just test AccountStoreMutationsTests 2>&1 | tee .agent-tmp/test-rename-1.txt
```

Expected: build failure with "Value of type 'AccountStore' has no member 'rename'".

- [ ] **Step 3: Add the `rename(id:to:)` method**

In `Features/Accounts/AccountStore+Mutations.swift`, immediately after the existing `update(_:)` block (around line 58, before `reorderAccounts`), add:

```swift
  /// Convenience rename. Trims whitespace; treats empty / whitespace-only
  /// input as a revert (no write, returns the current account unchanged).
  /// Same-name input is also a no-op. The reactive observation delivers
  /// the renamed account; `surfaceError` handling is delegated to
  /// `update(_:)`.
  @discardableResult
  func rename(id: UUID, to newName: String) async throws -> Account? {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let account = accounts.by(id: id) else { return nil }
    guard !trimmed.isEmpty, trimmed != account.name else { return account }
    var updated = account
    updated.name = trimmed
    return try await update(updated)
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
just test AccountStoreMutationsTests 2>&1 | tee .agent-tmp/test-rename-1.txt
grep -i 'failed\|error:' .agent-tmp/test-rename-1.txt || echo "OK"
```

Expected: all rename tests pass; existing AccountStoreMutationsTests still pass.

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename add \
  Features/Accounts/AccountStore+Mutations.swift \
  MoolahTests/Features/AccountStoreMutationsTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename commit -m "feat(accounts): AccountStore.rename(id:to:) convenience mutation

Trims whitespace, no-ops empty / unchanged / unknown-id inputs.
Thin layer over update(_:) so the upcoming inline-rename UI can call a
small, intent-shaped method instead of mutating an Account locally."
```

---

## Task 2: Add `EarmarkStore.rename(id:to:)`

**Files:**
- Modify: `Features/Earmarks/EarmarkStore+Mutations.swift` (after the existing `update(_:)` block, around line 45)
- Modify: `MoolahTests/Features/EarmarkStoreMutationTests.swift` (append to the existing `@Suite`)

- [ ] **Step 1: Write the failing tests**

Append to `MoolahTests/Features/EarmarkStoreMutationTests.swift` inside the `EarmarkStoreMutationTests` suite:

```swift
  @Test
  func renameUpdatesName() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()
    let created = await store.create(
      Earmark(name: "Old", instrument: .defaultTestInstrument))
    try #require(created != nil)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.count == 1 },
      description: "create observed"
    )

    let result = await store.rename(id: created!.id, to: "New")

    #expect(result?.name == "New")
    try await store.waitForNextEmission(
      matching: { $0.earmarks.first?.name == "New" },
      description: "rename observed"
    )
  }

  @Test
  func renameTrimsWhitespace() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()
    let created = await store.create(
      Earmark(name: "Old", instrument: .defaultTestInstrument))
    try #require(created != nil)

    let result = await store.rename(id: created!.id, to: "  Spaced  ")

    #expect(result?.name == "Spaced")
  }

  @Test
  func renameToEmptyReverts() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()
    let created = await store.create(
      Earmark(name: "Stable", instrument: .defaultTestInstrument))
    try #require(created != nil)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.count == 1 },
      description: "create observed"
    )

    let result = await store.rename(id: created!.id, to: "   ")

    #expect(result?.name == "Stable")
    #expect(store.earmarks.first?.name == "Stable")
  }

  @Test
  func renameToSameNameIsNoOp() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()
    let created = await store.create(
      Earmark(name: "Stable", instrument: .defaultTestInstrument))
    try #require(created != nil)

    let result = await store.rename(id: created!.id, to: "Stable")

    #expect(result?.name == "Stable")
  }

  @Test
  func renameOfUnknownIdReturnsNil() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let result = await store.rename(id: UUID(), to: "Whatever")

    #expect(result == nil)
    #expect(store.error == nil)
  }
```

- [ ] **Step 2: Run the new tests to verify they fail**

```bash
just test EarmarkStoreMutationTests 2>&1 | tee .agent-tmp/test-rename-2.txt
```

Expected: build failure with "Value of type 'EarmarkStore' has no member 'rename'".

- [ ] **Step 3: Add the `rename(id:to:)` method**

In `Features/Earmarks/EarmarkStore+Mutations.swift`, immediately after the existing `update(_:)` block (around line 45, before `hide(_:)`), add:

```swift
  /// Convenience rename. Trims whitespace; treats empty / whitespace-only
  /// input as a revert (no write, returns the current earmark unchanged).
  /// Same-name input is also a no-op. The reactive observation delivers
  /// the renamed earmark; error handling is delegated to `update(_:)`.
  @discardableResult
  func rename(id: UUID, to newName: String) async -> Earmark? {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let earmark = earmarks.first(where: { $0.id == id }) else { return nil }
    guard !trimmed.isEmpty, trimmed != earmark.name else { return earmark }
    var updated = earmark
    updated.name = trimmed
    return await update(updated)
  }
```

The lookup uses `earmarks.first(where:)` rather than a `by(id:)` helper because `EarmarkStore` exposes a flat `earmarks: [Earmark]`, not the `Accounts` collection wrapper. If you add a `by(id:)` helper while doing this work, do it as a separate refactoring PR — not in scope here.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
just test EarmarkStoreMutationTests 2>&1 | tee .agent-tmp/test-rename-2.txt
grep -i 'failed\|error:' .agent-tmp/test-rename-2.txt || echo "OK"
```

Expected: all rename tests pass; existing tests still pass.

- [ ] **Step 5: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename add \
  Features/Earmarks/EarmarkStore+Mutations.swift \
  MoolahTests/Features/EarmarkStoreMutationTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename commit -m "feat(earmarks): EarmarkStore.rename(id:to:) convenience mutation

Mirror of AccountStore.rename — trims, no-ops empty / unchanged /
unknown-id inputs. Thin layer over update(_:) for the upcoming inline
rename UI."
```

---

## Task 3: Extend `SidebarRowView` with optional inline-rename support

**Files:**
- Modify: `Features/Accounts/Views/AccountSidebarRow.swift` (the `SidebarRowView` struct, lines 13-79)

The component change is additive: when `isEditing` (a `Binding<Bool>`) and `onRename` (a closure) are both provided, the row renders a `TextField` in place of the `Text(name)`. When either is `nil`, the row renders exactly as today.

- [ ] **Step 1: Add the new properties and the conditional rename field**

In `Features/Accounts/Views/AccountSidebarRow.swift`, replace the `SidebarRowView` struct body and `var body` to:

```swift
struct SidebarRowView: View {
  let icon: String
  let name: String
  let amount: InstrumentAmount?
  var isSelected: Bool = false
  var unsetIndicator: String?
  /// When non-nil, the row supports inline rename. The caller flips
  /// `isEditing.wrappedValue` to true (via double-click, context menu,
  /// or keyboard shortcut). The row renders a `TextField` instead of
  /// `Text(name)` while editing; on commit (Return / focus loss) it
  /// calls `onRename` with the entered text (trimmed by the store).
  /// On Escape, it sets `isEditing` to false without calling `onRename`.
  /// Caller is responsible for ensuring only one row is editing at a
  /// time — there is no global coordination inside this view.
  var isEditing: Binding<Bool>? = nil
  var onRename: ((String) -> Void)? = nil

  @Environment(\.backgroundProminence) private var backgroundProminence

  private static let selectedPositiveColor = Color(red: 0.55, green: 1.0, blue: 0.65)
  private static let selectedNegativeColor = Color(red: 1.0, green: 0.6, blue: 0.6)

  private var amountColorOverride: Color? {
    guard let amount, isSelected, backgroundProminence == .increased else { return nil }
    if amount.isPositive { return Self.selectedPositiveColor }
    if amount.isNegative { return Self.selectedNegativeColor }
    return nil
  }

  var body: some View {
    HStack {
      Image(systemName: icon)
        .foregroundStyle(.secondary)
        .frame(width: UIConstants.IconSize.listIcon, height: UIConstants.IconSize.listIcon)
        .accessibilityHidden(true)

      nameContent

      Spacer()

      trailingValue
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
  }

  @ViewBuilder private var nameContent: some View {
    if let isEditing, let onRename, isEditing.wrappedValue {
      InlineRenameField(
        initialText: name,
        onCommit: { committed in
          isEditing.wrappedValue = false
          onRename(committed)
        },
        onCancel: { isEditing.wrappedValue = false }
      )
    } else {
      Text(name)
        .onTapGesture(count: 2) {
          guard let isEditing, onRename != nil else { return }
          isEditing.wrappedValue = true
        }
    }
  }

  @ViewBuilder private var trailingValue: some View {
    if let unsetIndicator {
      Text(unsetIndicator)
        .font(.caption)
        .foregroundStyle(.secondary)
    } else if let amount {
      InstrumentAmountView(amount: amount, colorOverride: amountColorOverride)
    } else {
      ProgressView()
        .controlSize(.small)
    }
  }

  private var accessibilitySummary: String {
    if let unsetIndicator { return "\(name), \(unsetIndicator)" }
    guard let amount else { return "\(name), balance loading" }
    return "\(name), \(amount.formatted)"
  }
}
```

The `.onTapGesture(count: 2)` only activates when `isEditing` is non-nil (callers that opt in). For non-rename callers the gesture is a no-op closure that is never installed — `.onTapGesture` is unconditional but its handler short-circuits.

Actually — the gesture *is* installed unconditionally. That's fine for a non-rename caller (the handler just returns early on the `guard`), but it does intercept a double-click on the row. If a non-rename caller has its own double-click affordance, it would silently break. **There are no such callers today**, but this is a behaviour worth flagging in the doc-comment so the next developer is aware.

Update the doc-comment on `SidebarRowView` (the existing comment block at lines 3-12 of the original file) to add:

```swift
/// **Inline rename:** when both `isEditing` and `onRename` are provided,
/// the row supports double-click-to-rename. Callers that do not opt in
/// still receive a double-click gesture that no-ops, so do not attach a
/// competing double-click handler to a `SidebarRowView`.
```

- [ ] **Step 2: Add the `InlineRenameField` companion view**

In the same file, immediately above `struct SidebarRowView` (or below — keep them adjacent), add:

```swift
/// TextField used by `SidebarRowView` while a row is in inline-rename
/// mode. Auto-focuses on appear; selects all text initially; commits on
/// Return or focus loss (calls `onCommit`); cancels on Escape (calls
/// `onCancel`). Separated from `SidebarRowView` so the focus/selection
/// machinery is testable in isolation via #Preview.
private struct InlineRenameField: View {
  let initialText: String
  let onCommit: (String) -> Void
  let onCancel: () -> Void

  @State private var text: String = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField("", text: $text)
      .textFieldStyle(.plain)
      .focused($isFocused)
      .onAppear {
        text = initialText
        isFocused = true
      }
      .onSubmit { onCommit(text) }
      .onChange(of: isFocused) { _, focused in
        // Focus loss without an explicit submit = commit (matches
        // Finder-style rename). Escape will have set onCancel via
        // .onKeyPress before focus drops.
        if !focused { onCommit(text) }
      }
      .onKeyPress(.escape) {
        onCancel()
        return .handled
      }
  }
}
```

Why separate: keeps `SidebarRowView` declarative and lets the rename field own its `@FocusState` + `@State` text buffer. The field unmounts when the row exits edit mode, so the local state is naturally discarded.

- [ ] **Step 3: Add a `#Preview` exercising the rename mode**

Append to the bottom of the file (after the existing previews):

```swift
#Preview("Sidebar row — inline rename") {
  @Previewable @State var isEditing = true
  return List(selection: .constant(Optional("selected"))) {
    SidebarRowView(
      icon: "building.columns",
      name: "Bank Account",
      amount: InstrumentAmount(quantity: 1234.56, instrument: .AUD),
      isSelected: true,
      isEditing: $isEditing,
      onRename: { newName in print("Rename to: \(newName)") }
    )
    .tag("selected")
  }
  .listStyle(.sidebar)
  .frame(width: 260)
}
```

- [ ] **Step 4: Render the preview to confirm the rename mode looks right**

Use the `reviewing-ui-with-preview` skill or open the worktree's `Moolah.xcodeproj` in Xcode and open the canvas on `AccountSidebarRow.swift`. The new preview should show a focused text field instead of the plain name, with the cursor placed at the start of "Bank Account".

Verify by eye: text is editable, hitting Return prints to the console, hitting Escape exits edit mode (the toggle is `@State` so it flips to false; the preview then re-renders as the plain row).

If the preview fails to compile, fix that before continuing — likely cause is `@Previewable` requiring a particular macOS deployment target or a missing import.

- [ ] **Step 5: Run the test suite to confirm no regression in the rest of the app**

```bash
just test 2>&1 | tee .agent-tmp/test-rename-3.txt
grep -i 'failed\|error:' .agent-tmp/test-rename-3.txt || echo "OK"
```

Expected: full suite passes. The non-rename `SidebarRowView` callers (account rows, earmark rows in the existing sidebar) keep their current behaviour because they don't pass `isEditing` / `onRename`.

- [ ] **Step 6: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename add \
  Features/Accounts/Views/AccountSidebarRow.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename commit -m "feat(sidebar): inline-rename support on SidebarRowView

Opt-in via isEditing + onRename. Renders a focused TextField in place
of the name when editing; commits on Return / focus loss; cancels on
Escape. Companion InlineRenameField owns the focus / text state so
SidebarRowView stays declarative."
```

---

## Task 4: Wire inline rename into `SidebarView` for account rows

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`
- Modify: `UITestSupport/UITestIdentifiers.swift` (add identifier for the Rename menu item)

- [ ] **Step 1: Add the editing-id state to `SidebarView`**

In `Features/Navigation/SidebarView.swift`, near the existing `@State` declarations (around line 29-32), add:

```swift
  /// Identifies the sidebar row currently in inline rename mode, if
  /// any. Local-only — never persisted, never synced. At most one row
  /// is in edit mode at a time across the entire sidebar (accounts,
  /// earmarks, future groups).
  @State private var editingRowId: UUID?
```

- [ ] **Step 2: Add the Rename menu item to `accountContextMenu(for:)`**

Replace the existing `accountContextMenu(for:)` (currently lines 362-370) with:

```swift
  @ViewBuilder
  private func accountContextMenu(for account: Account) -> some View {
    Button("Rename", systemImage: "character.cursor.ibeam") {
      editingRowId = account.id
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.renameContextMenuItem)
    Button("Edit Account\u{2026}", systemImage: "pencil") {
      accountToEdit = account
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.editAccountContextMenuItem)
    Button("View Transactions", systemImage: "list.bullet") {
      selection = .account(account.id)
    }
  }
```

- [ ] **Step 3: Wire the row to inline rename**

In the two places that build `AccountSidebarRow` (lines 162 and 203 in the original file — `currentAccountsSection` and `investmentsSection`), the existing call is:

```swift
AccountSidebarRow(account: account, isSelected: selection == .account(account.id))
```

`AccountSidebarRow` currently delegates straight to `SidebarRowView` without exposing rename — so we need to extend `AccountSidebarRow` to forward the rename binding. Update `AccountSidebarRow` in `Features/Accounts/Views/AccountSidebarRow.swift` (the struct at lines 91-105) to:

```swift
struct AccountSidebarRow: View {
  let account: Account
  var isSelected: Bool = false
  var isEditing: Binding<Bool>? = nil
  var onRename: ((String) -> Void)? = nil
  @Environment(AccountStore.self) private var accountStore

  var body: some View {
    SidebarRowView(
      icon: account.sidebarIcon,
      name: account.name,
      amount: accountStore.convertedBalances[account.id],
      isSelected: isSelected,
      unsetIndicator: accountStore.hasUnrecordedValue(account) ? "Not set" : nil,
      isEditing: isEditing,
      onRename: onRename
    )
  }
}
```

Then in `SidebarView.swift`, both `AccountSidebarRow` callsites become:

```swift
AccountSidebarRow(
  account: account,
  isSelected: selection == .account(account.id),
  isEditing: renameBinding(for: account.id),
  onRename: { newName in
    Task { _ = try? await accountStore.rename(id: account.id, to: newName) }
  }
)
```

Add the helper above `accountContextMenu(for:)`:

```swift
  /// Returns a binding that reports `true` when this row id is the
  /// one currently being inline-renamed, and (on `set(true)`) makes it
  /// so. Centralises the one-at-a-time invariant.
  private func renameBinding(for id: UUID) -> Binding<Bool> {
    Binding(
      get: { editingRowId == id },
      set: { newValue in editingRowId = newValue ? id : nil }
    )
  }
```

- [ ] **Step 4: Add the UITestIdentifier constant**

In `UITestSupport/UITestIdentifiers.swift`, inside `public enum Sidebar` (after `editAccountContextMenuItem` around line 50), add:

```swift
    /// "Rename" item in the sidebar context menu — applies to accounts,
    /// earmarks, and (Phase 4 onwards) account groups. Triggers inline
    /// rename mode in the sidebar.
    public static let renameContextMenuItem = "sidebar.contextMenu.rename"
```

- [ ] **Step 5: Build and exercise via preview**

```bash
just build-mac 2>&1 | tee .agent-tmp/test-rename-4.txt
grep -E 'error:' .agent-tmp/test-rename-4.txt || echo "OK"
```

If build is clean: open the worktree's `Moolah.xcodeproj` in Xcode, then run the app with a seeded profile. Right-click an account → **Rename**. The row's name should swap to a focused text field; type a new name + Return; the row should display the new name. Right-click again to confirm Rename still works; double-click the name to confirm that path works; press Escape to confirm cancel.

This step is manual verification — store-level behaviour is covered by Task 1's tests, and the SwiftUI keyboard / focus interaction is not currently in the XCUITest harness for this codebase. If exercising in the app reveals a behavioural bug, fix and re-verify before committing.

- [ ] **Step 6: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename add \
  Features/Navigation/SidebarView.swift \
  Features/Accounts/Views/AccountSidebarRow.swift \
  UITestSupport/UITestIdentifiers.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename commit -m "feat(sidebar): inline rename for account rows

Adds editingRowId state to SidebarView, a Rename context-menu item,
and double-click-to-rename on account rows in both Current and
Investments sections. Stores call AccountStore.rename. UITestIdentifier
added so the future group flow can target the same menu item."
```

---

## Task 5: Wire inline rename into earmark rows

**Files:**
- Modify: `Features/Earmarks/Views/EarmarkRowView.swift`
- Modify: `Features/Navigation/SidebarView.swift`

The earmarks section in `SidebarView` currently builds its rows inline with `SidebarRowView` (lines 184-188) rather than going through `EarmarkRowView`. There's also no earmark context menu today. We'll add both.

- [ ] **Step 1: Extend `EarmarkRowView` to forward the rename binding**

Replace the entire `EarmarkRowView` body in `Features/Earmarks/Views/EarmarkRowView.swift`:

```swift
struct EarmarkRowView: View {
  let earmark: Earmark
  var isSelected: Bool = false
  var isEditing: Binding<Bool>? = nil
  var onRename: ((String) -> Void)? = nil
  @Environment(EarmarkStore.self) private var earmarkStore

  var body: some View {
    SidebarRowView(
      icon: "bookmark.fill",
      name: earmark.name,
      amount: earmarkStore.convertedBalance(for: earmark.id)
        ?? .zero(instrument: earmark.instrument),
      isSelected: isSelected,
      isEditing: isEditing,
      onRename: onRename
    )
  }
}
```

(The `isSelected` parameter is also new — Phase 2 doesn't require it for behaviour but adding it now makes earmark rows consistent with account rows and removes a future churn point. The default `false` keeps callers that don't pass it unaffected.)

- [ ] **Step 2: Update the earmarks section in `SidebarView` to use `EarmarkRowView` and add the context menu**

In `Features/Navigation/SidebarView.swift`, replace the `earmarksSection` body (lines 180-197 of the original) with:

```swift
  private var earmarksSection: some View {
    Section {
      ForEach(earmarkStore.visibleEarmarks) { earmark in
        NavigationLink(value: SidebarSelection.earmark(earmark.id)) {
          EarmarkRowView(
            earmark: earmark,
            isSelected: selection == .earmark(earmark.id),
            isEditing: renameBinding(for: earmark.id),
            onRename: { newName in
              Task { _ = await earmarkStore.rename(id: earmark.id, to: newName) }
            }
          )
        }
        .contextMenu { earmarkContextMenu(for: earmark) }
      }
      .onMove { source, destination in
        Task { await earmarkStore.reorderEarmarks(from: source, to: destination) }
      }
      totalRow(label: "Earmarked Total", value: earmarkStore.convertedTotalBalance)
    } header: {
      sectionHeader(title: "Earmarks", addAction: addEarmarkAction)
    }
  }
```

Then add a sibling to `accountContextMenu(for:)`:

```swift
  @ViewBuilder
  private func earmarkContextMenu(for earmark: Earmark) -> some View {
    Button("Rename", systemImage: "character.cursor.ibeam") {
      editingRowId = earmark.id
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.renameContextMenuItem)
  }
```

This earmark menu starts with just Rename. The Edit-earmark sheet today is invoked from inside the earmark detail view, not from a sidebar context menu — Phase 2 doesn't change that. If you want to surface "Edit Earmark…" from the sidebar context menu too, treat it as a separate cleanup PR.

- [ ] **Step 3: Build and exercise**

```bash
just build-mac 2>&1 | tee .agent-tmp/test-rename-5.txt
grep -E 'error:' .agent-tmp/test-rename-5.txt || echo "OK"
```

Then open the app: right-click an earmark → Rename, confirm inline edit works exactly as for accounts. Double-click name to enter rename; Escape to cancel; Return to commit.

- [ ] **Step 4: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename add \
  Features/Earmarks/Views/EarmarkRowView.swift \
  Features/Navigation/SidebarView.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename commit -m "feat(sidebar): inline rename for earmark rows

EarmarkRowView forwards isEditing / onRename; SidebarView's earmarks
section gains a Rename context-menu item and switches from inline
SidebarRowView construction to EarmarkRowView (single source of truth
for earmark row rendering)."
```

---

## Task 6: Return-key trigger from a selected row

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`

Adds keyboard parity with Finder: when the sidebar is focused and a row is selected, hitting Return enters inline rename for that row.

- [ ] **Step 1: Add the `.onKeyPress(.return)` handler on the sidebar list**

In `Features/Navigation/SidebarView.swift`, locate the `List(selection: $selection) { … }` block (starts at line 54) and the `.listStyle(.sidebar)` modifier on line 61. Insert a new modifier *immediately after* `.listStyle(.sidebar)`:

```swift
    .onKeyPress(.return) {
      // Only respond to Return when the selection points at a row
      // that supports inline rename (account or earmark today; group
      // in Phase 4). Other selections (analysis / reports / etc.)
      // pass through unhandled so any default Return behaviour is
      // preserved.
      switch selection {
      case .account(let id):
        guard accountStore.accounts.by(id: id) != nil else { return .ignored }
        editingRowId = id
        return .handled
      case .earmark(let id):
        guard earmarkStore.earmarks.contains(where: { $0.id == id }) else { return .ignored }
        editingRowId = id
        return .handled
      case .none, .recentlyAdded, .allTransactions, .upcomingTransactions,
           .categories, .reports, .analysis:
        return .ignored
      }
    }
```

The exhaustive switch (rather than a default arm) forces a decision next time `SidebarSelection` grows a new case (e.g. `.group(UUID)` in Phase 4) — the compiler will flag the missing case.

- [ ] **Step 2: Build and exercise**

```bash
just build-mac 2>&1 | tee .agent-tmp/test-rename-6.txt
grep -E 'error:' .agent-tmp/test-rename-6.txt || echo "OK"
```

Then open the app: click an account row to select it; press Return; rename mode should activate. Press Escape; press Return again to confirm it re-enters. Click an "Analysis" / "Reports" navigation row; press Return — nothing should happen (no inline rename for navigation rows; default sidebar Return behaviour preserved).

If `.onKeyPress(.return)` does not fire on the List (a real possibility — SwiftUI's keyboard handling on macOS sidebars can be flaky depending on what owns key-window focus), fall back to a top-level command via `.focusedSceneValue`:

```swift
    .focusedSceneValue(\.renameSelectedRowAction) {
      // body of the .onKeyPress handler above
    }
```

…paired with a `.commands { CommandMenu("Edit") { Button("Rename", action: …) .keyboardShortcut(.return, modifiers: []) } }` modifier in `MoolahApp.scene`. This is a heavier wiring change and only do it if the direct `.onKeyPress` approach doesn't work after a real try (open the app, select a row, press Return, see if `editingRowId` flips). Document the choice in the commit message.

- [ ] **Step 3: Format-check and commit**

```bash
just format-check
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename add \
  Features/Navigation/SidebarView.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename commit -m "feat(sidebar): Return-key triggers inline rename on selected row

Mirrors Finder's row-rename convention. Account and earmark rows enter
rename mode; navigation rows pass through unhandled. Exhaustive
switch over SidebarSelection so a future .group case is forced to
make a decision."
```

---

## Task 7: Final verify + open PR

- [ ] **Step 1: Full test suite, both targets**

```bash
just test 2>&1 | tee .agent-tmp/test-rename-final.txt
grep -i 'failed\|error:' .agent-tmp/test-rename-final.txt || echo "OK"
```

Expected: every test passes on both iOS Simulator and macOS.

- [ ] **Step 2: Format-check (final)**

```bash
just format-check
```

Expected: exits 0.

- [ ] **Step 3: Push the branch**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename \
    push origin sidebar-inline-rename:sidebar-inline-rename
```

- [ ] **Step 4: Open the PR**

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-inline-rename && \
gh pr create --base main --head sidebar-inline-rename \
  --title "feat(sidebar): inline rename for accounts and earmarks" \
  --body "$(cat <<'EOF'
## Summary

- Add `AccountStore.rename(id:to:)` and `EarmarkStore.rename(id:to:)` — convenience mutations that trim whitespace, no-op empty / unchanged / unknown-id inputs, and delegate persistence to the existing `update(_:)` pass-throughs.
- Extend `SidebarRowView` with optional inline-rename support (`isEditing` binding + `onRename` closure). When the caller opts in, the row swaps the name `Text` for a focused `TextField` that commits on Return / focus loss and cancels on Escape.
- Wire account rows (Current + Investments sections) and earmark rows to inline rename. New "Rename" context-menu item on both. Centralised `editingRowId` state on `SidebarView` enforces the one-row-at-a-time invariant.
- Return key on a selected account / earmark row enters rename mode (Finder convention).

## Why

Phase 2 of the Account Groups feature (spec: `plans/2026-05-26-account-groups-design.md`). The spec calls for a single editing mode in the sidebar across all entity types — accounts, earmarks, and (Phase 4 onwards) groups. Building the rename infrastructure now means Phase 4's group rows pick it up for free, and the existing dialog-only rename UX gets faster for accounts and earmarks today.

## Test plan

- [x] Store unit tests: `just test AccountStoreMutationsTests EarmarkStoreMutationTests` — covers trim, no-op, empty-reverts, unknown-id paths
- [x] Preview check on `AccountSidebarRow.swift`: focused text field renders in rename mode
- [x] Manual exercise: right-click → Rename, double-click name, Return on selection (account and earmark); Escape cancels; Return commits
- [x] `just test` — full suite green
- [x] `just format-check` — clean

## Out of scope

- No UI-test coverage for the keyboard / focus interaction (not currently in the XCUITest harness for SwiftUI focus state). If a regression in the keyboard path is found later, that's the moment to add the XCUITest infrastructure.
- The Edit Account / Edit Earmark dialogs are unchanged — they still cover other-field edits.
- No `Rename` item on the earmark *detail view* yet (only sidebar). If wanted, add as a separate PR.
EOF
)"
```

Note the PR URL; queue it via `~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <pr-number>` per the project default.

---

## Acceptance criteria for Phase 2

- `AccountStore.rename(id:to:)` and `EarmarkStore.rename(id:to:)` exist with their respective test coverage (trim, no-op-empty, no-op-same, unknown-id-nil paths).
- `SidebarRowView` accepts optional `isEditing` + `onRename` and renders a `TextField` (via `InlineRenameField`) when both are provided and editing is true. Behaviour for non-opted-in callers is unchanged.
- `AccountSidebarRow` and `EarmarkRowView` forward the rename binding.
- `SidebarView` owns a single `editingRowId: UUID?` enforcing the one-row-at-a-time invariant.
- "Rename" context-menu item appears on account rows (Current + Investments) and earmark rows.
- Double-click on a row's name enters rename mode.
- Return key on a selected account / earmark row enters rename mode.
- Escape cancels; Return / focus loss commits (trimmed, via the store's `rename(id:to:)`).
- Empty / whitespace-only commit reverts silently (no error UI).
- `UITestIdentifiers.Sidebar.renameContextMenuItem` exists for future XCUITest coverage.
- Full `just test` passes on iOS + macOS.
- `just format-check` passes.
- PR opened against `main` and queued.

---

## What's NOT in this phase

For reference, the remaining phases (each gets its own plan):

3. `AccountGroup` model + CKDB record + GRDB table + DataFormatVersion bump.
4. Sidebar rendering with collapsed/expanded groups + drop semantics + creation flows (will reuse inline rename from this PR).
5. `AccountViewContext` + thread through detail view.
6. Description-rendering generalisation + transaction list under group view.
7. Sync wiring (record convertibles, conflict handling, retry surface).
8. Local-only `account_group_ui` table for `isExpandedInSidebar`.
