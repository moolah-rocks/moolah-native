#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "UpdateLegCommand")

  /// Handles: `update leg id "L" of profile "P" [type "transfer"]
  /// [account "A"] [amount N] [instrument "..."] [category "C"] [earmark "E"]`
  ///
  /// Edits one leg in place; omitted fields keep their current value and the
  /// leg's id / externalId / counterpartyAddress are preserved
  /// (see `AutomationService.updateLeg`).
  class UpdateLegCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        return fail("Missing profile specifier")
      }
      guard let args = evaluatedArguments,
        let legIdString = args["legId"] as? String
      else {
        return fail("Missing required parameter: id (the leg id)")
      }
      guard let legId = UUID(uuidString: legIdString) else {
        return fail("Invalid leg id '\(legIdString)'")
      }
      let type = (args["type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      let accountName = (args["account"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      let instrumentId = (args["instrument"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      let amount = (args["amount"] as? Double).map { Decimal($0) }
      let categoryName = (args["category"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      let earmarkName = (args["earmark"] as? String).flatMap { $0.isEmpty ? nil : $0 }

      let result: ScriptableTransaction? = runBlockingWithError {
        @MainActor () async throws -> ScriptableTransaction in
        let service = try Self.requireService()
        let updated = try await service.updateLeg(
          profileIdentifier: profileName,
          legId: legId,
          changes: AutomationService.LegChanges(
            type: type,
            accountName: accountName,
            instrumentId: instrumentId,
            amount: amount,
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
