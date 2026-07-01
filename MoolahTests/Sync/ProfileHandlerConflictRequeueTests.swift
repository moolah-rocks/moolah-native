import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Regression guard for the per-profile-zone `.serverRecordChanged`
/// conflict-path convergence invariant.
///
/// The conflict path never decodes the server record's field values into
/// local storage. `SyncErrorRecovery.classifySaveFailure` routes a
/// `.serverRecordChanged` failure into `ClassifiedFailures.conflicts`
/// carrying only the `recordID`, and `requeueFailures` re-queues it as
/// `.saveRecord(recordID)`. CKSyncEngine then rebuilds the upload CKRecord
/// by calling back into `ProfileDataSyncHandler.recordToSave(for:)`, which
/// reads the *current stored GRDB row* — not any cached server record.
///
/// Because fetch-path canonicalization already rewrites a
/// non-canonical instrument id before the row is stored, the row
/// `recordToSave` reads is always canonical, so the re-queued upload is
/// canonical too. There is no separate decode-and-write conflict path that
/// would need its own canonicalization.
///
/// This suite pins that invariant by driving the *production upload-lookup
/// path* (`recordToSave(for:)`, the exact method the conflict re-queue's
/// `.saveRecord(recordID)` triggers). A future refactor that made the
/// conflict path apply the server record's field values into storage —
/// bypassing the apply-path rewrite — would break this test.
@Suite("ProfileDataSyncHandler — conflict re-queue carries canonical instrument id")
struct ProfileHandlerConflictRequeueTests {

  /// After applying an incoming `10:native` (Optimism ETH) leg from an
  /// un-migrated peer — stored as `1:native` (mainnet ETH, the canonical
  /// id) — the CKRecord that `recordToSave(for:)` rebuilds for a conflict
  /// re-queue carries `1:native`.
  ///
  /// `recordToSave(for:)` is the real production method CKSyncEngine calls
  /// to materialise a `.saveRecord(recordID)` pending change (see
  /// `SyncCoordinator+BatchBuilder`), so this asserts the re-queued upload
  /// is drawn from the already-canonical GRDB row, not from server fields.
  @Test
  func rebuiltUploadRecordForAppliedLegCarriesCanonicalInstrument() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase(
        canonicalResolver: CanonicalInstrumentResolver())
    }
    let handler = harness.handler

    let txId = UUID()
    let legId = UUID()
    // Seed the parent transaction so the leg has a valid FK target.
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport
        .transactionRow(id: txId, payee: "ETH").insert(database)
    }

    // Simulate an incoming CKRecord from an un-migrated peer that still
    // uses the retired cross-chain id `10:native` (Optimism ETH). The
    // apply path rewrites it to the canonical `1:native` before storing.
    let leg = ProfileDataSyncHandlerTestSupport.transactionLegRow(
      id: legId, transactionId: txId, accountId: UUID(), instrumentId: "10:native")
    let applyResult = handler.applyRemoteChanges(
      saved: [leg.toCKRecord(in: handler.zoneID)], deleted: [])
    guard case .success = applyResult else {
      Issue.record("applyRemoteChanges did not succeed: \(applyResult)")
      return
    }

    // Rebuild the upload CKRecord via the SAME production path a conflict
    // re-queue uses: `.saveRecord(recordID)` → `recordToSave(for:)`. This
    // reads the current (canonical) GRDB row, proving the conflict path
    // never needs its own server-field canonicalization.
    let legRecordID = CKRecord.ID(
      recordType: TransactionLegRow.recordType, uuid: legId, zoneID: handler.zoneID)
    let outcome = await MainActor.run { handler.recordToSave(for: legRecordID) }
    guard case .found(let uploadRecord) = outcome else {
      Issue.record("recordToSave did not find the stored leg: \(outcome)")
      return
    }
    #expect(uploadRecord["instrumentId"] as? String == "1:native")
  }
}
