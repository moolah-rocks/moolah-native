// swiftlint:disable multiline_arguments

#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "DeleteCommand")

  /// Handles: `delete account "Checking" of profile "X"`
  /// Works for accounts, transactions, earmarks, and categories.
  class DeleteCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let specifier = directParameter as? NSScriptObjectSpecifier else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing object specifier for delete"
        return nil
      }
      guard let profileName = (specifier.container as? NSNameSpecifier)?.name else {
        scriptErrorNumber = -10000
        scriptErrorString = "Cannot determine profile for delete operation"
        return nil
      }
      guard let target = resolveTarget(specifier) else {
        scriptErrorNumber = -10000
        scriptErrorString = "Cannot identify object to delete"
        return nil
      }
      let objectKey = specifier.key
      let _: Void? = runBlockingWithError { @MainActor in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        try await Self.performDelete(
          objectKey: objectKey, target: target,
          profileName: profileName, service: service)
      }
      return nil
    }

    /// Identifies the object the user wants to delete by name or unique ID.
    private struct DeleteTarget: Sendable {
      let name: String?
      let id: String?
    }

    private func resolveTarget(_ specifier: NSScriptObjectSpecifier) -> DeleteTarget? {
      if let nameSpec = specifier as? NSNameSpecifier {
        return DeleteTarget(name: nameSpec.name, id: nil)
      }
      if let idSpec = specifier as? NSUniqueIDSpecifier {
        return DeleteTarget(name: nil, id: idSpec.uniqueID as? String)
      }
      return nil
    }

    @MainActor
    private static func performDelete(
      objectKey: String,
      target: DeleteTarget,
      profileName: String,
      service: AutomationService
    ) async throws {
      switch objectKey {
      case "scriptableAccounts":
        try await deleteAccount(target: target, profileName: profileName, service: service)
      case "scriptableTransactions":
        guard let objectID = target.id, let uuid = UUID(uuidString: objectID) else {
          throw AutomationError.transactionNotFound("unknown")
        }
        try await service.deleteTransaction(profileIdentifier: profileName, transactionId: uuid)
      case "scriptableEarmarks":
        try await deleteEarmark(target: target, profileName: profileName, service: service)
      case "scriptableCategories":
        try await deleteCategory(target: target, profileName: profileName, service: service)
      default:
        throw AutomationError.operationFailed("Cannot delete objects of type '\(objectKey)'")
      }
    }

    @MainActor
    private static func deleteAccount(
      target: DeleteTarget, profileName: String, service: AutomationService
    ) async throws {
      let account: Account
      if let name = target.name {
        account = try await service.resolveAccount(named: name, profileIdentifier: profileName)
      } else if let objectID = target.id, let uuid = UUID(uuidString: objectID) {
        account = try await service.resolveAccount(id: uuid, profileIdentifier: profileName)
      } else {
        throw AutomationError.accountNotFound("unknown")
      }
      try await service.deleteAccount(profileIdentifier: profileName, accountId: account.id)
    }

    @MainActor
    private static func deleteEarmark(
      target: DeleteTarget, profileName: String, service: AutomationService
    ) async throws {
      guard let name = target.name else { throw AutomationError.earmarkNotFound("unknown") }
      let earmark = try service.resolveEarmark(named: name, profileIdentifier: profileName)
      try await service.deleteEarmark(profileIdentifier: profileName, earmarkId: earmark.id)
    }

    @MainActor
    private static func deleteCategory(
      target: DeleteTarget, profileName: String, service: AutomationService
    ) async throws {
      guard let name = target.name else { throw AutomationError.categoryNotFound("unknown") }
      let category = try service.resolveCategory(named: name, profileIdentifier: profileName)
      try await service.deleteCategory(profileIdentifier: profileName, categoryId: category.id)
    }
  }
#endif
