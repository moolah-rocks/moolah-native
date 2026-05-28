#if os(macOS)
  import AppKit
  import Foundation
  import SwiftUI
  import Testing

  @testable import Moolah

  @Suite("SidebarContextMenuBuilder")
  @MainActor
  struct SidebarContextMenuBuilderTests {
    @Test("accountMenu first item is Rename and fires onBeginRename")
    func accountMenuRenameFiresClosure() async throws {
      let backend = PreviewBackend.create()
      let accountStore = AccountStore(
        repository: backend.accounts,
        conversionService: backend.conversionService,
        targetInstrument: .AUD)

      let account = Account(name: "Checking", type: .bank, instrument: .AUD)
      _ = try await accountStore.create(account)

      var beginRenameFired = false
      let menu = SidebarContextMenuBuilder.accountMenu(
        accountId: account.id,
        accountStore: accountStore,
        selection: .constant(nil),
        accountToEdit: .constant(nil),
        onBeginRename: { beginRenameFired = true })

      let first = try #require(menu.items.first)
      #expect(first.title == "Rename")
      #expect(
        first.accessibilityIdentifier()
          == UITestIdentifiers.Sidebar.renameContextMenuItem)

      // Trigger via the target/action sink directly — XCTest can't drive
      // an NSMenu programmatically without a real event loop.
      if let action = first.action, let target = first.target {
        _ = target.perform(action, with: first)
      }
      #expect(beginRenameFired)
    }

    @Test("earmarkMenu has a single Rename item that fires onBeginRename")
    func earmarkMenuRenameFiresClosure() throws {
      var beginRenameFired = false
      let menu = SidebarContextMenuBuilder.earmarkMenu(
        earmarkId: UUID(),
        onBeginRename: { beginRenameFired = true })

      #expect(menu.items.count == 1)
      let first = try #require(menu.items.first)
      #expect(first.title == "Rename")
      #expect(
        first.accessibilityIdentifier()
          == UITestIdentifiers.Sidebar.renameContextMenuItem)

      if let action = first.action, let target = first.target {
        _ = target.perform(action, with: first)
      }
      #expect(beginRenameFired)
    }

    @Test("groupMenu has a single Rename item that fires onBeginRename")
    func groupMenuRenameFiresClosure() throws {
      var beginRenameFired = false
      let menu = SidebarContextMenuBuilder.groupMenu(
        groupId: UUID(),
        onBeginRename: { beginRenameFired = true })

      #expect(menu.items.count == 1)
      let first = try #require(menu.items.first)
      #expect(first.title == "Rename")
      #expect(
        first.accessibilityIdentifier()
          == UITestIdentifiers.Sidebar.renameContextMenuItem)

      if let action = first.action, let target = first.target {
        _ = target.perform(action, with: first)
      }
      #expect(beginRenameFired)
    }
  }
#endif
