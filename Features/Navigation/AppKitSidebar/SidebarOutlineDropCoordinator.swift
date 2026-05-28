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
    let accountStore: AccountStore
    let accountGroupStore: AccountGroupStore
    let groupUIStateStore: GroupUIStateStore

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
      case .section: return nil
      case .account(let id): return accounts.by(id: id)?.bucket
      case .group(let id):
        return groups.first(where: { $0.id == id })?.bucket
      case .earmark, .total, .navigation: return nil
      }
    }
  }
#endif
