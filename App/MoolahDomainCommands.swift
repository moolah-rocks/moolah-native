import SwiftUI

// Command-menu definitions. Each struct is a top-level `Commands` type
// used in `MoolahApp.body`'s `.commands { ... }` builder.

/// Combined File > New… commands (Transaction, Earmark, Account, Category).
/// Grouping them into one Commands struct keeps the top-level `.commands` block
/// under `CommandsBuilder`'s 10-argument limit.
struct NewItemCommands: Commands {
  @FocusedValue(\.newTransactionAction) private var newTransactionAction
  @FocusedValue(\.newEarmarkAction) private var newEarmarkAction
  @FocusedValue(\.newAccountAction) private var newAccountAction
  @FocusedValue(\.newCategoryAction) private var newCategoryAction

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Transaction\u{2026}") {
        newTransactionAction?()
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(newTransactionAction == nil)

      Button("New Earmark\u{2026}") {
        newEarmarkAction?()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(newEarmarkAction == nil)

      Button("New Account\u{2026}") {
        newAccountAction?()
      }
      .keyboardShortcut("n", modifiers: [.command, .control])
      .disabled(newAccountAction == nil)

      Button("New Category\u{2026}") {
        newCategoryAction?()
      }
      .keyboardShortcut("n", modifiers: [.command, .option])
      .disabled(newCategoryAction == nil)
    }
  }
}

/// Commands for refreshing data
struct RefreshCommands: Commands {
  @FocusedValue(\.refreshAction) private var refreshAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()
      Button("Refresh") {
        refreshAction?()
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(refreshAction == nil)
    }
  }
}

/// View menu verb-pair for showing / hiding hidden accounts and earmarks.
/// Uses a Button with a flipped label (per §14 "Toggle State") and stays
/// visible when no window is focused — disabled per §14 "Disable, don't hide".
struct ShowHiddenCommands: Commands {
  @FocusedValue(\.showHiddenAccounts) private var showHidden

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button(
        showHidden?.wrappedValue == true ? "Hide Hidden Accounts" : "Show Hidden Accounts"
      ) {
        showHidden?.wrappedValue.toggle()
      }
      .keyboardShortcut("h", modifiers: [.command, .shift])
      .disabled(showHidden == nil)
    }
  }
}

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

/// Wrapper grouping the View-menu verb-pair toggles into a single
/// Commands argument so the outer `.commands` block stays within
/// `CommandsBuilder`'s 10-argument limit (mirrors the
/// `MoolahDomainCommands` grouping rationale at the top of this file).
struct ViewMenuToggleCommands: Commands {
  var body: some Commands {
    ShowHiddenCommands()
    ShowSpamTransactionsCommands()
  }
}

