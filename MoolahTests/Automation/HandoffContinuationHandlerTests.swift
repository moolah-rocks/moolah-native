import Foundation
import Testing

@testable import Moolah

/// Captures calls into NavigationBridge so we can assert order/arguments
/// without driving a real scene graph.
private final class BridgeRecorder {
  var openedProfiles: [UUID] = []
  var setNavigations: [PendingNavigation] = []
}

@Suite("HandoffContinuationHandler", .serialized)
@MainActor
struct HandoffContinuationHandlerTests {

  /// Installs recorder closures on NavigationBridge for the duration of
  /// the test, restoring the prior closures on tear-down.
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

  private func samplePayload() throws -> HandoffPayload {
    HandoffPayload(
      profileID: try #require(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")),
      destination: .account(try #require(UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))))
  }

  #if os(macOS)
    // NOTE: The "existing window" branch (locator returns true → openProfile
    // NOT called) is intentionally NOT integration-tested here. Constructing
    // a real NSWindow registers it with NSApp.windows for the lifetime of the
    // test process and leaks across tests, destabilising the macOS bundle.
    // The branch itself is two lines in `HandoffContinuationHandler.continue`
    // and `ProfileWindowLocator` has its own unit tests
    // (`ProfileWindowLocatorTests`).

    @Test("macOS: no window → openProfile then setPendingNavigation, in that order")
    func macOSNoWindowOpensProfileFirst() throws {
      // Use a fresh UUID nothing is registered for, so the locator returns false.
      let payload = try samplePayload()
      withRecorder { recorder in
        HandoffContinuationHandler.continue(payload: payload)
        #expect(recorder.openedProfiles == [payload.profileID])
        #expect(recorder.setNavigations.count == 1)
        #expect(recorder.setNavigations.first?.profileId == payload.profileID)
      }
    }
  #else
    @Test("iOS: openProfile then setPendingNavigation, in that order")
    func iOSAlwaysOpensProfileFirst() throws {
      let payload = try samplePayload()
      withRecorder { recorder in
        HandoffContinuationHandler.continue(payload: payload)
        #expect(recorder.openedProfiles == [payload.profileID])
        #expect(recorder.setNavigations.count == 1)
        #expect(recorder.setNavigations.first?.profileId == payload.profileID)
      }
    }
  #endif
}
