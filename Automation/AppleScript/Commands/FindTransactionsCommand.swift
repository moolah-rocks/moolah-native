#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "FindTransactionsCommand")

  /// Handles: `find txns of profile "X" account "Checking" from date ...`
  final class FindTransactionsCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileIdentifier = resolveProfileIdentifier() else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing profile specifier"
        return nil
      }

      let args = evaluatedArguments ?? [:]
      let accountName = args["account"] as? String
      let categoryName = args["category"] as? String
      let accountId: UUID?
      let categoryId: UUID?
      do {
        accountId = try parsedUUIDArgument(args["accountId"], label: "account id")
        categoryId = try parsedUUIDArgument(args["categoryId"], label: "category id")
      } catch {
        return nil
      }
      let fromDate = args["fromDate"] as? Date
      let toDate = args["toDate"] as? Date
      let scheduled =
        (args["scheduled"] as? Bool).map { isScheduled in
          isScheduled ? ScheduledFilter.scheduledOnly : .nonScheduledOnly
        } ?? .nonScheduledOnly
      let profileID = profileIdentifier

      return runBlockingWithError {
        @MainActor () async throws -> [ScriptableTransaction] in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }

        let transactions = try await service.findTransactions(
          profileIdentifier: profileID,
          accountName: accountName,
          accountId: accountId,
          categoryName: categoryName,
          categoryId: categoryId,
          fromDate: fromDate,
          toDate: toDate,
          scheduled: scheduled
        )
        return try Self.scriptableTransactions(
          transactions, profileIdentifier: profileID, service: service)
      }
    }

    private func parsedUUIDArgument(_ value: Any?, label: String) throws -> UUID? {
      guard let text = value as? String, !text.isEmpty else { return nil }
      guard let uuid = UUID(uuidString: text) else {
        scriptErrorNumber = -10000
        scriptErrorString = "Invalid \(label) '\(text)'"
        throw AutomationError.invalidParameter("Invalid \(label)")
      }
      return uuid
    }

    @MainActor
    private static func scriptableTransactions(
      _ transactions: [Transaction],
      profileIdentifier: String,
      service: AutomationService
    ) throws -> [ScriptableTransaction] {
      let session = try service.resolveSession(for: profileIdentifier)
      let snapshot = ScriptableProfileSnapshot(session: session).including(
        transactions: transactions)
      return transactions.map { transaction in
        ScriptableTransaction(
          transaction: transaction,
          snapshot: snapshot
        )
      }
    }
  }
#endif
