// MoolahTests/Backends/CloudKit/ProfileIndexInstrumentDispatchTests.swift

@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies `ProfileIndexSyncHandler`'s InstrumentRecord dispatch:
/// downlink apply, uplink build, `queueAllExistingRecords`, and the
/// system-fields write path. Conflict and lifecycle paths live in
/// `ProfileIndexInstrumentLifecycleTests`.
@Suite("ProfileIndexSyncHandler — InstrumentRecord dispatch")
struct ProfileIndexInstrumentDispatchTests {
  typealias Harness = ProfileIndexInstrumentTestSupport.Harness

  private static func makeInstrumentRecord(
    in zoneID: CKRecordZone.ID,
    id: String = "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    name: String = "USD Coin",
    pricingStatus: String = "priced",
    coingeckoId: String? = "usd-coin"
  ) -> CKRecord {
    ProfileIndexInstrumentTestSupport.makeInstrumentRecord(
      in: zoneID,
      id: id,
      name: name,
      pricingStatus: pricingStatus,
      coingeckoId: coingeckoId)
  }

  // MARK: - Downlink: applyRemoteChanges

  @Test("applyRemoteChanges upserts InstrumentRow + fires the closure once")
  func applyRemoteChangesUpsertsInstrumentRowAndFiresClosure() async throws {
    final class Counter: @unchecked Sendable {
      var value = 0
    }
    let counter = Counter()
    let lock = NSLock()
    let harness = try Harness(onInstrumentRemoteChange: {
      lock.withLock { counter.value += 1 }
    })

    let record = Self.makeInstrumentRecord(in: harness.handler.zoneID)
    let result = harness.handler.applyRemoteChanges(saved: [record], deleted: [])

    switch result {
    case let .success(changedTypes):
      #expect(changedTypes.contains(InstrumentRow.recordType))
    default:
      Issue.record("expected .success, got \(result)")
    }
    lock.withLock { #expect(counter.value == 1) }

    let row: InstrumentRow? = try await harness.queue.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == record.recordID.recordName)
        .fetchOne(database)
    }
    let stored = try #require(row)
    #expect(stored.name == "USD Coin")
    #expect(stored.coingeckoId == "usd-coin")
  }

  @Test("applyRemoteChanges does not crash when closure uses default no-op")
  func applyRemoteChangesUsesDefaultClosureWhenNoneInjected() async throws {
    let harness = try Harness()  // default `{}` closure
    let record = Self.makeInstrumentRecord(in: harness.handler.zoneID)
    _ = harness.handler.applyRemoteChanges(saved: [record], deleted: [])

    let row: InstrumentRow? = try await harness.queue.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == record.recordID.recordName)
        .fetchOne(database)
    }
    #expect(row != nil)
  }

  @Test("applyRemoteChanges silently drops InstrumentRecord when no instrument repository wired")
  func applyRemoteChangesIgnoresInstrumentsWithoutRegistry() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let profileRepo = GRDBProfileIndexRepository(database: queue)
    let handler = ProfileIndexSyncHandler(repository: profileRepo)
    let record = Self.makeInstrumentRecord(in: handler.zoneID)

    let result = handler.applyRemoteChanges(saved: [record], deleted: [])
    switch result {
    case let .success(changedTypes):
      #expect(!changedTypes.contains(InstrumentRow.recordType))
    default:
      Issue.record("expected .success, got \(result)")
    }
  }

  // MARK: - Uplink: recordToSave + queueAllExistingRecords

  @Test("recordToSave dispatches by record-name shape — string-keyed for instruments")
  func recordToSaveBuildsStringKeyedCKRecordForInstrument() async throws {
    let harness = try Harness()
    try await harness.registry.registerCrypto(
      Instrument.crypto(
        chainId: 1,
        contractAddress: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
        symbol: "WETH",
        name: "Wrapped Ether",
        decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId:
          "1:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
        coingeckoId: "weth",
        cryptocompareSymbol: nil,
        binanceSymbol: nil))

    let recordID = CKRecord.ID(
      recordName: "1:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
      zoneID: harness.handler.zoneID)
    let record = harness.handler.recordToSave(for: recordID)
    let built = try #require(record.foundRecord)
    #expect(built.recordType == InstrumentRow.recordType)
    #expect(built.recordID.recordName == recordID.recordName)
    #expect(built["coingeckoId"] as? String == "weth")
  }

  @Test("queueAllExistingRecords returns both ProfileRow + InstrumentRow IDs")
  func queueAllExistingRecordsCoversBothTypes() async throws {
    let harness = try Harness()

    try await harness.queue.write { database in
      try ProfileRow(
        id: UUID(),
        recordName: "ProfileRecord|abc",
        label: "Test",
        currencyCode: "AUD",
        financialYearStartMonth: 7,
        createdAt: Date(),
        encodedSystemFields: nil,
        dataFormatVersion: 0
      ).insert(database)
    }
    try await harness.registry.registerCrypto(
      Instrument.crypto(
        chainId: 1, contractAddress: "0xabc", symbol: "ABC", name: "Abc",
        decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xabc",
        coingeckoId: "abc",
        cryptocompareSymbol: nil,
        binanceSymbol: nil))

    let ids = harness.handler.queueAllExistingRecords()
    let recordNames = Set(ids.map(\.recordName))
    #expect(recordNames.contains("1:0xabc"))
    #expect(recordNames.contains(where: { $0.hasPrefix("ProfileRecord|") }))
  }

  @Test("queueAllExistingRecords returns only profile IDs when no instrument repository wired")
  func queueAllExistingRecordsOmitsInstrumentsWithoutRegistry() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let profileRepo = GRDBProfileIndexRepository(database: queue)
    let handler = ProfileIndexSyncHandler(repository: profileRepo)
    let ids = handler.queueAllExistingRecords()
    #expect(ids.isEmpty)
  }

  // MARK: - System-fields write path

  @Test("successful instrument save persists encoded_system_fields onto the row")
  func handleSentInstrumentChangesPersistsSystemFields() async throws {
    let harness = try Harness()
    try await harness.registry.registerCrypto(
      Instrument.crypto(
        chainId: 1, contractAddress: "0xdef", symbol: "DEF", name: "Def",
        decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xdef",
        coingeckoId: "def",
        cryptocompareSymbol: nil,
        binanceSymbol: nil))

    // Synthesise a server-returned record with encoded_system_fields.
    let recordID = CKRecord.ID(recordName: "1:0xdef", zoneID: harness.handler.zoneID)
    let savedRecord = CKRecord(recordType: InstrumentRow.recordType, recordID: recordID)
    let blob = savedRecord.encodedSystemFields

    _ = harness.handler.handleSentRecordZoneChanges(
      savedRecords: [savedRecord], failedSaves: [], failedDeletes: [])

    let stored: Data? = try await harness.queue.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == "1:0xdef")
        .fetchOne(database)?
        .encodedSystemFields
    }
    #expect(stored == blob)
  }
}
