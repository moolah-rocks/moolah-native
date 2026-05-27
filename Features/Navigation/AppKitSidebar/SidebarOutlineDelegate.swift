#if os(macOS)
  import AppKit

  /// `NSOutlineViewDelegate` for the unified sidebar. Produces cell
  /// views via `SidebarCellBuilder`, gates selection (sections and
  /// totals are non-selectable), and emits expand / collapse / selection
  /// notifications back to the controller through callback closures.
  ///
  /// `suppressExpansionCallbacks` lets the controller reconcile expansion
  /// state during a tree refresh without echoing the changes back to the
  /// `GroupUIStateStore` (which would race the data we just applied).
  @MainActor
  final class SidebarOutlineDelegate: NSObject, NSOutlineViewDelegate {
    var cellBuilder: SidebarCellBuilder?
    var selectionChanged: ((SidebarRow?) -> Void)?
    var expansionChanged: ((SidebarRow, Bool) -> Void)?
    var suppressExpansionCallbacks = false

    func outlineView(
      _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
      guard let row = item as? SidebarRow else { return nil }
      return cellBuilder?.makeCell(for: row)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
      guard let row = item as? SidebarRow else { return false }
      if case .section = row { return true }
      return false
    }

    func outlineView(
      _ outlineView: NSOutlineView, shouldSelectItem item: Any
    ) -> Bool {
      guard let row = item as? SidebarRow else { return false }
      switch row {
      case .section, .total: return false
      case .account, .group, .earmark, .navigation: return true
      }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
      guard let outlineView = notification.object as? NSOutlineView else { return }
      let row = outlineView.item(atRow: outlineView.selectedRow) as? SidebarRow
      selectionChanged?(row)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
      guard !suppressExpansionCallbacks,
        let row = notification.userInfo?["NSObject"] as? SidebarRow
      else { return }
      expansionChanged?(row, true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
      guard !suppressExpansionCallbacks,
        let row = notification.userInfo?["NSObject"] as? SidebarRow
      else { return }
      expansionChanged?(row, false)
    }
  }
#endif
