import Foundation

extension UITestIdentifiers {
  // MARK: - CryptoSettings

  public enum CryptoSettings {
    /// Root container of the `CryptoSettingsView` Form. Sentinel for the
    /// "Crypto tab is on screen" post-condition after switching tabs in the
    /// macOS Settings window.
    public static let container = "crypto.settings.container"

    /// "+" toolbar button in the Crypto tab header that opens
    /// `AddTokenSheet`. Tapping it presents the embedded
    /// `InstrumentPickerSheet` filtered to crypto tokens.
    public static let addTokenButton = "crypto.settings.addToken"

    /// A row in the registered-tokens list. The qualifier is the
    /// `CryptoRegistration.id`, which is the Instrument id (e.g.
    /// `1:0x1f9840…f984`).
    public static func registrationRow(_ id: String) -> String {
      "crypto.settings.registration.\(id)"
    }

    /// Secure field for the Alchemy API key. Pinned so a UI test can
    /// drive the settings flow end-to-end.
    public static let alchemyApiKeyField = "crypto.settings.alchemy.field"

    /// "Save" button next to the Alchemy API key entry field.
    public static let alchemyApiKeySaveButton = "crypto.settings.alchemy.save"

    /// "Remove" button shown when an Alchemy key is already configured.
    public static let alchemyApiKeyRemoveButton = "crypto.settings.alchemy.remove"

    /// Secure field for the CryptoCompare API key. Pinned so a UI test
    /// can drive the settings flow end-to-end.
    public static let cryptoCompareApiKeyField = "crypto.settings.cryptocompare.field"

    /// "Save" button next to the CryptoCompare API key entry field.
    public static let cryptoCompareApiKeySaveButton = "crypto.settings.cryptocompare.save"

    /// "Remove" button shown when a CryptoCompare key is already
    /// configured.
    public static let cryptoCompareApiKeyRemoveButton = "crypto.settings.cryptocompare.remove"

    /// Navigation row that opens the Discovered Tokens inbox.
    public static let discoveredTokensRow = "crypto.settings.discoveredTokens"

    /// Navigation row that opens the Spam Tokens management view.
    public static let spamTokensRow = "crypto.settings.spamTokens"

    /// A row inside the Discovered Tokens inbox. Qualifier is the
    /// `CryptoRegistration.id`.
    public static func discoveredRow(_ id: String) -> String {
      "crypto.settings.discovered.\(id)"
    }

    /// "Mark as spam" button on a Discovered Tokens row.
    public static func markSpamButton(_ id: String) -> String {
      "crypto.settings.discovered.spam.\(id)"
    }

    /// "Re-resolve" button on a Discovered Tokens row.
    public static func reResolveButton(_ id: String) -> String {
      "crypto.settings.discovered.reresolve.\(id)"
    }

    /// A row inside the Spam Tokens management view. Qualifier is the
    /// `CryptoRegistration.id`.
    public static func spamRow(_ id: String) -> String {
      "crypto.settings.spam.\(id)"
    }

    /// "Restore" button on a Spam Tokens row — flips status back to
    /// `.unpriced` so the row returns to the Discovered Tokens inbox.
    public static func restoreButton(_ id: String) -> String {
      "crypto.settings.spam.restore.\(id)"
    }
  }
}
