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
  /// `accessibilityIdentifier` is forwarded onto the cell so XCUITest
  /// resolves the row via the same identifier the SwiftUI sidebar uses
  /// today.
  static func hosting<Content: View>(
    accessibilityIdentifier: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> NSTableCellView {
    let cell = NSTableCellView()
    let host = NSHostingView(rootView: content())
    host.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(host)
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
      host.topAnchor.constraint(equalTo: cell.topAnchor),
      host.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
    ])
    if let accessibilityIdentifier {
      cell.setAccessibilityIdentifier(accessibilityIdentifier)
    }
    return cell
  }
}
