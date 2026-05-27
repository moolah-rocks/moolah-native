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

  // moolah: removed upstream's custom `heightOfRowByItem:` implementation.
  //
  // Upstream allocated a *fresh* `NSHostingView`-bearing cell on every
  // height query just to read its `fittingSize.height`. Under XCUITest,
  // AppKit's accessibility instrumentation forces a full-tree row-height
  // scan inside `NSOutlineView.endUpdates`, calling this delegate method
  // for rows that the in-flight diff has already removed from the data
  // source. The freshly built `NSHostingView` then tried to resolve the
  // SwiftUI environment chain (e.g. `@Environment(AccountStore.self)` on
  // `AccountSidebarRow`) against an item whose backing record has been
  // dropped — the resulting use-after-free dispatched through a freed
  // pointer and crashed inside `_safeSendDelegateHeightOfRow:`. Manual
  // (non-XCUITest) launches survived because AppKit only queries heights
  // for visible rows there, not the full tree.
  //
  // `OutlineViewController` configures `outlineView.usesAutomaticRowHeights
  // = true`, so AppKit derives the row height from each cell view's
  // intrinsic content size on first display. Not implementing the
  // delegate optional means AppKit falls back to that automatic path
  // entirely — heights resolve once the cell is realised, which is the
  // semantics we actually want for SwiftUI-hosted rows.

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
