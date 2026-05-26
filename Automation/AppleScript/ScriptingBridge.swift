#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "ScriptingBridge")

  /// Bridges the SwiftUI app to the AppleScript object model.
  /// Registered as the NSApplicationDelegate via @NSApplicationDelegateAdaptor.
  /// Exposes scriptableProfiles as the top-level element that NSApplication resolves
  /// via KVC for the SDEF's application class.
  final class ScriptingBridge: NSObject, NSApplicationDelegate {

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
      logger.info("Scripting bridge ready")
    }

    /// Receives Handoff `NSUserActivity` continuations from the OS. Routes
    /// valid payloads through `HandoffContinuationHandler`, which drives
    /// the same `NavigationBridge` that AppleScript and App Intents use.
    ///
    /// Returns `true` for every activity whose `activityType` matches
    /// `HandoffActivity.continueActivityType`, even when the payload is
    /// missing or undecodable — that signals AppKit we've consumed the
    /// activity rather than leaving it to default handling. SwiftUI's
    /// `WindowGroup` auto-spawn (the `#386` class of bug) is suppressed
    /// independently by `.handlesExternalEvents(matching: [])` on the
    /// `WindowGroup` in `MoolahApp`; returning `true` here does NOT stop
    /// it. Activities of other types return `false` so the OS can route
    /// them elsewhere.
    @MainActor
    func application(
      _ application: NSApplication,
      continue userActivity: NSUserActivity,
      restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
      guard userActivity.activityType == HandoffActivity.continueActivityType else {
        logger.debug(
          "Skipping non-Handoff activity: \(userActivity.activityType, privacy: .public)")
        return false
      }
      guard let payload = userActivity.handoffPayload else {
        logger.warning("Ignoring Handoff activity: payload missing or undecodable")
        return true
      }
      HandoffContinuationHandler.continue(payload: payload)
      return true
    }

    /// Tells the scripting infrastructure which keys the application handles.
    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
      key == "scriptableProfiles"
    }

    /// The top-level scripting element: all open profiles.
    /// Called by the scripting infrastructure when AppleScript accesses
    /// `profiles of application`. On macOS 26 this runs on the main thread,
    /// so we access `SessionManager` (also main-isolated) synchronously.
    @objc var scriptableProfiles: [ScriptableProfile] {
      if Thread.isMainThread {
        return MainActor.assumeIsolated {
          guard let sessionManager = ScriptingContext.sessionManager else {
            logger.warning("ScriptingBridge accessed before configuration")
            return []
          }
          return sessionManager.openProfiles.map { ScriptableProfile(session: $0) }
        }
      }

      // Off main — kept for whatever dedicated thread Cocoa might use in future.
      final class ResultBox: @unchecked Sendable {
        var profiles: [ScriptableProfile] = []
      }
      let box = ResultBox()
      let semaphore = DispatchSemaphore(value: 0)

      Task { @MainActor in
        if let sessionManager = ScriptingContext.sessionManager {
          box.profiles = sessionManager.openProfiles.map { ScriptableProfile(session: $0) }
        } else {
          logger.warning("ScriptingBridge accessed before configuration")
        }
        semaphore.signal()
      }

      semaphore.wait()
      return box.profiles
    }
  }
#endif
