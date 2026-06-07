#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(
    subsystem: "com.moolah.app", category: "ClearInvestmentValuesCommand")

  /// Handles: `clear investment values of account "A" of profile "P"`
  ///
  /// Deletes every recorded investment value for the named account (see
  /// `AutomationService.clearInvestmentValues`) and returns the number of
  /// value rows removed.
  class ClearInvestmentValuesCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        return fail("Missing profile specifier")
      }
      guard let args = evaluatedArguments,
        let accountName = args["account"] as? String, !accountName.isEmpty
      else {
        return fail("Missing required parameter: account")
      }

      let result: NSNumber? = runBlockingWithError { @MainActor () async throws -> NSNumber in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        let count = try await service.clearInvestmentValues(
          profileIdentifier: profileName, accountName: accountName)
        return count as NSNumber
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
