@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Reproduces the single-device data-loss race that survives the #1081
/// apply guard: the upload-ack clears `needs_push` on plain user-field
/// equality, with no awareness that a *stale echo of a superseded
/// version* may still be queued in the fetch stream.
///
/// Losing interleaving (single device, no peers):
///   1. create V_create, `needs_push = 1`, uploaded.
///   2. ack of V_create caches its server system fields (non-nil blob).
///   3. update → V_update, `needs_push = 1` re-raised.
///   4. V_update uploaded.
///   5. ack of V_update: current(V_update) == saved(V_update) →
///      the over-eager clear sets `needs_push = 0` (row "confirmed").
///   6. a stale fetched echo of V_create — queued back at step 1,
///      delivered late under upload/echo backlog — is applied. The row
///      is now clean, so the clean-path upsert clobbers V_update. LOST.
///
/// The acknowledgement may now clear `needs_push` immediately when its
/// causal mutation token still matches. Its newly cached server timestamp
/// must then reject any older echo through the clean-path date gate.
@Suite("needs_push survives a superseded-version echo (single-device loss)")
struct NeedsPushSupersededEchoLossTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
  private static let tCreate = Date(timeIntervalSince1970: 1_700_000_000)
  private static let tUpdate = Date(timeIntervalSince1970: 1_700_000_060)

  @Test("AccountRow: V_update survives a stale V_create echo after the ack")
  func accountUpdateSurvivesSupersededEcho() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()

    // Row is at V_update, dirty, and has already round-tripped once
    // (non-nil cached system fields from the V_create ack at step 2).
    let cachedFields = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "V_create")
      .toCKRecord(in: Self.zoneID).withModificationDate(Self.tCreate).encodedSystemFields
    let vUpdateRow = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "V_update", encodedSystemFields: cachedFields)
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try vUpdateRow.insert(database)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
    }

    // Step 5: ack of the V_update upload clears the matching mutation and
    // advances the cached server timestamp.
    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: id, zoneID: harness.handler.zoneID)
    let sentVUpdate = try #require(
      await MainActor.run { harness.handler.recordToSave(for: recordID).foundRecord }
    )
    .withModificationDate(Self.tUpdate)
    _ = await harness.handler.handleSentRecordZoneChanges(
      savedRecords: [sentVUpdate], failedSaves: [], failedDeletes: [])

    // Step 6: a stale fetched echo of V_create arrives late.
    let staleEcho = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "V_create"
    ).toCKRecord(in: Self.zoneID).withModificationDate(Self.tCreate)
    let result = harness.handler.applyRemoteChanges(saved: [staleEcho], deleted: [])
    if case .saveFailed(let message) = result { Issue.record("save failed: \(message)") }

    let row = try await harness.database.read { database in
      try AccountRow.fetchOne(database, key: id)
    }
    // The newer local edit must win — the stale echo must not clobber it.
    #expect(try #require(row).name == "V_update")
  }

  @Test("TransactionLegRow: V_update survives a stale V_create echo after the ack")
  func transactionLegUpdateSurvivesSupersededEcho() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    let transactionId = UUID()

    // Higher-fidelity variant: drive the leg through the real
    // create-then-update repository flow so `needs_push` and the cached
    // system fields are set exactly as production leaves them, rather
    // than stamped directly.
    let repo = harness.handler.grdbRepositories.transactionLegs
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      // create (V_create) — quantity 100, dirty.
      try ProfileDataSyncHandlerTestSupport.transactionLegRow(
        id: id, transactionId: transactionId, accountId: nil, quantity: 100
      ).insert(database)
      try repo.markNeedsPushSync(id: id, in: database)
    }
    // ack of V_create caches its (non-nil) server system fields.
    _ = try repo.setEncodedSystemFieldsSync(
      id: id,
      data: ProfileDataSyncHandlerTestSupport.transactionLegRow(
        id: id, transactionId: transactionId, accountId: nil, quantity: 100
      ).toCKRecord(in: Self.zoneID).withModificationDate(Self.tCreate).encodedSystemFields)
    // update → V_update (quantity 200), dirty again.
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.id == id)
        .updateAll(database, [TransactionLegRow.Columns.quantity.set(to: 200)])
      try repo.markNeedsPushSync(id: id, in: database)
    }

    // Step 5: ack of the V_update upload.
    let recordID = CKRecord.ID(
      recordType: TransactionLegRow.recordType, uuid: id, zoneID: harness.handler.zoneID)
    let sentVUpdate = try #require(
      await MainActor.run { harness.handler.recordToSave(for: recordID).foundRecord }
    )
    .withModificationDate(Self.tUpdate)
    _ = await harness.handler.handleSentRecordZoneChanges(
      savedRecords: [sentVUpdate], failedSaves: [], failedDeletes: [])

    // Step 6: stale V_create echo (quantity 100) arrives late.
    let staleEcho = ProfileDataSyncHandlerTestSupport.transactionLegRow(
      id: id, transactionId: transactionId, accountId: nil, quantity: 100
    ).toCKRecord(in: Self.zoneID).withModificationDate(Self.tCreate)
    let result = harness.handler.applyRemoteChanges(saved: [staleEcho], deleted: [])
    if case .saveFailed(let message) = result { Issue.record("save failed: \(message)") }

    let row = try await harness.database.read { database in
      try TransactionLegRow.fetchOne(database, key: id)
    }
    #expect(try #require(row).quantity == 200)
  }
}
