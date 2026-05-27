#if os(macOS)
  import AppKit
  import Foundation

  @testable import Moolah

  /// Shared helpers for the `SidebarOutlineDropReceiver` outcome tests.
  /// The receiver's policy is pure (no live NSOutlineView, no stores)
  /// so the tests construct `DropTarget` values directly. Extracted into
  /// its own file to keep each test file under SwiftLint's
  /// `file_length` / `type_body_length` thresholds without the helpers
  /// dominating either.
  @MainActor
  enum SidebarOutlineDropReceiverTestSupport {

    /// Builds a `DropTarget` with a single dragged `SidebarOutlineItem`.
    /// Matches the shape of what `readPasteboard` would return at
    /// runtime — the dragged item carries `children: nil` because the
    /// receiver only needs the `kind` to look the source up in the
    /// stores. `isItemExpanded` is unused by the policy, so a constant
    /// `true` is sufficient.
    static func target(
      dragged: SidebarOutlineItem.Kind,
      intoElement: SidebarOutlineItem.Kind?,
      childIndex: Int?
    ) -> DropTarget<SidebarOutlineItem> {
      let draggedItem = SidebarOutlineItem(kind: dragged, children: nil)
      let into: SidebarOutlineItem? =
        intoElement.map { kind in
          switch kind {
          case .account: return SidebarOutlineItem(kind: kind, children: nil)
          case .group: return SidebarOutlineItem(kind: kind, children: [])
          }
        }
      return DropTarget(
        items: [(draggedItem, DraggableSidebarItem.pasteboardType)],
        intoElement: into,
        childIndex: childIndex,
        isItemExpanded: { _ in true }
      )
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
