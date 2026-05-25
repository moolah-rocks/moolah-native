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

  static func `continue`(payload: HandoffPayload) {
    let nav = PendingNavigation(
      profileId: payload.profileID,
      destination: payload.destination)
    #if os(macOS)
      if !ProfileWindowLocator.activateExistingWindow(for: payload.profileID) {
        guard let opener = NavigationBridge.openProfile else {
          logger.warning("NavigationBridge.openProfile unset — dropping handoff")
          return
        }
        opener(payload.profileID)
      }
    #else
      guard let opener = NavigationBridge.openProfile else {
        logger.warning("NavigationBridge.openProfile unset — dropping handoff")
        return
      }
      opener(payload.profileID)
    #endif

    guard let setter = NavigationBridge.setPendingNavigation else {
      logger.warning("NavigationBridge.setPendingNavigation unset — dropping handoff")
      return
    }
    setter(nav)
  }
}
