#if os(macOS)
  import SwiftUI

  /// Hidden view hosted by the launcher Window. On `.task` it opens the
  /// main `ProfileWindowView` window and then stays around as a 1×1
  /// invisible window for the lifetime of the test process. Both seeded
  /// and Welcome (no-profile) launches use `openWindow(id:)`: the
  /// `WindowGroup(for:)` window opens with a nil binding, and
  /// `ProfileWindowView(profileID: uiTestingProfileId ?? profileID)`
  /// in `MoolahApp` pins the window to the seeded profile when one
  /// exists and falls back to `WelcomeView` otherwise.
  ///
  /// We avoid `openWindow(value:)` here because `MoolahApp`'s main
  /// `WindowGroup` uses `.handlesExternalEvents(matching: [])` to block
  /// SwiftUI's `#386` Handoff auto-spawn, and the empty match set also
  /// blocks cross-scene `openWindow(value:)` routing into that group —
  /// see the rationale comment above the modifier in `MoolahApp.swift`.
  ///
  /// The launcher Window is `.defaultLaunchBehavior(.suppressed)` in
  /// production, so this view is never instantiated outside
  /// `--ui-testing`. **Why we don't dismiss it:** dismissing the
  /// launcher immediately after `openWindow` lets the dismiss race
  /// ahead of the open's scene materialisation on cold-start CI
  /// runners and leave the app windowless — the launcher's Window
  /// goes away before the WindowGroup spawns its own, and SwiftUI
  /// then has nothing to show (issue #493). Leaving the launcher
  /// around eliminates the race deterministically: a
  /// `Color.clear`/1×1 frame is invisible to users, and UI test
  /// drivers locate elements by accessibility identifier, so a second
  /// content-free window adds nothing to the tree they care about.
  struct UITestingLauncherView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .task {
          openWindow(id: MoolahApp.mainWindowID)
        }
    }
  }
#endif
