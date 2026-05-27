import SwiftUI

/// Source-list section header used inside the macOS outline. Renders
/// the section title in the standard uppercased secondary style. The
/// toolbar carries the section add buttons (see
/// `Features/Navigation/SidebarSharedModifiers.swift`), so this header
/// is title-only.
struct SidebarSectionHeaderRowView: View {
  let title: String

  var body: some View {
    HStack {
      Text(title)
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Spacer()
    }
  }
}

#Preview("Plain") {
  List {
    Section {
      Text("Row content")
    } header: {
      SidebarSectionHeaderRowView(title: "Current Accounts")
    }
  }
  .listStyle(.sidebar)
  .frame(width: 260)
}
