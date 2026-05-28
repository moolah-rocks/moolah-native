import SwiftUI

/// TextField used by `SidebarRowView` while a row is in inline-rename
/// mode. Auto-focuses on appear; commits on Return or focus loss (calls
/// `onCommit`); cancels on Escape (calls `onCancel`). Extracted into its
/// own type so the `@FocusState` + `@State` text buffer are scoped to
/// the editing lifecycle (they reset naturally when the field unmounts)
/// without leaking into `SidebarRowView`'s state.
private struct InlineRenameField: View {
  let initialText: String
  let onCommit: (String) -> Void
  let onCancel: () -> Void

  @State private var text: String = ""
  @State private var didCommit = false
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField("Name", text: $text)
      .accessibilityLabel("Name")
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.renameNameField)
      .textFieldStyle(.plain)
      .focused($isFocused)
      .onAppear {
        text = initialText
        isFocused = true
      }
      .onSubmit {
        didCommit = true
        onCommit(text)
      }
      .onChange(of: isFocused) { _, focused in
        // Focus loss without an explicit submit = commit (matches
        // Finder-style rename). The didCommit guard prevents a
        // double call when Return triggers onSubmit -> drop focus.
        if !focused {
          if !didCommit { onCommit(text) }
          didCommit = false
        }
      }
      .onKeyPress(.escape) {
        onCancel()
        return .handled
      }
  }
}

/// Shared row view for sidebar items (accounts, earmarks) that displays
/// an icon, name, and balance with selection-aware color coding.
/// When `isSelected` is true and the selection background is prominent
/// (focused sidebar), uses hand-tuned bright greens/reds instead of
/// `.green` / `.red` so the amount stays legible against the saturated
/// blue selection highlight. System colours `.mint` / `.pink` were tried
/// and rejected — too desaturated. See
/// guides/UI_GUIDE.md §5 "Selected-Row Contrast Override (Exception)"
/// for the rationale and the rule that this is the only place in the
/// app where hardcoded RGB values are permitted.
///
/// **Inline rename:** when both `isEditing` and `onRename` are provided,
/// the row supports double-click-to-rename. Without those properties the
/// row installs no double-click handler.
struct SidebarRowView: View {
  let icon: String
  let name: String
  let amount: InstrumentAmount?
  var isSelected: Bool = false
  /// When non-nil, the row replaces the amount with this short label
  /// (e.g. "Not set") and the accompanying VoiceOver phrase. Used by
  /// `AccountSidebarRow` for recorded-value investment accounts that have
  /// no recorded snapshot, so the sidebar doesn't roll a synthetic `$0` into
  /// the user's mental model of the column. See guides/UI_GUIDE.md §"Not set"
  /// and `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 for the rationale.
  var unsetIndicator: String?
  /// Optional secondary text rendered below the name, in `.caption` /
  /// `.secondary`. Used by member rows under a group to surface chain
  /// / wallet-address / exchange-provider context so the user can pick
  /// the right member for reconciliation.
  var secondaryText: String?
  /// When non-nil, the row supports inline rename. The caller flips
  /// `isEditing.wrappedValue` to true (via double-click, context menu,
  /// or keyboard shortcut). The row renders a `TextField` instead of
  /// `Text(name)` while editing; on commit (Return / focus loss) it
  /// calls `onRename` with the entered text (trimmed by the store).
  /// On Escape, it sets `isEditing` to false without calling `onRename`.
  /// Caller is responsible for ensuring only one row is editing at a
  /// time — there is no global coordination inside this view.
  var isEditing: Binding<Bool>?
  var onRename: ((String) -> Void)?

  @Environment(\.backgroundProminence) private var backgroundProminence

  /// Hand-tuned bright greens/reds that contrast well against the blue
  /// selection highlight. Documented exception to the "system colours
  /// only" rule in guides/UI_GUIDE.md §5.
  private static let selectedPositiveColor = Color(red: 0.55, green: 1.0, blue: 0.65)
  private static let selectedNegativeColor = Color(red: 1.0, green: 0.6, blue: 0.6)

  private var amountColorOverride: Color? {
    // Only use bright overrides when the row has a prominent (blue) selection
    // background. When the sidebar is unfocused the background is grey and
    // standard green/red are more readable.
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
    .modifier(
      SidebarRowAccessibility(
        isEditing: isEditing?.wrappedValue == true,
        summary: accessibilitySummary))
  }

