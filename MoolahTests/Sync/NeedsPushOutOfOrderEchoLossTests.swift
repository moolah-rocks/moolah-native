@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Reproduces the REAL single-device data-loss race that survives both the
/// #1081 apply guard AND the #1081-follow-up ack-clear deferral (PR #1084),
/// and is closed by the #1085 modification-date gate on the clean apply path.
///
/// The #1084 fix rested on one load-bearing assumption, stated verbatim in
/// `ProfileDataSyncHandler+SystemFields.swift` and `+ApplyGuard.swift`:
///
///   > the flag stays set and is cleared later by the fetch/apply path when
///   > the *confirming* echo of the current version arrives — safe because
///   > CKSyncEngine delivers fetched changes in server-token order, so every
///   > earlier-token stale echo has already been processed by then.
///
/// That assumption is FALSE under a heavy upload/echo backlog. When a record
/// is created (V_create) and then updated (V_update) while sync is busy, the
/// two versions upload as *separate* in-flight batches. Their echoes do NOT
/// arrive in a single monotonic server-token stream — a save-completion echo,
/// a conflict-loser echo, and an independent fetch operation each carry their
/// own delivery, and under load the *newer* version's confirming echo can be
/// applied BEFORE the *older* version's stale echo.
///
/// Losing interleaving (single device, no peers):
///   1. create V_create, `needs_push = 1`, uploaded in batch N.
///   2. update → V_update, `needs_push = 1` re-raised, uploaded in batch M.
///   3. The CONFIRMING echo of V_update is applied first. The apply path's
///      `clearNeedsPushForConfirmingEchoes` sees `current(V_update) ==
///      echo(V_update)` and CLEARS `needs_push`. Row is now clean.
///   4. The STALE echo of V_create — still queued from batch N's separate
///      delivery — is applied LAST. The row is clean, so it would take the
///      normal upsert path and clobber V_update back to V_create — UNLESS
///      the modification-date gate rejects it: V_create's echo carries an
///      OLDER server `modificationDate` than the cached V_update version,
///      so the gate skips it and the newer edit survives.
///
/// This is the production symptom: a leg created as a placeholder
/// (AUD/income/qty 1) then updated to a real token leg reverts to the
/// placeholder; whole accounts end with only placeholder legs.
///
/// **#1085 amendment (design §5a).** As originally written the spec test
/// fabricated both echoes via `row.toCKRecord(in:)`, which builds a fresh
/// local `CKRecord` with `modificationDate == nil`. The gate fails open on
/// `nil` dates, so the stale echo would still apply and the loss would still
/// reproduce even with the fix. The echoes therefore carry distinct server
/// dates (`T_create < T_update`) via the test-only `withModificationDate`
/// helper, exactly as production does.
@Suite("needs_push survives an out-of-order echo under backlog (single-device loss)")
struct NeedsPushOutOfOrderEchoLossTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  /// Distinct server modification dates: V_create is older, V_update newer.
  private static let tCreate = Date(timeIntervalSince1970: 1_700_000_000)
  private static let tUpdate = Date(timeIntervalSince1970: 1_700_000_060)

  /// Drives a leg through the REAL create→update repository flow so
  /// `needs_push` and the cached system fields are left exactly as
  /// production leaves them, then delivers the V_update confirming echo and
  /// the V_create stale echo OUT OF ORDER (newer first) the way a heavy
  /// backlog does.
  @Test("TransactionLeg: V_update survives a V_update-echo-then-stale-V_create-echo")
  func legUpdateSurvivesOutOfOrderEcho() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    let transactionId = UUID()
    let repo = harness.handler.grdbRepositories.transactionLegs

    // create (V_create): placeholder AUD/income, quantity 1, dirty.
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.transactionLegRow(
        id: id, transactionId: transactionId, accountId: nil, quantity: 1
      ).insert(database)
      try repo.markNeedsPushSync(id: id, in: database)
    }
    let vCreateRow = try #require(try repo.fetchRowSync(id: id))
    // ack of V_create caches its (non-nil) server system fields; this is
    // the version that will echo back stale, stamped with the OLDER date.
    let vCreateEcho = vCreateRow.toCKRecord(in: Self.zoneID).withModificationDate(Self.tCreate)
    _ = try repo.setEncodedSystemFieldsSync(id: id, data: vCreateEcho.encodedSystemFields)

    // update → V_update: real token quantity 200, dirty again.
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.id == id)
        .updateAll(database, [TransactionLegRow.Columns.quantity.set(to: 200)])
      try repo.markNeedsPushSync(id: id, in: database)
    }
    let vUpdateRow = try #require(try repo.fetchRowSync(id: id))
    let vUpdateEcho = vUpdateRow.toCKRecord(in: Self.zoneID).withModificationDate(Self.tUpdate)

    // --- Heavy-backlog OUT-OF-ORDER delivery ---
    // (3) The confirming echo of V_update arrives FIRST and clears the flag,
    //     advancing the cached date to T_update.
    let confirm = harness.handler.applyRemoteChanges(saved: [vUpdateEcho], deleted: [])
    if case .saveFailed(let message) = confirm { Issue.record("confirm save failed: \(message)") }

    // (4) The stale echo of V_create arrives LAST, on a now-clean row;
    //     its older date is rejected by the gate.
    let stale = harness.handler.applyRemoteChanges(saved: [vCreateEcho], deleted: [])
    if case .saveFailed(let message) = stale { Issue.record("stale save failed: \(message)") }

    let row = try await harness.database.read { database in
      try TransactionLegRow.fetchOne(database, key: id)
    }
    // The newer local edit must survive the out-of-order stale echo.
    #expect(try #require(row).quantity == 200)
  }

  /// The same loss embedded in a HEAVY batch: hundreds of unrelated rows
  /// applied alongside the out-of-order echoes, modelling the ~514-record
  /// import upload backlog that triggers the real loss across many accounts.
  @Test("TransactionLeg: V_update survives out-of-order echo amid a 200-record batch")
  func legUpdateSurvivesOutOfOrderEchoUnderBatchLoad() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    let transactionId = UUID()
    let repo = harness.handler.grdbRepositories.transactionLegs

    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.transactionLegRow(
        id: id, transactionId: transactionId, accountId: nil, quantity: 1
      ).insert(database)
      try repo.markNeedsPushSync(id: id, in: database)
    }
    let vCreateRow = try #require(try repo.fetchRowSync(id: id))
    let vCreateEcho = vCreateRow.toCKRecord(in: Self.zoneID).withModificationDate(Self.tCreate)
    _ = try repo.setEncodedSystemFieldsSync(id: id, data: vCreateEcho.encodedSystemFields)

    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.id == id)
        .updateAll(database, [TransactionLegRow.Columns.quantity.set(to: 200)])
      try repo.markNeedsPushSync(id: id, in: database)
    }
    let vUpdateRow = try #require(try repo.fetchRowSync(id: id))
    let vUpdateEcho = vUpdateRow.toCKRecord(in: Self.zoneID).withModificationDate(Self.tUpdate)

    // A large batch of unrelated incoming legs (the import backlog echoing).
    let backlog: [CKRecord] = (0..<200).map { index in
      ProfileDataSyncHandlerTestSupport.transactionLegRow(
        id: UUID(), transactionId: UUID(), accountId: nil, quantity: Int64(index)
      ).toCKRecord(in: Self.zoneID)
    }

    // Confirming V_update echo lands inside a heavy batch; flag cleared.
    let confirm = harness.handler.applyRemoteChanges(saved: backlog + [vUpdateEcho], deleted: [])
    if case .saveFailed(let message) = confirm { Issue.record("confirm save failed: \(message)") }

    // Stale V_create echo lands in a later heavy batch, on a clean row.
    let stale = harness.handler.applyRemoteChanges(saved: [vCreateEcho] + backlog, deleted: [])
    if case .saveFailed(let message) = stale { Issue.record("stale save failed: \(message)") }

    let row = try await harness.database.read { database in
      try TransactionLegRow.fetchOne(database, key: id)
    }
    #expect(try #require(row).quantity == 200)
  }

  /// The constraint that defeats every single-cached-tag fix: a CLEAN,
  /// already-synced row (non-nil cached system fields) receiving a
  /// GENUINE remote change from a peer device MUST apply it. A stale
  /// self-echo and a genuine peer change are both "clean row, cached
  /// blob present, incoming fields differ" — they are distinguished only
  /// by `modificationDate`: the genuine peer change is strictly NEWER, so
  /// the gate applies it. This test must stay green.
  ///
  /// **#1085 amendment (design §5b).** The cached version carries an older
  /// stamped date and the peer change a strictly-newer one, so this exercises
  /// the gate's "newer → apply" branch explicitly rather than the `nil`
  /// fail-open.
  @Test("a clean, already-synced row still applies a genuine remote change")
  func syncedCleanRowAppliesGenuineRemoteChange() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    let transactionId = UUID()
    let repo = harness.handler.grdbRepositories.transactionLegs

    // Locally-synced clean row at quantity 100 with cached system fields
    // stamped at the OLDER date.
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.transactionLegRow(
        id: id, transactionId: transactionId, accountId: nil, quantity: 100
      ).insert(database)
    }
    let localRow = try #require(try repo.fetchRowSync(id: id))
    _ = try repo.setEncodedSystemFieldsSync(
      id: id,
      data: localRow.toCKRecord(in: Self.zoneID).withModificationDate(Self.tCreate)
        .encodedSystemFields)
    // needs_push stays 0 (clean — fully round-tripped).

    // A peer device's genuine update: quantity 500, stamped with a NEWER date.
    let remote = ProfileDataSyncHandlerTestSupport.transactionLegRow(
      id: id, transactionId: transactionId, accountId: nil, quantity: 500
    ).toCKRecord(in: Self.zoneID).withModificationDate(Self.tUpdate)

    let result = harness.handler.applyRemoteChanges(saved: [remote], deleted: [])
    if case .saveFailed(let message) = result { Issue.record("save failed: \(message)") }

    let row = try await harness.database.read { database in
      try TransactionLegRow.fetchOne(database, key: id)
    }
    #expect(try #require(row).quantity == 500)
  }
}
