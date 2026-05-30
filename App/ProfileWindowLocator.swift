#if os(macOS)
  import AppKit
  import Foundation
  import SwiftUI

  /// Finds and activates the existing window for a profile without going
  /// through the `moolah://` URL scheme — used by AppleScript and App Intents
  /// to focus an already-open profile without triggering SwiftUI's
  /// `WindowGroup(for:)` auto-spawn on URL events. See issue #378.
  ///
  /// Per-window identifiers are stamped onto the `NSWindow` by
  /// `ProfileWindowView` via `WindowAccessor`.
  enum ProfileWindowLocator {

    /// Common prefix on every per-profile window identifier — exposed so
    /// `anyProfileWindowPresent(in:)` can detect "any profile window is
    /// on screen" without enumerating profile IDs.
    static let identifierPrefix = "moolah.profile."

    /// Stable per-profile identifier; matches the one `ProfileWindowView`
    /// writes to `NSWindow.identifier`.
    static func identifier(for profileID: UUID) -> NSUserInterfaceItemIdentifier {
      NSUserInterfaceItemIdentifier("\(identifierPrefix)\(profileID.uuidString)")
    }

    /// Returns the first window in `windows` whose identifier matches the
    /// given profile. Pure lookup — the side-effecting version is
    /// `activateExistingWindow(for:)`.
    @MainActor
    static func existingWindow(for profileID: UUID, in windows: [NSWindow]) -> NSWindow? {
      let target = identifier(for: profileID)
      return windows.first { $0.identifier == target }
    }

    /// Returns a window in `windows` tagged for `profileID` that is not
    /// `currentWindow` — i.e. a duplicate. Used by
    /// `ProfileWindowView.tagHostingWindow` to detect and close
    /// duplicates. Returning a value means the caller should close
    /// `currentWindow` and focus the returned window.
    @MainActor
    static func duplicateWindow(
      for profileID: UUID,
      currentWindow: NSWindow,
      in windows: [NSWindow]
    ) -> NSWindow? {
      let target = identifier(for: profileID)
      return windows.first { $0 !== currentWindow && $0.identifier == target }
    }

    /// `true` when any window in `windows` is tagged with a per-profile
    /// identifier (i.e. some profile is presented in a
    /// `ProfileWindowView`). Used by
    /// `ProfileWindowView.nilBindingIsRedundant` so a state-restored
    /// nil-binding window can dismiss itself instead of lingering on a
    /// Welcome screen beside an already-presented profile.
    @MainActor
    static func anyProfileWindowPresent(in windows: [NSWindow]) -> Bool {
      windows.contains { window in
        guard let raw = window.identifier?.rawValue else { return false }
        return raw.hasPrefix(identifierPrefix)
      }
    }

    /// Brings the worktree's existing window for the profile to the front.
    /// Returns `true` if a window was found and activated; `false` if the
    /// caller should open a new window (e.g. via the scene's `openWindow`
    /// action) instead.
    @MainActor
    @discardableResult
    static func activateExistingWindow(for profileID: UUID) -> Bool {
      guard let window = existingWindow(for: profileID, in: NSApp.windows) else {
        return false
      }
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      return true
    }

    /// Focuses the existing window for the profile if one is on screen,
    /// otherwise calls `openWindow(value:)` to create a new one. Every
    /// in-app caller that opens a profile window goes through this helper
    /// so we never request a second window for a profile that is already
    /// presented — the one-window-per-profile invariant.
    ///
    /// Defence in depth alongside the duplicate-window guard in
    /// `ProfileWindowView.tagHostingWindow`: that guard will close any
    /// duplicate that does slip through (e.g. SwiftUI state restoration
    /// of a stale window from a prior version), but routing every caller
    /// here avoids the user-visible flash of a duplicate appearing and
    /// then closing itself.
    @MainActor
    static func openOrActivate(_ profileID: UUID, openWindow: OpenWindowAction) {
      if !activateExistingWindow(for: profileID) {
        openWindow(value: profileID)
      }
    }
  }
#endif