  @ViewBuilder private var nameContent: some View {
    VStack(alignment: .leading, spacing: 1) {
      nameLabel
      if let secondaryText, !secondaryText.isEmpty {
        Text(secondaryText)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var nameLabel: some View {
    if let isEditing, let onRename, isEditing.wrappedValue {
      InlineRenameField(
        initialText: name,
        onCommit: { committed in
          isEditing.wrappedValue = false
          onRename(committed)
        },
        onCancel: { isEditing.wrappedValue = false }
      )
    } else if let isEditing, onRename != nil, isSelected {
      // Finder pattern: rename gesture only attaches once the row is
      // selected. Attaching `.onTapGesture(count: 2)` on an unselected
      // row's Text makes SwiftUI hold the first click waiting for a
      // second, which prevents the parent NavigationLink from receiving
      // the click and updating selection.
      Text(name)
        .onTapGesture(count: 2) { isEditing.wrappedValue = true }
    } else {
      Text(name)
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

/// Accessibility wrapper for `SidebarRowView`. When the row is in
/// inline-rename mode, exposes children as individual accessibility
/// elements (`.contain`) so XCUITest and VoiceOver can resolve the
/// inline `TextField` by its `renameNameField` identifier. When the
/// row is static, collapses the children into a single element
/// labelled with `summary` (`.ignore` + `accessibilityLabel`) so
/// VoiceOver reads the row as one logical item
/// ("Checking, -$1,234.56") rather than navigating each subview.
private struct SidebarRowAccessibility: ViewModifier {
  let isEditing: Bool
  let summary: String

  func body(content: Content) -> some View {
    if isEditing {
      content
        .accessibilityElement(children: .contain)
    } else {
      content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }
  }
}

/// Sidebar row for an account. Reads the converted balance from
/// `AccountStore.convertedBalances` (populated and retried by the store
/// when conversions fail). Shows a spinner while no balance is available.
///
/// Recorded-value investment accounts with no externally-set value render
/// "Not set" instead of `$0` once the initial conversion pass has completed
/// — `$0` would be indistinguishable from "user entered zero" and would
/// roll into net-worth as a real number rather than a missing one. See
/// `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 and the design note in
/// `plans/per-account-valuation-mode.md`.
struct AccountSidebarRow: View {
  let account: Account
  var isSelected: Bool = false
  /// When `true`, the row is rendered as a group member: a short
  /// secondary line (chain / wallet address / exchange provider)
  /// appears under the name. The indentation itself is supplied by the
  /// container — this flag toggles only the secondary line.
  var isMember: Bool = false
  var isEditing: Binding<Bool>?
  var onRename: ((String) -> Void)?
  @Environment(AccountStore.self) private var accountStore

  var body: some View {
    SidebarRowView(
      icon: account.sidebarIcon,
      name: account.name,
      amount: accountStore.convertedBalances[account.id],
      isSelected: isSelected,
      unsetIndicator: accountStore.hasUnrecordedValue(account) ? "Not set" : nil,
      secondaryText: isMember ? memberSecondaryText : nil,
      isEditing: isEditing,
      onRename: onRename
    )
  }

  /// Truncated wallet address / exchange provider / nothing — what's
  /// useful as a glance-able subtitle when the account is shown as a
  /// member under a group row.
  private var memberSecondaryText: String? {
    switch account.type {
    case .crypto:
      if let address = account.walletAddress, !address.isEmpty {
        return Self.shortAddress(address)
      }
      return nil
    case .exchange:
      return account.exchangeProvider?.displayName
    case .bank, .creditCard, .asset, .investment:
      return nil
    }
  }

  /// Returns a `0xABCD…1234`-style short address. Truncates the middle
  /// while keeping the `0x` prefix + 4 chars + ellipsis + last 4 chars
  /// — enough to disambiguate at a glance without taking sidebar width.
  private static func shortAddress(_ address: String) -> String {
    guard address.count > 12 else { return address }
    let prefix = address.prefix(6)
    let suffix = address.suffix(4)
    return "\(prefix)…\(suffix)"
  }
}

#Preview {
  List(selection: .constant(Optional("selected"))) {
    SidebarRowView(
      icon: "building.columns",
      name: "Bank Account (selected)",
      amount: InstrumentAmount(quantity: 1234.56, instrument: .AUD),
      isSelected: true
    )
    .tag("selected")

    SidebarRowView(
      icon: "bookmark.fill",
      name: "Holiday Fund",
      amount: InstrumentAmount(quantity: 1500.00, instrument: .AUD)
    )
    .tag("other1")

    SidebarRowView(
      icon: "creditcard",
      name: "Credit Card",
      amount: InstrumentAmount(quantity: -500.00, instrument: .AUD)
    )
    .tag("other2")
  }
  .listStyle(.sidebar)
}

#Preview("Sidebar row — negative balance selected") {
  List(selection: .constant(Optional("selected"))) {
    SidebarRowView(
      icon: "creditcard",
      name: "Credit Card (selected)",
      amount: InstrumentAmount(quantity: -500.00, instrument: .AUD),
      isSelected: true
    )
    .tag("selected")
  }
  .listStyle(.sidebar)
}

#Preview("Sidebar row — Not set indicator") {
  List(selection: .constant(Optional("loaded"))) {
    SidebarRowView(
      icon: "chart.line.uptrend.xyaxis",
      name: "Brokerage (no value)",
      amount: InstrumentAmount(quantity: 0, instrument: .AUD),
      unsetIndicator: "Not set"
    )
    .tag("loaded")

    SidebarRowView(
      icon: "chart.line.uptrend.xyaxis",
      name: "Brokerage (loading)",
      amount: nil
    )
    .tag("loading")
  }
  .listStyle(.sidebar)
}

#Preview("Sidebar row — selected, dark mode") {
  List(selection: .constant(Optional("selected"))) {
    SidebarRowView(
      icon: "building.columns",
      name: "Bank Account (selected)",
      amount: InstrumentAmount(quantity: 1234.56, instrument: .AUD),
      isSelected: true
    )
    .tag("selected")

    SidebarRowView(
      icon: "creditcard",
      name: "Credit Card",
      amount: InstrumentAmount(quantity: -500.00, instrument: .AUD),
      isSelected: true
    )
    .tag("other")
  }
  .listStyle(.sidebar)
  .preferredColorScheme(.dark)
}

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
