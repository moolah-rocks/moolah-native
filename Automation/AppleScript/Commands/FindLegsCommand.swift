#if os(macOS)
  import AppKit
  import Foundation

  /// Handles: `find legs of profile "X" account id "..." from date ...`
  final class FindLegsCommand: AppLevelScriptCommand {
    private struct Result: Sendable {
      let legs: [ScriptableLeg]
    }

    override func performDefaultImplementation() -> Any? {
      guard let profileIdentifier = resolveProfileIdentifier() else {
        return fail("Missing profile specifier")
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

      let result: Result? = runBlockingWithError {
        @MainActor () async throws -> Result in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }

        let found = try await service.findLegs(
          profileIdentifier: profileIdentifier,
          accountName: accountName,
          accountId: accountId,
          categoryName: categoryName,
          categoryId: categoryId,
          fromDate: fromDate,
          toDate: toDate,
          scheduled: scheduled)
        let session = try service.resolveSession(for: profileIdentifier)
        let snapshot = ScriptableProfileSnapshot(session: session).including(
          transactions: found.map(\.transaction))
        let legs = found.map { entry in
          ScriptableLeg(
            leg: entry.leg,
            transaction: entry.transaction,
            snapshot: snapshot)
        }
        return Result(legs: legs)
      }
      return result?.legs
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

    private func fail(_ message: String) -> Any? {
      scriptErrorNumber = -10000
      scriptErrorString = message
      return nil
    }
  }
#endif
