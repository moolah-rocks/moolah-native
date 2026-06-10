// MoolahTests/Backends/GRDB/ProfileIndexSyncRoundTripTests.swift

import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies that `ProfileIndexSyncHandler.applyRemoteChanges` round-trips
/// `ProfileRecord` CKRecords through the GRDB dispatch path.
///
/// Mirrors `SyncRoundTripCSVImportTests`: device A produces a CKRecord
/// via `Row.toCKRecord(in:)`, device B's handler applies it via
/// `applyRemoteChanges`, and we assert the GRDB row on device B matches
/// the source — including the cached `encodedSystemFields` blob
/// bit-for-bit.
@Suite("CKSyncEngine ↔ GRDB round trip — profile index")
struct ProfileIndexSyncRoundTripTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)

  // MARK: - Construction helper

  private struct Harness {
    let handler: ProfileIndexSyncHandler
    let repository: GRDBProfileIndexRepository
    let database: DatabaseQueue
  }

  private static func makeHarness() throws -> Harness {
    let database = try ProfileIndexDatabase.openInMemory()
    let repository = GRDBProfileIndexRepository(database: database)
    let handler = ProfileIndexSyncHandler(repository: repository)
    return Harness(handler: handler, repository: repository, database: database)
  }

  private static func makeRow(
    id: UUID = UUID(),
    label: String = "Personal",
    currencyCode: String = "AUD",
    financialYearStartMonth: Int = 7,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    encodedSystemFields: Data? = nil
  ) -> ProfileRow {
    ProfileRow(
      id: id,
      recordName: ProfileRow.recordName(for: id),
      label: label,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth,
      createdAt: createdAt,
      encodedSystemFields: encodedSystemFields)
  }

  // MARK: - applyRemoteChanges (saved)

  @Test("profile applies via remote-change dispatch")
  func profileApplyRemoteChangesViaHandler() throws {
    let harnessA = try Self.makeHarness()
    let harnessB = try Self.makeHarness()
    let id = UUID()
    let source = Self.makeRow(
      id: id,
      label: "Family",
      currencyCode: "USD",
      financialYearStartMonth: 1,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    // Seed device A's repo so the source-of-truth row matches the
    // outbound CKRecord we then feed to device B.
    try harnessA.repository.applyRemoteChangesSync(saved: [source], deleted: [])
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = harnessB.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }
    // The handler reports the recordTypes it touched so the coordinator
    // can fan notifications out to the matching repos.
    guard case .success(let changedTypes) = result else {
      Issue.record("applyRemoteChanges returned \(result), expected .success")
      return
    }
    #expect(changedTypes == Set([ProfileRow.recordType]))

    let restored = try #require(try harnessB.repository.fetchRowSync(id: id))
    #expect(restored.id == source.id)
    #expect(restored.recordName == source.recordName)
    #expect(restored.label == source.label)
    #expect(restored.currencyCode == source.currencyCode)
    #expect(restored.financialYearStartMonth == source.financialYearStartMonth)
    #expect(restored.createdAt == source.createdAt)
    // CKSyncEngine's apply path stamps the cached system fields from
    // the incoming record — bit-for-bit byte equality is the contract
    // that prevents `.serverRecordChanged` cycles on the next upload.
    #expect(restored.encodedSystemFields == ckRecord.encodedSystemFields)
  }

  // MARK: - Uplink (upload) round trip

  @Test("profile uplinks fresh state, then a second device applies it byte-equal")
  func profileUplinkRoundTrip() async throws {
    // Device A: write a profile through the repo, then build the
    // CKRecord CKSyncEngine would upload via `recordToSave(for:)`.
    let harnessA = try Self.makeHarness()
    let id = UUID()
    let domain = Profile(
      id: id,
      label: "Travel",
      currencyCode: "EUR",
      financialYearStartMonth: 4,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    try await harnessA.repository.upsert(domain)
    let recordID = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: id, zoneID: Self.zoneID)
    let outgoing = try #require(harnessA.handler.recordToSave(for: recordID).foundRecord)

    // Stamp the server-issued change-tag bytes onto device A's row (a
    // real CKSyncEngine save populates these via the post-send
    // persistSystemFields path).
    let stampedFields = outgoing.encodedSystemFields
    _ = try harnessA.repository.setEncodedSystemFieldsSync(id: id, data: stampedFields)
    let rowA = try #require(try harnessA.repository.fetchRowSync(id: id))
    #expect(rowA.encodedSystemFields == stampedFields)

    // Device B applies the same CKRecord via the remote-change
    // dispatch path; the row must end up with the same field values
    // and the exact same encodedSystemFields bytes.
    let harnessB = try Self.makeHarness()
    let result = harnessB.handler.applyRemoteChanges(saved: [outgoing], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed on device B: \(message)")
    }

    let rowB = try #require(try harnessB.repository.fetchRowSync(id: id))
    #expect(rowB.id == rowA.id)
    #expect(rowB.label == "Travel")
    #expect(rowB.currencyCode == "EUR")
    #expect(rowB.financialYearStartMonth == 4)
    #expect(rowB.createdAt == rowA.createdAt)
    #expect(rowB.encodedSystemFields == outgoing.encodedSystemFields)
    #expect(rowB.encodedSystemFields == rowA.encodedSystemFields)
  }

  // MARK: - applyRemoteChanges (deleted)

  @Test("profile delete via remote-change dispatch removes the row")
  func profileApplyRemoteDeletionRemovesRow() throws {
    let harness = try Self.makeHarness()
    let id = UUID()
    let row = Self.makeRow(id: id)
    try harness.repository.applyRemoteChangesSync(saved: [row], deleted: [])
    #expect(try harness.repository.fetchRowSync(id: id) != nil)

    let recordID = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: id, zoneID: Self.zoneID)
    let result = harness.handler.applyRemoteChanges(saved: [], deleted: [recordID])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    #expect(try harness.repository.fetchRowSync(id: id) == nil)
  }

  // MARK: - Malformed recordID is logged and skipped

  /// Per `ProfileIndexSyncHandler.applyRemoteChanges`, a CKRecord whose
  /// `recordID` cannot be parsed as `<recordType>|<uuid>` is logged and
  /// skipped — the handler continues processing the rest of the batch
  /// and still reports `.success`. Constructed via the bare
  /// `CKRecord.ID(recordName:zoneID:)` initialiser so the recordName has
  /// no `|<UUID>` suffix; `ProfileRow.fieldValues(from:)` then returns
  /// `nil` and the loop continues without writing.
  @Test("applyRemoteChanges skips malformed recordIDs without writing")
  func profileApplyRemoteChangesSkipsMalformedRecord() throws {
    let harness = try Self.makeHarness()
    let malformedRecordID = CKRecord.ID(
      recordName: "not-a-valid-profile-record-name", zoneID: Self.zoneID)
    let malformed = CKRecord(
      recordType: ProfileRow.recordType, recordID: malformedRecordID)

    let result = harness.handler.applyRemoteChanges(saved: [malformed], deleted: [])

    // The handler still reports success — coordinators advance the
    // change token past the dropped record because there's nothing
    // left to do for it.
    guard case .success = result else {
      Issue.record("applyRemoteChanges returned \(result), expected .success")
      return
    }
    // No row was written.
    #expect(try harness.repository.allRowIdsSync().isEmpty)
  }

  // MARK: - Byte-for-byte preservation of encodedSystemFields

  /// Synthesises a CKRecord whose system fields carry a non-trivial,
  /// byte-distinguishable change tag (the bytes the real CKSyncEngine
  /// would issue) and asserts the stored row's blob matches byte-equal
  /// after applyRemoteChanges. Distinct from
  /// `profileApplyRemoteChangesViaHandler` because that test compares
  /// against the freshly-built record's bytes, while this one checks
  /// that round-tripping through `NSKeyedArchiver` doesn't perturb the
  /// blob.
  @Test("applyRemoteChanges preserves encodedSystemFields byte-for-byte")
  func profileApplyRemoteChangesPreservesEncodedSystemFieldsByteForByte() throws {
    let harness = try Self.makeHarness()
    let id = UUID()
    let source = Self.makeRow(id: id, label: "Bytes")
    let ckRecord = source.toCKRecord(in: Self.zoneID)
    let originalBytes = ckRecord.encodedSystemFields
    // The bytes must be non-empty otherwise the byte-equal check is
    // trivially true on every code path.
    #expect(!originalBytes.isEmpty)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let restored = try #require(try harness.repository.fetchRowSync(id: id))
    let restoredBytes = try #require(restored.encodedSystemFields)
    #expect(restoredBytes == originalBytes)
    // Defence-in-depth: the bytes must decode back to a CKRecord with
    // the same recordID / zoneID. A blob that's byte-equal but
    // un-decodable would silently break the next upload's
    // change-tag reuse.
    let decoded = try #require(CKRecord.fromEncodedSystemFields(restoredBytes))
    #expect(decoded.recordID == ckRecord.recordID)
    #expect(decoded.recordID.zoneID == Self.zoneID)
  }

  // MARK: - Data-loss regression: GRDB write failure must surface .saveFailed

  /// Mirror of `SyncRoundTripCSVImportTests`'
  /// `applyRemoteChangesReportsSaveFailedWhenGRDBUpsertFails`: install a
  /// `BEFORE INSERT` trigger that aborts on a sentinel `label`, feed a
  /// matching CKRecord through the handler, and assert the result is
  /// `.saveFailed(...)` so the coordinator schedules a re-fetch.
  @Test("applyRemoteChanges reports saveFailed when the GRDB upsert fails")
  func profileApplyRemoteChangesReturnsSaveFailedOnGRDBError() async throws {
    let harness = try Self.makeHarness()
    try await harness.database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_profile_apply_remote
          BEFORE INSERT ON profile
          WHEN NEW.label = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for data-loss regression');
          END;
          """)
    }

    let id = UUID()
    let failing = Self.makeRow(id: id, label: "___FAIL___")
    let ckRecord = failing.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    // The whole point of the contract: CKSyncEngine MUST be told the
    // apply failed so it refetches; .success would let the change
    // token advance past the dropped record (data-loss regression).
    guard case .saveFailed = result else {
      Issue.record(
        """
        applyRemoteChanges returned \(result) but the GRDB upsert was \
        rejected by the trigger — the result must be .saveFailed so the \
        coordinator schedules a re-fetch.
        """)
      return
    }

    // No row landed: the failed transaction rolled back inside the repo.
    #expect(try harness.repository.allRowIdsSync().isEmpty)
  }
}
