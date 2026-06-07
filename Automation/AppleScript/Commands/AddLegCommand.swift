#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "AddLegCommand")

  /// Handles: `add leg to txn id "T" of profile "P" account "A" amount N
  /// type "transfer" [instrument "AUD"] [category "C"] [earmark "E"]`
  ///
  /// Appends a leg to an existing transaction, carrying every other leg through
  /// unchanged so a sync-owned leg's externalId survives
  /// (see `AutomationService.addLeg`).
  class AddLegCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        return fail("Missing profile specifier")
      }
      guard let args = evaluatedArguments,
        let txnIdString = args["txnId"] as? String,
        let accountName = args["account"] as? String,
        let amount = args["amount"] as? Double,
        let type = args["type"] as? String
      else {
        return fail("Missing required parameters: id, account, amount, and type")
      }
      guard let txnId = UUID(uuidString: txnIdString) else {
        return fail("Invalid transaction id '\(txnIdString)'")
      }
      let instrumentId = (args["instrument"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      let categoryName = (args["category"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      let earmarkName = (args["earmark"] as? String).flatMap { $0.isEmpty ? nil : $0 }

      let result: ScriptableTransaction? = runBlockingWithError {
        @MainActor () async throws -> ScriptableTransaction in
        let service = try Self.requireService()
        let updated = try await service.addLeg(
          profileIdentifier: profileName,
          transactionId: txnId,
          draft: AutomationService.LegDraft(
            accountName: accountName,
            instrumentId: instrumentId,
            amount: Decimal(amount),
            type: type,
            categoryName: categoryName,
            earmarkName: earmarkName))
        let session = try service.resolveSession(for: profileName)
        return ScriptableTransaction(
          transaction: updated,
          profileName: profileName,
          accountStore: session.accountStore,
          categoryStore: session.categoryStore)
      }
      return result
    }

    @MainActor
    private static func requireService() throws -> AutomationService {
      guard let service = ScriptingContext.automationService else {
        throw AutomationError.operationFailed("Scripting not configured")
      }
      return service
    }

    private func fail(_ message: String) -> Any? {
      scriptErrorNumber = -10000
      scriptErrorString = message
      return nil
    }
  }
#endif
