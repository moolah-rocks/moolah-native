#if os(macOS)
  import AppKit
  import Foundation

  /// AppleScript wrapper for a Profile / ProfileSession.
  /// Serves as the container for accounts, transactions, earmarks, and categories.
  ///
  /// Data is captured at construction time (on MainActor) and stored as plain values.
  /// The object specifier methods are nonisolated so NSScripting can call them freely.
  @objc(ScriptableProfile)
  final class ScriptableProfile: NSObject, Sendable {
    private let _uniqueID: String
    private let _name: String
    private let _currencyCode: String
    private let _accounts: [ScriptableAccount]
    private let _transactions: [ScriptableTransaction]
    private let _legs: [ScriptableLeg]
    private let _earmarks: [ScriptableEarmark]
    private let _categories: [ScriptableCategory]

    @MainActor
    init(session: ProfileSession) {
      _uniqueID = session.profile.id.uuidString
      _name = session.profile.label
      _currencyCode = session.profile.currencyCode

      _accounts = session.accountStore.accounts.ordered.map {
        ScriptableAccount(account: $0, profileName: session.profile.label)
      }
      _transactions = session.transactionStore.transactions.map {
        ScriptableTransaction(
          transaction: $0.transaction,
          profileName: session.profile.label,
          accountStore: session.accountStore,
          categoryStore: session.categoryStore,
          earmarkStore: session.earmarkStore
        )
      }
      _legs = _transactions.flatMap(\.scriptableLegs)
      _earmarks = session.earmarkStore.earmarks.ordered.map {
        ScriptableEarmark(earmark: $0, profileName: session.profile.label)
      }

      let categories = session.categoryStore.categories
      _categories = categories.flattenedByPath().map {
        let parentName: String
        if let parentId = $0.category.parentId,
          let parent = categories.by(id: parentId)
        {
          parentName = parent.name
        } else {
          parentName = ""
        }
        return ScriptableCategory(
          category: $0.category,
          parentName: parentName,
          profileName: session.profile.label
        )
      }

      super.init()
    }

    @objc var uniqueID: String { _uniqueID }
    @objc var name: String { _name }
    @objc var currencyCode: String { _currencyCode }
    @objc var scriptableAccounts: [ScriptableAccount] { _accounts }
    @objc var scriptableTransactions: [ScriptableTransaction] { _transactions }
    @objc var scriptableLegs: [ScriptableLeg] { _legs }
    @objc var scriptableEarmarks: [ScriptableEarmark] { _earmarks }
    @objc var scriptableCategories: [ScriptableCategory] { _categories }

    // MARK: - Object Specifier

    override var objectSpecifier: NSScriptObjectSpecifier? {
      guard
        let appDescription = NSScriptSuiteRegistry.shared().classDescription(
          withAppleEventCode: 0x6361_7070  // 'capp'
        )
      else {
        return nil
      }
      return NSNameSpecifier(
        containerClassDescription: appDescription,
        containerSpecifier: nil,
        key: "scriptableProfiles",
        name: _name
      )
    }
  }
#endif
