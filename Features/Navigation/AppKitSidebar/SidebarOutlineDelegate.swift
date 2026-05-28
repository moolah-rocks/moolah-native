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
    /// Fired when the user requests "rename current selection" via a
    /// keyboard / menu trigger. The receiver (`SidebarOutline`) is
    /// expected to map the current selection to its row id and flip
    /// `editingRowId`.
    var beginRenameRequested: (() -> Void)?
    /// Strong reference to the drop coordinator. The data source holds
    /// it weakly to break the controller <-> data source <-> coordinator
    /// cycle; this property anchors the coordinator's lifetime to the
    /// controller's. The delegate is the natural owner because it lives
    /// for the entire controller lifetime and never changes identity
    /// across SwiftUI updates (`cellBuilder` is the only field that does).
    var coordinatorRetainBox: SidebarOutlineDropCoordinator?
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
