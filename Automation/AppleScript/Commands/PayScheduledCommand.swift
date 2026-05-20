#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "PayScheduledCommand")

  /// Handles: `pay txn id "uuid" of profile "X"`
  class PayScheduledCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let specifier = directParameter as? NSScriptObjectSpecifier else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing transaction specifier"
        return nil
      }

      // Get the transaction ID from the specifier
      guard let idSpec = specifier as? NSUniqueIDSpecifier,
        let transactionID = idSpec.uniqueID as? String,
        let uuid = UUID(uuidString: transactionID)
      else {
        scriptErrorNumber = -10000
        scriptErrorString = "Pay command requires a transaction specifier with an ID"
        return nil
      }

      // Get the profile from the container
      guard let profileSpec = specifier.container as? NSNameSpecifier else {
        scriptErrorNumber = -10000
        scriptErrorString = "Cannot determine profile for pay command"
        return nil
      }
      let profName = profileSpec.name

      let result: ScriptableTransaction? = runBlockingWithError {
        @MainActor () async throws -> ScriptableTransaction in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        let payResult = try await service.payScheduledTransaction(
          profileIdentifier: profName,
          transactionId: uuid
        )
        let session = try service.resolveSession(for: profName)
        switch payResult {
        case .paid(let updatedScheduled):
          if let updated = updatedScheduled {
            return ScriptableTransaction(
              transaction: updated,
              profileName: profName,
              accountStore: session.accountStore,
              categoryStore: session.categoryStore
            )
          }
          throw AutomationError.operationFailed(
            "Transaction was paid but no updated version returned")
        case .deleted:
          throw AutomationError.operationFailed("Scheduled transaction was deleted after payment")
        case .failed:
          throw AutomationError.operationFailed("Failed to pay scheduled transaction")
        }
      }
      return result
    }
  }
#endif
