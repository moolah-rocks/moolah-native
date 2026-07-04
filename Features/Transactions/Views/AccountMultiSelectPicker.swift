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
  nonisolated static func selectionSummary(
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
      #if os(macOS)
        searchField
      #endif
      list
    }
    #if os(iOS)
      // `.searchable` installs a search item into the surrounding
      // navigation/toolbar. That is fine for the iOS `NavigationLink`
      // host, but on macOS this picker is presented inside a `.popover`,
      // where routing a search item through the window's `NSToolbar`
      // bridge crashes (`-[NSToolbar _insertNewItemWithItemIdentifier:…]`
      // during the popover's preference update). macOS therefore uses the
      // inline `searchField` above instead.
      .searchable(text: $searchText, prompt: "Search accounts")
      .navigationTitle("Accounts")
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  #if os(macOS)
    /// Inline search field for the macOS popover host — see the note on
    /// `.searchable` in `body` for why the toolbar-backed modifier can't
    /// be used here.
    private var searchField: some View {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField("Search accounts", text: $searchText)
          .textFieldStyle(.plain)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
  #endif

  // Inline header rather than `.toolbar`: SwiftUI toolbar items don't
  // render inside a macOS popover, so a toolbar Clear would be invisible
  // on the macOS host. The inline header works on both platforms.
  // The macOS popover gets its title from the inline label below; the
  // iOS NavigationLink host already supplies one via `navigationTitle`.
  private var header: some View {
    HStack {
      #if os(macOS)
        Text("Accounts")
          .font(.headline)
      #endif
      Spacer()
      // Whole-value reassignment for the same propagation reason as
      // the per-row toggle.
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
        ContentUnavailableView("No Accounts", systemImage: "creditcard")
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
          // Read-modify-write the whole `Set<UUID>` rather than calling
          // a mutating method (`insert(_:)` / `remove(_:)`) on the
          // `@Binding` projection. The mutating-method form did not
          // propagate updates back to the host's `@State` when the
          // picker was hosted inside a macOS popover (issue #781).
          // Whole-value reassignment goes through `Binding.wrappedValue`'s
          // `nonmutating set` unambiguously, which fixes it. Mirrors
          // the Clear button and `CategoryMultiSelectPicker`.
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
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 100)]),
    Account(
      id: UUID(),
      name: "Savings",
      type: .bank,
      instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 200)]),
  ]

  return AccountMultiSelectPicker(accounts: accounts, selectedIds: $selected)
    .frame(width: 320, height: 420)
}
