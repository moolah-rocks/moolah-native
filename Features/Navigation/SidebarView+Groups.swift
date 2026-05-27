// Group-aware sidebar surface: row builders, context menus, drop
// handlers, expand-state binding, and creation flows.

import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
  extension SidebarView {

    // MARK: - Row builders

    /// Renders a single group entry: the disclosure-aware group row +
    /// member rows when expanded. Group selection routes through
    /// `SidebarSelection.group(id)`, which currently navigates to a
    /// placeholder detail surface.
    @ViewBuilder
    func groupSidebarEntry(_ group: AccountGroup, members: [Account]) -> some View {
      groupRowLink(group)
      if expandBinding(for: group.id).wrappedValue {
        ForEach(members) { member in
          memberRowLink(member)
        }
      }
    }

    /// The clickable group row + its drop / context-menu modifiers. Drop
    /// onto a group row adds an account to that group (cross-bucket
    /// rejected); group-onto-group drop is rejected (no nesting).
    ///
    /// The aggregate balance is computed by `GroupAggregateBalanceLoader`
    /// — a thin wrapper that owns the `@State InstrumentAmount?` and
    /// recomputes via `AccountStore.aggregateBalance(for:in:)` whenever
    /// the member set changes. Per
    /// `feedback_conversion_failure_ux.md`, a conversion failure on any
    /// member surfaces as `nil` (badge / spinner), never a partial sum.
    @ViewBuilder
    func groupRowLink(_ group: AccountGroup) -> some View {
      let memberIds = accountStore.accounts.ordered
        .filter { $0.groupId == group.id }
        .sorted(by: { $0.position < $1.position })
        .map(\.id)
      NavigationLink(value: SidebarSelection.group(group.id)) {
        GroupAggregateBalanceLoader(
          memberIds: memberIds,
          targetInstrument: group.instrument
        ) { balance in
          AccountGroupSidebarRow(
            group: group,
            isSelected: selection == .group(group.id),
            isExpanded: expandBinding(for: group.id),
            aggregateBalance: balance,
            isEditing: renameBinding(for: group.id),
            onRename: renameAction(for: group)
          )
        }
      }
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.group(group.id))
      .draggable(DraggableSidebarItem(kind: .group, id: group.id))
      .dropDestination(for: DraggableSidebarItem.self) { items, _ in
        guard let item = items.first else { return false }
        Task { await handleDrop(item, ontoGroup: group) }
        return true
      }
      .contextMenu { groupContextMenu(for: group) }
    }

    /// A member row: same `AccountSidebarRow` shape as standalone, but
    /// rendered with the `isMember` style hint so the secondary line
    /// (chain / address / exchange provider) surfaces. The drag source
    /// is a `.account` `DraggableSidebarItem`; dropping onto another
    /// account/group works as it does for standalone accounts.
    @ViewBuilder
    func memberRowLink(_ account: Account) -> some View {
      NavigationLink(value: SidebarSelection.account(account.id)) {
        AccountSidebarRow(
          account: account,
          isSelected: selection == .account(account.id),
          isMember: true,
          isEditing: renameBinding(for: account.id),
          onRename: renameAction(for: account)
        )
        .padding(.leading, 16)
      }
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.account(account.id))
      .draggable(DraggableSidebarItem(kind: .account, id: account.id))
      .dropDestination(for: DraggableSidebarItem.self) { items, _ in
        guard let item = items.first else { return false }
        Task { await handleDrop(item, ontoAccount: account) }
        return true
      }
      .contextMenu { accountContextMenu(for: account) }
    }

    /// Standalone account row, wired with drag / drop / group context
    /// menu. Used by both the Current and Investments sections in place
    /// of the previous inline row construction so the drop / drag
    /// modifiers stay consistent across bucket sections.
    @ViewBuilder
    func standaloneAccountRowLink(_ account: Account) -> some View {
      NavigationLink(value: SidebarSelection.account(account.id)) {
        AccountSidebarRow(
          account: account,
          isSelected: selection == .account(account.id),
          isEditing: renameBinding(for: account.id),
          onRename: renameAction(for: account)
        )
      }
      .dropDestination(for: URL.self) { urls, _ in
        Task { await ingestDroppedURLs(urls, forcedAccountId: account.id) }
        return !urls.isEmpty
      }
      .draggable(DraggableSidebarItem(kind: .account, id: account.id))
      .dropDestination(for: DraggableSidebarItem.self) { items, _ in
        guard let item = items.first else { return false }
        Task { await handleDrop(item, ontoAccount: account) }
        return true
      }
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.account(account.id))
      .contextMenu { accountContextMenu(for: account) }
    }

    // MARK: - Expand state

    /// Returns a two-way binding to the expand state of `groupId`.
    /// Reads from `groupUIStateStore.expandedGroupIds` (driven by the
    /// reactive observation of the local-only `account_group_ui` table)
    /// and writes through `setExpanded(_:for:)` so the change is
    /// persisted per profile and survives app relaunch.
    ///
    /// The store closes the loop: setExpanded → repo write → observation
    /// emits → `expandedGroupIds` updates → the binding's `get` returns
    /// the new value → SwiftUI re-renders.
    func expandBinding(for groupId: UUID) -> Binding<Bool> {
      Binding(
        get: { groupUIStateStore.expandedGroupIds.contains(groupId) },
        set: { newValue in
          Task { await groupUIStateStore.setExpanded(newValue, for: groupId) }
        }
      )
    }

    // MARK: - Context menus

    /// Right-click menu for a group row. Only Rename is exposed —
    /// Hide and Delete are intentionally absent because membership is
    /// the unit of group lifecycle: remove the last member to delete
    /// the group.
    @ViewBuilder
    func groupContextMenu(for group: AccountGroup) -> some View {
      Button("Rename", systemImage: "character.cursor.ibeam") {
        editingRowId = group.id
      }
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.renameContextMenuItem)
    }

    /// "Group ▸" submenu inside an account's right-click menu. Lists the
    /// other groups in the account's bucket, then a "New Group…" entry,
    /// then a "Remove from Group" entry if the account is currently in a
    /// group. Same-bucket constraint is enforced by filtering the move
    /// list to `bucket == account.bucket`.
    @ViewBuilder
    func accountGroupSubmenu(for account: Account) -> some View {
      let groupsInBucket = accountGroupStore.groups
        .filter { $0.bucket == account.bucket && $0.id != account.groupId }
      Menu {
        ForEach(groupsInBucket) { group in
          Button(group.name) {
            // Store errors surface reactively on `accountGroupStore.error`;
            // discarding the throw here keeps the view as the leaf consumer.
            Task {
              try? await accountGroupStore.addAccount(
                account, to: group, accountStore: accountStore)
            }
          }
        }
        if !groupsInBucket.isEmpty { Divider() }
        Button("New Group\u{2026}") {
          Task { await createGroupFromAccount(account) }
        }
        if account.groupId != nil {
          Divider()
          Button("Remove from Group") {
            // Store errors surface reactively on `accountGroupStore.error`;
            // discarding the throw here keeps the view as the leaf consumer.
            Task {
              try? await accountGroupStore.removeAccount(
                account, accountStore: accountStore)
            }
          }
        }
      } label: {
        Label("Group", systemImage: "folder")
      }
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.groupSubmenu)
    }

    // MARK: - Drop handling

    /// Policy gate for a drop targeting an account row. Same-bucket only;
    /// group-onto-account is rejected; account-onto-account in the same
    /// bucket creates a new 2-member group (or moves the dragged account
    /// into the target's existing group when the target is itself a
    /// member).
    ///
    /// Thin wrapper over `SidebarDropDispatch.dropOntoAccount` — the
    /// dispatch helper owns the policy gate and store calls so the
    /// macOS AppKit drop receiver shares the same logic. The iOS-only
    /// post-hop is setting `editingRowId` to the newly created group's
    /// id so inline rename starts immediately. Store errors are already
    /// surfaced reactively on `accountGroupStore.error`; discarding the
    /// throw here keeps the view as the leaf consumer of that path.
    func handleDrop(
      _ item: DraggableSidebarItem,
      ontoAccount target: Account
    ) async {
      guard item.kind == .account else { return }  // group-onto-account = no-op
      do {
        let created = try await SidebarDropDispatch.dropOntoAccount(
          sourceId: item.id,
          targetId: target.id,
          accountStore: accountStore,
          accountGroupStore: accountGroupStore,
          groupUIStateStore: groupUIStateStore)
        if let created {
          editingRowId = created.id
        }
      } catch {
        // Error already surfaced on `accountGroupStore.error`; no extra UI hop.
      }
    }

    /// Policy gate for a drop targeting a group row. Adds the dragged
    /// account to the group; rejects group-onto-group (no nesting) and
    /// cross-bucket.
    ///
    /// Thin wrapper over `SidebarDropDispatch.dropOntoGroup`. Store
    /// errors are already surfaced reactively on
    /// `accountGroupStore.error`; discarding the throw here keeps the
    /// view as the leaf consumer of that path.
    func handleDrop(
      _ item: DraggableSidebarItem,
      ontoGroup target: AccountGroup
    ) async {
      guard item.kind == .account else { return }  // group-onto-group rejected
      do {
        try await SidebarDropDispatch.dropOntoGroup(
          sourceId: item.id,
          groupId: target.id,
          accountStore: accountStore,
          accountGroupStore: accountGroupStore)
      } catch {
        // Error already surfaced on `accountGroupStore.error`; no extra UI hop.
      }
    }

    // MARK: - Creation flows

    /// Right-click → New Group… → creates a single-member group from the
    /// source account and immediately enters inline rename mode so the
    /// user can overwrite the default "New Group" placeholder.
    func createGroupFromAccount(_ account: Account) async {
      do {
        let created = try await accountGroupStore.createGroup(
          from: account, name: "New Group", accountStore: accountStore)
        editingRowId = created.id
        await groupUIStateStore.setExpanded(true, for: created.id)
      } catch {
        // Error surfaces on `accountGroupStore.error`; no extra UI hop.
      }
    }
  }
#endif

// MARK: - Transferable wrapper

/// Payload carrying the kind (account vs group) + the dragged entity's
/// UUID across SwiftUI's drag-and-drop boundary.
struct DraggableSidebarItem: Codable, Sendable, Equatable {
  enum Kind: String, Codable, Sendable, Equatable { case account, group }

  let kind: Kind
  let id: UUID
}

/// `Transferable` requires the payload itself to be `Codable`; the
/// `CodableRepresentation` defaults to JSON encoding.
extension DraggableSidebarItem: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .moolahSidebarItem)
  }
}

extension UTType {
  /// Bespoke UTType for sidebar drag-and-drop. Exported so SwiftUI's
  /// drag system can negotiate the type across rows without falling
  /// back to plain text. The string must stay stable — it's part of the
  /// pasteboard contract within a single app session.
  static var moolahSidebarItem: UTType {
    UTType(exportedAs: "com.moolah.sidebar-item")
  }
}
