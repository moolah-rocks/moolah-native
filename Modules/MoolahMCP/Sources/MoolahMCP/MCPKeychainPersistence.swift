import Foundation
import Security

/// A single atomic blob contains only grant metadata and high-entropy-token verifiers.
/// Calls run on MCPGrantStore's actor, never on the UI actor.
public protocol MCPSecretPersisting: Sendable {
  /// - Returns: the complete verifier archive, or nil only when none exists; throws on access failure.
  func readData() throws -> Data?
  /// Atomically replaces the archive; throws without discarding the previous data on failure.
  func writeData(_ data: Data) throws
}

/// Fail-closed credential persistence and metadata failures, without platform error details.
public enum MCPStorageFailure: Error, Sendable {
  case unavailable
  case invalidData
  case invalidGrant
  case grantLimit
}

/// Data Protection Keychain enables the documented after-first-unlock policy on macOS.
/// No synchronization, user-presence requirement, or recoverable bearer token is stored.
public struct MCPKeychainPersistence: MCPSecretPersisting {
  let service: String

  /// Selects the device-local Keychain service namespace; performs no I/O.
  public init(service: String) {
    self.service = service
  }

  var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "mcp-grants-v1",
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  /// Reads the complete archive, returning nil only for a missing item.
  /// - Throws: unavailable for denied, locked or unreadable Keychain data. Run off the main actor.
  public func readData() throws -> Data? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw MCPStorageFailure.unavailable
    }
    return data
  }

  /// Atomically updates or inserts the archive with after-first-unlock device-only protection.
  /// - Throws: unavailable on any Keychain failure. Run off the main actor.
  public func writeData(_ data: Data) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw MCPStorageFailure.unavailable }
    let insertion = query.merging(attributes) { _, value in value }
    guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
      throw MCPStorageFailure.unavailable
    }
  }
}
