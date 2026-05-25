import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "Handoff")

/// Single entry point for resuming a Handoff activity. Reuses the existing
/// `NavigationBridge` that AppleScript and App Intents already drive.
///
/// On macOS, the bridge is only called for `openProfile` when no window is
/// already showing the target profile — otherwise `ProfileWindowLocator`
/// brings the existing window forward and we skip straight to setting the
/// pending navigation.
@MainActor
enum HandoffContinuationHandler {

  /// Resumes a Handoff continuation by reactivating an existing window
  /// (macOS only) or opening the target profile, then enqueuing the
  /// pending navigation through `NavigationBridge`.
  ///
  /// Drops the continuation with a warning log if either
  /// `NavigationBridge.openProfile` or `setPendingNavigation` is nil —
  /// the bridges are populated by the active scene during its `.task`,
  /// so this should only occur if no scene is yet on-screen.
  static func `continue`(payload: HandoffPayload) {
    let nav = PendingNavigation(
      profileId: payload.profileID,
      destination: payload.destination)
    #if os(macOS)
      let alreadyOpen = ProfileWindowLocator.activateExistingWindow(for: payload.profileID)
    #else
      let alreadyOpen = false
    #endif
    if !alreadyOpen {
      guard let opener = NavigationBridge.openProfile else {
        logger.warning("NavigationBridge.openProfile unset — dropping handoff")
        return
      }
      opener(payload.profileID)
    }
    guard let setter = NavigationBridge.setPendingNavigation else {
      logger.warning("NavigationBridge.setPendingNavigation unset — dropping handoff")
      return
    }
    setter(nav)
  }
}
