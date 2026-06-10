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
/// The fix must keep `needs_push` set through the step-5→6 window: a row
/// that has already round-tripped at least once (non-nil cached system
/// fields) and is being re-confirmed at a *newer* version must NOT have
/// its flag cleared by the ack, because an earlier version's echo can
/// still arrive. The flag is instead cleared by the fetch/apply path
/// when the *confirming* echo of the current version arrives — safe
/// because CKSyncEngine delivers fetched changes in server-token order,
/// so every earlier-token stale echo has already been processed by then.
@Suite("needs_push survives a superseded-version echo (single-device loss)")
struct NeedsPushSupersededEchoLossTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  /// Encodes a non-nil cached system-fields blob for `id` of an account,
  /// standing in for the server system fields cached after the V_create
  /// round-trip (step 2). Locally-built records carry no server change
  /// tag, but the encoded blob is still non-nil Data — which is the
  /// signal "this row has round-tripped before".
  private static func cachedSystemFields(forAccount id: UUID) -> Data {
    ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "V_create")
      .toCKRecord(in: zoneID)
      .encodedSystemFields
  }

  private static func cachedSystemFields(
    forLeg id: UUID, transactionId: UUID
  ) -> Data {
    ProfileDataSyncHandlerTestSupport.transactionLegRow(
      id: id, transactionId: transactionId, accountId: nil, quantity: 100
    )
    .toCKRecord(in: zoneID)
    .encodedSystemFields
  }

  @Test("AccountRow: V_update survives a stale V_create echo after the ack")
  func accountUpdateSurvivesSupersededEcho() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()

    // Row is at V_update, dirty, and has already round-tripped once
    // (non-nil cached system fields from the V_create ack at step 2).
    let vUpdateRow = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "V_update",
      encodedSystemFields: Self.cachedSystemFields(forAccount: id))
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try vUpdateRow.insert(database)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
    }

    // Step 5: ack of the V_update upload — current row matches the sent
    // V_update record, so the over-eager clear fires here.
    let sentVUpdate = vUpdateRow.toCKRecord(in: Self.zoneID)
    await MainActor.run {
      _ = harness.handler.handleSentRecordZoneChanges(
        savedRecords: [sentVUpdate], failedSaves: [], failedDeletes: [])
    }

    // Step 6: a stale fetched echo of V_create arrives late.
    let staleEcho = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "V_create"
    ).toCKRecord(in: Self.zoneID)
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
      id: id, data: Self.cachedSystemFields(forLeg: id, transactionId: transactionId))
    // update → V_update (quantity 200), dirty again.
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.id == id)
        .updateAll(database, [TransactionLegRow.Columns.quantity.set(to: 200)])
      try repo.markNeedsPushSync(id: id, in: database)
    }

    let vUpdateRow = try #require(try repo.fetchRowSync(id: id))

    // Step 5: ack of the V_update upload.
    let sentVUpdate = vUpdateRow.toCKRecord(in: Self.zoneID)
    await MainActor.run {
      _ = harness.handler.handleSentRecordZoneChanges(
        savedRecords: [sentVUpdate], failedSaves: [], failedDeletes: [])
    }

    // Step 6: stale V_create echo (quantity 100) arrives late.
    let staleEcho = ProfileDataSyncHandlerTestSupport.transactionLegRow(
      id: id, transactionId: transactionId, accountId: nil, quantity: 100
    ).toCKRecord(in: Self.zoneID)
    let result = harness.handler.applyRemoteChanges(saved: [staleEcho], deleted: [])
    if case .saveFailed(let message) = result { Issue.record("save failed: \(message)") }

    let row = try await harness.database.read { database in
      try TransactionLegRow.fetchOne(database, key: id)
    }
    #expect(try #require(row).quantity == 200)
  }
}
