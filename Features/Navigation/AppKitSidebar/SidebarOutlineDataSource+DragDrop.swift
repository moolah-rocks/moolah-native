#if os(macOS)
  import AppKit

  /// `NSOutlineViewDataSource` drag-and-drop conformance for the
  /// unified sidebar. All policy logic lives in
  /// `SidebarOutlineDropCoordinator`; this file owns the AppKit
  /// surface — pasteboard encode, retarget hint, drop dispatch.
  ///
  /// `pasteboardWriter(forItem:)` returns the dragged
  /// `DraggableSidebarItem`'s JSON-encoded pasteboard item for
  /// account / group rows; everything else is non-draggable.
  ///
  /// `validateDrop` decodes the dragged item, asks the coordinator
  /// for an outcome, calls `setDropItem(_:dropChildIndex:)` for
  /// `.retargetRoot` / `.retargetGroup` outcomes (the visual hint
  /// that converts a near-the-bottom-of-account hover into a real
  /// insertion slot), and returns `.move` for any non-`.deny`
  /// outcome.
  ///
  /// `acceptDrop` re-resolves the outcome (the policy may yield a
  /// different result after the retarget) and dispatches via
  /// `coordinator.commit(_:bucket:)` from a `Task`. Returns `true`
  /// for non-`.deny` outcomes so `NSOutlineView` plays the drop
  /// animation.
  extension SidebarOutlineDataSource {

    func outlineView(
      _ outlineView: NSOutlineView, pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
      guard let row = item as? SidebarRow else { return nil }
      switch row {
      case .account(let id):
        return DraggableSidebarItem(kind: .account, id: id).pasteboardItem()
      case .group(let id):
        return DraggableSidebarItem(kind: .group, id: id).pasteboardItem()
      case .section, .earmark, .total, .navigation:
        return nil
      }
    }

    func outlineView(
      _ outlineView: NSOutlineView,
      validateDrop info: NSDraggingInfo,
      proposedItem item: Any?,
      proposedChildIndex index: Int
    ) -> NSDragOperation {
      guard let coordinator = dropCoordinator else { return [] }
      guard
        let dragged = DraggableSidebarItem.read(from: info.draggingPasteboard)
      else { return [] }
      let proposedRow = item as? SidebarRow
      let outcome = coordinator.outcome(
        forProposedItem: proposedRow, childIndex: index, dragged: dragged)
      switch outcome {
      case .deny:
        return []
      case .retargetRoot(let idx):
        let bucketSection = sectionRow(
          forBucket: inferredBucket(
            forProposedItem: proposedRow, coordinator: coordinator))
        outlineView.setDropItem(bucketSection, dropChildIndex: idx)
        return .move
      case let .retargetGroup(gId, idx):
        outlineView.setDropItem(SidebarRow.group(gId), dropChildIndex: idx)
        return .move
      case .addToGroup, .dropOntoAccount, .reorderRoot, .reorderMembers:
        return .move
      }
    }

    func outlineView(
      _ outlineView: NSOutlineView,
      acceptDrop info: NSDraggingInfo,
      item: Any?,
      childIndex index: Int
    ) -> Bool {
      guard let coordinator = dropCoordinator else { return false }
      guard
        let dragged = DraggableSidebarItem.read(from: info.draggingPasteboard)
      else { return false }
      let proposedRow = item as? SidebarRow
      let outcome = coordinator.outcome(
        forProposedItem: proposedRow, childIndex: index, dragged: dragged)
      guard
        let bucket = inferredBucket(
          forProposedItem: proposedRow, coordinator: coordinator)
      else { return false }
      switch outcome {
      case .deny, .retargetRoot, .retargetGroup:
        return false
      case .addToGroup, .dropOntoAccount, .reorderRoot, .reorderMembers:
        Task { await coordinator.commit(outcome, bucket: bucket) }
        return true
      }
    }

    // MARK: - Helpers

    private func inferredBucket(
      forProposedItem item: SidebarRow?,
      coordinator: SidebarOutlineDropCoordinator
    ) -> AccountBucket? {
      SidebarOutlineDropCoordinator.bucket(
        forProposedItem: item,
        accounts: coordinator.accountStore.accounts,
        groups: coordinator.accountGroupStore.groups)
    }

    private func sectionRow(forBucket bucket: AccountBucket?) -> SidebarRow? {
      switch bucket {
      case .current: return .section(.current)
      case .investments: return .section(.investments)
      case .none: return nil
      }
    }
  }
#endif
