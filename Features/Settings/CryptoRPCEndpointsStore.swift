import Foundation
import OSLog
import Security

private let cryptoRPCEndpointsLogger = Logger(
  subsystem: "com.moolah.app", category: "CryptoRPCEndpointsStore")

/// Persistence seam for the custom JSON-RPC endpoint list, matching the
/// `any InstrumentRegistryRepository` / `any InstrumentConversionService`
/// shape `CryptoTokenStore` already injects its other dependencies
/// through. `CryptoTokenStore` holds this as `any CryptoRPCEndpointsStoring`
/// rather than the concrete `CryptoRPCEndpointsStore` so store-level tests
/// can inject a double whose `save(_:)` throws deterministically —
/// exercising `addRPCEndpoint`/`removeRPCEndpoint`'s rollback-on-failure
/// path without depending on a genuine (and CI-flaky) Keychain error.
protocol CryptoRPCEndpointsStoring: Sendable {
  func load() -> [String]
  func save(_ endpoints: [String]) throws
}

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

extension CryptoRPCEndpointsStore: CryptoRPCEndpointsStoring {}

/// In-memory endpoint list for UI tests. The production store writes to the
/// synchronizable Keychain, which fails on a headless CI runner (no iCloud
/// keychain) and — because `addRPCEndpoint` reverts on a save failure — would
/// make every added row vanish immediately. UI tests inject this instead so
/// add/remove work in-process, mirroring how `alchemyKeyPresent` keeps API-key
/// handling off the system keychain in the UI-test launch environment.
final class InMemoryCryptoRPCEndpointsStore: CryptoRPCEndpointsStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var endpoints: [String] = []

  func load() -> [String] { lock.withLock { endpoints } }

  func save(_ endpoints: [String]) throws { lock.withLock { self.endpoints = endpoints } }
}
