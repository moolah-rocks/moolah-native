import Foundation
import OSLog
import Security

private let cryptoRPCEndpointsLogger = Logger(
  subsystem: "com.moolah.app", category: "CryptoRPCEndpointsStore")

/// Persists the user's list of custom JSON-RPC endpoint URLs for direct
/// on-chain wallet sync.
///
/// A custom RPC URL can embed an API key (e.g. an Alchemy or Infura
/// project id in the path or query string), so the list is stored in
/// the synced Keychain rather than `UserDefaults` — it follows the user
/// across devices the same way the CoinGecko / Alchemy API keys do (see
/// `CryptoTokenStore+APIKeys.swift`). The list itself is JSON-encoded
/// into a single Keychain string entry.
struct CryptoRPCEndpointsStore: Sendable {
  private let store: KeychainStore

  init(
    store: KeychainStore = KeychainStore(
      service: KeychainServices.apiKeys, account: "rpc-endpoints", synchronizable: true)
  ) {
    self.store = store
  }

  /// Reads and JSON-decodes the endpoint list. Never throws: a missing
  /// entry, an empty string, or a corrupt (non-JSON) blob all resolve
  /// to `[]` so a damaged Keychain row can't brick the settings screen.
  /// A non-empty blob that fails to decode is logged as a warning so
  /// the corruption is still visible in diagnostics.
  func load() -> [String] {
    let raw: String?
    do {
      raw = try store.restoreString()
    } catch {
      cryptoRPCEndpointsLogger.error(
        "keychain read failed: \(error.localizedDescription, privacy: .public)")
      return []
    }
    guard let raw, !raw.isEmpty else { return [] }
    guard let data = raw.data(using: .utf8),
      let endpoints = try? JSONDecoder().decode([String].self, from: data)
    else {
      cryptoRPCEndpointsLogger.warning(
        "stored RPC endpoint list is not valid JSON; returning an empty list")
      return []
    }
    return endpoints
  }

  /// JSON-encodes `endpoints` and saves it to the synced Keychain.
  ///
  /// An empty list is still saved as the literal `"[]"` (rather than
  /// clearing the entry) so `load()` and `save([])` stay symmetric:
  /// "no endpoints configured" and "the entry was never written" are
  /// the same observable state either way.
  func save(_ endpoints: [String]) throws {
    let data = try JSONEncoder().encode(endpoints)
    guard let json = String(bytes: data, encoding: .utf8) else {
      throw KeychainError.saveFailed(errSecParam)
    }
    try store.saveString(json)
  }
}
