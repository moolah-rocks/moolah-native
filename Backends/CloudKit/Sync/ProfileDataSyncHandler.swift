@preconcurrency import CloudKit
import Foundation
import OSLog
import os

/// Result of applying remote changes from CKSyncEngine.
enum ApplyResult: Sendable {
  /// Changes saved successfully. Contains the set of changed record types.
  case success(changedTypes: Set<String>)
  /// context.save() failed. The coordinator should schedule a re-fetch.
  case saveFailed(String)
}

/// Stateless batch processing logic for a single profile's data zone.
/// Contains all data transformation, upsert, deletion, and record-building
/// logic with no CKSyncEngine dependency.
///
/// The coordinator owns the CKSyncEngine instance and delegates data processing
/// to this handler. Methods return results (changed types, record IDs, failures)
/// instead of directly interacting with CKSyncEngine state.
///
/// Functionality is split across several `ProfileDataSyncHandler+*.swift`
/// extensions (applying remote changes, batch upserts, record lookup, queueing,
/// and system fields) so that each file keeps a single focus.
@MainActor
final class ProfileDataSyncHandler {
  nonisolated let profileId: UUID
  nonisolated let zoneID: CKRecordZone.ID
  /// GRDB-backed repos for the eight per-profile record types. Used by
  /// the dispatch tables in `+ApplyRemoteChanges`, `+QueueAndDelete`,
  /// `+RecordLookup`, and `+SystemFields` so each per-type save/delete
  /// handler can address the right repository without leaking GRDB
  /// types into the sync engine's wire layer.
  nonisolated let grdbRepositories: ProfileGRDBRepositories

  nonisolated let logger = Logger(
    subsystem: "com.moolah.app", category: "ProfileDataSyncHandler")

  /// Logger used by `nonisolated static` batch helpers that cannot reach `self.logger`.
  nonisolated static let batchLogger = Logger(
    subsystem: "com.moolah.app", category: "ProfileDataSyncHandler")

  init(
    profileId: UUID,
    zoneID: CKRecordZone.ID,
    grdbRepositories: ProfileGRDBRepositories
  ) {
    self.profileId = profileId
    self.zoneID = zoneID
    self.grdbRepositories = grdbRepositories
  }

  // MARK: - Building CKRecords

  /// Builds a `CKRecord` from a GRDB row for upload.
  ///
  /// If cached system fields exist for this row, applies fields
  /// directly onto the cached record to preserve the change tag and
  /// avoid `.serverRecordChanged` conflicts. If the cached system
  /// fields reference a *different* zone than this handler's own zone,
  /// they are discarded and the record is uploaded as a fresh create
  /// in the handler's zone — defence-in-depth against cross-zone
  /// system-fields corruption.
  /// `nonisolated` so the off-main fetched-changes apply path and the
  /// in-transaction ack-clear compare (issue #1081) can build the upload
  /// record without hopping to the main actor. Touches only the
  /// `nonisolated let zoneID`.
  nonisolated func buildCKRecord<T: CloudKitRecordConvertible>(
    from record: T, encodedSystemFields: Data?
  ) -> CKRecord {
    let freshRecord = record.toCKRecord(in: zoneID)
    if let cachedData = encodedSystemFields,
      let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData),
      cachedRecord.recordID.zoneID == zoneID,
      CKRecordIDRecordName.isUsableCachedRecordName(cachedRecord.recordID.recordName)
    {
      for key in freshRecord.allKeys() {
        cachedRecord[key] = freshRecord[key]
      }
      return cachedRecord
    }
    return freshRecord
  }

}
