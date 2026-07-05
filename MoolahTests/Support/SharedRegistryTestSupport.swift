// MoolahTests/Support/SharedRegistryTestSupport.swift

import GRDB

@testable import Moolah

/// Builds an isolated, in-memory shared instrument registry for tests
/// and previews — a `GRDBInstrumentRegistryRepository` backed by a fresh
/// `ProfileIndexDatabase.openInMemory()` queue.
///
/// This is the test-side mirror of how production wires the
/// shared registry (`MoolahApp.makeSharedInstrumentRegistry` over
/// `ProfileContainerManager.profileIndexDatabase`). It is the instrument
/// resolver / registrar seam for every repository / sync / rollback
/// test. Suites that use it do not seed the shared registry, so reads
/// fall through to the `Instrument.fiat(code:)` path; the per-profile
/// rows those suites insert for FK / cascade structure stay untouched.
enum SharedRegistryTestSupport {
  /// A fresh shared registry over its own in-memory profile-index DB.
  /// Each call returns an independent registry/database pair, matching
  /// the per-test isolation the `PerProfile*` shims provided.
  static func makeSharedRegistry() throws -> GRDBInstrumentRegistryRepository {
    GRDBInstrumentRegistryRepository(
      database: try ProfileIndexDatabase.openInMemory())
  }

  /// Registers an arbitrary crypto instrument, which fires the registry's
  /// `observeChanges()` stream — the signal an in-app import emits before
  /// writing its per-profile rows. Shared by every store's registry-refresh
  /// backstop test (Account/Group/Category/ImportRule).
  static func fireRegistryChange(
    on registry: GRDBInstrumentRegistryRepository
  ) async throws {
    let crypto = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
      symbol: "WBTC", name: "Wrapped Bitcoin", decimals: 8)
    try await registry.registerCrypto(
      crypto,
      mapping: CryptoProviderMapping(
        instrumentId: crypto.id, coingeckoId: "wrapped-bitcoin",
        binanceSymbol: nil))
  }
}
