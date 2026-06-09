@preconcurrency import CloudKit
import Foundation

// Queue-all-existing and local-data-deletion helpers for the
// profile-index zone, split out of `ProfileIndexSyncHandler.swift` so
// each file keeps a single focus (and stays under the file-length
// ceiling). See `ProfileIndexSyncHandler+Instruments.swift` for the
// record-type partitioning, and `ProfileIndexSyncHandler.swift` for the
// apply / system-fields paths.
extension ProfileIndexSyncHandler {
  // MARK: - Queue All Existing Records

  /// Scans every `ProfileRow` and (when wired) every `InstrumentRow`
  /// in the local store and returns their CKRecord.IDs. Called on
  /// first start when there's no saved sync state, and from the
  /// startup self-heal path that re-queues rows whose
  /// `encoded_system_fields` is NULL.
  ///
  /// SYNC_GUIDE Rule 14 (queue dependency order): the two record
  /// types in this zone have no inter-record dependencies — a
  /// `ProfileRow` does not reference an `InstrumentRow` and vice
  /// versa. The combined list is therefore returned in
  /// profile-then-instrument order purely for log readability; the
  /// merge queue and CKSyncEngine treat the order as immaterial.
  func queueAllExistingRecords() -> [CKRecord.ID] {
    let profileRecordIDs = collectProfileRecordIDs()
    let instrumentRecordIDs = collectInstrumentRecordIDs()
    let combined = profileRecordIDs + instrumentRecordIDs
    if !combined.isEmpty {
      logger.info(
        "Collected \(profileRecordIDs.count) profile + \(instrumentRecordIDs.count) instrument records for upload"
      )
    }
    return combined
  }

  private func collectProfileRecordIDs() -> [CKRecord.ID] {
    do {
      let ids = try repository.allRowIdsSync()
      return ids.map { id in
        CKRecord.ID(
          recordType: ProfileRow.recordType, uuid: id, zoneID: zoneID)
      }
    } catch {
      logger.error(
        "queueAllExistingRecords: failed to fetch profile row ids: \(error, privacy: .public)"
      )
      return []
    }
  }

  private func collectInstrumentRecordIDs() -> [CKRecord.ID] {
    guard let instrumentRepository else { return [] }
    do {
      let ids = try instrumentRepository.allRowIdsSync()
      return ids.map { id in
        CKRecord.ID(recordName: id, zoneID: zoneID)
      }
    } catch {
      logger.error(
        "queueAllExistingRecords: failed to fetch instrument row ids: \(error, privacy: .public)"
      )
      return []
    }
  }

  // MARK: - Local Data Deletion

  /// Deletes all local profile-index data — `profile`, `instrument`,
  /// and the six rate-cache tables — atomically. Called on account
  /// sign-out, account switch, zone deletion, and zone purge.
  ///
  /// Atomicity rationale: a process kill mid-wipe would otherwise
  /// leave price-cache rows that reference instruments now gone, or
  /// profiles whose instruments survived. Sign-out semantics demand
  /// "the DB is empty"; partial wipes are not safe.
  func deleteLocalData() {
    do {
      try repository.deleteAllProfileIndexDataSync()
      logger.info("Deleted all profile-index data")
    } catch {
      logger.error("Failed to delete profile-index data: \(error, privacy: .public)")
    }
  }
}
