import Foundation

/// Stateless dispatch helper for sidebar drag-and-drop.
///
/// Holds no references — every entry point takes the stores it needs as
/// parameters so the call shapes are explicit at the use site. The iOS
/// SwiftUI row builders (`SidebarView+Groups.swift`) and the macOS
/// AppKit drop receiver both call the same four primitives here, which
/// keeps the policy gate ("same-bucket, no self-drop, no nesting") in
/// one place rather than duplicated across platform-specific drop
/// handlers.
///
/// `@MainActor`-bound because every entry point ultimately writes to
/// `@MainActor`-isolated store state (`AccountStore`,
/// `AccountGroupStore`, `GroupUIStateStore`). Store errors propagate
/// verbatim — the underlying stores *also* capture their own `error`
/// property so the reactive view path still surfaces failures, but the
/// dispatch helper itself does not swallow. Callers decide whether to
/// react to the throw or `try?`-discard at the view layer.
///
/// `dropOntoAccount` returns the newly created `AccountGroup` (or
/// `nil`) rather than taking a closure or mutating `editingRowId`
/// directly: the iOS handler needs to drive its `@State editingRowId`
/// after the create succeeds, and the macOS receiver has its own
/// post-create UX hook. Returning the value keeps this helper free of
/// any UI surface coupling.
@MainActor
enum SidebarDropDispatch {

  /// Drop-onto-account. Same-bucket only; rejects self-drop and
  /// missing source. If the target is already a group member, source
  /// is added to that group; otherwise a 2-member group is created
  /// joining the two accounts and the new group is auto-expanded via
  /// `groupUIStateStore`.
  ///
  /// - Returns: When a *new* group is created (the joining case), the
  ///   `AccountGroup` so the caller can enter inline-rename mode. `nil`
  ///   for the add-to-existing case or when the drop is rejected.
  @discardableResult
  static func dropOntoAccount(
    sourceId: UUID,
    targetId: UUID,
    accountStore: AccountStore,
    accountGroupStore: AccountGroupStore,
    groupUIStateStore: GroupUIStateStore
  ) async throws -> AccountGroup? {
    guard sourceId != targetId else { return nil }
    guard let source = accountStore.accounts.by(id: sourceId) else { return nil }
    guard let target = accountStore.accounts.by(id: targetId) else { return nil }
    guard source.bucket == target.bucket else { return nil }

    // If the source is currently in a group different from where it's
    // heading, clean up the old group first. `removeAccount` auto-deletes
    // the old group when it becomes empty. The `target.groupId` guard
    // avoids a wasteful remove/re-add when source and target are already
    // in the same group.
    if let groupId = source.groupId, groupId != target.groupId {
      try await accountGroupStore.removeAccount(source, accountStore: accountStore)
    }

    if let targetGroupId = target.groupId {
      guard let group = accountGroupStore.by(id: targetGroupId) else { return nil }
      guard let refreshed = accountStore.accounts.by(id: sourceId) else { return nil }
      try await accountGroupStore.addAccount(
        refreshed, to: group, accountStore: accountStore)
      return nil
    }

    guard let refreshed = accountStore.accounts.by(id: sourceId) else { return nil }
    let created = try await accountGroupStore.createGroup(
      joining: target,
      and: refreshed,
      name: "New Group",
      accountStore: accountStore)
    await groupUIStateStore.setExpanded(true, for: created.id)
    return created
  }

  /// Drop-onto-group. Same-bucket only; rejects re-adding to the same
  /// group and missing source. Adds the source account to the target
  /// group via `accountGroupStore.addAccount`, then auto-expands the
  /// target group via `groupUIStateStore` so the freshly added member
  /// is visible (otherwise a drop into a collapsed group would hide
  /// the new member with no visual feedback that the drop succeeded —
  /// mirrors the auto-expand `dropOntoAccount` does for a newly
  /// created group).
  static func dropOntoGroup(
    sourceId: UUID,
    groupId: UUID,
    accountStore: AccountStore,
    accountGroupStore: AccountGroupStore,
    groupUIStateStore: GroupUIStateStore
  ) async throws {
    guard let source = accountStore.accounts.by(id: sourceId) else { return }
    guard let group = accountGroupStore.by(id: groupId) else { return }
    guard source.bucket == group.bucket else { return }
    guard source.groupId != group.id else { return }

    // If the source is currently in a group, remove it first so the
    // old group auto-deletes when emptied. The `source.groupId !=
    // group.id` guard above already rejects same-group sources, so any
    // non-nil groupId here is definitely a different group.
    if source.groupId != nil {
      try await accountGroupStore.removeAccount(source, accountStore: accountStore)
    }

    guard let refreshed = accountStore.accounts.by(id: sourceId) else { return }
    try await accountGroupStore.addAccount(
      refreshed, to: group, accountStore: accountStore)
    await groupUIStateStore.setExpanded(true, for: group.id)
  }

