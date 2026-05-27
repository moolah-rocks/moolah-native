#if os(macOS)
  import Foundation

  // TODO(#991): SidebarDropPolicy currently consumes
  // `DropTarget<SidebarOutlineItem>` and returns
  // `ValidationResult<SidebarOutlineItem>` from the vendored OutlineView
  // package. The unified-AppKit sidebar rewrite removes that package; at
  // that point the policy's signature needs to adapt to
  // `NSOutlineViewDataSource`'s native drag/drop shape. Tracking issue:
  // https://github.com/moolah-rocks/moolah-native/issues/991

  /// Pure decision-table policy that maps a sidebar `DropTarget` to a
  /// `DropOutcome`. View-agnostic: no store mutation, no awaits, no
  /// AppKit calls — every branch is a value transform over the
  /// (bucket, accounts, groups) snapshot. Lets the whole decision table
  /// be unit-tested without a live `NSOutlineView`. Accept-time
  /// dispatch (committing the outcome to a store) lives in whichever
  /// component owns the outline view.
  enum SidebarDropPolicy {

    /// All possible outcomes of resolving a `DropTarget` against the
    /// current store snapshots. Pure value so the policy is trivially
    /// testable. The `asValidationResult` transform is equally pure —
    /// callers own any UI-state side-effects after inspecting the outcome.
    enum DropOutcome: Equatable {
      case deny
      case addToGroup(sourceAccountId: UUID, groupId: UUID)
      case dropOntoAccount(sourceAccountId: UUID, targetAccountId: UUID)
      case reorderRoot(item: DraggableSidebarItem, insertionIndex: Int)
      case reorderMembers(
        groupId: UUID, sourceAccountId: UUID, insertionIndex: Int)
      case retargetRoot(insertionIndex: Int)
      case retargetGroup(groupId: UUID, insertionIndex: Int)

      func asValidationResult() -> ValidationResult<SidebarOutlineItem> {
        switch self {
        case .deny:
          return .deny
        case .addToGroup, .dropOntoAccount, .reorderRoot, .reorderMembers:
          return .move
        case .retargetRoot(let idx):
          return .moveRedirect(item: nil, childIndex: idx)
        case let .retargetGroup(gId, idx):
          return .moveRedirect(
            item: SidebarOutlineItem(kind: .group(gId), children: []),
            childIndex: idx)
        }
      }
    }

    /// Bundles the (bucket, accounts, groups) trio every decision-table
    /// branch needs. Keeps per-helper signatures under SwiftLint's
    /// `function_parameter_count` ceiling and matches the read shape:
    /// every helper resolves the dragged source against the same store
    /// snapshot.
    struct Context {
      let bucket: AccountBucket
      let accounts: Accounts
      let groups: [AccountGroup]
    }

    /// Resolves a `DropTarget` into a `DropOutcome` against the bucket
    /// the receiver renders and the current store snapshots. Pure —
    /// no awaits, no store mutation. Dispatches into per-`intoElement`
    /// helpers below; each helper covers one column of the decision
    /// table (root / group / account) and annotates each branch with a
    /// `// row N:` comment so a test failure can be matched back to a
    /// specific row.
    static func outcome(
      for target: DropTarget<SidebarOutlineItem>,
      bucket: AccountBucket,
      accounts: Accounts,
      groups: [AccountGroup]
    ) -> DropOutcome {
      // The package only ever delivers a single dragged item for our
      // single-drag use case. If we ever get an empty `items` array,
      // bail.
      guard let droppedSidebarItem = target.items.first?.item else {
        return .deny
      }
      // `droppedSidebarItem` is the `SidebarOutlineItem` we returned
      // from `readPasteboard`. Translate it back into a
      // `DraggableSidebarItem` so the source's bucket / groupId can be
      // resolved from `accounts` / `groups`.
      let dragged: DraggableSidebarItem =
        switch droppedSidebarItem.kind {
        case .account(let id):
          DraggableSidebarItem(kind: .account, id: id)
        case .group(let id):
          DraggableSidebarItem(kind: .group, id: id)
        }
      let context = Context(bucket: bucket, accounts: accounts, groups: groups)

      switch target.intoElement?.kind {
      case .none:
        return outcomeForRoot(
          dragged: dragged,
          childIndex: target.childIndex,
          context: context)
      case .group(let gId):
        return outcomeForGroup(
          gId: gId,
          dragged: dragged,
          childIndex: target.childIndex,
          context: context)
      case .account(let aId):
        return outcomeForAccount(
          aId: aId,
          dragged: dragged,
          childIndex: target.childIndex,
          context: context)
      }
    }

    /// Decision-table column for `intoElement == nil` (root). Rows 1-5.
    private static func outcomeForRoot(
      dragged: DraggableSidebarItem,
      childIndex: Int?,
      context: Context
    ) -> DropOutcome {
      // row 1: drop directly onto the root area (no insertion slot) is
      // not meaningful — there is no "root row" to drop onto.
      guard let idx = childIndex else { return .deny }
      switch dragged.kind {
      case .account:
        guard let sourceAccount = context.accounts.by(id: dragged.id) else {
          return .deny
        }
        // row 5: cross-bucket drop.
        guard sourceAccount.bucket == context.bucket else { return .deny }
        // row 3: dragging a member to root denies (no silent un-group).
        guard sourceAccount.groupId == nil else { return .deny }
        // row 2.
        return .reorderRoot(item: dragged, insertionIndex: idx)
      case .group:
        guard
          let sourceGroup = context.groups.first(where: { $0.id == dragged.id })
        else { return .deny }
        // row 5: cross-bucket group.
        guard sourceGroup.bucket == context.bucket else { return .deny }
        // row 4.
        return .reorderRoot(item: dragged, insertionIndex: idx)
      }
    }

    /// Decision-table column for `intoElement == .group(gId)`. Rows 6-10.
    private static func outcomeForGroup(
      gId: UUID,
      dragged: DraggableSidebarItem,
      childIndex: Int?,
      context: Context
    ) -> DropOutcome {
      // rows 7 & 10: groups cannot be nested (whether dropped onto the
      // group row itself or between its members).
      guard case .account = dragged.kind else { return .deny }
      guard let sourceAccount = context.accounts.by(id: dragged.id) else {
        return .deny
      }
      guard let targetGroup = context.groups.first(where: { $0.id == gId })
      else { return .deny }
      // row 5: cross-bucket.
      guard sourceAccount.bucket == context.bucket,
        targetGroup.bucket == context.bucket
      else { return .deny }
      if let idx = childIndex {
        // row 9: an account NOT currently in this group cannot be
        // dropped between its members (use drop-onto-group instead).
        guard sourceAccount.groupId == gId else { return .deny }
        // row 8.
        return .reorderMembers(
          groupId: gId, sourceAccountId: dragged.id, insertionIndex: idx)
      } else {
        // row 6 (variant): already a member of this group — denying
        // avoids a no-op store write and keeps the cursor honest.
        guard sourceAccount.groupId != gId else { return .deny }
        // row 6.
        return .addToGroup(sourceAccountId: dragged.id, groupId: gId)
      }
    }

    /// Decision-table column for `intoElement == .account(aId)`. Rows
    /// 11-13 (the last is the retarget — NSOutlineView reports
    /// `.account` with a non-nil `childIndex` when the cursor hovers
    /// near the bottom half of an account row, but the user means
    /// "drop between this row and the next").
    private static func outcomeForAccount(
      aId: UUID,
      dragged: DraggableSidebarItem,
      childIndex: Int?,
      context: Context
    ) -> DropOutcome {
      // row 12: a group cannot be dropped onto an account.
      guard case .account = dragged.kind else { return .deny }
      guard let targetAccount = context.accounts.by(id: aId) else {
        return .deny
      }
      // row 5: cross-bucket retargets aren't meaningful either.
      guard targetAccount.bucket == context.bucket else { return .deny }
      if childIndex != nil {
        // row 13: retarget.
        return retargetForAccount(
          targetAccount: targetAccount, context: context)
      }
      // row 11: drop-onto-account.
      guard dragged.id != aId else { return .deny }  // self-drop
      guard let sourceAccount = context.accounts.by(id: dragged.id) else {
        return .deny
      }
      guard sourceAccount.bucket == context.bucket else { return .deny }
      return .dropOntoAccount(
        sourceAccountId: dragged.id, targetAccountId: aId)
    }

    /// Row 13: retargets a hover near the bottom of an account row to a
    /// real insertion slot. Standalone targets retarget to root; member
    /// targets retarget to the parent group. The `+1` lands the
    /// insertion *after* the hovered row, which is the standard
    /// NSOutlineView interpretation.
    private static func retargetForAccount(
      targetAccount: Account,
      context: Context
    ) -> DropOutcome {
      if let parentId = targetAccount.groupId {
        // Member account: retarget to the parent group at memberIndex+1.
        guard
          let memberIndex = context.accounts.ordered
            .filter({ $0.groupId == parentId })
            .sorted(by: { $0.position < $1.position })
            .firstIndex(where: { $0.id == targetAccount.id })
        else { return .deny }
        return .retargetGroup(
          groupId: parentId, insertionIndex: memberIndex + 1)
      }
      // Standalone account: find its index among root entries and
      // retarget to root at rootIndex+1.
      let entries = context.accounts.groupAwareSidebar(groups: context.groups)
      let bucketEntries: [SidebarBucketEntry] =
        switch context.bucket {
        case .current: entries.current
        case .investments: entries.investments
        }
      guard
        let rootIndex = bucketEntries.firstIndex(where: { entry in
          if case .account(let acct) = entry, acct.id == targetAccount.id {
            return true
          }
          return false
        })
      else { return .deny }
      return .retargetRoot(insertionIndex: rootIndex + 1)
    }
  }
#endif
