#if os(macOS)
  import AppKit
  import Foundation

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
  ///    take account / group snapshots as parameters so they are
  ///    unit-testable without standing up a backend.
  ///
  /// 2. **Instance methods** — `outcome(forProposedItem:childIndex:dragged:)`
  ///    and `commit(_:bucket:)` read the live store snapshots,
  ///    call `SidebarDropPolicy.outcome(...)`, and dispatch via
  ///    `SidebarDropDispatch`. `commit` invokes `onCreatedGroup`
  ///    when `dropOntoAccount` creates a new group so the host
  ///    binding can enter inline-rename mode.
  @MainActor
  final class SidebarOutlineDropCoordinator {
    private let accountStore: AccountStore
    private let accountGroupStore: AccountGroupStore
    private let groupUIStateStore: GroupUIStateStore

    /// Fired after `commit` lands a `dropOntoAccount` outcome that
    /// joined two standalone accounts into a new group. The host
    /// (`SidebarOutline`) typically maps this to `editingRowId = id`
    /// so inline rename starts on the new group.
    var onCreatedGroup: ((AccountGroup) -> Void)?

    init(
      accountStore: AccountStore,
      accountGroupStore: AccountGroupStore,
      groupUIStateStore: GroupUIStateStore
    ) {
      self.accountStore = accountStore
      self.accountGroupStore = accountGroupStore
      self.groupUIStateStore = groupUIStateStore
    }

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

  extension SidebarOutlineDropCoordinator {
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
#endif