  /// Root-level reorder: rewrites `position` so the dragged
  /// standalone-account-or-group lands at `insertionIndex` in the
  /// recomputed bucket entry order (standalone accounts + groups
  /// intermixed by position, as `Accounts.groupAwareSidebar(...)`
  /// produces).
  ///
  /// `dragged` carries both the kind (account vs group) and the id —
  /// the same `DraggableSidebarItem` value the iOS drop handler and
  /// the macOS pasteboard receiver already hold.
  ///
  /// Walks the new entry order assigning each entry its walk-order
  /// index as its `position` value: accounts go through
  /// `accountStore.reorderAccounts([account], positionOffset: walkIndex)`
  /// (single-element batches keep the `position = offset + index_in_list`
  /// arithmetic equal to `walkIndex`), and groups go through
  /// `accountGroupStore.moveGroup(_:to: walkIndex)`. The walk-index
  /// approach preserves the interleave the user dropped to — a
  /// single batched `reorderAccounts(0..N-1)` would collapse standalone
  /// positions back to a contiguous run and break drops where a group
  /// is meant to land between two standalones.
  static func reorderRoot(
    dragged: DraggableSidebarItem,
    insertionIndex: Int,
    bucket: AccountBucket,
    accountStore: AccountStore,
    accountGroupStore: AccountGroupStore
  ) async throws {
    // If the dragged source is a group member, remove it from its group
    // first. `removeAccount` clears `Account.groupId`, parks the source at
    // end-of-standalone, and auto-deletes the now-empty old group. The
    // walk-order rewrite below overwrites the temporary position with the
    // dropped insertion-slot one. Group sources fall through (they have
    // no `groupId`, and `accounts.by(id:)` returns nil for a group's id).
    if let source = accountStore.accounts.by(id: dragged.id),
      source.groupId != nil
    {
      try await accountGroupStore.removeAccount(source, accountStore: accountStore)
    }

    let entries = bucketEntries(
      bucket: bucket,
      accountStore: accountStore,
      accountGroupStore: accountGroupStore)
    guard
      let removalIndex = indexOfEntry(
        kind: dragged.kind, id: dragged.id, in: entries)
    else { return }
    var reordered = entries
    let entry = reordered.remove(at: removalIndex)
    let clampedIndex = min(max(insertionIndex, 0), reordered.count)
    reordered.insert(entry, at: clampedIndex)

    // Walk the reordered list and assign every entry its walk-order
    // index as its `position`. Per-entry calls are necessary so the
    // standalone-account / group interleave is preserved across the
    // shared `position` number space. Cancellation check between
    // iterations lets a replacement drop's enclosing Task bail out
    // mid-walk rather than racing the previous drop's tail writes.
    for (walkIndex, entry) in reordered.enumerated() {
      guard !Task.isCancelled else { return }
      switch entry {
      case .account(let account):
        await accountStore.reorderAccounts(
          [account], positionOffset: walkIndex)
      case let .group(group, members):
        // Skip phantom empty-group entries: when a member was just removed
        // via `removeAccount` above, the account observation can fire before
        // the group-deletion observation, leaving a zero-member group in the
        // snapshot. Calling `moveGroup` on a group the DB already deleted
        // throws 404. The next observation tick removes the phantom; skipping
        // here is safe because the group's position is irrelevant once empty.
        guard !members.isEmpty else { continue }
        try await accountGroupStore.moveGroup(group, to: walkIndex)
      }
    }
  }

  /// In-group member reorder: rewrites member `position` values so
  /// the dragged account lands at `insertionIndex` in the group's
  /// member list. Cross-group movement is not handled here — use
  /// `dropOntoGroup` for that. Silently no-ops when the source is not
  /// a member of `groupId`.
  static func reorderMembers(
    groupId: UUID,
    sourceAccountId: UUID,
    insertionIndex: Int,
    accountStore: AccountStore
  ) async {
    var members = accountStore.accounts.ordered
      .filter { $0.groupId == groupId }
      .sorted { $0.position < $1.position }
    guard let removalIndex = members.firstIndex(where: { $0.id == sourceAccountId })
    else { return }
    let dragged = members.remove(at: removalIndex)
    let clampedIndex = min(max(insertionIndex, 0), members.count)
    members.insert(dragged, at: clampedIndex)
    await accountStore.reorderAccounts(members)
  }

  // MARK: - Helpers

  /// Returns the current `[SidebarBucketEntry]` order for `bucket`,
  /// composed from `accountStore.accounts` + `accountGroupStore.groups`
  /// via the shared `Accounts.groupAwareSidebar` helper. Picks the
  /// right side of the tuple based on the requested bucket.
  private static func bucketEntries(
    bucket: AccountBucket,
    accountStore: AccountStore,
    accountGroupStore: AccountGroupStore
  ) -> [SidebarBucketEntry] {
    let grouped = accountStore.accounts.groupAwareSidebar(
      groups: accountGroupStore.groups)
    switch bucket {
    case .current: return grouped.current
    case .investments: return grouped.investments
    }
  }

  /// Locates the entry matching `(kind, id)` in `entries`. Accounts
  /// only match `.account` entries; groups only match `.group`
  /// entries. Returns nil when the id is unknown or the kind doesn't
  /// match (a dragged member account, for example, wouldn't appear as
  /// a top-level entry — its row is dispatched through
  /// `reorderMembers` instead).
  private static func indexOfEntry(
    kind: DraggableSidebarItem.Kind,
    id: UUID,
    in entries: [SidebarBucketEntry]
  ) -> Int? {
    entries.firstIndex { entry in
      switch (kind, entry) {
      case (.account, .account(let account)):
        return account.id == id
      case (.group, .group(let group, _)):
        return group.id == id
      default:
        return false
      }
    }
  }
}
