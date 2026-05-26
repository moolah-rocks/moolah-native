import SwiftUI

extension ContentView {
  /// Phase 5 placeholder for the composite group detail view. Until
  /// the `AccountViewContext`-driven detail surface lands, the
  /// placeholder shows the group's name and a brief note so the user
  /// has clear feedback that the group is selected.
  @ViewBuilder
  func groupDetailPlaceholder(id: UUID) -> some View {
    if let group = accountGroupStore.by(id: id) {
      ContentUnavailableView(
        group.name,
        systemImage: "folder.fill",
        description: Text(
          "Group details are coming soon. Expand the group in the sidebar to view its members.")
      )
    } else {
      ContentUnavailableView(
        "Group not found",
        systemImage: "folder.badge.questionmark",
        description: Text("This group may not have arrived from sync yet.")
      )
    }
  }
}
