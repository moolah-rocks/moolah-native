#if os(macOS)
  import Foundation

  @testable import Moolah

  /// Shared fixtures for the `SidebarDropPolicy` outcome tests: a
  /// `SidebarDropTarget` builder, plus account / group factories used
  /// across the decision-table and retarget suites.
  enum SidebarDropPolicyTestSupport {

    /// Builds a `SidebarDropTarget` for tests. The `dragged:` parameter
    /// reuses `IntoKind` purely for symmetry — both cases carry a UUID,
    /// which is all the policy needs to look the dragged source up in
    /// `accounts` / `groups`.
    static func target(
      dragged: SidebarDropTarget.IntoKind,
      intoElement: SidebarDropTarget.IntoKind?,
      childIndex: Int?
    ) -> SidebarDropTarget {
      let draggable: DraggableSidebarItem =
        switch dragged {
        case .account(let id): DraggableSidebarItem(kind: .account, id: id)
        case .group(let id): DraggableSidebarItem(kind: .group, id: id)
        }
      return SidebarDropTarget(
        dragged: draggable, into: intoElement, childIndex: childIndex)
    }

    static func bankAccount(
      name: String, position: Int, groupId: UUID? = nil
    ) -> Account {
      Account(
        id: UUID(),
        name: name,
        type: .bank,
        instrument: .defaultTestInstrument,
        position: position,
        groupId: groupId)
    }

    static func investmentAccount(name: String, position: Int) -> Account {
      Account(
        name: name,
        type: .investment,
        instrument: .defaultTestInstrument,
        position: position)
    }

    static func currentGroup(position: Int) -> AccountGroup {
      AccountGroup(
        name: "G",
        bucket: .current,
        instrument: .defaultTestInstrument,
        position: position)
    }
  }
#endif
