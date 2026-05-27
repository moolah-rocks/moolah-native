#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import Moolah

  /// Pins the JSON round-trip behaviour of the `DraggableSidebarItem`
  /// pasteboard codec. The macOS `NSOutlineView` drag source writes
  /// items onto `NSPasteboardItem`s and the drop receiver reads them
  /// back; if the encoding changes shape we want a unit-test failure
  /// rather than a silent drag-and-drop regression at runtime.
  @MainActor
  @Suite
  struct DraggableSidebarItemPasteboardTests {
    @Test
    func roundTripsAccountThroughPasteboardItem() throws {
      let id = UUID()
      let original = DraggableSidebarItem(kind: .account, id: id)
      let pbItem = try #require(original.pasteboardItem())
      let decoded = try #require(DraggableSidebarItem.read(from: pbItem))
      #expect(decoded.kind == .account)
      #expect(decoded.id == id)
    }

    @Test
    func roundTripsGroupThroughPasteboardItem() throws {
      let id = UUID()
      let original = DraggableSidebarItem(kind: .group, id: id)
      let pbItem = try #require(original.pasteboardItem())
      let decoded = try #require(DraggableSidebarItem.read(from: pbItem))
      #expect(decoded.kind == .group)
      #expect(decoded.id == id)
    }

    @Test
    func readReturnsNilForUnrelatedPasteboardType() {
      let pbItem = NSPasteboardItem()
      pbItem.setString("hello", forType: .string)
      #expect(DraggableSidebarItem.read(from: pbItem) == nil)
    }

    @Test
    func readReturnsNilForCorruptPayload() {
      let pbItem = NSPasteboardItem()
      pbItem.setData(Data("not json".utf8), forType: DraggableSidebarItem.pasteboardType)
      #expect(DraggableSidebarItem.read(from: pbItem) == nil)
    }
  }
#endif
