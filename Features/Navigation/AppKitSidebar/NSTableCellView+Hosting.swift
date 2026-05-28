#if os(macOS)
  import AppKit
  import SwiftUI

  extension NSTableCellView {
    /// Builds an `NSTableCellView` whose only subview is an
    /// `NSHostingView` rendering `swiftUIContent`. `NSTableCellView` is the
    /// preferred cell base class because `NSTableRowView` cascades the
    /// right `backgroundStyle` (`.emphasized` vs `.normal`) into the cell
    /// on selection — direct `NSHostingView` rows lose that treatment.
    ///
    /// `accessibilityIdentifier` is attached to the wrapped SwiftUI
    /// content via `.accessibilityIdentifier(_:)` (XCUITest sees the
    /// `NSHostingView`'s leaf, not the cell) plus a belt-and-braces
    /// `setAccessibilityIdentifier` on the cell. `menu` attaches an
    /// AppKit right-click menu directly to the cell so it survives
    /// SwiftUI re-renders that replace the hosted view tree.
    ///
    /// `exposeChildAccessibility: true` skips the SwiftUI-level
    /// identifier wrap so descendant elements (e.g. the inline rename
    /// `TextField`) remain individually discoverable in the accessibility
    /// tree. The AppKit-level `setAccessibilityIdentifier` on the cell
    /// still fires, so the row stays findable via the cell element. Use
    /// this for rows that contain a discoverable editable control.
    static func hosting<Content: View>(
      accessibilityIdentifier: String? = nil,
      exposeChildAccessibility: Bool = false,
      menu: NSMenu? = nil,
      @ViewBuilder content: () -> Content
    ) -> NSTableCellView {
      let cell = NSTableCellView()
      let swiftUIIdentifier = exposeChildAccessibility ? nil : accessibilityIdentifier
      let host = MenuForwardingHostingView(
        rootView: cellRootView(
          content: content(),
          accessibilityIdentifier: swiftUIIdentifier))
      host.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(host)
      // 4pt vertical padding mirrors what SwiftUI `List(.sidebar)`
      // applies around hosted rows; without it the NSHostingView's
      // fittingSize collapses to bare HStack height and the outline
      // packs tighter than the surrounding SwiftUI sections.
      NSLayoutConstraint.activate([
        host.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
        host.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        host.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
        host.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
      ])
      if let accessibilityIdentifier {
        cell.setAccessibilityIdentifier(accessibilityIdentifier)
      }
      cell.menu = menu
      return cell
    }

    @ViewBuilder
    private static func cellRootView<Content: View>(
      content: Content,
      accessibilityIdentifier: String?
    ) -> some View {
      if let accessibilityIdentifier {
        content.accessibilityIdentifier(accessibilityIdentifier)
      } else {
        content
      }
    }
  }

  /// `NSHostingView` subclass whose `menu(for:)` falls back to the
  /// enclosing cell's `menu` when the hosted SwiftUI tree returns none.
  /// Right-click hit-tests land inside the hosting view, and without
  /// this forward AppKit's responder chain never sees the cell's
  /// attached `NSMenu`.
  private final class MenuForwardingHostingView<Content: View>: NSHostingView<Content> {
    override func menu(for event: NSEvent) -> NSMenu? {
      if let inherited = super.menu(for: event) {
        return inherited
      }
      return superview?.menu
    }
  }
#endif
