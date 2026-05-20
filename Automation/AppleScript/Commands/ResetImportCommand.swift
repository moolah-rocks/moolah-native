#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "ResetImportCommand")

  /// Handles: `reset import of account "Coinstash" of profile "X"`
  ///
  /// Deletes every transaction with a leg on the account in a single
  /// operation so a subsequent `synchronize` re-imports it from scratch.
  /// Prefer this over iterating `delete txn id` when you want to clear an
  /// entire synced account — the bulk path is atomic and avoids O(n)
  /// AppleScript round trips.
  class ResetImportCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let specifier = directParameter as? NSScriptObjectSpecifier else {
        scriptErrorNumber = -10000
        scriptErrorString = "reset import requires an account specifier"
        return nil
      }
      guard let profileName = (specifier.container as? NSNameSpecifier)?.name else {
        scriptErrorNumber = -10000
        scriptErrorString = "Cannot determine profile for reset import"
        return nil
      }
      guard let nameSpecifier = specifier as? NSNameSpecifier else {
        scriptErrorNumber = -10000
        scriptErrorString = "reset import target must be an account name"
        return nil
      }
      let accountName = nameSpecifier.name
      let _: Void? = runBlockingWithError { @MainActor in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        let deleted = try await service.resetImportedTransactions(
          profileIdentifier: profileName, accountName: accountName)
        logger.info(
          """
          reset import: deleted \(deleted, privacy: .public) transactions on \
          \(accountName, privacy: .public)
          """)
      }
      return nil
    }
  }
#endif
