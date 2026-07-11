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

    @Test("scriptable leg exposes object references for account category and earmark")
    func scriptableLegExposesObjectReferences() async throws {
      let (service, session) = try await AutomationTestSession.make()
      let account = try await service.createAccount(
        profileIdentifier: "Test", name: "Checking", type: .bank)
      let category = try await service.createCategory(profileIdentifier: "Test", name: "Food")
      let earmark = try await service.createEarmark(profileIdentifier: "Test", name: "Groceries")

      await expectEventually("scriptable reference stores observed created objects") {
        session.accountStore.accounts.by(id: account.id) != nil
          && session.categoryStore.categories.by(id: category.id) != nil
          && session.earmarkStore.earmarks.by(id: earmark.id) != nil
      }

      let transaction = Transaction(
        date: Date(),
        payee: "Market",
        legs: [
          TransactionLeg(
            accountId: account.id,
            instrument: session.profile.instrument,
            quantity: -18,
            type: .expense,
            categoryId: category.id,
            earmarkId: earmark.id)
        ])
      let scriptable = ScriptableTransaction(
        transaction: transaction,
        profileName: session.profile.label,
        accountStore: session.accountStore,
        categoryStore: session.categoryStore,
        earmarkStore: session.earmarkStore)
      let leg = try #require(scriptable.scriptableLegs.first)

      #expect(leg.uniqueID == transaction.legs[0].id.uuidString)
      #expect(leg.account?.uniqueID == account.id.uuidString)
      #expect(leg.account?.name == "Checking")
      #expect(leg.category?.uniqueID == category.id.uuidString)
      #expect(leg.category?.name == "Food")
      #expect(leg.earmark?.uniqueID == earmark.id.uuidString)
      #expect(leg.earmark?.name == "Groceries")
    }
  }
#endif
