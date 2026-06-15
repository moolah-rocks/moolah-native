#if os(macOS)
  import Foundation
  import Testing

  @testable import Moolah

  /// Guards `ScriptingBridge.scriptableProfiles` — the top-level element the
  /// AppleScript object model resolves for `profiles of application`. The
  /// accessor reads `SessionManager` synchronously on the `MainActor`
  /// (`assumeIsolated`); these tests exercise that path with and without a
  /// configured session.
  @Suite("ScriptingBridge scriptableProfiles", .serialized)
  @MainActor
  struct ScriptingBridgeProfilesTests {

    @discardableResult
    private func withSessionManager<R>(
      _ sessionManager: SessionManager?,
      _ body: () throws -> R
    ) rethrows -> R {
      let prior = ScriptingContext.sessionManager
      defer { ScriptingContext.sessionManager = prior }
      ScriptingContext.sessionManager = sessionManager
      return try body()
    }

    @Test("returns an empty list when the bridge has not been configured")
    func unconfiguredReturnsEmpty() {
      let bridge = ScriptingBridge()
      withSessionManager(nil) {
        #expect(bridge.scriptableProfiles.isEmpty)
      }
    }

    @Test("maps each open profile session to a ScriptableProfile")
    func mapsOpenProfiles() async throws {
      let (service, session) = try await AutomationTestSession.make()
      let bridge = ScriptingBridge()

      try withSessionManager(service.sessionManager) {
        let profiles = bridge.scriptableProfiles
        let profile = try #require(profiles.first)
        #expect(profiles.count == 1)
        #expect(profile.name == session.profile.label)
        #expect(profile.uniqueID == session.profile.id.uuidString)
      }
    }
  }
#endif
