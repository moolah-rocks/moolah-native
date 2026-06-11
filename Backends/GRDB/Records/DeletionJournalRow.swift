import Foundation
import GRDB

/// One persisted deletion intent (issue #1090). Written inside the same
/// `database.write` that deletes a synced local row, replayed as a
/// `.deleteRecord` on engine start, and cleared on confirmation or when the
/// record is re-created with the same id. Because it lives in GRDB (not the
/// CKSyncEngine state blob) it survives a sync-state reset, so a deletion is
/// never lost to engine-down timing or a state reset.
///
/// Keyed by `(zoneName, recordName)` — 1:1 with a `CKRecord.ID` — so
/// re-deleting is idempotent.
struct DeletionJournalRow: Codable, Sendable {
  static let databaseTableName = "deletion_journal"

  /// `CKRecordZone.ID.zoneName`.
  var zoneName: String
  /// `CKRecord.ID.recordName` (the prefixed `<RecordType>|<UUID>` form, or a
  /// bare string id for instruments).
  var recordName: String
  /// The record's type — for logging / replay dispatch only.
  var recordType: String
  /// `Date.timeIntervalSince1970` of when the intent was recorded — for
  /// observability / ordering. A local clock value; never crosses the wire.
  var queuedAt: Double

  enum CodingKeys: String, CodingKey {
    case zoneName = "zone_name"
    case recordName = "record_name"
    case recordType = "record_type"
    case queuedAt = "queued_at"
  }

  enum Columns {
    static let zoneName = Column(CodingKeys.zoneName)
    static let recordName = Column(CodingKeys.recordName)
    static let recordType = Column(CodingKeys.recordType)
    static let queuedAt = Column(CodingKeys.queuedAt)
  }
}

extension DeletionJournalRow: FetchableRecord {}
extension DeletionJournalRow: PersistableRecord {
  /// Re-recording an existing intent is a no-op overwrite (idempotent delete),
  /// so an `INSERT` that collides on the `(zone_name, record_name)` PK replaces.
  static let persistenceConflictPolicy = PersistenceConflictPolicy(
    insert: .replace, update: .replace)
}

/// Read/write helpers for the deletion journal. Plain strings + a `Database`,
/// so the per-repository delete/create methods can call them inside their own
/// write transaction without importing CloudKit (issue #1090).
enum DeletionJournal {
  /// The `CKRecordZone.ID.zoneName` of the shared profile-index zone — a
  /// frozen CloudKit contract. Profile and shared-instrument records live
  /// here, so the profile-index DB's journal entries carry this zone name.
  static let profileIndexZoneName = "profile-index"

  /// The per-profile data zone name for `profileId`, matching the
  /// `profile-<uuid>` form used by the sync layer. Used by the start-time
  /// replay to resolve the real zone for a per-profile journal entry from the
  /// DB it was read from.
  static func dataZoneName(for profileId: UUID) -> String {
    "profile-\(profileId.uuidString)"
  }

  /// Sentinel `zone_name` stored for per-profile data-zone journal entries
  /// (issue #1090, "Option B"). A per-profile DB only ever holds that one
  /// profile's data-zone deletions, so the real zone (`profile-<id>`) is
  /// implicit in which DB the entry lives in; the repos store this sentinel
  /// and the coordinator resolves the real zone at replay from the DB's
  /// `profileId`. The leading `@` can never collide with a real CloudKit zone
  /// name (`profile-index` / `profile-<uuid>`). The `(zone_name, record_name)`
  /// PK still holds because `record_name` is unique within one profile's DB.
  static let profileDataSentinelZone = "@profile-data"

  /// Records a deletion intent inside the caller's active write transaction.
  /// MUST be called in the SAME `database.write` that deletes the local row,
  /// so a crash can never land the row-delete without the intent.
  static func record(
    zoneName: String,
    recordName: String,
    recordType: String,
    at date: Date,
    in database: Database
  ) throws {
    try DeletionJournalRow(
      zoneName: zoneName,
      recordName: recordName,
      recordType: recordType,
      queuedAt: date.timeIntervalSince1970
    ).insert(database)
  }

  /// Clears the intent for `(zoneName, recordName)` inside the caller's write
  /// transaction. MUST be called in the SAME `database.write` that (re-)creates
  /// the row, so a re-created record drops its own stale deletion intent before
  /// any replay can fire (D1-b). Idempotent — clearing an absent entry is a
  /// no-op.
  static func clear(
    zoneName: String, recordName: String, in database: Database
  ) throws {
    _ =
      try DeletionJournalRow
      .filter(
        DeletionJournalRow.Columns.zoneName == zoneName
          && DeletionJournalRow.Columns.recordName == recordName
      )
      .deleteAll(database)
  }

  /// Records a per-profile DATA-zone deletion intent under the sentinel zone
  /// (Option B), in the caller's active write transaction. The owning DB holds
  /// exactly one profile's data, so the coordinator resolves the real
  /// `profile-<id>` zone at replay; the repos never need their profileId here.
  static func recordDataDeletion(
    recordName: String, recordType: String, at date: Date, in database: Database
  ) throws {
    try record(
      zoneName: profileDataSentinelZone,
      recordName: recordName,
      recordType: recordType,
      at: date,
      in: database)
  }

  /// Clears a per-profile DATA-zone deletion intent (sentinel zone) in the
  /// caller's write transaction — the D1-b drop a (re-)created data row makes
  /// so a start-time replay can't delete the live record. Idempotent.
  static func clearDataDeletion(
    recordName: String, in database: Database
  ) throws {
    try clear(
      zoneName: profileDataSentinelZone, recordName: recordName, in: database)
  }

  /// Every recorded intent in this database, oldest first.
  static func allEntries(in database: Database) throws -> [DeletionJournalRow] {
    try DeletionJournalRow
      .order(DeletionJournalRow.Columns.queuedAt)
      .fetchAll(database)
  }

  /// Clears the intents for the given `(zoneName, recordName)` pairs (e.g. after
  /// their `.deleteRecord` was confirmed sent). Idempotent.
  static func clear(
    _ keys: [(zoneName: String, recordName: String)], in database: Database
  ) throws {
    for key in keys {
      try clear(zoneName: key.zoneName, recordName: key.recordName, in: database)
    }
  }
}
