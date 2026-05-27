#if os(macOS)
  import AppKit

  /// `NSOutlineViewDataSource` for the unified sidebar. Reads a
  /// `SidebarRowTree.Result` snapshot — child counts and child items
  /// come from `children(of:)`; root items come from `roots`. Expandable
  /// rows are reported by `isExpandable(_:)`, which short-circuits to
  /// `false` for empty groups so the disclosure triangle does not flash.
  ///
  /// `NSOutlineView` hands its data-source / delegate `item: Any?` values
  /// that originated from one of our `child(_:ofItem:)` returns. We use
  /// `SidebarRow` directly as that `Any` payload — `Hashable` value
  /// equality is enough; the outline doesn't need a class identity.
  @MainActor
  final class SidebarOutlineDataSource: NSObject, NSOutlineViewDataSource {
    var tree: SidebarRowTree.Result = .empty

    func outlineView(
      _ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?
    ) -> Int {
      guard let row = item as? SidebarRow else { return tree.roots.count }
      return tree.children(of: row).count
    }

    func outlineView(
      _ outlineView: NSOutlineView, child index: Int, ofItem item: Any?
    ) -> Any {
      guard let row = item as? SidebarRow else { return tree.roots[index] }
      return tree.children(of: row)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
      guard let row = item as? SidebarRow else { return false }
      return tree.isExpandable(row)
    }
  }

#endif
