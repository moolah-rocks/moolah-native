#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("AppleScript set command", .serialized)
  @MainActor
  struct SetCommandTests {
    @Test("sets the same transaction property repeatedly")
    func setsTransactionPayeeRepeatedly() async throws {
      let (service, session) = try await AutomationTestSession.make()
      _ = try await service.createAccount(
        profileIdentifier: "Test", name: "Checking", type: .bank)
      let transaction = try await service.createTransaction(
        profileIdentifier: "Test",
        payee: "Original",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        legs: [
          AutomationService.LegSpec(
            accountName: "Checking",
            amount: -25,
            categoryName: nil,
            earmarkName: nil)
        ])
      await session.transactionStore.load(filter: TransactionFilter())
      await expectEventually("created transaction is visible to AppleScript") {
        session.transactionStore.transactions.contains { $0.transaction.id == transaction.id }
      }

      try await withScriptingContext(service: service) {
        let firstSpecifier = try transactionPayeeSpecifier(
          profileName: session.profile.label,
          transactionID: transaction.id.uuidString)

        let firstCommand = try setCommand(
          propertySpecifier: firstSpecifier,
          value: "First value")
        _ = firstCommand.execute()
        await expectPayee(
          "First value",
          transactionID: transaction.id,
          session: session)

        let secondSpecifier = try transactionPayeeSpecifier(
          profileName: session.profile.label,
          transactionID: transaction.id.uuidString)
        let secondCommand = try setCommand(
          propertySpecifier: secondSpecifier,
          value: "Second value")
        _ = secondCommand.execute()
        await expectPayee(
          "Second value",
          transactionID: transaction.id,
          session: session)

        #expect(firstCommand.scriptErrorNumber == NSNoScriptError)
        #expect(secondCommand.scriptErrorNumber == NSNoScriptError)
      }
    }

    @Test("reports an AppleScript error for a stale transaction specifier")
    func staleTransactionReportsError() async throws {
      let (service, session) = try await AutomationTestSession.make()

      try await withScriptingContext(service: service) {
        let propertySpecifier = try transactionPayeeSpecifier(
          profileName: session.profile.label,
          transactionID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        let command = try setCommand(
          propertySpecifier: propertySpecifier,
          value: "Unreachable")

        _ = command.execute()

        #expect(command.scriptErrorNumber == -10000)
        #expect(command.scriptErrorString == "Operation failed: The set target no longer exists")
      }
    }
  }

  extension SetCommandTests {
    private func withScriptingContext<R>(
      service: AutomationService,
      _ body: () async throws -> R
    ) async rethrows -> R {
      let previousService = ScriptingContext.automationService
      let previousSessionManager = ScriptingContext.sessionManager
      let previousDelegate = NSApp.delegate
      let bridge = ScriptingBridge()
      defer {
        ScriptingContext.automationService = previousService
        ScriptingContext.sessionManager = previousSessionManager
        NSApp.delegate = previousDelegate
        withExtendedLifetime(bridge) {}
      }

      ScriptingContext.automationService = service
      ScriptingContext.sessionManager = service.sessionManager
      NSApp.delegate = bridge
      return try await body()
    }

    private func setCommand(
      propertySpecifier: NSPropertySpecifier,
      value: String
    ) throws -> SetCommand {
      let description = try #require(
        NSScriptSuiteRegistry.shared().commandDescription(
          withAppleEventClass: 0x636F_7265,
          andAppleEventCode: 0x7365_7464))
      let command = try #require(description.createCommandInstance() as? SetCommand)
      command.directParameter = propertySpecifier
      command.arguments = ["to": value]
      return command
    }

    private func transactionPayeeSpecifier(
      profileName: String,
      transactionID: String
    ) throws -> NSPropertySpecifier {
      let registry = NSScriptSuiteRegistry.shared()
      let appDescription = try #require(
        registry.classDescription(withAppleEventCode: 0x6361_7070))
      let profileSpecifier = NSNameSpecifier(
        containerClassDescription: appDescription,
        containerSpecifier: nil,
        key: "scriptableProfiles",
        name: profileName)
      let profileDescription = try #require(
        registry.classDescription(withAppleEventCode: 0x5072_6F66))
      let transactionSpecifier = NSUniqueIDSpecifier(
        containerClassDescription: profileDescription,
        containerSpecifier: profileSpecifier,
        key: "scriptableTransactions",
        uniqueID: transactionID)
      let transactionDescription = try #require(
        registry.classDescription(withAppleEventCode: 0x5478_6E20))
      return NSPropertySpecifier(
        containerClassDescription: transactionDescription,
        containerSpecifier: transactionSpecifier,
        key: "payee")
    }

    private func expectPayee(
      _ expectedPayee: String,
      transactionID: UUID,
      session: ProfileSession
    ) async {
      await expectEventually("transaction payee becomes \(expectedPayee)") {
        let transactions = try? await session.backend.transactions.fetchAll(
          filter: TransactionFilter())
        return transactions?.first { $0.id == transactionID }?.payee == expectedPayee
      }
    }
  }
#endif
