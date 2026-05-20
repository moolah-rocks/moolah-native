#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "CreateTransactionCommand")

  /// Handles: `create txn in profile "X" with payee "Store" amount -42.50 account "Checking"`
  class CreateTransactionCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing profile specifier"
        return nil
      }
      guard let args = evaluatedArguments,
        let payee = args["withPayee"] as? String,
        let amount = args["amount"] as? Double,
        let accountName = args["account"] as? String
      else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing required parameters: with payee, amount, and account"
        return nil
      }

      let categoryName = args["category"] as? String
      let date = args["onDate"] as? Date ?? Date()
      let notes = args["notes"] as? String
      let profName = profileName

      let result: ScriptableTransaction? = runBlockingWithError {
        @MainActor () async throws -> ScriptableTransaction in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }

        let leg = AutomationService.LegSpec(
          accountName: accountName,
          amount: Decimal(amount),
          categoryName: categoryName,
          earmarkName: nil
        )

        let transaction = try await service.createTransaction(
          profileIdentifier: profName,
          payee: payee,
          date: date,
          legs: [leg],
          notes: notes
        )
        let session = try service.resolveSession(for: profName)
        return ScriptableTransaction(
          transaction: transaction,
          profileName: profName,
          accountStore: session.accountStore,
          categoryStore: session.categoryStore
        )
      }
      return result
    }
  }
#endif
