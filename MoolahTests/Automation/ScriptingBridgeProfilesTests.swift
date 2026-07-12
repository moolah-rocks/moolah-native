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
      let snapshot = ScriptableProfileSnapshot(session: session).including(
        transaction: transaction)
      let scriptable = ScriptableTransaction(transaction: transaction, snapshot: snapshot)
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

  extension ScriptingBridgeProfilesTests {
    @Test("account exposes transactions containing one of its legs")
    func accountExposesTransactionsContainingItsLegs() async throws {
      let (service, session) = try await AutomationTestSession.make()
      let checking = try await service.createAccount(
        profileIdentifier: "Test", name: "Checking", type: .bank)
      let savings = try await service.createAccount(
        profileIdentifier: "Test", name: "Savings", type: .bank)

      let checkingOnly = try await service.createTransaction(
        profileIdentifier: "Test",
        payee: "Market",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        legs: [
          AutomationService.LegSpec(
            accountName: "Checking",
            amount: -25,
            categoryName: nil,
            earmarkName: nil)
        ])
      let transfer = try await service.createTransaction(
        profileIdentifier: "Test",
        payee: "Transfer",
        date: Date(timeIntervalSince1970: 1_700_086_400),
        legs: [
          AutomationService.LegSpec(
            accountName: "Checking",
            amount: -100,
            categoryName: nil,
            earmarkName: nil),
          AutomationService.LegSpec(
            accountName: "Savings",
            amount: 100,
            categoryName: nil,
            earmarkName: nil),
        ])

      await session.transactionStore.load(filter: TransactionFilter())
      await expectEventually("created transactions are visible to the scriptable profile") {
        session.transactionStore.transactions.count == 2
      }

      let profile = ScriptableProfile(session: session)
      let checkingAccount = try #require(
        profile.scriptableAccounts.first { $0.uniqueID == checking.id.uuidString })
      let savingsAccount = try #require(
        profile.scriptableAccounts.first { $0.uniqueID == savings.id.uuidString })

      #expect(
        Set(checkingAccount.scriptableTransactions.map(\.uniqueID))
          == Set([checkingOnly.id.uuidString, transfer.id.uuidString]))
      #expect(savingsAccount.scriptableTransactions.map(\.uniqueID) == [transfer.id.uuidString])
    }

    @Test("account reached through a leg exposes its transactions without recursion")
    func legAccountExposesTransactionsWithoutRecursion() async throws {
      let (service, session) = try await AutomationTestSession.make()
      _ = try await service.createAccount(
        profileIdentifier: "Test", name: "Checking", type: .bank)
      let transaction = try await service.createTransaction(
        profileIdentifier: "Test",
        payee: "Market",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        legs: [
          AutomationService.LegSpec(
            accountName: "Checking",
            amount: -25,
            categoryName: nil,
            earmarkName: nil)
        ])

      await session.transactionStore.load(filter: TransactionFilter())
      await expectEventually("created transaction is visible to the scriptable profile") {
        session.transactionStore.transactions.count == 1
      }

      let profile = ScriptableProfile(session: session)
      let account = try #require(profile.scriptableLegs.first?.account)

      #expect(account.scriptableTransactions.map(\.uniqueID) == [transaction.id.uuidString])
    }

    @Test("find results share returned transactions through their leg accounts")
    func findResultsShareTransactionsThroughLegAccounts() async throws {
      let (service, session) = try await AutomationTestSession.make()
      let checking = try await service.createAccount(
        profileIdentifier: "Test", name: "Checking", type: .bank)

      await expectEventually("created account is visible to the scriptable snapshot") {
        session.accountStore.accounts.by(id: checking.id) != nil
      }

      let baseSnapshot = ScriptableProfileSnapshot(session: session)
      let first = try await service.createTransaction(
        profileIdentifier: "Test",
        payee: "First",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        legs: [
          AutomationService.LegSpec(
            accountName: "Checking",
            amount: -10,
            categoryName: nil,
            earmarkName: nil)
        ])
      let second = try await service.createTransaction(
        profileIdentifier: "Test",
        payee: "Second",
        date: Date(timeIntervalSince1970: 1_700_086_400),
        legs: [
          AutomationService.LegSpec(
            accountName: "Checking",
            amount: -20,
            categoryName: nil,
            earmarkName: nil)
        ])

      let returned = [first, second]
      let sharedSnapshot = baseSnapshot.including(transactions: returned)
      let scriptableResults = returned.map {
        ScriptableTransaction(transaction: $0, snapshot: sharedSnapshot)
      }
      let expectedIDs = Set(returned.map { $0.id.uuidString })

      for result in scriptableResults {
        let account = try #require(result.scriptableLegs.first?.account)
        #expect(Set(account.scriptableTransactions.map(\.uniqueID)) == expectedIDs)
      }
    }
  }
#endif
