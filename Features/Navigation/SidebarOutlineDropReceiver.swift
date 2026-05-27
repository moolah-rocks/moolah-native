#if os(macOS)
  import AppKit
  import Foundation

  /// `DropReceiver` for the macOS `SidebarOutlineView` — one instance
  /// per bucket. Sits between the vendored `OutlineView` package's
  /// pasteboard protocol and the shared `SidebarDropDispatch` helper
  /// that owns the actual mutation primitives.
  ///
  /// The whole policy ("which drops are allowed, and what do they map
  /// to") lives in the static `outcome(for:bucket:accounts:groups:)`
  /// function — a pure transform over a `DropTarget`, the bucket, and
  /// the current store snapshots. `validateDrop` / `acceptDrop` route
  /// through it so unit tests can hit every row of the decision table
  /// without spinning up a live `NSOutlineView`. The store-touching
  /// dispatch happens only inside `acceptDrop`, where each valid case
  /// fires a `Task { try? await … }` against `SidebarDropDispatch`.
  /// Fire-and-forget is correct here: the dispatch helpers already
  /// surface their own errors via the underlying stores' `error`
  /// property, the `OutlineView` callback is synchronous, and a
  /// failure-state hover from AppKit's perspective is `false` (drag
  /// snaps back). Awaiting inside `acceptDrop` would force the whole
  /// receiver protocol async, which the vendored package does not
  /// support.
  ///
  /// `@MainActor` because every read of `accountStore.accounts` and
  /// `accountGroupStore.groups` is main-actor-isolated and the dispatch
  /// `Task`s inherit the receiver's isolation.
  @MainActor
  struct SidebarOutlineDropReceiver: @MainActor DropReceiver {
    typealias DataElement = SidebarOutlineItem

    let bucket: AccountBucket
    let accountStore: AccountStore
    let accountGroupStore: AccountGroupStore
    let groupUIStateStore: GroupUIStateStore

    func readPasteboard(item: NSPasteboardItem) -> DraggedItem<SidebarOutlineItem>? {
      guard let payload = DraggableSidebarItem.read(from: item) else { return nil }
      let kind: SidebarOutlineItem.Kind =
        switch payload.kind {
        case .account: .account(payload.id)
        case .group: .group(payload.id)
        }
      return (
        SidebarOutlineItem(kind: kind, children: nil),
        DraggableSidebarItem.pasteboardType
      )
    }

    func validateDrop(
      target: DropTarget<SidebarOutlineItem>
    ) -> ValidationResult<SidebarOutlineItem> {
      let outcome = Self.outcome(
        for: target,
        bucket: bucket,
        accounts: accountStore.accounts,
        groups: accountGroupStore.groups)
      return outcome.asValidationResult()
    }

    func acceptDrop(target: DropTarget<SidebarOutlineItem>) -> Bool {
      let outcome = Self.outcome(
        for: target,
        bucket: bucket,
        accounts: accountStore.accounts,
        groups: accountGroupStore.groups)
      // Retargets are validate-time hints to NSOutlineView; AppKit
      // re-fires validate against the new target and we accept on the
      // second pass.
      switch outcome {
      case .deny, .retargetRoot, .retargetGroup: return false
      case let .addToGroup(sourceId, gId): dispatchAddToGroup(sourceId, gId)
      case let .dropOntoAccount(sourceId, targetId):
        dispatchDropOntoAccount(sourceId, targetId)
      case let .reorderRoot(item, idx): dispatchReorderRoot(item, idx)
      case let .reorderMembers(gId, sourceId, idx):
        dispatchReorderMembers(gId, sourceId, idx)
      }
      return true
    }

    // MARK: - Dispatch helpers

    // Each dispatch helper fires a `Task { try? await … }` against the
    // matching `SidebarDropDispatch` entry point. Fire-and-forget is
    // correct: the underlying stores capture their own `error`
    // property so the reactive view path surfaces failures, the
    // `DropReceiver.acceptDrop` callback is synchronous, and awaiting
    // here would force the whole protocol async (which the vendored
    // package does not support). The `Task` inherits the receiver's
    // `@MainActor` isolation so the store reads stay isolated.

    private func dispatchAddToGroup(_ sourceId: UUID, _ groupId: UUID) {
      Task {
        try? await SidebarDropDispatch.dropOntoGroup(
          sourceId: sourceId,
          groupId: groupId,
          accountStore: accountStore,
          accountGroupStore: accountGroupStore)
      }
    }

    private func dispatchDropOntoAccount(_ sourceId: UUID, _ targetId: UUID) {
      Task {
        _ = try? await SidebarDropDispatch.dropOntoAccount(
          sourceId: sourceId,
          targetId: targetId,
          accountStore: accountStore,
          accountGroupStore: accountGroupStore,
          groupUIStateStore: groupUIStateStore)
      }
    }

    private func dispatchReorderRoot(
      _ item: DraggableSidebarItem, _ insertionIndex: Int
    ) {
      Task {
        try? await SidebarDropDispatch.reorderRoot(
          dragged: item,
          insertionIndex: insertionIndex,
          bucket: bucket,
          accountStore: accountStore,
          accountGroupStore: accountGroupStore)
      }
    }

    private func dispatchReorderMembers(
      _ groupId: UUID, _ sourceId: UUID, _ insertionIndex: Int
    ) {
      Task {
        await SidebarDropDispatch.reorderMembers(
          groupId: groupId,
          sourceAccountId: sourceId,
          insertionIndex: insertionIndex,
          accountStore: accountStore)
      }
    }

  }
#endif
