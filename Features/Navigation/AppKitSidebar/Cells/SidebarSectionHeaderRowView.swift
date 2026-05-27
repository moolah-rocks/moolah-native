import SwiftUI

/// Source-list section header used inside the macOS outline. Renders
/// the section title in the standard uppercased secondary style.
/// `onAddAction` shows a trailing "+" button when non-nil; in the
/// current configuration the toolbar carries the add buttons (see
/// `Features/Navigation/SidebarSharedModifiers.swift`), so the factory
/// passes `nil` and no inline `+` appears.
struct SidebarSectionHeaderRowView: View {
  let title: String
  var onAddAction: (() -> Void)?
  var addAccessibilityIdentifier: String?

  var body: some View {
    HStack {
      Text(title)
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Spacer()
      if let onAddAction {
        addButton(action: onAddAction)
      }
    }
  }

  @ViewBuilder
  private func addButton(action: @escaping () -> Void) -> some View {
    let button =
      Button(action: action) {
        Image(systemName: "plus").font(.caption)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Add \(title.lowercased())")
    if let addAccessibilityIdentifier {
      button.accessibilityIdentifier(addAccessibilityIdentifier)
    } else {
      button
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

#Preview("With add button") {
  List {
    Section {
      Text("Row content")
    } header: {
      SidebarSectionHeaderRowView(title: "Earmarks", onAddAction: {})
    }
  }
  .listStyle(.sidebar)
  .frame(width: 260)
}
