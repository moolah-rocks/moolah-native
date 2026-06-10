// MoolahTests/Backends/GRDB/SyncRoundTripCSVImportTests.swift

import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies that `ProfileDataSyncHandler.applyRemoteChanges` round-trips
/// CSV-import-profile and import-rule CKRecords through the GRDB
/// dispatch path.
///
/// The flow mirrors what CKSyncEngine drives in production: device A
/// produces a CKRecord via `Row.toCKRecord(in:)`, device B's data
/// handler applies it via `applyRemoteChanges`, and we assert the GRDB
/// row on device B matches the source — including the cached
/// `encodedSystemFields` blob bit-for-bit.
@Suite("CKSyncEngine ↔ GRDB round trip — CSV import + rules")
@MainActor
struct SyncRoundTripCSVImportTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  // MARK: - CSVImportProfileRow

  @Test("CSV import profile applies via remote-change dispatch")
  func csvImportProfileRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler
    let database = harness.database
    let id = UUID()
    let accountId = UUID()
    let source = CSVImportProfileRow(
      id: id,
      recordName: CSVImportProfileRow.recordName(for: id),
      accountId: accountId,
      parserIdentifier: "generic-bank",
      headerSignature: "date\u{1F}amount",
      filenamePattern: nil,
      deleteAfterImport: false,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastUsedAt: nil,
      dateFormatRawValue: nil,
      columnRoleRawValuesEncoded: nil,
      encodedSystemFields: nil)
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let rows = try await database.read { database in
      try CSVImportProfileRow.fetchAll(database)
    }
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.id == id)
    #expect(row.accountId == accountId)
    #expect(row.parserIdentifier == "generic-bank")
    #expect(row.headerSignature == "date\u{1F}amount")
    // CKSyncEngine's apply path stamps the cached system fields from the
    // incoming record — bit-for-bit byte equality is the contract that
    // prevents `.serverRecordChanged` cycles on the next upload.
    #expect(row.encodedSystemFields == ckRecord.encodedSystemFields)
  }

  @Test("CSV import profile delete via remote-change dispatch removes the row")
  func csvImportProfileDelete() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler
    let database = harness.database
    let id = UUID()
    let row = CSVImportProfileRow(
      id: id,
      recordName: CSVImportProfileRow.recordName(for: id),
      accountId: UUID(),
      parserIdentifier: "p",
      headerSignature: "a",
      filenamePattern: nil,
      deleteAfterImport: false,
      createdAt: Date(),
      lastUsedAt: nil,
      dateFormatRawValue: nil,
      columnRoleRawValuesEncoded: nil,
      encodedSystemFields: nil)
    try await database.write { database in
      try row.insert(database)
    }

    let recordID = CKRecord.ID(
      recordType: CSVImportProfileRow.recordType, uuid: id, zoneID: Self.zoneID)
    let result = handler.applyRemoteChanges(
      saved: [], deleted: [(recordID, CSVImportProfileRow.recordType)])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let count = try await database.read { database in
      try CSVImportProfileRow.fetchCount(database)
    }
    #expect(count == 0)
  }

  // MARK: - ImportRuleRow

  @Test("import rule applies via remote-change dispatch")
  func importRuleRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler
    let database = harness.database
    let id = UUID()
    let conditionsJSON = Data(#"[{"k":"v"}]"#.utf8)
    let actionsJSON = Data(#"[{"a":"b"}]"#.utf8)
    let source = ImportRuleRow(
      id: id,
      recordName: ImportRuleRow.recordName(for: id),
      name: "Rent",
      enabled: true,
      position: 3,
      matchMode: MatchMode.all.rawValue,
      conditionsJSON: conditionsJSON,
      actionsJSON: actionsJSON,
      accountScope: nil,
      encodedSystemFields: nil)
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let rows = try await database.read { database in
      try ImportRuleRow.fetchAll(database)
    }
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.id == id)
    #expect(row.name == "Rent")
    #expect(row.enabled)
    #expect(row.position == 3)
    #expect(row.matchMode == "all")
    #expect(row.conditionsJSON == conditionsJSON)
    #expect(row.actionsJSON == actionsJSON)
    // Byte-for-byte preservation of the incoming change tag — see the
    // matching expectation on `csvImportProfileRoundTrip`.
    #expect(row.encodedSystemFields == ckRecord.encodedSystemFields)
  }

  // MARK: - Uplink (upload) round trip

  @Test("CSV import profile uplinks fresh state, then a second device applies it byte-equal")
  func csvImportProfileUplinkRoundTrip() async throws {
    // Device A: write a row through the repo, then build the CKRecord
    // CKSyncEngine would upload via `recordToSave(for:)`.
    let harnessA = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let id = UUID()
    let accountId = UUID()
    let domain = CSVImportProfile(
      id: id,
      accountId: accountId,
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "amount"],
      filenamePattern: nil,
      deleteAfterImport: false,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastUsedAt: nil,
      dateFormatRawValue: nil,
      columnRoleRawValues: [])
    _ = try await harnessA.handler.grdbRepositories.csvImportProfiles.create(domain)
    let recordID = CKRecord.ID(
      recordType: CSVImportProfileRow.recordType, uuid: id, zoneID: harnessA.handler.zoneID)
    let outgoing = try #require(harnessA.handler.recordToSave(for: recordID).foundRecord)

    // Stamp the server-issued change-tag bytes onto the record (a real
    // CKSyncEngine save populates these) and feed them back to Device A
    // via the system-fields apply path used after a successful send.
    let stampedFields = outgoing.encodedSystemFields
    _ = try harnessA.handler.grdbRepositories.csvImportProfiles
      .setEncodedSystemFieldsSync(id: id, data: stampedFields)
    let rowsA = try await harnessA.database.read { database in
      try CSVImportProfileRow.fetchAll(database)
    }
    let rowA = try #require(rowsA.first)
    #expect(rowA.encodedSystemFields == stampedFields)

    // Device B applies the same CKRecord via the remote-change dispatch
    // path; the row must end up with the same field values and the
    // exact same encodedSystemFields bytes.
    let harnessB = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let result = harnessB.handler.applyRemoteChanges(saved: [outgoing], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed on device B: \(message)")
    }
    let rowsB = try await harnessB.database.read { database in
      try CSVImportProfileRow.fetchAll(database)
    }
    let rowB = try #require(rowsB.first)
    #expect(rowB.id == rowA.id)
    #expect(rowB.accountId == accountId)
    #expect(rowB.parserIdentifier == "generic-bank")
    #expect(rowB.headerSignature == rowA.headerSignature)
    #expect(rowB.encodedSystemFields == outgoing.encodedSystemFields)
  }

  /// Sibling of `csvImportProfileUplinkRoundTrip` for `ImportRuleRow`.
  /// Exercises `recordToSave(for:)` → `fetchImportRuleRow` →
  /// `mapBuiltRows` → `applyRemoteChanges` to ensure the upload-side
  /// path doesn't silently regress (e.g. a future refactor that
  /// returns `nil` from `fetchImportRuleRow`, or a missing
  /// `ImportRuleRow.recordType` case in `mapBuiltRows`).
  @Test
  func importRuleUplinkRoundTrip() async throws {
    let harnessA = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let id = UUID()
    let domain = ImportRule(
      id: id,
      name: "Coffee shops",
      enabled: true,
      position: 0,
      matchMode: .all,
      conditions: [],
      actions: [],
      accountScope: nil)
    _ = try await harnessA.handler.grdbRepositories.importRules.create(domain)
    let recordID = CKRecord.ID(
      recordType: ImportRuleRow.recordType, uuid: id, zoneID: harnessA.handler.zoneID)
    let outgoing = try #require(harnessA.handler.recordToSave(for: recordID).foundRecord)

    // Stamp server-issued change tag and write it back to the row.
    let stampedFields = outgoing.encodedSystemFields
    _ = try harnessA.handler.grdbRepositories.importRules
      .setEncodedSystemFieldsSync(id: id, data: stampedFields)
    let rowsA = try await harnessA.database.read { database in
      try ImportRuleRow.fetchAll(database)
    }
    let rowA = try #require(rowsA.first)
    #expect(rowA.encodedSystemFields == stampedFields)

    // Device B applies the same CKRecord via apply-remote-changes and
    // must end up with the same fields and bytes.
    let harnessB = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let result = harnessB.handler.applyRemoteChanges(saved: [outgoing], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed on device B: \(message)")
    }
    let rowsB = try await harnessB.database.read { database in
      try ImportRuleRow.fetchAll(database)
    }
    let rowB = try #require(rowsB.first)
    #expect(rowB.id == rowA.id)
    #expect(rowB.name == "Coffee shops")
    #expect(rowB.enabled == true)
    #expect(rowB.position == 0)
    #expect(rowB.matchMode == "all")
    #expect(rowB.encodedSystemFields == outgoing.encodedSystemFields)
  }

  // MARK: - Data-loss regression: GRDB write failure must surface .saveFailed

  /// Regression for the round-2 finding I-1 (silent data loss on remote
  /// pulls). Pre-fix: `applyGRDBBatchSave` swallowed the error and
  /// returned `true`, the surrounding `context.save()` succeeded against
  /// SwiftData, and `applyRemoteChanges` returned `.success(...)` —
  /// CKSyncEngine then advanced its change token past the dropped
  /// record. The fix propagates the throw so `applyRemoteChanges`
  /// returns `.saveFailed(...)` and the coordinator re-fetches.
  ///
  /// Mirror of `CSVImportRollbackTests` trigger pattern: install a
  /// BEFORE-INSERT trigger that aborts on a sentinel parser identifier,
  /// feed a matching CKRecord through `applyRemoteChanges`, assert the
  /// result is `.saveFailed(...)`.
  @Test("applyRemoteChanges reports saveFailed when the GRDB upsert fails")
  func applyRemoteChangesReportsSaveFailedWhenGRDBUpsertFails() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    try await harness.database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_csv_import_profile_apply_remote
          BEFORE INSERT ON csv_import_profile
          WHEN NEW.parser_identifier = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for data-loss regression');
          END;
          """)
    }

    let id = UUID()
    let failing = CSVImportProfileRow(
      id: id,
      recordName: CSVImportProfileRow.recordName(for: id),
      accountId: UUID(),
      parserIdentifier: "___FAIL___",
      headerSignature: "date\u{1F}amount",
      filenamePattern: nil,
      deleteAfterImport: false,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastUsedAt: nil,
      dateFormatRawValue: nil,
      columnRoleRawValuesEncoded: nil,
      encodedSystemFields: nil)
    let ckRecord = failing.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    // The whole point of the fix: CKSyncEngine MUST be told the apply
    // failed so it refetches; .success would let the change token
    // advance past the dropped record.
    guard case .saveFailed = result else {
      Issue.record(
        """
        applyRemoteChanges returned \(result) but the GRDB upsert was \
        rejected by the trigger — the result must be .saveFailed so the \
        coordinator schedules a re-fetch (data-loss regression I-1).
        """)
      return
    }

    // No row landed: the failed transaction rolled back inside the repo.
    let count = try await harness.database.read { database in
      try CSVImportProfileRow.fetchCount(database)
    }
    #expect(count == 0)
  }
}
