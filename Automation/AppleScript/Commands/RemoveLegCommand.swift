#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "RemoveLegCommand")

  /// Handles: `remove leg id "L" of profile "P"`
  ///
  /// Drops the leg from its transaction, re-saving the remaining legs
  /// unchanged. Throws rather than deleting a transaction down to zero legs
  /// (see `AutomationService.removeLeg`).
  class RemoveLegCommand: AppLevelScriptCommand {
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

      let result: ScriptableTransaction? = runBlockingWithError {
        @MainActor () async throws -> ScriptableTransaction in
        let service = try Self.requireService()
        let updated = try await service.removeLeg(
          profileIdentifier: profileName, legId: legId)
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
