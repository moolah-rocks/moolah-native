#if os(macOS)
  import AppKit
  import Foundation

  /// AppleScript wrapper for a Transaction domain model.
  /// Data captured at construction time; all properties are nonisolated.
  @objc(ScriptableTransaction)
  final class ScriptableTransaction: NSObject, Sendable {
    private let _uniqueID: String
    private let _date: Date
    private let _payee: String
    private let _notes: String
    private let _transactionType: String
    private let _amount: Double
    private let _isScheduled: Bool
    private let _legs: [ScriptableLeg]
    private let _profileName: String

    @MainActor
    init(
      transaction: Transaction,
      profileName: String,
      accountStore: AccountStore,
      categoryStore: CategoryStore
    ) {
      _uniqueID = transaction.id.uuidString
      _date = transaction.date
      _payee = transaction.payee ?? ""
      _notes = transaction.notes ?? ""
      _transactionType = transaction.legs.first?.type.rawValue ?? "expense"
      _isScheduled = transaction.isScheduled
      _profileName = profileName

      let total = transaction.legs.reduce(Decimal(0)) { sum, leg in
        sum + leg.quantity
      }
      _amount = Double(truncating: total as NSDecimalNumber)

      _legs = transaction.legs.enumerated().map { index, leg in
        ScriptableLeg(
          leg: leg,
          transactionID: transaction.id.uuidString,
          profileName: profileName,
          accountStore: accountStore,
          categoryStore: categoryStore,
          index: index
        )
      }

      super.init()
    }

    @objc var uniqueID: String { _uniqueID }
    @objc var date: Date { _date }
    @objc var payee: String { _payee }
    @objc var notes: String { _notes }
    @objc var transactionType: String { _transactionType }
    @objc var amount: Double { _amount }
    @objc var isScheduled: Bool { _isScheduled }
    @objc var scriptableLegs: [ScriptableLeg] { _legs }

    // MARK: - Object Specifier

    override var objectSpecifier: NSScriptObjectSpecifier? {
      guard
        let appDescription = NSScriptSuiteRegistry.shared().classDescription(
          withAppleEventCode: 0x6361_7070  // 'capp'
        )
      else {
        return nil
      }
      let profileSpecifier = NSNameSpecifier(
        containerClassDescription: appDescription,
        containerSpecifier: nil,
        key: "scriptableProfiles",
        name: _profileName
      )
      guard
        let profileDescription = NSScriptSuiteRegistry.shared().classDescription(
          withAppleEventCode: 0x5072_6F66  // 'Prof'
        )
      else {
        return nil
      }
      return NSUniqueIDSpecifier(
        containerClassDescription: profileDescription,
        containerSpecifier: profileSpecifier,
        key: "scriptableTransactions",
        uniqueID: _uniqueID
      )
    }
  }

  /// AppleScript wrapper for a TransactionLeg.
  /// Data captured at construction time; all properties are nonisolated.
  @objc(ScriptableLeg)
  final class ScriptableLeg: NSObject, Sendable {
    private let _legID: String
    private let _externalID: String
    private let _accountName: String
    private let _amount: Double
    private let _categoryName: String
    private let _legType: String
    private let _transactionID: String
    private let _profileName: String
    private let _index: Int

    @MainActor
    init(
      leg: TransactionLeg,
      transactionID: String,
      profileName: String,
      accountStore: AccountStore,
      categoryStore: CategoryStore,
      index: Int = 0
    ) {
      _legID = leg.id.uuidString
      _externalID = leg.externalId ?? ""
      _accountName = leg.accountId.flatMap { accountStore.accounts.by(id: $0)?.name } ?? ""
      _amount = leg.amount.doubleValue
      _categoryName = leg.categoryId.flatMap { categoryStore.categories.by(id: $0)?.name } ?? ""
      _legType = leg.type.rawValue
      _transactionID = transactionID
      _profileName = profileName
      _index = index
      super.init()
    }

    @objc var legID: String { _legID }
    @objc var externalID: String { _externalID }
    @objc var accountName: String { _accountName }
    @objc var amount: Double { _amount }
    @objc var categoryName: String { _categoryName }
    @objc var legType: String { _legType }

    // MARK: - Object Specifier

    override var objectSpecifier: NSScriptObjectSpecifier? {
      guard
        let appDescription = NSScriptSuiteRegistry.shared().classDescription(
          withAppleEventCode: 0x6361_7070  // 'capp'
        )
      else {
        return nil
      }
      let profileSpecifier = NSNameSpecifier(
        containerClassDescription: appDescription,
        containerSpecifier: nil,
        key: "scriptableProfiles",
        name: _profileName
      )
      guard
        let profileDescription = NSScriptSuiteRegistry.shared().classDescription(
          withAppleEventCode: 0x5072_6F66  // 'Prof'
        )
      else {
        return nil
      }
      let transactionSpecifier = NSUniqueIDSpecifier(
        containerClassDescription: profileDescription,
        containerSpecifier: profileSpecifier,
        key: "scriptableTransactions",
        uniqueID: _transactionID
      )
      guard
        let transactionDescription = NSScriptSuiteRegistry.shared().classDescription(
          withAppleEventCode: 0x5478_6E20  // 'Txn '
        )
      else {
        return nil
      }
      return NSIndexSpecifier(
        containerClassDescription: transactionDescription,
        containerSpecifier: transactionSpecifier,
        key: "scriptableLegs",
        index: _index
      )
    }
  }
#endif
