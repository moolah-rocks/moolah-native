#if os(macOS)
  import AppKit
  import Foundation

  /// AppleScript wrapper for an Earmark domain model.
  /// Data captured at construction time; all properties are nonisolated.
  @objc(ScriptableEarmark)
  final class ScriptableEarmark: NSObject, Sendable {
    private let _uniqueID: String
    private let _name: String
    private let _balance: Double
    private let _targetAmount: Double
    private let _profileName: String

    init(earmark: Earmark, profileName: String) {
      _uniqueID = earmark.id.uuidString
      _name = earmark.name
      _balance = 0
      _targetAmount = earmark.savingsGoal?.doubleValue ?? 0
      _profileName = profileName
      super.init()
    }

    @objc var uniqueID: String { _uniqueID }
    @objc var name: String { _name }
    @objc var balance: Double { _balance }
    @objc var targetAmount: Double { _targetAmount }

    var scriptProfileName: String { _profileName }

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
        key: "scriptableEarmarks",
        uniqueID: _uniqueID
      )
    }
  }
#endif
