@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Guards against the single-device data-loss race: when CloudKit echoes
/// back a record this device just uploaded (delivered via
/// `fetchedRecordZoneChanges`) while the user has since made a *newer*
/// local edit that is still queued for upload, the stale echo must not
/// clobber the in-flight local edit.
///
/// The fix flags the locally-edited row `needs_push = 1` and reads that
/// flag inside the apply write transaction (issue #1081): a dirty row's
/// field values are preserved and it receives a system-fields-only update
/// (the cached change tag advances so the queued upload lands cleanly),
/// while clean rows apply normally (genuine remote changes from another
/// device, or harmless no-op echoes). This suite exercises that
/// transactional guard — the regression coverage migrated off the older
/// main-actor pending-record snapshot.
@Suite("Apply remote changes preserves in-flight local edits")
struct ApplyRemoteChangesPendingGuardTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  // MARK: - Account (simple single-row type)

  @Test("Stale account echo does not overwrite a pending local edit")
  func accountEchoSkippedWhilePending() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()

    // Local state reflects the user's *newer* edit (edit #2), not yet
    // uploaded, flagged dirty as a mutation would.
    let localRow = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "LOCAL EDIT 2", encodedSystemFields: nil)
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try localRow.insert(database)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
    }

    // Stale server echo carries edit #1's value.
    let staleEcho = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "STALE SERVER EDIT 1"
    ).toCKRecord(in: Self.zoneID)
    let echoSystemFields = staleEcho.encodedSystemFields

    let result = harness.handler.applyRemoteChanges(saved: [staleEcho], deleted: [])

    if case .saveFailed(let message) = result {
      Issue.record("Expected success, got .saveFailed(\(message))")
    }

    let saved = try await harness.database.read { database in
      try AccountRow.fetchOne(database, key: id)
    }
    let row = try #require(saved)
    // Field values preserved — the in-flight local edit wins.
    #expect(row.name == "LOCAL EDIT 2")
    // System fields *were* updated from the echo (only system fields).
    #expect(row.encodedSystemFields == echoSystemFields)
  }

  @Test("Account echo applies normally when no local edit is pending")
  func accountEchoAppliedWhenNotPending() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()

    let localRow = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "OLD LOCAL", encodedSystemFields: nil)
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try localRow.insert(database)
      // needs_push defaults to 0 (clean) — no local edit pending.
    }

    let remote = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "GENUINE REMOTE CHANGE"
    ).toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [remote], deleted: [])

    if case .saveFailed(let message) = result {
      Issue.record("Expected success, got .saveFailed(\(message))")
    }

    let saved = try await harness.database.read { database in
      try AccountRow.fetchOne(database, key: id)
    }
    // No pending edit — a genuine remote change must apply.
    #expect(try #require(saved).name == "GENUINE REMOTE CHANGE")
  }

  // MARK: - Transaction (the user's reported case)

  @Test("Stale transaction echo does not overwrite a pending local edit")
  func transactionEchoSkippedWhilePending() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    let localRow = ProfileDataSyncHandlerTestSupport.transactionRow(
      id: id, date: date, payee: "LOCAL EDIT 2", encodedSystemFields: nil)
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try localRow.insert(database)
      try TransactionRow.filter(TransactionRow.Columns.id == id)
        .updateAll(database, [TransactionRow.Columns.needsPush.set(to: true)])
    }

    let staleEcho = ProfileDataSyncHandlerTestSupport.transactionRow(
      id: id, date: date, payee: "STALE SERVER EDIT 1"
    ).toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [staleEcho], deleted: [])

    if case .saveFailed(let message) = result {
      Issue.record("Expected success, got .saveFailed(\(message))")
    }

    let saved = try await harness.database.read { database in
      try TransactionRow.fetchOne(database, key: id)
    }
    #expect(try #require(saved).payee == "LOCAL EDIT 2")
  }

  @Test("Stale transaction-leg echo does not overwrite a pending local edit")
  func transactionLegEchoSkippedWhilePending() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    let transactionId = UUID()

    // Legs are the most frequently mutated per-profile record type —
    // every transaction amount/account/category edit touches them.
    let localRow = ProfileDataSyncHandlerTestSupport.transactionLegRow(
      id: id, transactionId: transactionId, accountId: nil, quantity: 200,
      encodedSystemFields: nil)
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try localRow.insert(database)
      try TransactionLegRow.filter(TransactionLegRow.Columns.id == id)
        .updateAll(database, [TransactionLegRow.Columns.needsPush.set(to: true)])
    }

    let staleEcho = ProfileDataSyncHandlerTestSupport.transactionLegRow(
      id: id, transactionId: transactionId, accountId: nil, quantity: 100
    ).toCKRecord(in: Self.zoneID)
    let echoSystemFields = staleEcho.encodedSystemFields

    let result = harness.handler.applyRemoteChanges(saved: [staleEcho], deleted: [])

    if case .saveFailed(let message) = result {
      Issue.record("Expected success, got .saveFailed(\(message))")
    }

    let saved = try await harness.database.read { database in
      try TransactionLegRow.fetchOne(database, key: id)
    }
    let row = try #require(saved)
    #expect(row.quantity == 200)
    #expect(row.encodedSystemFields == echoSystemFields)
  }
}
