@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Protects the no-FK sync contract for child records that arrive before
/// their parent during CloudKit's out-of-order delivery.
@Suite("Sync apply tolerates an out-of-order transaction leg")
struct OutOfOrderTransactionLegSyncTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("TransactionLeg CKRecord landing before its parent transaction succeeds")
  func transactionLegArrivesBeforeTransaction() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }

    let orphanTransactionId = UUID()
    let legId = UUID()
    let legRow = TransactionLegRow(
      id: legId,
      recordName: TransactionLegRow.recordName(for: legId),
      transactionId: orphanTransactionId,
      accountId: nil,
      instrumentId: "USD",
      quantity: 1000,
      type: TransactionType.expense.rawValue,
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil)
    let ckRecord = legRow.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    if case .saveFailed(let message) = result {
      Issue.record("Expected success, got .saveFailed(\(message))")
    }

    let count = try await harness.database.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ?",
        arguments: [legId]) ?? -1
    }
    #expect(count == 1)
  }
}
