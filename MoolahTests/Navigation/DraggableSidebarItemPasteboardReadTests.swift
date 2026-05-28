#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("DraggableSidebarItem — pasteboard read")
  struct DraggableSidebarItemPasteboardReadTests {

    @Test("round-trips through NSPasteboard")
    func roundTrip() throws {
      let original = DraggableSidebarItem(kind: .group, id: UUID())
      let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-pb-\(UUID().uuidString)"))
      pasteboard.clearContents()
      let item = try #require(original.pasteboardItem())
      pasteboard.writeObjects([item])

      let decoded = DraggableSidebarItem.read(from: pasteboard)

      #expect(decoded == original)
    }

    @Test("returns nil when pasteboard has no moolah-sidebar-item type")
    func emptyPasteboard() {
      let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-pb-\(UUID().uuidString)"))
      pasteboard.clearContents()
      pasteboard.setString("hello", forType: .string)

      let decoded = DraggableSidebarItem.read(from: pasteboard)

      #expect(decoded == nil)
    }
  }
#endif
