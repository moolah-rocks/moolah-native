#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "MergeTransactionsCommand")

  /// Handles: `merge txns profile "X" first "uuid" second "uuid"`
  ///
  /// Collapses the two referenced single-account transactions into one
  /// cross-account transfer (see `AutomationService.mergeTransactions`).
  class MergeTransactionsCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        return fail("Missing profile specifier")
      }
      guard let args = evaluatedArguments,
        let firstString = args["first"] as? String,
        let secondString = args["second"] as? String
      else {
        return fail("Missing required parameters: first and second (transaction ids)")
      }
      guard let firstId = UUID(uuidString: firstString) else {
        return fail("Invalid transaction id '\(firstString)' for 'first'")
      }
      guard let secondId = UUID(uuidString: secondString) else {
        return fail("Invalid transaction id '\(secondString)' for 'second'")
      }

      let result: ScriptableTransaction? = runBlockingWithError {
        @MainActor () async throws -> ScriptableTransaction in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        let merged = try await service.mergeTransactions(
          profileIdentifier: profileName, firstId: firstId, secondId: secondId)
        let session = try service.resolveSession(for: profileName)
        return ScriptableTransaction(
          transaction: merged,
          profileName: profileName,
          accountStore: session.accountStore,
          categoryStore: session.categoryStore)
      }
      return result
    }

    private func fail(_ message: String) -> Any? {
      scriptErrorNumber = -10000
      scriptErrorString = message
      return nil
    }
  }
#endif
