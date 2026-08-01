#if os(macOS)
  import AppKit
  import Foundation

  // MARK: - State and lifecycle

  /// Mediates `NSOutlineView` drag-and-drop for the unified macOS
  /// sidebar. Owned by `SidebarOutline.makeNSViewController` and
  /// attached weakly to `SidebarOutlineDataSource` via its
  /// `dropCoordinator` property.
  ///
  /// Splits into two layers:
  ///
  /// 1. **Static pure translators** — `bucket(forProposedItem:...)`
  ///    and `target(forProposedItem:...)` map `NSOutlineView`'s
  ///    `(proposedItem, childIndex)` plus the dragged
  ///    `DraggableSidebarItem` into the policy-shaped inputs. They
  ///    take store snapshots as parameters so they are
  ///    unit-testable without standing up a backend.
  ///
  /// 2. **Instance methods** — `outcome(forProposedItem:childIndex:dragged:)`
  ///    and `commit(_:bucket:)` read the live store snapshots,
  ///    call the matching account or earmark policy, and dispatch via
  ///    the owning store. `commit` invokes `onCreatedGroup`
  ///    when `dropOntoAccount` creates a new group so the host
  ///    binding can enter inline-rename mode.
  @MainActor
  final class SidebarOutlineDropCoordinator {
    private let accountStore: AccountStore
    private let accountGroupStore: AccountGroupStore
    private let earmarkStore: EarmarkStore?
    private let groupUIStateStore: GroupUIStateStore

    /// Fired after `commit` lands a `dropOntoAccount` outcome that
    /// joined two standalone accounts into a new group. The host
    /// (`SidebarOutline`) typically maps this to `editingRowId = id`
    /// so inline rename starts on the new group.
    var onCreatedGroup: ((AccountGroup) -> Void)?

    init(
      accountStore: AccountStore,
      accountGroupStore: AccountGroupStore,
      earmarkStore: EarmarkStore? = nil,
      groupUIStateStore: GroupUIStateStore
    ) {
      self.accountStore = accountStore
      self.accountGroupStore = accountGroupStore
      self.earmarkStore = earmarkStore
      self.groupUIStateStore = groupUIStateStore
    }

    // MARK: - Pure translation

    /// Infers the `AccountBucket` implied by an `NSOutlineView`
    /// drop's proposed item. Section headers carry the bucket
    /// directly; account / group rows look up their bucket from the
    /// supplied snapshots. Any non-account / non-group / non-bucket
    /// section row returns `nil` — those rows are rejected at the
    /// data-source level.
    ///
    /// Marked `nonisolated` because the function is a pure value
    /// transform over its parameters — it touches no actor-isolated
    /// state — and unit tests call it from non-isolated synchronous
    /// contexts.
    nonisolated static func bucket(
      forProposedItem item: SidebarRow?,
      accounts: Accounts,
      groups: [AccountGroup]
    ) -> AccountBucket? {
      guard let item else { return nil }
      switch item {
      case .section(.current): return .current
      case .section(.investments): return .investments
      case .section(.earmarks), .section(.totals), .section(.navigation): return nil
      case .account(let id): return accounts.by(id: id)?.bucket
      case .group(let id):
        return groups.first(where: { $0.id == id })?.bucket
      case .earmark, .total, .navigation: return nil
      }
    }
  }

  // MARK: - Earmark translation

  extension SidebarOutlineDropCoordinator {
    /// Resolves an earmark drag independently from the account/group
    /// decision table. Earmarks can only move between insertion slots in
    /// their own section; dropping onto a row or crossing section types is
    /// denied.
    nonisolated static func earmarkOutcome(
      forProposedItem item: SidebarRow?,
      childIndex: Int,
      dragged: DraggableSidebarItem,
      earmarks: [Earmark]
    ) -> SidebarDropPolicy.DropOutcome {
      guard dragged.kind == .earmark,
        earmarks.contains(where: { $0.id == dragged.id }),
        let item
      else { return .deny }

      switch item {
      case .section(.earmarks):
        guard childIndex != NSOutlineViewDropOnItemIndex else { return .deny }
        return .reorderEarmark(
          sourceId: dragged.id,
          insertionIndex: min(max(childIndex, 0), earmarks.count))
      case .earmark(let id):
        guard childIndex != NSOutlineViewDropOnItemIndex,
          let targetIndex = earmarks.firstIndex(where: { $0.id == id })
        else { return .deny }
        return .retargetEarmarks(insertionIndex: targetIndex + 1)
      case .section, .account, .group, .total, .navigation:
        return .deny
      }
    }

    /// Translates `NSOutlineView`'s `(proposedItem, childIndex)` plus
    /// the dragged item into a `SidebarDropTarget` ready for
    /// `SidebarDropPolicy.outcome(...)`. Returns `nil` only when the
    /// proposed item is not a valid drop surface (nil, earmark / total /
    /// navigation rows, or the earmarks / totals / navigation section
    /// headers); out-of-bucket and self-drop denials happen inside the
    /// policy.
    ///
    /// `NSOutlineViewDropOnItemIndex` (`-1`) maps to `childIndex: nil`
    /// — the policy uses `nil` to mean "drop directly onto the
    /// target row" (full-row highlight); a non-negative integer means
    /// "drop between children at insertion slot N" (insertion line).
    ///
    /// `nonisolated` for the same reason as `bucket(...)`.
    nonisolated static func target(
      forProposedItem item: SidebarRow?,
      childIndex: Int,
      dragged: DraggableSidebarItem,
      accounts: Accounts,
      groups: [AccountGroup]
    ) -> SidebarDropTarget? {
      let mappedChildIndex: Int? =
        (childIndex == NSOutlineViewDropOnItemIndex) ? nil : childIndex
      guard let item else { return nil }
      switch item {
      case .section(.current), .section(.investments):
        return SidebarDropTarget(
          dragged: dragged, into: nil, childIndex: mappedChildIndex)
      case .section(.earmarks), .section(.totals), .section(.navigation):
        return nil
      case .account(let id):
        guard accounts.by(id: id) != nil else { return nil }
        return SidebarDropTarget(
          dragged: dragged,
          into: .account(id),
          childIndex: mappedChildIndex)
      case .group(let id):
        guard groups.contains(where: { $0.id == id }) else { return nil }
        return SidebarDropTarget(
          dragged: dragged,
          into: .group(id),
          childIndex: mappedChildIndex)
      case .earmark, .total, .navigation:
        return nil
      }
    }
  }

  // MARK: - Account translation

  extension SidebarOutlineDropCoordinator {
    /// Reads the coordinator's live `accountStore` and
    /// `accountGroupStore` snapshots and forwards to the static
    /// `bucket(forProposedItem:accounts:groups:)` helper. Lets call
    /// sites that already hold a coordinator infer the bucket of a
    /// proposed drop item without reaching into the private store
    /// properties.
    func bucket(forProposedItem item: SidebarRow?) -> AccountBucket? {
      Self.bucket(
        forProposedItem: item,
        accounts: accountStore.accounts,
        groups: accountGroupStore.groups)
    }
  }

  // MARK: - Live resolution

  extension SidebarOutlineDropCoordinator {
    /// Reads current store snapshots and resolves the policy outcome
    /// for an `NSOutlineView` drop's `(proposedItem, childIndex)` plus
    /// the dragged `DraggableSidebarItem`. Returns `.deny` when the
    /// proposed item is not a valid drop surface. Account and group
    /// drags also require a matching `AccountBucket`.
    ///
    /// Instance method (not `nonisolated static`) because it reads
    /// `@MainActor`-isolated store state. Earmark drags are resolved
    /// first because they do not belong to an `AccountBucket`. Tests
    /// call it from a `@MainActor` suite.
    func outcome(
      forProposedItem item: SidebarRow?,
      childIndex: Int,
      dragged: DraggableSidebarItem
    ) -> SidebarDropPolicy.DropOutcome {
      if dragged.kind == .earmark {
        guard let earmarkStore else { return .deny }
        return Self.earmarkOutcome(
          forProposedItem: item,
          childIndex: childIndex,
          dragged: dragged,
          earmarks: earmarkStore.visibleEarmarks)
      }

      let accounts = accountStore.accounts
      let groups = accountGroupStore.groups
      guard
        let bucket = Self.bucket(
          forProposedItem: item, accounts: accounts, groups: groups),
        let target = Self.target(
          forProposedItem: item,
          childIndex: childIndex,
          dragged: dragged,
          accounts: accounts,
          groups: groups)
      else { return .deny }
      return SidebarDropPolicy.outcome(
        for: target, bucket: bucket, accounts: accounts, groups: groups)
    }

    // MARK: - Commit dispatch

    /// Dispatches a `DropOutcome` to the matching `SidebarDropDispatch`
    /// entry point. Fires `onCreatedGroup` when `dropOntoAccount`
    /// creates a new group so the host binding can flip
    /// `editingRowId` to the new group.
    ///
    /// Returns `true` when the dispatch was attempted (even if the store
    /// call threw — store errors are surfaced reactively on
    /// `accountStore.error` / `accountGroupStore.error`, so the caller
    /// shouldn't gate the drop animation on the throw). `false` for
    /// `.deny` and the `.retarget*` outcomes; retargets are
    /// visual-hint-only and never survive into accept.
    @discardableResult
    func commit(
      _ outcome: SidebarDropPolicy.DropOutcome,
      bucket: AccountBucket?
    ) async -> Bool {
      switch outcome {
      case let .reorderEarmark(sourceId, insertionIndex):
        guard let earmarkStore else { return false }
        await earmarkStore.reorderEarmark(id: sourceId, to: insertionIndex)
        return true
      case .retargetEarmarks:
        return false
      default:
        guard let bucket else { return false }
        return await commitAccountOutcome(outcome, bucket: bucket)
      }
    }

    private func commitAccountOutcome(
      _ outcome: SidebarDropPolicy.DropOutcome,
      bucket: AccountBucket
    ) async -> Bool {
      switch outcome {
      case .deny, .retargetRoot, .retargetGroup, .retargetEarmarks,
        .reorderEarmark:
        return false
      case let .addToGroup(sourceId, groupId):
        do {
          try await SidebarDropDispatch.dropOntoGroup(
            sourceId: sourceId,
            groupId: groupId,
            accountStore: accountStore,
            accountGroupStore: accountGroupStore,
            groupUIStateStore: groupUIStateStore)
        } catch {
          // Error already surfaced reactively on accountGroupStore.error.
        }
        return true
      case let .dropOntoAccount(sourceId, targetId):
        var created: AccountGroup?
        do {
          created = try await SidebarDropDispatch.dropOntoAccount(
            sourceId: sourceId,
            targetId: targetId,
            accountStore: accountStore,
            accountGroupStore: accountGroupStore,
            groupUIStateStore: groupUIStateStore)
        } catch {
          // Error already surfaced reactively on accountGroupStore.error.
        }
        if let created { onCreatedGroup?(created) }
        return true
      case let .reorderRoot(item, idx):
        return await commitRootReorder(item, insertionIndex: idx, bucket: bucket)
      case let .reorderMembers(groupId, sourceId, idx):
        do {
          try await SidebarDropDispatch.reorderMembers(
            groupId: groupId,
            sourceAccountId: sourceId,
            insertionIndex: idx,
            accountStore: accountStore,
            accountGroupStore: accountGroupStore)
        } catch {
          // Error already surfaced reactively on accountStore.error
          // or accountGroupStore.error.
        }
        return true
      }
    }

    private func commitRootReorder(
      _ item: DraggableSidebarItem,
      insertionIndex: Int,
      bucket: AccountBucket
    ) async -> Bool {
      do {
        try await SidebarDropDispatch.reorderRoot(
          dragged: item,
          insertionIndex: insertionIndex,
          bucket: bucket,
          accountStore: accountStore,
          accountGroupStore: accountGroupStore)
      } catch {
        // Error already surfaced reactively on accountGroupStore.error.
      }
      return true
    }
  }
#endif
