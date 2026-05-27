import Cocoa

// moolah: marked `@MainActor` — see OutlineViewDataSource for
// rationale (Swift 6 / macOS 26 strict concurrency).
@available(macOS 10.15, *)
@MainActor
class OutlineViewDelegate<Data: Sequence>: NSObject, NSOutlineViewDelegate
where Data.Element: Identifiable {
  let content: (Data.Element) -> NSView
  let selectionChanged: (Data.Element?) -> Void
  let separatorInsets: ((Data.Element) -> NSEdgeInsets)?
  var selectedItem: OutlineViewItem<Data>?
  // moolah: optional closure that asks the caller whether a given
  // element should render with NSOutlineView's source-list group-row
  // chrome. Defaults to nil (treat no rows as group rows), preserving
  // upstream behaviour.
  var isGroupItem: ((Data.Element) -> Bool)?
  // moolah: optional callback invoked after a row's expansion state
  // changes (expand or collapse). Used to write back into a caller's
  // `expandedItems` binding so the state can be persisted.
  var expansionChanged: ((Data.Element, Bool) -> Void)?

  func typedItem(_ item: Any) -> OutlineViewItem<Data> {
    item as! OutlineViewItem<Data>
  }

  init(
    content: @escaping (Data.Element) -> NSView,
    selectionChanged: @escaping (Data.Element?) -> Void,
    separatorInsets: ((Data.Element) -> NSEdgeInsets)?
  ) {
    self.content = content
    self.selectionChanged = selectionChanged
    self.separatorInsets = separatorInsets
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    viewFor tableColumn: NSTableColumn?,
    item: Any
  ) -> NSView? {
    content(typedItem(item).value)
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    rowViewForItem item: Any
  ) -> NSTableRowView? {
    if #available(macOS 11.0, *) {
      // Release any unused row views.
      releaseUnusedRowViews(from: outlineView)
      let rowView = AdjustableSeparatorRowView(frame: .zero)
      rowView.separatorInsets = separatorInsets?(typedItem(item).value)
      return rowView
    } else {
      return nil
    }
  }

  // There seems to be a memory leak on macOS 11 where row views returned
  // from `rowViewForItem` are never freed. This hack patches the leak.
  func releaseUnusedRowViews(from outlineView: NSOutlineView) {
    guard #available(macOS 11.0, *) else { return }

    // Equivalent to _rowData._rowViewPurgatory
    let purgatoryPath = unmangle("^qnvC`s`-^qnvUhdvOtqf`snqx")
    if let rowViewPurgatory = outlineView.value(forKeyPath: purgatoryPath) as? NSMutableSet {
      rowViewPurgatory
        .compactMap { $0 as? AdjustableSeparatorRowView }
        .forEach {
          $0.removeFromSuperview()
          rowViewPurgatory.remove($0)
        }
    }
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    heightOfRowByItem item: Any
  ) -> CGFloat {
    // It appears that for outline views with automatic row heights, the
    // initial height of the row still needs to be provided. Not providing
    // a height for each cell would lead to the outline view defaulting to the
    // `outlineView.rowHeight` when inserted. The cell may resize to the correct
    // height if the outline view is reloaded.

    // I am not able to find a better way to compute the final width of the cell
    // other than hard-coding some of the constants.
    let columnHorizontalInset: CGFloat
    if #available(macOS 11.0, *) {
      if outlineView.effectiveStyle == .plain {
        columnHorizontalInset = 18
      } else {
        columnHorizontalInset = 9
      }
    } else {
      columnHorizontalInset = 9
    }

    let column = outlineView.tableColumns.first.unsafelyUnwrapped
    let indentInset = CGFloat(outlineView.level(forItem: item)) * outlineView.indentationPerLevel

    let width = column.width - indentInset - columnHorizontalInset

    // The view is provided by the user. And the width info is not provided
    // separately. It does not seem efficient to create a new cell to find
    // out the width of a cell. In practice I have not experienced any issues
    // with a moderate number of cells.
    let view = content(typedItem(item).value)
    view.widthAnchor.constraint(equalToConstant: width).isActive = true
    return view.fittingSize.height
  }

  // moolah: source-list group-row chrome (capitalised label,
  // secondary text colour, no disclosure on the row itself). Returns
  // false by default so existing callers see no change.
  func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
    isGroupItem?(typedItem(item).value) ?? false
  }

  // moolah: group rows must not be selectable (matches Finder /
  // Mail.app sidebar behaviour and Apple HIG).
  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    !(isGroupItem?(typedItem(item).value) ?? false)
  }

  func outlineViewItemDidExpand(_ notification: Notification) {
    let outlineView = notification.object as! NSOutlineView
    if outlineView.selectedRow == -1 {
      selectRow(for: selectedItem, in: outlineView)
    }
    // moolah: notify the caller's expansion-state binding.
    if let info = NSOutlineView.expansionNotificationInfo(notification) {
      let element = typedItem(info.object).value
      expansionChanged?(element, true)
    }
  }

  // moolah: mirror of `outlineViewItemDidExpand` for collapse so the
  // caller's binding stays in sync on both transitions.
  func outlineViewItemDidCollapse(_ notification: Notification) {
    if let info = NSOutlineView.expansionNotificationInfo(notification) {
      let element = typedItem(info.object).value
      expansionChanged?(element, false)
    }
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    let outlineView = notification.object as! NSOutlineView
    if outlineView.selectedRow != -1 {
      let newSelection = outlineView.item(atRow: outlineView.selectedRow).map(typedItem)
      if selectedItem?.id != newSelection?.id {
        selectedItem = newSelection
        selectionChanged(selectedItem?.value)
      }
    }
  }

  func selectRow(
    for item: OutlineViewItem<Data>?,
    in outlineView: NSOutlineView
  ) {
    // Returns -1 if row is not found.
    let index = outlineView.row(forItem: selectedItem)
    if index != -1 {
      outlineView.selectRowIndexes(IndexSet([index]), byExtendingSelection: false)
    } else {
      outlineView.deselectAll(nil)
    }
  }

  func changeSelectedItem(
    to item: OutlineViewItem<Data>?,
    in outlineView: NSOutlineView
  ) {
    guard selectedItem?.id != item?.id else { return }
    selectedItem = item
    selectRow(for: selectedItem, in: outlineView)
  }
}
