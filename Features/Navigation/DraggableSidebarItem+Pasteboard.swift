#if canImport(AppKit)
  import AppKit
  import UniformTypeIdentifiers

  extension DraggableSidebarItem {
    /// The `NSPasteboard.PasteboardType` used when the
    /// `NSOutlineView` drag source / drop receiver shuttles a
    /// `DraggableSidebarItem` between sidebar rows. Derived from the
    /// bespoke `UTType.moolahSidebarItem.identifier` so the SwiftUI
    /// `.draggable` / `.dropDestination` path and the AppKit
    /// pasteboard path agree on a single wire identifier — otherwise
    /// a drag that crosses the SwiftUI ↔ AppKit boundary would
    /// silently be dropped as the wrong type.
    static var pasteboardType: NSPasteboard.PasteboardType {
      NSPasteboard.PasteboardType(UTType.moolahSidebarItem.identifier)
    }

    /// JSON-encodes the item onto a fresh `NSPasteboardItem` so the
    /// `NSOutlineView` drag source can hand it to AppKit. JSON keeps
    /// the wire format aligned with the `Transferable`
    /// `CodableRepresentation` path used by the SwiftUI fallback;
    /// shipping the same bytes both directions means a drag that
    /// originates in either surface decodes identically.
    ///
    /// Returns `nil` if `JSONEncoder` fails. In practice it cannot
    /// — the struct is two trivially-encodable fields — but
    /// `NSPasteboardItem.setData(_:forType:)` accepts `Data` only, so
    /// the optional return forces the call sites to consider the
    /// failure rather than force-unwrap.
    func pasteboardItem() -> NSPasteboardItem? {
      guard let data = try? JSONEncoder().encode(self) else { return nil }
      let item = NSPasteboardItem()
      item.setData(data, forType: Self.pasteboardType)
      return item
    }

    /// Inverse of `pasteboardItem()`. Returns `nil` when the item has
    /// no data for our type (foreign drag, e.g. a plain-text drop) or
    /// when the payload is present but not decodable (corrupt /
    /// cross-version mismatch). Callers treat `nil` as "drop is not
    /// for us" and fall through to the next handler.
    static func read(from item: NSPasteboardItem) -> DraggableSidebarItem? {
      guard let data = item.data(forType: pasteboardType) else { return nil }
      return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// `NSPasteboard` convenience over `read(from: NSPasteboardItem)`.
    /// Returns the first `DraggableSidebarItem` decodable from any of
    /// the pasteboard's items, or `nil` when no item carries our
    /// pasteboard type. Used by `SidebarOutlineDataSource+DragDrop`'s
    /// `validateDrop` / `acceptDrop` paths — `NSDraggingInfo` only
    /// hands them the full pasteboard, not individual items.
    static func read(from pasteboard: NSPasteboard) -> DraggableSidebarItem? {
      guard let items = pasteboard.pasteboardItems else { return nil }
      for item in items {
        if let decoded = read(from: item) { return decoded }
      }
      return nil
    }
  }
#endif
