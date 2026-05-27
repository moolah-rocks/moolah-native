import SwiftUI

/// Sidebar total row used inside the macOS outline. Mirrors
/// `SidebarView.totalRow(label:value:)` so the unified outline renders
/// totals identically to the iOS list path.
///
/// `emphasised` swaps the secondary `.callout` style for a primary
/// `.headline` style — used for "Available Funds" and "Net Worth"
/// (mirrors the existing `totalsSection` body in
/// `Features/Navigation/SidebarView+Sections.swift`).
struct SidebarTotalRowView: View {
  let label: String
  let amount: InstrumentAmount?
  var emphasised: Bool = false

  var body: some View {
    LabeledContent(label) {
      if let amount {
        InstrumentAmountView(amount: amount)
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .foregroundStyle(emphasised ? .primary : .secondary)
    .font(emphasised ? .headline : .callout)
  }
}

#Preview {
  List {
    SidebarTotalRowView(
      label: "Current Total",
      amount: InstrumentAmount(quantity: 1234.56, instrument: .AUD))
    SidebarTotalRowView(
      label: "Net Worth",
      amount: InstrumentAmount(quantity: 50000, instrument: .AUD),
      emphasised: true)
    SidebarTotalRowView(label: "Loading", amount: nil)
  }
  .listStyle(.sidebar)
  .frame(width: 260)
}
