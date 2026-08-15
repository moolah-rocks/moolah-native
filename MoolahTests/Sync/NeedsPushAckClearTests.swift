@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Upload ack clears needs_push only when unchanged")
struct NeedsPushAckClearTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  /// Reads the raw `needs_push` flag for an account id. Uses raw SQL
  /// because the flag is a local-only column absent from `AccountRow`'s
  /// `CodingKeys`, so it is not visible on the decoded row.
  private func needsPushFlag(
    in database: DatabaseQueue, id: UUID
  ) async throws -> Bool {
    try await database.read { database -> Bool in
      try Bool.fetchOne(
        database, sql: "SELECT needs_push FROM account WHERE id = ?", arguments: [id]) ?? false
    }
  }

  private func encodedSystemFields(
    in database: DatabaseQueue, id: UUID
  ) async throws -> Data? {
    try await database.read { database in
      try Data.fetchOne(
        database,
        sql: "SELECT encoded_system_fields FROM account WHERE id = ?",
        arguments: [id])
    }
  }

  @Test("ack clears the flag when the row matches what was sent")
  func clearsWhenUnchanged() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    let row = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "Sent")
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try row.insert(database)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
    }
    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: id, zoneID: harness.handler.zoneID)
    let sent = try #require(
      await MainActor.run { harness.handler.recordToSave(for: recordID).foundRecord })

    _ = await harness.handler.handleSentRecordZoneChanges(
      savedRecords: [sent], failedSaves: [], failedDeletes: [])

    #expect(try await needsPushFlag(in: harness.database, id: id) == false)
  }

  @Test("ack leaves the flag set when the row changed since send")
  func keepsWhenChanged() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "EDIT 1").insert(database)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
    }
    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: id, zoneID: harness.handler.zoneID)
    let sent = try #require(
      await MainActor.run { harness.handler.recordToSave(for: recordID).foundRecord })
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      _ = try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(
          database,
          [
            AccountRow.Columns.name.set(to: "EDIT 2"),
            AccountRow.Columns.needsPush.set(to: true),
          ])
    }

    _ = await harness.handler.handleSentRecordZoneChanges(
      savedRecords: [sent], failedSaves: [], failedDeletes: [])

    #expect(try await needsPushFlag(in: harness.database, id: id))  // newer edit must remain pending
  }

  @Test("ack persistence rolls back and requeues when any record type fails")
  func rollsBackWholeAcknowledgementBatch() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let accountId = UUID()
    let categoryId = UUID()
    let account = ProfileDataSyncHandlerTestSupport.accountRow(id: accountId, name: "Sent")
    let category = ProfileDataSyncHandlerTestSupport.categoryRow(id: categoryId, name: "Broken")
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try account.insert(database)
      try AccountRow.filter(AccountRow.Columns.id == accountId)
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
      try category.insert(database)
      try CategoryRow.filter(CategoryRow.Columns.id == categoryId)
        .updateAll(database, [CategoryRow.Columns.needsPush.set(to: true)])
    }
    let accountRecordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: accountId, zoneID: harness.handler.zoneID)
    let categoryRecordID = CKRecord.ID(
      recordType: CategoryRow.recordType, uuid: categoryId, zoneID: harness.handler.zoneID)
    let saved = try await MainActor.run {
      [
        try #require(harness.handler.recordToSave(for: accountRecordID).foundRecord),
        try #require(harness.handler.recordToSave(for: categoryRecordID).foundRecord),
      ]
    }
    try await harness.database.write { database in
      try database.execute(sql: "DROP TABLE category")
    }

    let failures = await harness.handler.handleSentRecordZoneChanges(
      savedRecords: saved, failedSaves: [], failedDeletes: [])

    #expect(Set(failures.requeue) == Set(saved.map(\.recordID)))
    #expect(try await needsPushFlag(in: harness.database, id: accountId))
    #expect(try await encodedSystemFields(in: harness.database, id: accountId) == nil)
  }
}

