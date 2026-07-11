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

    @Test("profile-level legs flatten every transaction leg with transaction context")
    func profileLevelLegsIncludeTransactionContext() async throws {
      let (service, session) = try await AutomationTestSession.make()
      _ = try await service.createAccount(profileIdentifier: "Test", name: "Checking", type: .bank)
      _ = try await service.createAccount(profileIdentifier: "Test", name: "Savings", type: .bank)
      let date = try #require(
        Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 14)))

      let transaction = try await service.createTransaction(
        profileIdentifier: "Test",
        payee: "Split Shop",
        date: date,
        legs: [
          AutomationService.LegSpec(
            accountName: "Checking",
            amount: -42,
            categoryName: nil,
            earmarkName: nil),
          AutomationService.LegSpec(
            accountName: "Savings",
            amount: 42,
            categoryName: nil,
            earmarkName: nil),
        ])

      await session.transactionStore.load(filter: TransactionFilter())
      await expectEventually("created transaction is visible to scriptable profile") {
        session.transactionStore.transactions.contains { $0.transaction.id == transaction.id }
      }

      let profile = ScriptableProfile(session: session)
      let legs = profile.scriptableLegs

      #expect(legs.map(\.uniqueID) == transaction.legs.map { $0.id.uuidString })
      #expect(legs.allSatisfy { $0.transactionID == transaction.id.uuidString })
      #expect(legs.allSatisfy { $0.transactionDate == date })
      #expect(legs.allSatisfy { $0.payee == "Split Shop" })
    }

    @Test("profile-level legs can be filtered by account and category properties")
    func profileLevelLegsCanBeFilteredByAccountAndCategory() async throws {
      let (service, session) = try await AutomationTestSession.make()
      _ = try await service.createAccount(profileIdentifier: "Test", name: "Checking", type: .bank)
      _ = try await service.createAccount(profileIdentifier: "Test", name: "Savings", type: .bank)
      _ = try await service.createCategory(profileIdentifier: "Test", name: "Food")
      _ = try await service.createCategory(profileIdentifier: "Test", name: "Transport")
      let date = try #require(
        Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 14)))

      let food = try await service.createTransaction(
        profileIdentifier: "Test",
        payee: "Grocer",
        date: date,
        legs: [
          AutomationService.LegSpec(
            accountName: "Checking",
            amount: -35,
            categoryName: "Food",
            earmarkName: nil)
        ])
      _ = try await service.createTransaction(
        profileIdentifier: "Test",
        payee: "Train",
        date: date,
        legs: [
          AutomationService.LegSpec(
            accountName: "Savings",
            amount: -6,
            categoryName: "Transport",
            earmarkName: nil)
        ])

      await session.transactionStore.load(filter: TransactionFilter())
      await expectEventually("created transactions are visible to scriptable profile") {
        session.transactionStore.transactions.count == 2
      }

      let profile = ScriptableProfile(session: session)
      let checkingFoodLegs = profile.scriptableLegs.filter {
        $0.accountName == "Checking" && $0.categoryName == "Food"
      }

      #expect(checkingFoodLegs.map(\.transactionID) == [food.id.uuidString])
      #expect(checkingFoodLegs.map(\.payee) == ["Grocer"])
      #expect(checkingFoodLegs.map(\.amount) == [-35])
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
