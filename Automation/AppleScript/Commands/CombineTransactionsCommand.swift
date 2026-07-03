#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "CombineTransactionsCommand")

  /// Handles: `combine txns profile "X" ids {"uuid", "uuid", …}`
  ///
  /// Collapses the referenced transactions into one merged transaction
  /// whose legs are the union of the sources' legs (see
  /// `AutomationService.combineTransactions`). Distinct from
  /// `merge txns`, which merges two opposing sides into a transfer.
  class CombineTransactionsCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        return fail("Missing profile specifier")
      }
      guard let args = evaluatedArguments, let rawIds = args["ids"] as? [String] else {
        return fail("Missing required parameter: ids (list of transaction ids)")
      }
      guard rawIds.count >= 2 else {
        return fail("Provide at least two transaction ids to combine")
      }
      var ids: [UUID] = []
      for raw in rawIds {
        guard let id = UUID(uuidString: raw) else {
          return fail("Invalid transaction id '\(raw)'")
        }
        ids.append(id)
      }

      let result: ScriptableTransaction? = runBlockingWithError {
        @MainActor () async throws -> ScriptableTransaction in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        let merged = try await service.combineTransactions(
          profileIdentifier: profileName, ids: ids)
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
