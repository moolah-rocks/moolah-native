import AppKit
import SwiftUI

extension NSTableCellView {
  /// Builds an `NSTableCellView` whose only subview is an
  /// `NSHostingView` rendering `swiftUIContent`. Per the upstream
  /// `OutlineView` README, `NSTableCellView` is the preferred cell base
  /// class because `NSTableRowView` cascades the right `backgroundStyle`
  /// (`.emphasized` vs `.normal`) into the cell's text field on
  /// selection — direct `NSHostingView` rows lose that treatment. The
  /// hosting view's SwiftUI content can still pick up the selected /
  /// emphasised state via `@Environment(\.backgroundStyle)` from inside
  /// the wrapped view tree.
  ///
  /// `accessibilityIdentifier` is applied to the wrapped SwiftUI
  /// content via `.accessibilityIdentifier(_:)` so XCUITest resolves the
  /// row via the same identifier the SwiftUI sidebar uses today.
  ///
  /// moolah: `cell.setAccessibilityIdentifier(_:)` alone is not enough
  /// here — `NSTableCellView` is not itself an accessibility element by
  /// default, so XCUITest's tree exposes its child `NSHostingView` (and
  /// the SwiftUI elements beneath it) instead. Calling
  /// `setAccessibilityIdentifier` on the cell silently has no effect on
  /// the element the test harness sees. Wrapping the SwiftUI content in
  /// `.accessibilityIdentifier(_:)` puts the identifier on the leaf
  /// element XCUITest actually resolves, matching how every other
  /// sidebar row attaches its identifier (`SidebarView+Groups.swift`,
  /// `SidebarView+Sections.swift`). The cell-side call is preserved
  /// belt-and-braces in case future AppKit changes expose it.
  ///
  /// moolah: an optional `menu` parameter attaches an AppKit `NSMenu`
  /// directly to the cell's `menu` property. This is the right-click
  /// menu for the cell. Using an AppKit menu (rather than a SwiftUI
  /// `.contextMenu` on the hosted view) is required because the hosted
  /// SwiftUI tree is rebuilt by the vendored `OutlineView` controller
  /// whenever the data source changes — if a SwiftUI context menu is
  /// open while AccountStore re-emits, the menu's host view is replaced
  /// under AppKit's foot and the menu dismisses or never opens (see
  /// `EditAccountValuationPickerTests` flake hunt). An AppKit `NSMenu`
  /// attached to the cell is owned by AppKit's menu-tracking session,
  /// independent of any SwiftUI re-render.
  static func hosting<Content: View>(
    accessibilityIdentifier: String? = nil,
    menu: NSMenu? = nil,
    @ViewBuilder content: () -> Content
  ) -> NSTableCellView {
    let cell = NSTableCellView()
    let host = MenuForwardingHostingView(
      rootView: cellRootView(
        content: content(),
        accessibilityIdentifier: accessibilityIdentifier
      ))
    host.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(host)
    // moolah: padding mirrors what SwiftUI `List(.sidebar)` rows apply
    // around their hosted content — without it, NSHostingView's
    // fittingSize collapses to the bare HStack content height (~16pt)
    // and the outline rows pack visibly tighter than the surrounding
    // SwiftUI sections.
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

  // moolah: small wrapper so the identifier is only attached when
  // the caller supplies one — applying `.accessibilityIdentifier("")`
  // would clobber any identifier the wrapped SwiftUI content sets on
  // its own subtree.
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

// moolah: `NSHostingView` subclass whose `menu(for:)` falls back to its
// `superview?.menu` if the hosted SwiftUI tree does not return one. The
// hosted SwiftUI content does not declare a `.contextMenu` (we use an
// AppKit `NSMenu` on the enclosing `NSTableCellView` to dodge the
// SwiftUI-rebuild flake — see
// `NSTableCellView.hosting(accessibilityIdentifier:menu:content:)`),
// so without this override the right-click event sees no menu on the
// hit-tested view and AppKit gives up. Forwarding to the cell's menu
// lets AppKit's responder chain find the menu we attached to the cell.
private final class MenuForwardingHostingView<Content: View>: NSHostingView<Content> {
  override func menu(for event: NSEvent) -> NSMenu? {
    if let inherited = super.menu(for: event) {
      return inherited
    }
    return superview?.menu
  }
}
