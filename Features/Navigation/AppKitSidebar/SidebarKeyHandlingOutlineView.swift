#if os(macOS)
  import AppKit
  import Carbon.HIToolbox

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
    /// Called when the physical Return key (`kVK_Return`) is pressed.
    /// When `nil`, the event falls through to `super.keyDown(with:)`
    /// so default AppKit behaviour is preserved. Numpad Enter
    /// (`kVK_ANSI_KeypadEnter`, 76) is intentionally excluded — the
    /// iOS path does not fire on it either.
    var onReturnKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
      if event.keyCode == kVK_Return, let handler = onReturnKey {
        handler()
        return
      }
      super.keyDown(with: event)
    }
  }
#endif
