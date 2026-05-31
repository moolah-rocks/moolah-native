import Foundation
import OSLog
import Security

enum KeychainError: LocalizedError {
  case saveFailed(OSStatus)
  case readFailed(OSStatus)

  /// Human-readable description that includes the underlying `OSStatus`
  /// and Apple's localised string for it. The raw status code surfaces
  /// even when `SecCopyErrorMessageString` returns nil (some codes have
  /// no human string on macOS).
  var errorDescription: String? {
    switch self {
    case .saveFailed(let status):
      return "Keychain save failed (OSStatus \(status): \(Self.message(for: status)))"
    case .readFailed(let status):
      return "Keychain read failed (OSStatus \(status): \(Self.message(for: status)))"
    }
  }

  private static func message(for status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) {
      return message as String
    }
    return "no description"
  }
}

private let keychainLogger = Logger(subsystem: "com.moolah.app", category: "KeychainStore")

/// Generic Keychain wrapper supporting Data and String values, with optional iCloud sync.
///
/// Used for API keys (String, synced) and cookies (Data, device-local).
struct KeychainStore: Sendable {
  let service: String
  let account: String
  let synchronizable: Bool

  init(service: String, account: String, synchronizable: Bool = false) {
    self.service = service
    self.account = account
    self.synchronizable = synchronizable
  }

  // MARK: - Data

  func saveData(_ data: Data) throws {
    let query = baseQuery()
    let deleteStatus = SecItemDelete(query as CFDictionary)
    keychainLogger.info(
      """
      saveData: service=\(self.service, privacy: .public) \
      account=\(self.account, privacy: .public) \
      synchronizable=\(self.synchronizable, privacy: .public) \
      deleteStatus=\(deleteStatus, privacy: .public)
      """
    )

    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    keychainLogger.info(
      """
      saveData: service=\(self.service, privacy: .public) \
      account=\(self.account, privacy: .public) \
      addStatus=\(status, privacy: .public)
      """
    )
    guard status == errSecSuccess else {
      throw KeychainError.saveFailed(status)
    }
  }

  func restoreData() throws -> Data? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    keychainLogger.info(
      """
      restoreData: service=\(self.service, privacy: .public) \
      account=\(self.account, privacy: .public) \
      synchronizable=\(self.synchronizable, privacy: .public) \
      copyStatus=\(status, privacy: .public)
      """
    )

    switch status {
    case errSecSuccess:
      return result as? Data
    case errSecItemNotFound:
      return nil
    default:
      throw KeychainError.readFailed(status)
    }
  }

  // MARK: - String

  func saveString(_ value: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw KeychainError.saveFailed(errSecParam)
    }
    try saveData(data)
  }

  func restoreString() throws -> String? {
    guard let data = try restoreData() else { return nil }
    return String(data: data, encoding: .utf8)
  }

  // MARK: - Clear

  func clear() {
    let query = baseQuery()
    SecItemDelete(query as CFDictionary)
  }

  // MARK: - Private

  private func baseQuery() -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if synchronizable {
      query[kSecAttrSynchronizable as String] = true
    }
    return query
  }
}
