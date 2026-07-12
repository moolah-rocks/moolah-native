#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "SetCommand")

  /// Handles AppleScript assignment for mutable Moolah properties.
  ///
  /// The standard Cocoa KVC setter path is synchronous, while Moolah writes are
  /// async repository/store operations. This command keeps AppleScript's normal
  /// `set ... to ...` syntax but routes writable domain properties through the
  /// same suspend/resume pattern as explicit automation commands.
  final class SetCommand: NSSetCommand {
    override func execute() -> Any? {
      performDefaultImplementation()
    }

    override func performDefaultImplementation() -> Any? {
      guard let propertySpecifier = keySpecifier as? NSPropertySpecifier else {
        return super.performDefaultImplementation()
      }

      do {
        guard let target = try targetObject(from: propertySpecifier) else {
          return super.performDefaultImplementation()
        }

        switch target {
        case let account as ScriptableAccount:
          return try setAccount(account, property: propertySpecifier.key, value: newValue())
        case let transaction as ScriptableTransaction:
          return try setTransaction(transaction, property: propertySpecifier.key, value: newValue())
        case let leg as ScriptableLeg:
          return try setLeg(leg, property: propertySpecifier.key, value: newValue())
        case let earmark as ScriptableEarmark:
          return try setEarmark(earmark, property: propertySpecifier.key, value: newValue())
        case let category as ScriptableCategory:
          return try setCategory(category, property: propertySpecifier.key, value: newValue())
        default:
          return super.performDefaultImplementation()
        }
      } catch {
        return fail(error.localizedDescription)
      }
    }

    private func targetObject(from propertySpecifier: NSPropertySpecifier) throws -> Any? {
      guard let container = propertySpecifier.container else { return nil }
      let evaluated = container.objectsByEvaluatingSpecifier
      if let array = evaluated as? NSArray {
        guard array.count <= 1 else {
          throw AutomationError.operationFailed(
            "Cannot set a property on multiple objects at once")
        }
        return array.firstObject
      }
      if let array = evaluated as? [Any] {
        guard array.count <= 1 else {
          throw AutomationError.operationFailed(
            "Cannot set a property on multiple objects at once")
        }
        return array.first
      }
      return evaluated
    }

    private func newValue() -> Any? {
      evaluatedArguments?["Value"] ?? evaluatedArguments?["value"] ?? evaluatedArguments?["to"]
    }
  }

  extension SetCommand {
    private func setAccount(
      _ account: ScriptableAccount,
      property: String,
      value: Any?
    ) throws -> Any? {
      let changes: AccountChanges
      switch property {
      case "name":
        changes = AccountChanges(name: try Self.string(from: value, property: "account name"))
      case "isHidden":
        changes = AccountChanges(hidden: .setTo(try Self.bool(from: value, property: "hidden")))
      default:
        return super.performDefaultImplementation()
      }

      guard let accountId = UUID(uuidString: account.uniqueID) else {
        throw AutomationError.accountNotFound(account.uniqueID)
      }

      let result: ScriptableAccount? = runBlockingWithError {
        @MainActor () async throws -> ScriptableAccount in
        let service = try Self.requireService()
        let updated = try await service.updateAccount(
          profileIdentifier: account.scriptProfileName,
          accountId: accountId,
          changes: changes)
        let session = try service.resolveSession(for: account.scriptProfileName)
        let snapshot = ScriptableProfileSnapshot(session: session).including(account: updated)
        return ScriptableAccount(account: updated, snapshot: snapshot)
      }
      return result
    }

    private func setTransaction(
      _ transaction: ScriptableTransaction,
      property: String,
      value: Any?
    ) throws -> Any? {
      let payee: String?
      let date: Date?
      let notes: String?
      switch property {
      case "payee":
        payee = try Self.string(from: value, property: "payee")
        date = nil
        notes = nil
      case "date":
        payee = nil
        date = try Self.date(from: value, property: "date")
        notes = nil
      case "notes":
        payee = nil
        date = nil
        notes = try Self.string(from: value, property: "notes")
      default:
        return super.performDefaultImplementation()
      }

      guard let transactionId = UUID(uuidString: transaction.uniqueID) else {
        throw AutomationError.transactionNotFound(transaction.uniqueID)
      }

      let result: ScriptableTransaction? = runBlockingWithError {
        @MainActor () async throws -> ScriptableTransaction in
        let service = try Self.requireService()
        let updated = try await service.updateTransaction(
          profileIdentifier: transaction.scriptProfileName,
          transactionId: transactionId,
          payee: payee,
          date: date,
          notes: notes)
        let session = try service.resolveSession(for: transaction.scriptProfileName)
        let snapshot = ScriptableProfileSnapshot(session: session).including(transaction: updated)
        return ScriptableTransaction(
          transaction: updated,
          snapshot: snapshot)
      }
      return result
    }

    private func setLeg(
      _ leg: ScriptableLeg,
      property: String,
      value: Any?
    ) throws -> Any? {
      let changes: AutomationService.LegChanges
      switch property {
      case "account":
        changes = AutomationService.LegChanges(accountName: try Self.accountChange(from: value))
      case "amount":
        changes = AutomationService.LegChanges(
          amount: try Self.decimal(from: value, property: "amount"))
      case "category":
        changes = AutomationService.LegChanges(categoryName: try Self.categoryChange(from: value))
      case "earmark":
        changes = AutomationService.LegChanges(earmarkName: try Self.earmarkChange(from: value))
      case "legType":
        changes = AutomationService.LegChanges(type: try Self.string(from: value, property: "type"))
      default:
        return super.performDefaultImplementation()
      }

      guard let legId = UUID(uuidString: leg.uniqueID) else {
        throw AutomationError.transactionNotFound("leg \(leg.uniqueID)")
      }

      let result: ScriptableTransaction? = runBlockingWithError {
        @MainActor () async throws -> ScriptableTransaction in
        let service = try Self.requireService()
        let updated = try await service.updateLeg(
          profileIdentifier: leg.scriptProfileName,
          legId: legId,
          changes: changes)
        let session = try service.resolveSession(for: leg.scriptProfileName)
        let snapshot = ScriptableProfileSnapshot(session: session).including(transaction: updated)
        return ScriptableTransaction(
          transaction: updated,
          snapshot: snapshot)
      }
      return result
    }

    private func setEarmark(
      _ earmark: ScriptableEarmark,
      property: String,
      value: Any?
    ) throws -> Any? {
      let name: String?
      let targetAmount: Decimal?
      switch property {
      case "name":
        name = try Self.string(from: value, property: "earmark name")
        targetAmount = nil
      case "targetAmount":
        name = nil
        targetAmount = try Self.decimal(from: value, property: "target amount")
      default:
        return super.performDefaultImplementation()
      }

      guard let earmarkId = UUID(uuidString: earmark.uniqueID) else {
        throw AutomationError.earmarkNotFound(earmark.uniqueID)
      }

      let result: ScriptableEarmark? = runBlockingWithError {
        @MainActor () async throws -> ScriptableEarmark in
        let service = try Self.requireService()
        let updated = try await service.updateEarmark(
          profileIdentifier: earmark.scriptProfileName,
          earmarkId: earmarkId,
          name: name,
          targetAmount: targetAmount)
        return ScriptableEarmark(earmark: updated, profileName: earmark.scriptProfileName)
      }
      return result
    }

    private func setCategory(
      _ category: ScriptableCategory,
      property: String,
      value: Any?
    ) throws -> Any? {
      guard property == "name" else {
        return super.performDefaultImplementation()
      }
      guard let categoryId = UUID(uuidString: category.uniqueID) else {
        throw AutomationError.categoryNotFound(category.uniqueID)
      }
      let name = try Self.string(from: value, property: "category name")

      let result: ScriptableCategory? = runBlockingWithError {
        @MainActor () async throws -> ScriptableCategory in
        let service = try Self.requireService()
        let updated = try await service.updateCategory(
          profileIdentifier: category.scriptProfileName,
          categoryId: categoryId,
          name: name)
        let session = try service.resolveSession(for: category.scriptProfileName)
        let parentName =
          updated.parentId.flatMap {
            session.categoryStore.categories.by(id: $0)?.name
          } ?? ""
        return ScriptableCategory(
          category: updated,
          parentName: parentName,
          profileName: category.scriptProfileName)
      }
      return result
    }
  }

  extension SetCommand {
    @MainActor
    private static func requireService() throws -> AutomationService {
      guard let service = ScriptingContext.automationService else {
        throw AutomationError.operationFailed("Scripting not configured")
      }
      return service
    }

    private static func accountChange(from value: Any?) throws -> AutomationService.ReferenceChange
    {
      if isMissingValue(value) { return .clear }
      if let account = value as? ScriptableAccount {
        return try .id(uuid(from: account.uniqueID, property: "account"))
      }
      return .named(try string(from: value, property: "account"))
    }

    private static func categoryChange(from value: Any?) throws -> AutomationService.ReferenceChange
    {
      if isMissingValue(value) { return .clear }
      if let category = value as? ScriptableCategory {
        return try .id(uuid(from: category.uniqueID, property: "category"))
      }
      return .named(try string(from: value, property: "category"))
    }

    private static func earmarkChange(from value: Any?) throws -> AutomationService.ReferenceChange
    {
      if isMissingValue(value) { return .clear }
      if let earmark = value as? ScriptableEarmark {
        return try .id(uuid(from: earmark.uniqueID, property: "earmark"))
      }
      return .named(try string(from: value, property: "earmark"))
    }

    private static func uuid(from value: String, property: String) throws -> UUID {
      guard let uuid = UUID(uuidString: value) else {
        throw AutomationError.invalidParameter("Invalid \(property) id '\(value)'")
      }
      return uuid
    }

    private static func string(from value: Any?, property: String) throws -> String {
      guard let value, !isMissingValue(value) else {
        throw AutomationError.invalidParameter("Missing value for \(property)")
      }
      if let string = value as? String { return string }
      if let number = value as? NSNumber { return number.stringValue }
      throw AutomationError.invalidParameter(
        "Expected text for \(property), got \(type(of: value))")
    }

    private static func decimal(from value: Any?, property: String) throws -> Decimal {
      guard let value, !isMissingValue(value) else {
        throw AutomationError.invalidParameter("Missing value for \(property)")
      }
      if let decimal = value as? Decimal { return decimal }
      if let number = value as? NSNumber { return number.decimalValue }
      if let string = value as? String, let decimal = Decimal(string: string) {
        return decimal
      }
      throw AutomationError.invalidParameter(
        "Expected number for \(property), got \(type(of: value))")
    }

    private static func bool(from value: Any?, property: String) throws -> Bool {
      guard let value, !isMissingValue(value) else {
        throw AutomationError.invalidParameter("Missing value for \(property)")
      }
      if let bool = value as? Bool { return bool }
      if let number = value as? NSNumber { return number.boolValue }
      throw AutomationError.invalidParameter(
        "Expected boolean for \(property), got \(type(of: value))")
    }

    private static func date(from value: Any?, property: String) throws -> Date {
      guard let value, !isMissingValue(value) else {
        throw AutomationError.invalidParameter("Missing value for \(property)")
      }
      guard let date = value as? Date else {
        throw AutomationError.invalidParameter(
          "Expected date for \(property), got \(type(of: value))")
      }
      return date
    }

    private static func isMissingValue(_ value: Any?) -> Bool {
      guard let value else { return true }
      if value is NSNull { return true }
      if let descriptor = value as? NSAppleEventDescriptor {
        return descriptor.descriptorType == typeNull
      }
      return false
    }

    private func fail(_ message: String) -> Any? {
      logger.error("\(message, privacy: .public)")
      scriptErrorNumber = -10000
      scriptErrorString = message
      return nil
    }
  }
#endif
