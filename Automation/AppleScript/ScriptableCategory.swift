#if os(macOS)
  import AppKit
  import Foundation

  /// AppleScript wrapper for a Category domain model.
  /// Data captured at construction time; all properties are nonisolated.
  @objc(ScriptableCategory)
  final class ScriptableCategory: NSObject, Sendable {
    private let _uniqueID: String
    private let _name: String
    private let _parentName: String
    private let _profileName: String

    init(category: Category, parentName: String, profileName: String) {
      _uniqueID = category.id.uuidString
      _name = category.name
      _parentName = parentName
      _profileName = profileName
      super.init()
    }

    @objc var uniqueID: String { _uniqueID }
    @objc var name: String { _name }
    @objc var parentName: String { _parentName }

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
        key: "scriptableCategories",
        uniqueID: _uniqueID
      )
    }
  }
#endif
