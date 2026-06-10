@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Reproduction for the #1085 out-of-order self-echo loss on the
/// profile-index zone's profile apply path (`applyProfilesGuarded`). A
/// profile created then renamed under backlog must not revert to its
/// created name when the stale V_create echo lands after the eager
/// index-zone `needs_push` ack-clear.
@Suite("profile-index out-of-order echo gate (issue #1085)")
@MainActor
struct ProfileIndexOutOfOrderEchoTests {
  private static let tOlder = Date(timeIntervalSince1970: 1_700_000_000)
  private static let tNewer = Date(timeIntervalSince1970: 1_700_000_060)
  private static let createdAt = Date(timeIntervalSince1970: 1_600_000_000)

  @Test("a renamed profile survives a V_update-echo-then-stale-V_create-echo")
  func renameSurvivesOutOfOrderEcho() throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let repository = GRDBProfileIndexRepository(database: database)
    let handler = ProfileIndexSyncHandler(repository: repository)
    let id = UUID()

    // V_create: created profile "Old Profile", dirty, cached at tOlder.
    let vCreate = ProfileRow(
      id: id,
      recordName: ProfileRow.recordName(for: id),
      label: "Old Profile",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Self.createdAt,
      encodedSystemFields: nil)
    try repository.applyRemoteChangesSync(saved: [vCreate], deleted: [])
    try repository.markNeedsPushSync(id: id)
    let vCreateEcho = vCreate.toCKRecord(in: handler.zoneID).withModificationDate(Self.tOlder)
    _ = try repository.setEncodedSystemFieldsSync(id: id, data: vCreateEcho.encodedSystemFields)

    // V_update: rename to "New Profile" (preserve the cached blob — update
    // only the label column), dirty again.
    try database.write { database in
      _ =
        try ProfileRow
        .filter(ProfileRow.Columns.id == id)
        .updateAll(database, [ProfileRow.Columns.label.set(to: "New Profile")])
    }
    try repository.markNeedsPushSync(id: id)
    let current = try #require(try repository.fetchRowSync(id: id))
    let vUpdateEcho = current.toCKRecord(in: handler.zoneID).withModificationDate(Self.tNewer)

    // (3) Confirming echo of V_update arrives first: row dirty → system-fields
    //     only, advancing the cached date to tNewer.
    _ = handler.applyRemoteChanges(saved: [vUpdateEcho], deleted: [])
    // Eager index-zone ack-clear makes the row clean.
    handler.clearNeedsPushForConfirmed([vUpdateEcho])

    // (4) Stale V_create echo arrives last on the now-clean row; its older
    //     date is rejected by the gate.
    _ = handler.applyRemoteChanges(saved: [vCreateEcho], deleted: [])

    #expect(try #require(try repository.fetchRowSync(id: id)).label == "New Profile")
  }
}
