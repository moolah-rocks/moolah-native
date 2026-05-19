import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Pins the nine merged-import wire keys on the
/// `"TransactionRecord"` CKRecord: `importOriginKind` and the eight
/// `importOriginIncoming*` columns. These string keys are a frozen
/// CloudKit contract — existing iCloud zones reference these exact
/// names — so the round-trip is asserted by string key, not just by
/// decoded value. A separate suite (and file) from `RecordMappingTests`
/// keeps each within its length budget.
@Suite("TransferWireKeyMapping")
struct TransferWireKeyMappingTests {

  let zoneID = CKRecordZone.ID(zoneName: "profile-test", ownerName: CKCurrentUserDefaultName)

  private let importedAt = Date(timeIntervalSince1970: 1_700_000_100)
  private let txnDate = Date(timeIntervalSince1970: 1_700_000_000)

  /// Builds a `.merged` transaction whose outgoing/incoming origins
  /// populate all nine merged-import columns.
  private func makeMergedTransaction(
    outgoingSessionId: UUID,
    incomingSessionId: UUID
  ) -> Transaction {
    let outgoing = ImportOrigin(
      rawDescription: "OUT debit raw",
      bankReference: "OUTREF",
      rawAmount: Decimal(-12_345) / 100,
      rawBalance: Decimal(100_000) / 100,
      importedAt: importedAt,
      importSessionId: outgoingSessionId,
      sourceFilename: "out.csv",
      parserIdentifier: "csv-parser-out")
    let incoming = ImportOrigin(
      rawDescription: "IN credit raw",
      bankReference: "INREF",
      rawAmount: Decimal(12_345) / 100,
      rawBalance: Decimal(212_345) / 100,
      importedAt: importedAt,
      importSessionId: incomingSessionId,
      sourceFilename: "in.csv",
      parserIdentifier: "csv-parser-in")
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.USD,
      quantity: Decimal(-12_345) / 100,
      type: .transfer)
    return Transaction(
      date: txnDate,
      payee: "Merged transfer",
      legs: [leg],
      importOrigin: .merged(MergedImportOrigin(outgoing: outgoing, incoming: incoming)))
  }

  @Test("merged import wire keys round-trip by string key")
  func mergedImportWireKeysRoundTrip() throws {
    let outgoingSessionId = UUID()
    let incomingSessionId = UUID()
    let transaction = makeMergedTransaction(
      outgoingSessionId: outgoingSessionId,
      incomingSessionId: incomingSessionId)

    let ckRecord = TransactionRow(domain: transaction).toCKRecord(in: zoneID)

    #expect(ckRecord["importOriginKind"] as? String == "merged")
    #expect(
      ckRecord["importOriginIncomingRawDescription"] as? String
        == "IN credit raw")
    #expect(
      ckRecord["importOriginIncomingImportSessionId"] as? String
        == incomingSessionId.uuidString)

    let restored = try #require(TransactionRow.fieldValues(from: ckRecord))
    #expect(restored.importOriginKind == "merged")
    #expect(restored.importOriginIncomingRawDescription == "IN credit raw")
    #expect(restored.importOriginIncomingBankReference == "INREF")
    #expect(restored.importOriginIncomingImportSessionId == incomingSessionId)
    #expect(restored.importOriginIncomingSourceFilename == "in.csv")
    #expect(restored.importOriginIncomingParserIdentifier == "csv-parser-in")
  }

  @Test("plain transaction skips the merged import wire keys")
  func plainTransactionSkipsMergedWireKeys() {
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.USD,
      quantity: Decimal(5_000) / 100,
      type: .expense)
    let plain = Transaction(date: txnDate, payee: "Plain", legs: [leg])

    let ckRecord = TransactionRow(domain: plain).toCKRecord(in: zoneID)

    #expect(ckRecord["importOriginKind"] == nil)
    #expect(ckRecord["importOriginIncomingRawDescription"] == nil)
  }
}
