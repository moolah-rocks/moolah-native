import Cocoa

@available(macOS 10.15, *)
public class OutlineViewController<Data: Sequence, Drop: DropReceiver>: NSViewController
where Drop.DataElement == Data.Element {
  // moolah: raised from `internal` to `public` so callers in the
  // hosting module (Moolah_macOS) can drive expand / collapse and
  // read the underlying view for accessibility identifiers. Required
  // for restoring expansion state from GroupUIStateStore.
  public let outlineView = NSOutlineView()
  let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))

  let dataSource: OutlineViewDataSource<Data, Drop>
  let delegate: OutlineViewDelegate<Data>
  let updater = OutlineViewUpdater<Data>()

  let childrenSource: ChildSource<Data>

  init(
    data: Data,
    childrenSource: ChildSource<Data>,
    content: @escaping (Data.Element) -> NSView,
    selectionChanged: @escaping (Data.Element?) -> Void,
    separatorInsets: ((Data.Element) -> NSEdgeInsets)?
  ) {
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalRuler = true
    scrollView.drawsBackground = false
    // moolah: clear the scroll view + outline view backgrounds so the
    // host SwiftUI sidebar material (vibrancy) shows through. Default
    // AppKit chrome paints `controlBackgroundColor` here, which
    // appears as an opaque off-colour band against a `.listStyle(.sidebar)`
    // List that hosts this view.
    scrollView.backgroundColor = .clear
    // moolah: NSScrollView delegates its contentView (an `NSClipView`)
    // to paint the visible region's backdrop; its `drawsBackground`
    // defaults to `true` and paints `controlBackgroundColor`, which is
    // the actual source of the opaque grey "band" the user sees around
    // the outline rows when this view is embedded inside a SwiftUI
    // `List(.sidebar)`. Clearing it lets the host sidebar material
    // (vibrancy) show through the entire outline region — not just the
    // outline view itself.
    scrollView.contentView.drawsBackground = false
    if let clipView = scrollView.contentView as NSClipView? {
      clipView.backgroundColor = .clear
    }
    outlineView.backgroundColor = .clear
    // moolah: belt-and-braces — disable AppKit's default row-stripe
    // and grid chrome that would paint over the host SwiftUI sidebar
    // material. `selectionHighlightStyle = .regular` is the modern
    // replacement for the deprecated `.sourceList` style; combined
    // with `usesAlternatingRowBackgroundColors = false` and an empty
    // gridStyleMask, no per-row backdrop is painted unless a row is
    // actually selected.
    outlineView.selectionHighlightStyle = .regular
    outlineView.usesAlternatingRowBackgroundColors = false
    outlineView.gridStyleMask = []
    // moolah: tighten the per-row internal spacing — SwiftUI's
    // `List(.sidebar)` rows have ~28pt heights with tight intercell
    // spacing. Default `(3, 2)` adds a visible gap between rows that
    // doesn't match the host List.
    outlineView.intercellSpacing = NSSize(width: 0, height: 0)
    outlineView.autoresizesOutlineColumn = false
    outlineView.headerView = nil
    outlineView.usesAutomaticRowHeights = true
    outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

    let onlyColumn = NSTableColumn()
    onlyColumn.resizingMask = .autoresizingMask
    outlineView.addTableColumn(onlyColumn)

    dataSource = OutlineViewDataSource(
      items: data.map { OutlineViewItem(value: $0, children: childrenSource) },
      childSource: childrenSource
    )
    delegate = OutlineViewDelegate(
      content: content,
      selectionChanged: selectionChanged,
      separatorInsets: separatorInsets)
    outlineView.dataSource = dataSource
    outlineView.delegate = delegate

    self.childrenSource = childrenSource

    super.init(nibName: nil, bundle: nil)

    view.addSubview(scrollView)
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    return nil
  }

  public override func loadView() {
    view = NSView()
  }

  public override func viewWillAppear() {
    // Size the column to take the full width. This combined with
    // the uniform column autoresizing style allows the column to
    // adjust its width with a change in width of the outline view.
    outlineView.sizeLastColumnToFit()
    super.viewWillAppear()
  }
}

