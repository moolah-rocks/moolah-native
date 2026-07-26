#if os(macOS)
  import Observation
  import SwiftUI

  /// Selection shared by the AppKit outline and its independently hosted
  /// SwiftUI cells. Keeping this observable lets selected-row styling update
  /// in place instead of asking `NSOutlineView` to replace the affected cells.
  @MainActor
  @Observable
  final class SidebarSelectionState {
    var selection: SidebarSelection?

    init(selection: SidebarSelection? = nil) {
      self.selection = selection
    }
  }

  /// Re-evaluates hosted row content when `SidebarSelectionState` changes.
  /// The cell remains installed at the table column's width, so its trailing
  /// spacer cannot collapse during a selection-only update.
  struct SelectionAwareSidebarRow<Content: View>: View {
    let selectionState: SidebarSelectionState
    let rowSelection: SidebarSelection
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
      content(selectionState.selection == rowSelection)
    }
  }
#endif
