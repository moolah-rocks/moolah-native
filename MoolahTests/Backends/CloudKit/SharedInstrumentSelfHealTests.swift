// MoolahTests/Backends/CloudKit/SharedInstrumentSelfHealTests.swift

@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Confirms `ProfileIndexSyncHandler.queueUnsyncedSharedInstrumentRecords`
/// returns string-keyed CKRecord.IDs for instrument rows whose
/// `encoded_system_fields` is `NULL`, and skips rows that have already
/// roundtripped.
@MainActor
@Suite("Shared registry self-heal")
struct SharedInstrumentSelfHealTests {

  @Test("self-heal scan returns IDs for unsynced instrument rows only")
  func selfHealEnumeratesUnsyncedRowsOnly() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let profileRepo = GRDBProfileIndexRepository(database: queue)
    let registry = GRDBInstrumentRegistryRepository(database: queue)
    let handler = ProfileIndexSyncHandler(
      repository: profileRepo, instrumentRepository: registry)

    // One row that hasn't roundtripped (NULL encoded_system_fields):
    try await registry.registerCrypto(
      Instrument.crypto(
        chainId: 1, contractAddress: "0xunsynced", symbol: "UNS", name: "Unsynced",
        decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xunsynced",
        coingeckoId: "unsynced",
        binanceSymbol: nil))

    // Another row that has roundtripped (non-NULL):
    try await registry.registerCrypto(
      Instrument.crypto(
        chainId: 1, contractAddress: "0xsynced", symbol: "SYN", name: "Synced",
        decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xsynced",
        coingeckoId: "synced",
        binanceSymbol: nil))
    try await queue.write { database in
      try database.execute(
        sql: """
          UPDATE instrument SET encoded_system_fields = ? WHERE id = ?
          """,
        arguments: [Data([0x01]), "1:0xsynced"])
    }

    let recordIDs = handler.queueUnsyncedSharedInstrumentRecords()
    let names = Set(recordIDs.map(\.recordName))
    #expect(names == ["1:0xunsynced"])
    #expect(recordIDs.first?.zoneID == handler.zoneID)
  }

  @Test("self-heal scan returns empty when no instrument repository wired")
  func selfHealReturnsEmptyWithoutInstrumentRepository() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let profileRepo = GRDBProfileIndexRepository(database: queue)
    let handler = ProfileIndexSyncHandler(repository: profileRepo)
    #expect(handler.queueUnsyncedSharedInstrumentRecords().isEmpty)
  }
}
