import SwiftUI

/// Sidebar row for an `AccountGroup`. Composes a chevron disclosure
/// affordance (toggling `isExpanded`) plus the shared `SidebarRowView`
/// for the icon / name / amount. Aggregated balance is supplied by the
/// caller — the sidebar wraps each group row in
/// `GroupAggregateBalanceLoader` which keeps the aggregate refreshed
/// via `AccountStore.aggregateBalance(for:in:)`; this row itself just
/// renders whatever it's given (or shows a spinner if `nil`).
///
/// Inline rename, selection styling, and identifier wiring follow the
/// account-row conventions so context menus / Return-to-rename / the
/// shared row component continue to work uniformly.
struct AccountGroupSidebarRow: View {
  let group: AccountGroup
  /// `true` when the group row itself is the current selection.
  var isSelected: Bool = false
  /// Two-way binding to the in-memory expand state for this group.
  /// Toggling fires only the chevron; clicking the row label still
  /// selects the group (the NavigationLink wraps the entire row).
  @Binding var isExpanded: Bool
  /// Aggregated balance to render in the row. `nil` shows a spinner —
  /// Phase 5 will compute this from member positions; for Phase 4 the
  /// row simply forwards what the caller provides.
  var aggregateBalance: InstrumentAmount?
  /// Inline-rename plumbing — same shape as account / earmark rows.
  var isEditing: Binding<Bool>?
  var onRename: ((String) -> Void)?

  var body: some View {
    HStack(spacing: 4) {
      disclosureChevron
      SidebarRowView(
        icon: "folder.fill",
        name: group.name,
        amount: aggregateBalance,
        isSelected: isSelected,
        isEditing: isEditing,
        onRename: onRename
      )
    }
  }

  /// Manual chevron toggling expand state. Button styled `.plain` so
  /// it doesn't visually compete with the row's selection highlight;
  /// `accessibilityHidden` because expand/collapse is exposed via the
  /// row's combined VoiceOver label below.
  private var disclosureChevron: some View {
    Button {
      isExpanded.toggle()
    } label: {
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 12)
    }
    .buttonStyle(.plain)
    .accessibilityHidden(true)
  }
}

#Preview("Group row — collapsed") {
  @Previewable @State var expanded = false
  return List(selection: .constant(Optional("group"))) {
    AccountGroupSidebarRow(
      group: AccountGroup(
        name: "Trust Fund Crypto",
        bucket: .investments,
        instrument: .AUD,
        position: 0),
      isSelected: false,
      isExpanded: $expanded,
      aggregateBalance: InstrumentAmount(quantity: 42180, instrument: .AUD)
    )
    .tag("group")
  }
  .listStyle(.sidebar)
  .frame(width: 260)
}

#Preview("Group row — expanded + selected") {
  @Previewable @State var expanded = true
  return List(selection: .constant(Optional("group"))) {
    AccountGroupSidebarRow(
      group: AccountGroup(
        name: "Personal Crypto",
        bucket: .investments,
        instrument: .AUD,
        position: 1),
      isSelected: true,
      isExpanded: $expanded,
      aggregateBalance: InstrumentAmount(quantity: 8920, instrument: .AUD)
    )
    .tag("group")
  }
  .listStyle(.sidebar)
  .frame(width: 260)
}

#Preview("Group row — balance loading") {
  @Previewable @State var expanded = false
  return List(selection: .constant(Optional("group"))) {
    AccountGroupSidebarRow(
      group: AccountGroup(
        name: "Pending",
        bucket: .investments,
        instrument: .AUD,
        position: 0),
      isSelected: false,
      isExpanded: $expanded,
      aggregateBalance: nil
    )
    .tag("group")
  }
  .listStyle(.sidebar)
  .frame(width: 260)
}
