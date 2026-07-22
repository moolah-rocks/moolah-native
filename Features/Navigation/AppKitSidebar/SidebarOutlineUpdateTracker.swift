#if os(macOS)
  /// Remembers the last rendered sidebar content so selection-only SwiftUI
  /// updates do not trigger a full `NSOutlineView` reload.
  @MainActor
  final class SidebarOutlineUpdateTracker {
    private var previousContent: SidebarOutlineContent?

    func requiresDataReload(for content: SidebarOutlineContent) -> Bool {
      defer { previousContent = content }
      return previousContent != content
    }
  }
#endif