// MARK: - Performing updates
@available(macOS 10.15, *)
extension OutlineViewController {
  func updateData(newValue: Data) {
    let newState = newValue.map { OutlineViewItem(value: $0, children: childrenSource) }

    outlineView.beginUpdates()

    dataSource.items = newState
    updater.performUpdates(
      outlineView: outlineView,
      oldStateTree: dataSource.treeMap,
      newState: newState,
      parent: nil)

    outlineView.endUpdates()

    // After updates, dataSource must rebuild its idTree for future updates
    dataSource.rebuildIDTree(rootItems: newState, outlineView: outlineView)
  }

  func changeSelectedItem(to item: Data.Element?) {
    delegate.changeSelectedItem(
      to: item.map { OutlineViewItem(value: $0, children: childrenSource) },
      in: outlineView)
  }

  @available(macOS 11.0, *)
  func setStyle(to style: NSOutlineView.Style) {
    outlineView.style = style
  }

  func setIndentation(to width: CGFloat) {
    outlineView.indentationPerLevel = width
  }

  func setRowSeparator(visibility: SeparatorVisibility) {
    switch visibility {
    case .hidden:
      outlineView.gridStyleMask = []
    case .visible:
      outlineView.gridStyleMask = .solidHorizontalGridLineMask
    }
  }

  func setRowSeparator(color: NSColor) {
    guard color != outlineView.gridColor else {
      return
    }

    outlineView.gridColor = color
    outlineView.reloadData()
  }

  func setDragSourceWriter(_ writer: DragSourceWriter<Data.Element>?) {
    dataSource.dragWriter = writer
  }

  func setDropReceiver(_ receiver: Drop?) {
    dataSource.dropReceiver = receiver
  }

  func setAcceptedDragTypes(_ acceptedTypes: [NSPasteboard.PasteboardType]?) {
    outlineView.unregisterDraggedTypes()
    if let acceptedTypes,
      !acceptedTypes.isEmpty
    {
      outlineView.registerForDraggedTypes(acceptedTypes)
    }
  }

  // moolah: install the caller's `isGroupItem` closure on the
  // delegate. Called from `OutlineView.updateNSViewController` so the
  // closure can capture fresh state on each SwiftUI update.
  func setIsGroupItem(_ isGroupItem: ((Data.Element) -> Bool)?) {
    delegate.isGroupItem = isGroupItem
  }

  // moolah: install the caller's expansion-change callback. Called
  // by `OutlineView.updateNSViewController` to feed expand /
  // collapse events back into the bound `Set<Element.ID>`.
  func setExpansionChanged(_ handler: ((Data.Element, Bool) -> Void)?) {
    delegate.expansionChanged = handler
  }

  // moolah: reconcile the NSOutlineView's current expansion state
  // with `expandedIDs`. Items in the set but not currently expanded
  // get expanded; items currently expanded but not in the set get
  // collapsed. We suppress the expansion callback during this
  // reconciliation so the caller's binding does not feed back into
  // itself.
  func applyExpandedItems(_ expandedIDs: Set<Data.Element.ID>) {
    // Snapshot then nil-out the callback so notifications fired
    // during expand / collapse do not write back into the binding
    // that triggered this call. Restored at exit.
    let saved = delegate.expansionChanged
    delegate.expansionChanged = nil
    defer { delegate.expansionChanged = saved }

    for item in dataSource.items {
      applyExpansion(item: item, expandedIDs: expandedIDs)
    }
  }

  private func applyExpansion(
    item: OutlineViewItem<Data>,
    expandedIDs: Set<Data.Element.ID>
  ) {
    let shouldExpand = expandedIDs.contains(item.id)
    let isExpanded = outlineView.isItemExpanded(item)
    if shouldExpand, !isExpanded {
      outlineView.expandItem(item)
    } else if !shouldExpand, isExpanded {
      outlineView.collapseItem(item)
    }
    // Recurse into children so nested groups are reconciled too.
    if let children = item.children {
      for child in children {
        applyExpansion(item: child, expandedIDs: expandedIDs)
      }
    }
  }
}
