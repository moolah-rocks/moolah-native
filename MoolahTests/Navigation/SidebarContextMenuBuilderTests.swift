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

    @Test("accountMenu omits Resync Now for a non-synced account")
    func accountMenuOmitsResyncForNonSyncedAccount() async throws {
      let backend = PreviewBackend.create()
      let accountStore = AccountStore(
        repository: backend.accounts,
        conversionService: backend.conversionService,
        targetInstrument: .AUD)

      let account = Account(name: "Checking", type: .bank, instrument: .AUD)
      _ = try await accountStore.create(account)
      await expectEventually("seeded account observed") {
        accountStore.accounts.by(id: account.id) != nil
      }

      let menu = SidebarContextMenuBuilder.accountMenu(
        accountId: account.id,
        accountStore: accountStore,
        selection: .constant(nil),
        accountToEdit: .constant(nil),
        onBeginRename: {})

      #expect(!menu.items.contains { $0.title == "Resync Now (Full History)" })
    }

    @Test("accountMenu includes Resync Now for a synced account and posts .requestAccountResync")
    func accountMenuResyncFiresNotification() async throws {
      let backend = PreviewBackend.create()
      let accountStore = AccountStore(
        repository: backend.accounts,
        conversionService: backend.conversionService,
        targetInstrument: .AUD)

      let eth = Instrument.crypto(
        chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
      let account = Account(
        name: "Wallet", type: .crypto, instrument: eth,
        walletAddress: "0xabc", chainId: 1)
      _ = try await accountStore.create(account)
      await expectEventually("seeded account observed") {
        accountStore.accounts.by(id: account.id) != nil
      }

      let menu = SidebarContextMenuBuilder.accountMenu(
        accountId: account.id,
        accountStore: accountStore,
        selection: .constant(nil),
        accountToEdit: .constant(nil),
        onBeginRename: {})

      let resyncItem = try #require(
        menu.items.first { $0.title == "Resync Now (Full History)" })
      #expect(
        resyncItem.accessibilityIdentifier()
          == UITestIdentifiers.Sidebar.resyncAccountContextMenuItem)

      // Observes the global `NotificationCenter.default` because the
      // production code posts there — there is no injectable center to
      // substitute. No other suite currently posts/observes
      // `.requestAccountResync`, so there is no cross-talk today; if a
      // future suite (e.g. a `MoolahDomainCommands` test) starts posting
      // it under parallel execution, revisit this to scope the object.
      //
      // `confirmation` proves the notification actually fires (a bare
      // `#expect` inside the observer would silently pass if it never
      // ran). The post is synchronous (`queue: nil`), so it completes
      // before `perform` returns and the confirmation is satisfied
      // within the closure — no async waiting.
      let label = "resync item posts .requestAccountResync with the account id"
      await confirmation(Comment(rawValue: label)) { posted in
        let observer = NotificationCenter.default.addObserver(
          forName: .requestAccountResync, object: nil, queue: nil
        ) { note in
          #expect(note.object as? UUID == account.id)
          posted()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        if let action = resyncItem.action, let target = resyncItem.target {
          _ = target.perform(action, with: resyncItem)
        }
      }
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
