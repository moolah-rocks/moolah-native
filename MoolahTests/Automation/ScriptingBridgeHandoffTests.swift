#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import Moolah

  private final class BridgeRecorder {
    var openedProfiles: [UUID] = []
    var setNavigations: [PendingNavigation] = []
  }

  @Suite("ScriptingBridge Handoff", .serialized)
  @MainActor
  struct ScriptingBridgeHandoffTests {

    private func withRecorder<R>(_ body: (BridgeRecorder) throws -> R) rethrows -> R {
      let priorOpen = NavigationBridge.openProfile
      let priorSet = NavigationBridge.setPendingNavigation
      defer {
        NavigationBridge.openProfile = priorOpen
        NavigationBridge.setPendingNavigation = priorSet
      }
      let recorder = BridgeRecorder()
      NavigationBridge.openProfile = { recorder.openedProfiles.append($0) }
      NavigationBridge.setPendingNavigation = { recorder.setNavigations.append($0) }
      return try body(recorder)
    }

    private func makeActivity(_ payload: HandoffPayload) -> NSUserActivity {
      let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
      activity.configureHandoff(payload: payload, title: "t")
      return activity
    }

    @Test("returns true and drives the bridge for a valid continuation activity")
    func validActivityDrivesBridge() throws {
      let profileID = try #require(UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"))
      let payload = HandoffPayload(profileID: profileID, destination: .accounts)
      // UUID is not registered with ProfileWindowLocator — locator returns
      // false and HandoffContinuationHandler takes the open-profile path.
      let bridge = ScriptingBridge()
      let activity = makeActivity(payload)

      withRecorder { recorder in
        let handled = bridge.application(
          NSApp,
          continue: activity,
          restorationHandler: { _ in })
        #expect(handled)
        #expect(recorder.openedProfiles == [profileID])
        #expect(recorder.setNavigations.count == 1)
      }
    }

    @Test("returns false for an activity with the wrong type")
    func wrongTypeReturnsFalse() {
      let activity = NSUserActivity(activityType: "com.example.other")
      let bridge = ScriptingBridge()

      withRecorder { recorder in
        let handled = bridge.application(
          NSApp,
          continue: activity,
          restorationHandler: { _ in })
        #expect(!handled)
        #expect(recorder.openedProfiles.isEmpty)
        #expect(recorder.setNavigations.isEmpty)
      }
    }

    @Test("drops silently and returns true when the payload is missing")
    func missingPayloadIsDropped() {
      let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
      // No userInfo set — handoffPayload returns nil.
      let bridge = ScriptingBridge()

      withRecorder { recorder in
        let handled = bridge.application(
          NSApp,
          continue: activity,
          restorationHandler: { _ in })
        // Returns true to signal AppKit we've consumed the activity. The
        // `#386` auto-spawn guard lives on the WindowGroup itself
        // (`.handlesExternalEvents(matching: [])`), not here. No bridge
        // calls because the payload was malformed.
        #expect(handled)
        #expect(recorder.openedProfiles.isEmpty)
        #expect(recorder.setNavigations.isEmpty)
      }
    }

    @Test("drops silently and returns true when the payload is unparseable")
    func unparseablePayloadIsDropped() {
      let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
      activity.userInfo = ["payload": Data([0xFF, 0xFE])]
      let bridge = ScriptingBridge()

      withRecorder { recorder in
        let handled = bridge.application(
          NSApp,
          continue: activity,
          restorationHandler: { _ in })
        #expect(handled)
        #expect(recorder.openedProfiles.isEmpty)
        #expect(recorder.setNavigations.isEmpty)
      }
    }
  }
#endif
