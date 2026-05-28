#if os(macOS)
  import AppKit

  /// `NSOutlineView` subclass that intercepts Return and forwards it as
  /// a high-level "begin rename on the current selection" signal via
  /// the `onReturnKey` closure. All other keys fall through to the
  /// default `keyDown` so arrow-key navigation, expand/collapse, Esc
  /// handoff, and Tab cycling behave normally.
  ///
  /// The closure is intentionally unconditional — the controller that
  /// wires this view decides whether the current selection is
  /// renamable and only fires the delegate-level callback when it is.
  /// Keeping the subclass minimal avoids leaking knowledge of
  /// `SidebarRow` into the key-handling surface.
  @MainActor
  final class SidebarKeyHandlingOutlineView: NSOutlineView {
    var onReturnKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
      if event.keyCode == 36 {  // Return
        onReturnKey?()
        return
      }
      super.keyDown(with: event)
    }
  }
#endif
