import SwiftUI

/// Sidebar navigation row used inside the macOS outline. Mirrors the
/// existing iOS `NavigationLink(value:) { Label(...) }` rows in
/// `navigationSection` (Features/Navigation/SidebarView+Sections.swift),
/// plus the unread-badge styling from
/// `SidebarView.recentlyAddedLabel`.
struct SidebarNavigationRowView: View {
  let title: String
  let systemImage: String
  var badgeCount: Int = 0
  var isSelected = false

  var body: some View {
    HStack {
      Label(title, systemImage: systemImage)
      Spacer()
      if badgeCount > 0 {
        Text("\(badgeCount)")
          .font(.caption)
          .monospacedDigit()
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.tint, in: Capsule())
          .foregroundStyle(.white)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var accessibilityLabel: String {
    guard badgeCount > 0 else { return title }
    let reviewDescription =
      badgeCount == 1
      ? "1 recently imported transaction needs a category"
      : "\(badgeCount) recently imported transactions need categories"
    return "\(title), \(reviewDescription)"
  }
}

#Preview {
  List {
    SidebarNavigationRowView(title: "Analysis", systemImage: "chart.bar.xaxis")
    SidebarNavigationRowView(title: "Reports", systemImage: "chart.bar.fill")
    SidebarNavigationRowView(
      title: "Recently Added", systemImage: "tray.full", badgeCount: 3)
  }
  .listStyle(.sidebar)
  .frame(width: 260)
}
