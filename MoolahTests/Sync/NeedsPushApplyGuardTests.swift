@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Apply guards rows flagged needs_push")
struct NeedsPushApplyGuardTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("a dirty row's field values survive a stale echo; system fields update")
  func dirtyRowFieldValuesPreserved() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    // Local newer edit, flagged dirty (as a mutation would).
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "LOCAL EDIT 2")
        .insert(database)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
    }
    let staleEcho = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "STALE SERVER EDIT 1"
    ).toCKRecord(in: Self.zoneID)
    let echoSystemFields = staleEcho.encodedSystemFields

    let result = harness.handler.applyRemoteChanges(saved: [staleEcho], deleted: [])
    if case .saveFailed(let message) = result { Issue.record("save failed: \(message)") }

    let row = try await harness.database.read { database in
      try AccountRow.fetchOne(database, key: id)
    }
    let saved = try #require(row)
    #expect(saved.name == "LOCAL EDIT 2")  // field values preserved
    #expect(saved.encodedSystemFields == echoSystemFields)  // system fields updated
  }

  @Test("a clean row applies the remote change normally")
  func cleanRowApplies() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "OLD").insert(database)
      // needs_push defaults to 0 (clean).
    }
    let remote = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "REMOTE"
    ).toCKRecord(in: Self.zoneID)

    _ = harness.handler.applyRemoteChanges(saved: [remote], deleted: [])

    let row = try await harness.database.read { database in
      try AccountRow.fetchOne(database, key: id)
    }
    #expect(try #require(row).name == "REMOTE")
  }
}
