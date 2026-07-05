// MoolahTests/Backends/GRDB/GRDBInstrumentMapCacheTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies `GRDBInstrumentRegistryRepository.instrumentMap()` serves a
/// memoised `[String: Instrument]` snapshot that is rebuilt from the
/// database only when a registry mutation invalidates it. Every
/// per-profile instrument resolution routes through this single
/// shared method on the serial profile-index queue; a per-call DB read
/// would serialise and regress the cold-launch burst. The correctness
/// invariant under test is that *every* mutation path (local writes,
/// `*Sync` mutators, and the remote-apply path) invalidates the cache so
/// a reader after a mutation never observes stale instrument data.
@Suite("Shared registry memoises the instrument map until a mutation")
struct GRDBInstrumentMapCacheTests {
  private func makeRegistry() throws -> (
    GRDBInstrumentRegistryRepository, any DatabaseWriter
  ) {
    let queue = try ProfileIndexDatabase.openInMemory()
    return (GRDBInstrumentRegistryRepository(database: queue), queue)
  }

  private func sampleCrypto() -> Instrument {
    Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  }

  @Test("memoised until a mutation; first read hits the DB once")
  func memoizedUntilMutation() async throws {
    let (registry, _) = try makeRegistry()

    #expect(registry.instrumentMapDBReadCountForTesting == 0)

    let first = try await registry.instrumentMap()
    #expect(registry.instrumentMapDBReadCountForTesting == 1)
    #expect(first["USD"]?.kind == .fiatCurrency)

    // Repeated reads are served from the cache — no further DB rebuilds.
    _ = try await registry.instrumentMap()
    _ = try await registry.instrumentMap()
    #expect(registry.instrumentMapDBReadCountForTesting == 1)

    // A mutation invalidates; the next read rebuilds exactly once and
    // reflects the new row while ambient fiat is still present.
    let eth = sampleCrypto()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil))

    let afterMutation = try await registry.instrumentMap()
    #expect(registry.instrumentMapDBReadCountForTesting == 2)
    #expect(afterMutation[eth.id]?.kind == .cryptoToken)
    #expect(afterMutation["USD"]?.kind == .fiatCurrency)
  }

  @Test("update(_:) invalidates the cache")
  func invalidatedByUpdate() async throws {
    let (registry, _) = try makeRegistry()
    let eth = sampleCrypto()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil))

    // Prime the cache.
    _ = try await registry.instrumentMap()
    let primedCount = registry.instrumentMapDBReadCountForTesting

    try await registry.update(
      CryptoRegistration(
        instrument: eth,
        mapping: CryptoProviderMapping(
          instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil),
        pricingStatus: .spam))

    let rebuilt = try await registry.instrumentMap()
    #expect(registry.instrumentMapDBReadCountForTesting == primedCount + 1)
    #expect(rebuilt[eth.id]?.kind == .cryptoToken)
  }

  @Test("sync-apply path (applyRemoteChangesSync) invalidates the cache")
  func invalidatedBySyncApply() async throws {
    let (registry, _) = try makeRegistry()

    // Prime the cache before the remote apply.
    _ = try await registry.instrumentMap()
    let primedCount = registry.instrumentMapDBReadCountForTesting
    #expect(primedCount == 1)

    let eth = sampleCrypto()
    var row = InstrumentRow(domain: eth)
    row.coingeckoId = "ethereum"
    try registry.applyRemoteChangesSync(saved: [row], deleted: [])

    let rebuilt = try await registry.instrumentMap()
    #expect(registry.instrumentMapDBReadCountForTesting == primedCount + 1)
    #expect(rebuilt[eth.id]?.kind == .cryptoToken)
  }

  @Test("metadata-only *Sync mutator still invalidates the cache")
  func invalidatedBySystemFieldsWrite() async throws {
    let (registry, _) = try makeRegistry()
    let eth = sampleCrypto()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil))

    _ = try await registry.instrumentMap()
    let primedCount = registry.instrumentMapDBReadCountForTesting

    // System-fields-only writes don't change the domain `Instrument`,
    // but a blanket invalidate-on-any-write is the safe simple invariant
    // — assert the rebuild still happens.
    let updated = try registry.setEncodedSystemFieldsSync(
      id: eth.id, data: Data([0x01, 0x02]))
    #expect(updated)

    _ = try await registry.instrumentMap()
    #expect(registry.instrumentMapDBReadCountForTesting == primedCount + 1)
  }

  @Test("registerStock(_:) invalidates the cache")
  func invalidatedByRegisterStock() async throws {
    let (registry, _) = try makeRegistry()

    _ = try await registry.instrumentMap()
    let primedCount = registry.instrumentMapDBReadCountForTesting

    let bhp = Instrument.stock(ticker: "BHP", exchange: "ASX", name: "BHP Group")
    try await registry.registerStock(bhp)

    let rebuilt = try await registry.instrumentMap()
    #expect(registry.instrumentMapDBReadCountForTesting == primedCount + 1)
    #expect(rebuilt[bhp.id]?.kind == .stock)
  }

  @Test("remove(id:) invalidates the cache")
  func invalidatedByRemove() async throws {
    let (registry, _) = try makeRegistry()
    let eth = sampleCrypto()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil))

    let primed = try await registry.instrumentMap()
    #expect(primed[eth.id]?.kind == .cryptoToken)
    let primedCount = registry.instrumentMapDBReadCountForTesting

    try await registry.remove(id: eth.id)

    let rebuilt = try await registry.instrumentMap()
    #expect(registry.instrumentMapDBReadCountForTesting == primedCount + 1)
    #expect(rebuilt[eth.id] == nil)
  }

  @Test("clearAllSystemFieldsSync() invalidates the cache")
  func invalidatedByClearAllSystemFields() async throws {
    let (registry, _) = try makeRegistry()
    let eth = sampleCrypto()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil))

    _ = try await registry.instrumentMap()
    let primedCount = registry.instrumentMapDBReadCountForTesting

    // Metadata-only write, but the blanket invalidate-on-any-write
    // invariant means the next read must still rebuild exactly once.
    try registry.clearAllSystemFieldsSync()

    let rebuilt = try await registry.instrumentMap()
    #expect(registry.instrumentMapDBReadCountForTesting == primedCount + 1)
    #expect(rebuilt[eth.id]?.kind == .cryptoToken)
  }

  @Test("deleteAllSync() invalidates the cache")
  func invalidatedByDeleteAll() async throws {
    let (registry, _) = try makeRegistry()
    let eth = sampleCrypto()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil))

    let primed = try await registry.instrumentMap()
    #expect(primed[eth.id]?.kind == .cryptoToken)
    let primedCount = registry.instrumentMapDBReadCountForTesting

    try registry.deleteAllSync()

    let rebuilt = try await registry.instrumentMap()
    #expect(registry.instrumentMapDBReadCountForTesting == primedCount + 1)
    #expect(rebuilt[eth.id] == nil)
    // Ambient ISO fiat survives a stored-row wipe.
    #expect(rebuilt["USD"]?.kind == .fiatCurrency)
  }
}
