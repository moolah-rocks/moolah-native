import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileDataSyncHandler — record lookup")
@MainActor
struct ProfileDataSyncHandlerLookupTests {

  @Test
  func buildBatchRecordLookupFindsRecordsByUUID() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler

    let accountId = UUID()
    let txnId = UUID()

    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try AccountRow(
        id: accountId,
        recordName: AccountRow.recordName(for: accountId),
        name: "Acc",
        type: "bank",
        instrumentId: Instrument.defaultTestInstrument.id,
        position: 0,
        isHidden: false,
        encodedSystemFields: nil,
        valuationMode: ValuationMode.recordedValue.rawValue
      ).upsert(database)
      try TransactionRow(
        id: txnId,
        recordName: TransactionRow.recordName(for: txnId),
        date: Date(),
        payee: "Test",
        notes: nil,
        recurPeriod: nil,
        recurEvery: nil,
        importOriginRawDescription: nil,
        importOriginBankReference: nil,
        importOriginRawAmount: nil,
        importOriginRawBalance: nil,
        importOriginImportedAt: nil,
        importOriginImportSessionId: nil,
        importOriginSourceFilename: nil,
        importOriginParserIdentifier: nil,
        encodedSystemFields: nil
      ).upsert(database)
    }

    let lookup = handler.buildBatchRecordLookup(byRecordType: [
      AccountRow.recordType: [accountId],
      TransactionRow.recordType: [txnId],
    ])

    #expect(
      lookup[AccountRow.recordType]?.succeededHits[accountId]?.recordType == "AccountRecord")
    #expect(
      lookup[TransactionRow.recordType]?.succeededHits[txnId]?.recordType == "TransactionRecord")
  }

  @Test
  func recordToSaveFindsAccountByUUID() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler

    let accountId = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try AccountRow(
        id: accountId,
        recordName: AccountRow.recordName(for: accountId),
        name: "Found",
        type: "bank",
        instrumentId: Instrument.defaultTestInstrument.id,
        position: 0,
        isHidden: false,
        encodedSystemFields: nil,
        valuationMode: ValuationMode.recordedValue.rawValue
      ).upsert(database)
    }

    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: accountId, zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID).foundRecord
    #expect(result != nil)
    #expect(result?.recordType == "AccountRecord")
    #expect(result?["name"] as? String == "Found")
  }

  // There is no per-profile `InstrumentRecord` upload path:
  // `ProfileDataSyncHandler.recordToSave` traps in DEBUG (logs+returns
  // nil in release) for any InstrumentRecord routed to a per-profile
  // zone — see `ProfileDataSyncHandler+RecordLookup.swift`. The
  // instrument upload path is exercised by
  // `ProfileIndexInstrumentDispatchTests`.

  @Test
  func recordToSaveReturnsNilForMissingRecord() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler

    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: UUID(), zoneID: handler.zoneID)
    // Missing row, query succeeded → `.absent` (issue #1087 tri-state).
    guard case .absent = handler.recordToSave(for: recordID) else {
      Issue.record("expected .absent for a missing record")
      return
    }
  }
}
