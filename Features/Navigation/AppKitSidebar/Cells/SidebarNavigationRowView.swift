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
  }

  private var accessibilityLabel: String {
    badgeCount > 0 ? "\(title), \(badgeCount) need review" : title
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