/// Moolah-specific top-level domain menus grouped into one Commands struct so
/// the outer `.commands` block stays within `CommandsBuilder`'s 10-argument limit.
/// CommandMenus are inlined here (rather than references to per-feature structs)
/// to keep the opaque `some Commands` return type inferable.
struct MoolahDomainCommands: Commands {
  @FocusedValue(\.selectedAccount) private var selectedAccount
  @FocusedValue(\.selectedEarmark) private var selectedEarmark
  @FocusedValue(\.selectedCategory) private var selectedCategory
  @FocusedValue(\.sidebarSelection) private var sidebarSelection
  @FocusedValue(\.goBackAction) private var goBackAction
  @FocusedValue(\.goForwardAction) private var goForwardAction
  @FocusedValue(\.findInListAction) private var findInListAction
  @FocusedValue(\.setTransactionTypeAction) private var setTransactionTypeAction
  @FocusedValue(\.editTransactionAction) private var editTransactionAction
  @FocusedValue(\.deleteTransactionAction) private var deleteTransactionAction
  @FocusedValue(\.payTransactionAction) private var payTransactionAction
  @FocusedValue(\.mergeAsTransferAction) private var mergeAsTransferAction
  @FocusedValue(\.unmergeTransferAction) private var unmergeTransferAction
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openURL) private var openURL

  var body: some Commands {
    CommandMenu("Transaction") {
      Button("Edit Transaction\u{2026}") { editTransactionAction?() }
        .disabled(editTransactionAction == nil)

      Button("Duplicate Transaction") {}.disabled(true)

      Menu("Type") {
        transactionTypeMenuItems
      }
      .disabled(setTransactionTypeAction == nil)

      Button("Pay Scheduled Transaction") { payTransactionAction?() }
        .disabled(payTransactionAction == nil)

      Divider()

      // Transfer-lifecycle group. No keyboard shortcuts (infrequent
      // actions, UI_GUIDE §14) and no destructive role on these
      // menu-bar buttons — the menu bar does not render role colour and
      // splitting a merged transfer restores data, so it does not
      // belong in the Delete group below.
      Button("Merge as Transfer") { mergeAsTransferAction?() }
        .disabled(mergeAsTransferAction == nil)

      Button("Split Back into Separate Transactions\u{2026}") {
        unmergeTransferAction?()
      }
      .disabled(unmergeTransferAction == nil)

      Divider()

      Button("Delete Transaction\u{2026}", role: .destructive) { deleteTransactionAction?() }
        .disabled(deleteTransactionAction == nil)
    }

    CommandMenu("Go") {
      goMenuItems
    }

    CommandMenu("Account") {
      Button("Edit Account\u{2026}") {
        NotificationCenter.default.post(
          name: .requestAccountEdit,
          object: selectedAccount?.wrappedValue?.id
        )
      }
      .disabled(selectedAccount?.wrappedValue == nil)

      Button("View Transactions") {
        if let id = selectedAccount?.wrappedValue?.id {
          sidebarSelection?.wrappedValue = .account(id)
        }
      }
      .disabled(selectedAccount?.wrappedValue == nil)

      Divider()

      // Incremental "Sync Now" (⇧⌘R — ⌘R is already claimed by the
      // generic "Refresh" command, `RefreshCommands`) plus a full
      // "Resync Now (Full History)". Resync carries NO keyboard shortcut:
      // SwiftUI `Commands` can't render a native Option-alternate item (no
      // `NSMenuItem.isAlternate`), and a second shortcut-bearing entry
      // would clutter/collide. But the menu entry itself is required —
      // UI_GUIDE §14: every toolbar/context-menu action needs a menu-bar
      // counterpart for VoiceOver / full-keyboard discoverability, and the
      // label matches the sidebar context menu so the two agree. The
      // synced-account header button's Option relabel offers the same
      // full resync with the mnemonic.
      Button("Sync Now") {
        NotificationCenter.default.post(
          name: .requestAccountSync,
          object: selectedAccount?.wrappedValue?.id
        )
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(!accountOffersSync)

      Button("Resync Now (Full History)") {
        NotificationCenter.default.post(
          name: .requestAccountResync,
          object: selectedAccount?.wrappedValue?.id
        )
      }
      .disabled(!accountOffersSync)
    }

    CommandMenu("Earmark") {
      Button("Edit Earmark\u{2026}") {
        NotificationCenter.default.post(
          name: .requestEarmarkEdit,
          object: selectedEarmark?.wrappedValue?.id
        )
      }
      .disabled(selectedEarmark?.wrappedValue == nil)

      Button(
        selectedEarmark?.wrappedValue?.isHidden == true ? "Show Earmark" : "Hide Earmark"
      ) {
        NotificationCenter.default.post(
          name: .requestEarmarkToggleHidden,
          object: selectedEarmark?.wrappedValue?.id
        )
      }
      .disabled(selectedEarmark?.wrappedValue == nil)
    }

    CommandMenu("Category") {
      Button("Edit Category\u{2026}") {
        NotificationCenter.default.post(
          name: .requestCategoryEdit,
          object: selectedCategory?.wrappedValue?.id
        )
      }
      .disabled(selectedCategory?.wrappedValue == nil)
    }

    CommandGroup(after: .textEditing) {
      Button("Find Transactions\u{2026}") { findInListAction?() }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(findInListAction == nil)

      Button("Find Next") {}
        .keyboardShortcut("g", modifiers: .command)
        .disabled(true)

      Button("Find Previous") {}
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(true)
    }

    CommandGroup(after: .pasteboard) {
      Button("Copy Transaction Link") {}
        .keyboardShortcut("c", modifiers: [.command, .control])
        .disabled(true)
    }

    CommandGroup(replacing: .help) {
      // We don't ship a native HelpViewer book — HelpViewer's sidebar TOC is
      // gated to Apple-CDN-hosted books, and any in-bundle help loses the
      // sidebar. The Help menu opens moolah.rocks/help instead, where the
      // full corpus is rendered with a proper TOC sidebar.
      Button("Moolah Help") {
        if let url = URL(string: "https://moolah.rocks/help/") { openURL(url) }
      }
      .keyboardShortcut("?", modifiers: [.command, .shift])

      Divider()

      Button("Keyboard Shortcuts\u{2026}") {
        openWindow(id: "keyboard-shortcuts")
      }
      .keyboardShortcut("/", modifiers: [.command, .shift])

      Divider()

      Button("Report a Bug") {
        if let url = URL(string: "https://github.com/moolah-rocks/moolah-native/issues/new") {
          openURL(url)
        }
      }

      Divider()

      Button("Privacy Policy") {
        if let url = URL(string: "https://moolah.rocks/privacy") { openURL(url) }
      }
    }
  }

  /// Whether the selected account offers Sync/Resync — mirrors
  /// `AccountType.isSynced`, the same predicate `SyncedAccountStore` and
  /// `SyncedAccountHeaderLogic` use to decide an account is a synced
  /// wallet/exchange rather than manually entered.
  private var accountOffersSync: Bool {
    selectedAccount?.wrappedValue?.type.isSynced == true
  }

  @ViewBuilder private var transactionTypeMenuItems: some View {
    Button("Income") { setTransactionTypeAction?(.income) }
      .keyboardShortcut("1", modifiers: [.option, .command])
      .disabled(setTransactionTypeAction == nil)
    Button("Expense") { setTransactionTypeAction?(.expense) }
      .keyboardShortcut("2", modifiers: [.option, .command])
      .disabled(setTransactionTypeAction == nil)
    Button("Transfer") { setTransactionTypeAction?(.transfer) }
      .keyboardShortcut("3", modifiers: [.option, .command])
      .disabled(setTransactionTypeAction == nil)
    Button("Trade") { setTransactionTypeAction?(.trade) }
      .keyboardShortcut("4", modifiers: [.option, .command])
      .disabled(setTransactionTypeAction == nil)
    Button("Custom") { setTransactionTypeAction?(.custom) }
      .keyboardShortcut("5", modifiers: [.option, .command])
      .disabled(setTransactionTypeAction == nil)
  }

  @ViewBuilder private var goMenuItems: some View {
    // Back/Forward at the top of the Go menu, matching macOS HIG / Safari /
    // Xcode / Finder / Mail. Numbered destinations follow.
    Button("Go Back") { goBackAction?() }
      .keyboardShortcut("[", modifiers: .command)
      .disabled(goBackAction == nil)
    Button("Go Forward") { goForwardAction?() }
      .keyboardShortcut("]", modifiers: .command)
      .disabled(goForwardAction == nil)
    Divider()
    Button("Transactions") { sidebarSelection?.wrappedValue = .allTransactions }
      .keyboardShortcut("1", modifiers: .command)
      .disabled(sidebarSelection == nil)
    Button("Scheduled") { sidebarSelection?.wrappedValue = .upcomingTransactions }
      .keyboardShortcut("2", modifiers: .command)
      .disabled(sidebarSelection == nil)
    Button("Categories") { sidebarSelection?.wrappedValue = .categories }
      .keyboardShortcut("3", modifiers: .command)
      .disabled(sidebarSelection == nil)
    Button("Reports") { sidebarSelection?.wrappedValue = .reports }
      .keyboardShortcut("4", modifiers: .command)
      .disabled(sidebarSelection == nil)
    Button("Analysis") { sidebarSelection?.wrappedValue = .analysis }
      .keyboardShortcut("5", modifiers: .command)
      .disabled(sidebarSelection == nil)
  }
}
