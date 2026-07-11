#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "FindTransactionsCommand")

  /// Handles: `find txns of profile "X" account "Checking" from date ...`
  final class FindTransactionsCommand: AppLevelScriptCommand {
    private struct Result: Sendable {
      let transactions: [ScriptableTransaction]
    }

    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing profile specifier"
        return nil
      }

      let args = evaluatedArguments ?? [:]
      let accountName = args["account"] as? String
      let categoryName = args["category"] as? String
      let fromDate = args["fromDate"] as? Date
      let toDate = args["toDate"] as? Date
      let scheduled =
        (args["scheduled"] as? Bool).map { isScheduled in
          isScheduled ? ScheduledFilter.scheduledOnly : .nonScheduledOnly
        } ?? .nonScheduledOnly
      let profName = profileName

      let result: Result? = runBlockingWithError {
        @MainActor () async throws -> Result in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }

        let transactions = try await service.findTransactions(
          profileIdentifier: profName,
          accountName: accountName,
          categoryName: categoryName,
          fromDate: fromDate,
          toDate: toDate,
          scheduled: scheduled
        )
        let session = try service.resolveSession(for: profName)
        let scriptableTransactions = transactions.map { transaction in
          ScriptableTransaction(
            transaction: transaction,
            profileName: profName,
            accountStore: session.accountStore,
            categoryStore: session.categoryStore,
            earmarkStore: session.earmarkStore
          )
        }
        return Result(transactions: scriptableTransactions)
      }
      return result?.transactions
    }
  }
#endif
