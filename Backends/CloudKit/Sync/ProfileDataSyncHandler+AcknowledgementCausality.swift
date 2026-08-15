@preconcurrency import CloudKit
import GRDB

extension ProfileDataSyncHandler {
  /// Acknowledgements and recovery callbacks may arrive out of order. Accept
  /// metadata only when it advances the cached server version, or repeats the
  /// exact same change tag. A missing local cache is the first-upload case and
  /// deliberately fails open; a missing incoming date cannot replace a dated
  /// cache.
  nonisolated static func serverMetadataIsCurrentOrNewer(
    _ incoming: CKRecord, than current: CKRecord
  ) -> Bool {
    if let incomingTag = incoming.recordChangeTag,
      let currentTag = current.recordChangeTag,
      incomingTag == currentTag
    {
      return true
    }
    guard let cachedDate = current.modificationDate else { return true }
    guard let incomingDate = incoming.modificationDate else { return false }
    return incomingDate > cachedDate
  }

  /// Conflict metadata is valid only for the exact local mutation that
  /// CloudKit rejected. A newer local edit has a different token; a fetched
  /// echo or later acknowledgement may also have advanced the cached server
  /// base while retaining the same token.
  nonisolated func applicableConflictMetadata(
    _ failures: SyncErrorRecovery.ClassifiedFailures, in database: Database
  ) throws -> [CKRecord] {
    try failures.conflicts.compactMap { conflict in
      guard let client = failures.failedClientRecords[conflict.recordID],
        let id = conflict.recordID.uuid,
        let current = try currentCKRecord(
          recordType: client.recordType, id: id, in: database),
        current.hasSameUserFields(as: client),
        current.recordChangeTag == client.recordChangeTag
      else { return nil }
      return conflict.serverRecord
    }
  }

  /// `unknownItem` clears a stale change tag only when the row is still the
  /// exact client version that failed. Otherwise a delayed failure could erase
  /// the newer base cached by a later acknowledgement.
  nonisolated func applicableUnknownItemClears(
    _ failures: SyncErrorRecovery.ClassifiedFailures, in database: Database
  ) throws -> [(recordID: CKRecord.ID, recordType: String)] {
    try failures.unknownItems.filter { item in
      guard let client = failures.failedClientRecords[item.recordID],
        let id = item.recordID.uuid,
        let current = try currentCKRecord(
          recordType: item.recordType, id: id, in: database)
      else { return false }
      return current.hasSameUserFields(as: client)
        && current.recordChangeTag == client.recordChangeTag
    }
  }
}
