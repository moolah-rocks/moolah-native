// MoolahTests/Backends/CloudKit/RegistryInvariantTests.swift

import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the structural invariant `id == record_name` on every
/// `InstrumentRecord` round-trip: the CloudKit `recordName`, the GRDB
/// `id` column, and the GRDB `record_name` column must all carry the
/// same string. The shared registry's `INSERT … ON CONFLICT(id)`
/// apply-merge and the `record_name UNIQUE` reservation
/// (`ProfileIndexSchema+SharedInstrumentRegistry`) rely on this
/// invariant — drift between the two columns would silently split a
/// single instrument into two registry rows that could never
/// reconcile.
@Suite("InstrumentRecord id == record_name invariant")
struct RegistryInvariantTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)

  // MARK: - toCKRecord(in:)

  @Test("Stock toCKRecord emits recordName matching the row id")
  func stockToCKRecordPreservesId() {
    let row = makeStockRow(id: "ASX:BHP.AX")
    let ckRecord = row.toCKRecord(in: Self.zoneID)
    #expect(ckRecord.recordID.recordName == "ASX:BHP.AX")
    #expect(ckRecord.recordID.recordName == row.id)
    #expect(ckRecord.recordID.recordName == row.recordName)
  }

  @Test("Crypto (chain-prefixed) toCKRecord emits recordName matching the row id")
  func cryptoToCKRecordPreservesId() {
    let id = "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    let row = makeCryptoRow(id: id)
    let ckRecord = row.toCKRecord(in: Self.zoneID)
    #expect(ckRecord.recordID.recordName == id)
    #expect(ckRecord.recordID.recordName == row.id)
    #expect(ckRecord.recordID.recordName == row.recordName)
  }

  @Test("Fiat (ISO code) toCKRecord emits recordName matching the row id")
  func fiatToCKRecordPreservesId() {
    let row = makeFiatRow(id: "USD")
    let ckRecord = row.toCKRecord(in: Self.zoneID)
    #expect(ckRecord.recordID.recordName == "USD")
    #expect(ckRecord.recordID.recordName == row.id)
    #expect(ckRecord.recordID.recordName == row.recordName)
  }

  // MARK: - fieldValues(from:)

  @Test("fieldValues(from:) sets id and record_name to the CKRecord recordName")
  func fieldValuesPreservesIdEqualsRecordName() throws {
    for id in ["AUD", "ASX:BHP.AX", "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"] {
      let recordID = CKRecord.ID(recordName: id, zoneID: Self.zoneID)
      let ckRecord = CKRecord(recordType: InstrumentRow.recordType, recordID: recordID)
      let decoded = try #require(InstrumentRow.fieldValues(from: ckRecord))
      #expect(decoded.id == id)
      #expect(decoded.recordName == id)
    }
  }

  // MARK: - Round-trip through the shared `instrument` table

  @Test("Post-merge rows in the shared instrument table preserve id == record_name")
  func postMergeRowsPreserveIdEqualsRecordName() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: queue)

    try await registry.registerStock(
      Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP Group"))
    try await registry.registerCrypto(
      Instrument.crypto(
        chainId: 1,
        contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        symbol: "USDC",
        name: "USD Coin",
        decimals: 6),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        coingeckoId: "usd-coin",
        binanceSymbol: nil))

    let rows = try await queue.read { database in
      try InstrumentRow.fetchAll(database)
    }
    #expect(rows.count == 2)
    for row in rows {
      #expect(row.id == row.recordName, "id (\(row.id)) must equal record_name (\(row.recordName))")
    }
  }

  // MARK: - Fixtures

  private func makeStockRow(id: String) -> InstrumentRow {
    InstrumentRow(
      id: id,
      recordName: id,
      kind: "stock",
      name: "BHP Group",
      decimals: 0,
      ticker: "BHP.AX",
      exchange: "ASX",
      chainId: nil,
      contractAddress: nil,
      coingeckoId: nil,
      binanceSymbol: nil,
      encodedSystemFields: nil)
  }

  private func makeCryptoRow(id: String) -> InstrumentRow {
    InstrumentRow(
      id: id,
      recordName: id,
      kind: "cryptoToken",
      name: "USD Coin",
      decimals: 6,
      ticker: "USDC",
      exchange: nil,
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      coingeckoId: "usd-coin",
      binanceSymbol: nil,
      encodedSystemFields: nil)
  }

  private func makeFiatRow(id: String) -> InstrumentRow {
    InstrumentRow(
      id: id,
      recordName: id,
      kind: "fiatCurrency",
      name: "US Dollar",
      decimals: 2,
      ticker: nil,
      exchange: nil,
      chainId: nil,
      contractAddress: nil,
      coingeckoId: nil,
      binanceSymbol: nil,
      encodedSystemFields: nil)
  }
}
