#if os(macOS)
  import AppKit
  import Foundation

  /// AppleScript wrapper for an Account domain model.
  /// Data captured at construction time; all properties are nonisolated.
  @objc(ScriptableAccount)
  final class ScriptableAccount: NSObject, Sendable {
    private let _uniqueID: String
    private let _name: String
    private let _accountType: String
    private let _balance: Double
    private let _investmentValue: Double
    private let _isHidden: Bool
    private let _profileName: String
    private let _positions: [String]

    @MainActor
    init(account: Account, profileName: String) {
      _uniqueID = account.id.uuidString
      _name = account.name
      _accountType = account.type.rawValue
      // Compute balance from positions
      let primaryPosition = account.positions.first(where: { $0.instrument == account.instrument })
      _balance = primaryPosition?.amount.doubleValue ?? 0
      _investmentValue = 0
      _isHidden = account.isHidden
      _profileName = profileName
      // One "SYMBOL=quantity" entry per held instrument, ordered by
      // instrument id (matches `Position` ordering). Multi-instrument
      // accounts (crypto / exchange) hold more than the primary; `balance`
      // alone can't express them.
      _positions = account.positions.map { "\($0.instrument.shortCode)=\($0.quantity)" }
      super.init()
    }

    @objc var uniqueID: String { _uniqueID }
    @objc var name: String { _name }
    @objc var accountType: String { _accountType }
    @objc var balance: Double { _balance }
    @objc var investmentValue: Double { _investmentValue }
    @objc var isHidden: Bool { _isHidden }
    @objc var positions: [String] { _positions }

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
        key: "scriptableAccounts",
        uniqueID: _uniqueID
      )
    }
  }
#endif
