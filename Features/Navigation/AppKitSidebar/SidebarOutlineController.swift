#if os(macOS)
  import AppKit

  /// `NSViewController` owning the single `NSOutlineView` that drives
  /// the entire macOS sidebar. The outline lives inside an
  /// `NSScrollView`; the scroll view fills the controller's view via
  /// auto-layout so the sidebar gets a single, full-bleed scrollbar
  /// (replacing the per-section scrollbars from the earlier hybrid
  /// `SidebarOutlineView` design).
  ///
  /// `apply(tree:expandedGroupIds:selection:)` replaces the current
  /// snapshot, reloads the outline, and reconciles expand + selection
  /// state — invoked by `SidebarOutline.updateNSViewController` on
  /// every SwiftUI update. Expansion-callback echo is suppressed during
  /// the reconcile so persisted state is the source of truth, never the
  /// reload-induced collapse/expand events.
  @MainActor
  final class SidebarOutlineController: NSViewController {
    let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    let dataSource = SidebarOutlineDataSource()
    let delegate = SidebarOutlineDelegate()

    override func loadView() {
      view = NSView()
      configureOutlineView()
      configureScrollView()
      installScrollView()
    }

    private func configureOutlineView() {
      outlineView.style = .sourceList
      outlineView.headerView = nil
      outlineView.autoresizesOutlineColumn = false
      outlineView.usesAutomaticRowHeights = true
      outlineView.floatsGroupRows = true
      outlineView.allowsMultipleSelection = false
      outlineView.allowsEmptySelection = true
      outlineView.intercellSpacing = NSSize(width: 0, height: 0)

      let column = NSTableColumn()
      column.resizingMask = .autoresizingMask
      outlineView.addTableColumn(column)
      outlineView.outlineTableColumn = column

      outlineView.dataSource = dataSource
      outlineView.delegate = delegate
    }

    private func configureScrollView() {
      scrollView.documentView = outlineView
      scrollView.hasVerticalScroller = true
      scrollView.hasHorizontalScroller = false
      scrollView.drawsBackground = false
      scrollView.backgroundColor = .clear
      scrollView.contentView.drawsBackground = false
      scrollView.contentView.backgroundColor = .clear
      scrollView.scrollerStyle = .overlay
    }

    private func installScrollView() {
      scrollView.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(scrollView)
      NSLayoutConstraint.activate([
        scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        scrollView.topAnchor.constraint(equalTo: view.topAnchor),
        scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
    }

    /// Replaces the current tree, reloads, and reconciles expansion +
    /// selection. Called by `SidebarOutline.updateNSViewController` on
    /// every SwiftUI update — the snapshot includes the freshly built
    /// `SidebarRowTree.Result`, the persisted set of expanded group ids,
    /// and the current selection.
    func apply(
      tree: SidebarRowTree.Result,
      expandedGroupIds: Set<UUID>,
      selection: SidebarSelection?
    ) {
      dataSource.tree = tree
      outlineView.reloadData()

      delegate.suppressExpansionCallbacks = true
      defer { delegate.suppressExpansionCallbacks = false }

      // Section headers are always expanded — we never give the user a
      // way to collapse them. expand them after every reload so children
      // remain visible.
      for root in tree.roots {
        outlineView.expandItem(root)
      }

      // Reconcile per-group expand state against the store-supplied set.
      for root in tree.roots {
        for child in tree.children(of: root) {
          guard case .group(let id) = child else { continue }
          if expandedGroupIds.contains(id) {
            outlineView.expandItem(child)
          } else {
            outlineView.collapseItem(child)
          }
        }
      }

      reconcileSelection(selection)
    }

    private func reconcileSelection(_ selection: SidebarSelection?) {
      guard let selection, let row = SidebarRow(selection: selection) else {
        outlineView.deselectAll(nil)
        return
      }
      let index = outlineView.row(forItem: row)
      if index >= 0 {
        outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      } else {
        outlineView.deselectAll(nil)
      }
    }
  }
#endif
