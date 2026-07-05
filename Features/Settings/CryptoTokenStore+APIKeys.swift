import Foundation

/// Provider API-key surface for `CryptoTokenStore` — the CoinGecko and
/// Alchemy keychain reads / writes that back the Crypto preferences tab.
/// Split into its own file so the core store stays under the file-length
/// limit. Every member proxies the store's `let` keychain handles; none
/// owns new state.
///
/// Each provider follows the same shape: a `has…ApiKey` read that
/// drives a status badge, a `save…ApiKey(_:)` that trims surrounding
/// whitespace and persists to the synced Keychain (an all-whitespace
/// input is a no-op, never persisted empty), and a `clear…ApiKey()`
/// that removes the entry. The
/// key value itself is never logged; failure paths log only the
/// wrapping `error.localizedDescription` (which carries the underlying
/// `OSStatus` via `KeychainError`).
extension CryptoTokenStore {

  // MARK: - CoinGecko API Key

  var hasCoinGeckoApiKey: Bool {
    do {
      return try apiKeyStore.restoreString() != nil
    } catch {
      logger.error("keychain read failed: \(error.localizedDescription)")
      return false
    }
  }

  func saveCoinGeckoApiKey(_ key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      try apiKeyStore.saveString(trimmed)
      setError(nil)
    } catch {
      logger.error(
        "CoinGecko API key save failed: \(error.localizedDescription, privacy: .public)")
      setError("Failed to save API key: \(error.localizedDescription)")
    }
  }

  func clearCoinGeckoApiKey() {
    apiKeyStore.clear()
  }

  // MARK: - Alchemy API Key
  //
  // The Alchemy key drives the wallet auto-import.
  // `ProfileSession.resolveAlchemyApiKey()` reads from the same
  // `(service, account)` keychain entry, so a write here is picked up
  // by the next sync cycle without further plumbing.

  /// `true` when an Alchemy API key is configured in the synced
  /// Keychain. Read on every UI render to drive the status badge —
  /// the keychain read is cheap (~µs) and consulting a cached `Bool`
  /// would require an explicit invalidation hook on save / clear.
  var hasAlchemyApiKey: Bool {
    do {
      return try alchemyKeyStore.restoreString() != nil
    } catch {
      logger.error("keychain read failed: \(error.localizedDescription)")
      return false
    }
  }

  /// Persists the Alchemy API key to the synced Keychain. Sets
  /// `error` (without logging the key) on failure.
  func saveAlchemyApiKey(_ key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      try alchemyKeyStore.saveString(trimmed)
      setError(nil)
    } catch {
      logger.error(
        "Alchemy API key save failed: \(error.localizedDescription, privacy: .public)")
      setError("Failed to save Alchemy API key: \(error.localizedDescription)")
    }
  }

  /// Removes the Alchemy API key from the synced Keychain. Subsequent
  /// sync cycles will produce `WalletSyncError.missingApiKey` until a
  /// new key is saved.
  func clearAlchemyApiKey() {
    alchemyKeyStore.clear()
  }

}
