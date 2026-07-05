// MoolahTests/Features/Settings/CryptoRPCEndpointsStoreTests.swift
import Foundation
import Testing

@testable import Moolah

/// Tests for `CryptoRPCEndpointsStore`, the synced-Keychain-backed list
/// of custom JSON-RPC endpoint URLs a user has configured for direct
/// on-chain wallet sync.
///
/// Production wires a synchronisable `KeychainStore`, but the macOS
/// test runner cannot write to the iCloud-synced keychain (the runner
/// isn't part of an iCloud-signed-in user session). We inject a
/// per-test, non-synchronisable `KeychainStore` via the store's test
/// seam initialiser, namespaced under a unique service id so concurrent
/// test runs cannot collide on the same keychain row — mirroring
/// `KeychainStoreTests` and `CryptoSettingsAPIKeyTests`.
#if os(macOS)  // Keychain tests require code signing (macOS only)

  @Suite("CryptoRPCEndpointsStore")
  struct CryptoRPCEndpointsStoreTests {
    private func makeKeychain() -> KeychainStore {
      KeychainStore(
        service: "com.moolah.test.rpc-endpoints.\(UUID().uuidString)",
        account: "rpc-endpoints",
        synchronizable: false)
    }

    @Test("save then load round-trips a list of endpoint URLs")
    func saveLoadRoundTrips() throws {
      let keychain = makeKeychain()
      defer { keychain.clear() }
      let store = CryptoRPCEndpointsStore(store: keychain)

      let endpoints = ["https://rpc.example.com/v1?key=abc", "https://eth.example.org"]
      try store.save(endpoints)

      #expect(store.load() == endpoints)
    }

    @Test("load returns an empty list when the keychain entry is missing")
    func loadReturnsEmptyWhenMissing() {
      let keychain = makeKeychain()
      let store = CryptoRPCEndpointsStore(store: keychain)

      #expect(store.load().isEmpty)
    }

    @Test("load returns an empty list without throwing when the stored blob is corrupt")
    func loadReturnsEmptyOnCorruptBlob() throws {
      let keychain = makeKeychain()
      defer { keychain.clear() }
      try keychain.saveString("not valid json { at all")

      let store = CryptoRPCEndpointsStore(store: keychain)

      #expect(store.load().isEmpty)
    }
  }

#endif
