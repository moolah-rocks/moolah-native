// MoolahTests/Backends/GRDB/TransactionLegCloudKitOnChainFieldsTests.swift

import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Pins that a wallet-imported leg's on-chain identity — `externalId` (the
/// importer's dedup key, half of `(accountId, externalId)`) and
/// `counterpartyAddress` — survives the CloudKit wire round-trip
/// (`TransactionLegRow` → `CKRecord` → `TransactionLegRow`).
///
/// The existing sync round-trip tests only ever seed `nil` for both fields, so
/// a regression that dropped either from `toCKRecord` / `fieldValues(from:)` or
/// the generated wire struct would pass CI silently — and cause the next wallet
/// sync to re-import the transaction as a duplicate on the receiving device.
@Suite("TransactionLegRow CloudKit on-chain field round-trip")
struct TransactionLegCloudKitOnChainFieldsTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test
  func onChainIdentitySurvivesCloudKitRoundTrip() throws {
    let id = UUID()
    let row = TransactionLegRow(
      id: id,
      recordName: TransactionLegRow.recordName(for: id),
      transactionId: UUID(),
      accountId: UUID(),
      instrumentId: Instrument.defaultTestInstrument.id,
      quantity: -1000,
      type: "expense",
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil,
      externalId: "0xabc:erc20:0",
      counterpartyAddress: "0xcounterparty")

    let record = row.toCKRecord(in: Self.zoneID)
    let roundTripped = try #require(TransactionLegRow.fieldValues(from: record))

    #expect(roundTripped.externalId == "0xabc:erc20:0")
    #expect(roundTripped.counterpartyAddress == "0xcounterparty")
  }
}