extension NeedsPushAckClearTests {
  @Test("a later edit upload clears needs_push without waiting for a fetched echo")
  func clearsAfterLaterUpload() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    let row = ProfileDataSyncHandlerTestSupport.accountRow(
      id: id, name: "Edited", encodedSystemFields: Data([0x01]))
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try row.insert(database)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
    }
    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: id, zoneID: harness.handler.zoneID)
    let sent = try #require(
      await MainActor.run { harness.handler.recordToSave(for: recordID).foundRecord })

    let result = await harness.handler.handleSentRecordZoneChanges(
      savedRecords: [sent], failedSaves: [], failedDeletes: [])

    #expect(result.requeue.isEmpty)
    #expect(try await needsPushFlag(in: harness.database, id: id) == false)
  }

  @Test("an A-B-A edit cannot be cleared by the older A acknowledgement")
  func abaEditStaysDirty() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "A").insert(database)
      try AccountRow.filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
    }
    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: id, zoneID: harness.handler.zoneID)
    let sentA = try #require(
      await MainActor.run { harness.handler.recordToSave(for: recordID).foundRecord })
    try await harness.database.write { database in
      for name in ["B", "A"] {
        _ = try AccountRow.filter(AccountRow.Columns.id == id)
          .updateAll(
            database,
            [
              AccountRow.Columns.name.set(to: name),
              AccountRow.Columns.needsPush.set(to: true),
            ])
      }
    }

    let result = await harness.handler.handleSentRecordZoneChanges(
      savedRecords: [sentA], failedSaves: [], failedDeletes: [])
    _ = harness.handler.applyRemoteChanges(saved: [sentA], deleted: [])

    #expect(result.requeue == [recordID])
    #expect(try await needsPushFlag(in: harness.database, id: id))
  }

  @Test("an older duplicate acknowledgement cannot regress cached server metadata")
  func olderDuplicateAcknowledgementIsRequeued() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "A").insert(database)
      try harness.handler.grdbRepositories.accounts.markNeedsPushSync(id: id, in: database)
    }
    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: id, zoneID: harness.handler.zoneID)
    let sent = try #require(
      await MainActor.run { harness.handler.recordToSave(for: recordID).foundRecord })
    let older = sent.withModificationDate(Date(timeIntervalSince1970: 1_700_000_000))
    let newer = sent.withModificationDate(Date(timeIntervalSince1970: 1_700_000_060))

    _ = await harness.handler.handleSentRecordZoneChanges(
      savedRecords: [newer], failedSaves: [], failedDeletes: [])
    let delayed = await harness.handler.handleSentRecordZoneChanges(
      savedRecords: [older], failedSaves: [], failedDeletes: [])

    let cachedFields = try await encodedSystemFields(in: harness.database, id: id)
    let cachedDate = cachedFields.flatMap(CKRecord.modificationDate(fromEncodedSystemFields:))
    #expect(delayed.requeue == [recordID])
    #expect(cachedDate == newer.modificationDate)
  }

  @Test("an exact-base conflict converges when server timestamps tie")
  func equalDateConflictAdvancesChangeTag() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let unsent = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "A")
      .toCKRecord(in: harness.handler.zoneID)
    let base = unsent.withServerMetadata(modificationDate: date, changeTag: "C0")
    var seededRow = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "A")
    seededRow.encodedSystemFields = base.encodedSystemFields
    let row = seededRow
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try row.insert(database)
      try harness.handler.grdbRepositories.accounts.markNeedsPushSync(id: id, in: database)
    }
    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: id, zoneID: harness.handler.zoneID)
    let client = try #require(
      await MainActor.run { harness.handler.recordToSave(for: recordID).foundRecord })
    let server = client.withServerMetadata(modificationDate: date, changeTag: "C1")
    var classified = SyncErrorRecovery.ClassifiedFailures()
    classified.conflicts = [(recordID, server)]
    classified.failedClientRecords[recordID] = client
    let failures = classified

    let applicable = try await harness.database.read { database in
      try harness.handler.applicableConflictMetadata(failures, in: database)
    }
    harness.handler.applySystemFieldsBatched(applicable)
    let retry = try #require(
      await MainActor.run { harness.handler.recordToSave(for: recordID).foundRecord })

    #expect(applicable.map(\.recordChangeTag) == ["C1"])
    #expect(retry.recordChangeTag == "C1")
  }
}
