// Backends/CloudKit/Sync/ProfileIndexSyncHandler+Instruments.swift

@preconcurrency import CloudKit
import Foundation
import OSLog

/// Instrument-specific helpers for the profile-index zone: the
/// partitioning, build, and conflict-merge shapes for instrument records.
extension ProfileIndexSyncHandler {

  /// Partitions the fetched batch into `(profileRows, instrumentRows)`.
  /// Records of unknown types are logged and dropped.
  static func partitionSaved(
    _ saved: [CKRecord], logger: Logger
  ) -> (profileRows: [ProfileRow], instrumentRows: [InstrumentRow]) {
    var profileRows: [ProfileRow] = []
    var instrumentRows: [InstrumentRow] = []
    for record in saved {
      switch record.recordType {
      case ProfileRow.recordType:
        guard var values = ProfileRow.fieldValues(from: record) else {
          logger.error(
            "applyRemoteChanges: malformed ProfileRow recordID '\(record.recordID.recordName)' — skipping"
          )
          continue
        }
        values.encodedSystemFields = record.encodedSystemFields
        profileRows.append(values)
      case InstrumentRow.recordType:
        guard var values = InstrumentRow.fieldValues(from: record) else {
          logger.error(
            "applyRemoteChanges: malformed InstrumentRow recordID '\(record.recordID.recordName)' — skipping"
          )
          continue
        }
        values.encodedSystemFields = record.encodedSystemFields
        instrumentRows.append(values)
      default:
        logger.error(
          "applyRemoteChanges: unexpected recordType '\(record.recordType, privacy: .public)' on profile-index zone — skipping"
        )
      }
    }
    return (profileRows, instrumentRows)
  }

  /// Partitions deleted record IDs into `(profileIds, instrumentIds)`
  /// by record-name shape. The two recognised shapes on the
  /// profile-index zone are `<ProfileRow.recordType>|<UUID>` (profile
  /// tombstones) and a bare string id (instrument tombstones; see
  /// `InstrumentRow+CloudKit.swift` — instruments use the bare-id
  /// recordName form on purpose). Anything else (an unknown prefixed
  /// record type, or a bare-UUID profile tombstone from a peer on a
  /// build without the prefix) is dropped with a logged warning so a
  /// future record type added to this zone can't silently misroute
  /// into the instrument bucket.
  static func partitionDeleted(
    _ deleted: [CKRecord.ID], logger: Logger
  ) -> (profileIds: [UUID], instrumentIds: [String]) {
    var profileIds: [UUID] = []
    var instrumentIds: [String] = []
    for recordID in deleted {
      switch recordID.prefixedRecordType {
      case ProfileRow.recordType:
        // `<ProfileRow>|<UUID>` form — UUID component must parse.
        if let profileId = recordID.uuid {
          profileIds.append(profileId)
        } else {
          logger.error(
            """
            partitionDeleted: ProfileRow tombstone with unparseable UUID \
            component '\(recordID.recordName, privacy: .public)' — skipping.
            """
          )
        }
      case nil:
        // No `|` separator — bare-string instrument id.
        instrumentIds.append(recordID.recordName)
      case let other?:
        logger.error(
          """
          partitionDeleted: unexpected prefixed recordType '\(other, privacy: .public)' \
          on profile-index zone deletion '\(recordID.recordName, privacy: .public)' — skipping.
          """
        )
      }
    }
    return (profileIds, instrumentIds)
  }

  /// Looks up an `InstrumentRow` by string-keyed `recordID` and builds
  /// a CKRecord for upload, as a tri-state (issue #1087): `.found` on a hit,
  /// `.absent` when the query succeeds but the row is gone (safe to drop the
  /// stale save + queue a deletion), `.failed` when no registry is wired or
  /// the fetch throws (keep pending — never delete a possibly-live record).
  func instrumentRecordToSave(for recordID: CKRecord.ID) -> RecordLookupOutcome {
    guard let instrumentRepository else { return .failed }
    do {
      guard
        let row = try instrumentRepository.fetchRowSync(id: recordID.recordName)
      else { return .absent }
      return .found(buildCKRecord(for: row))
    } catch {
      logger.error(
        "recordToSave: failed to fetch instrument row '\(recordID.recordName, privacy: .public)': \(error, privacy: .public) — keeping pending"
      )
      return .failed
    }
  }

  /// Builds a CKRecord from a local `InstrumentRow` for upload. Same
  /// cached-system-fields shape as the `ProfileRow` builder.
  private func buildCKRecord(for row: InstrumentRow) -> CKRecord {
    let freshRecord = row.toCKRecord(in: zoneID)
    if let cachedData = row.encodedSystemFields,
      let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData),
      cachedRecord.recordID.zoneID == zoneID
    {
      for key in freshRecord.allKeys() {
        cachedRecord[key] = freshRecord[key]
      }
      return cachedRecord
    }
    return freshRecord
  }

  /// Returns CKRecord.IDs for every shared `instrument` row whose
  /// `encoded_system_fields` is `NULL`. Used by the coordinator's
  /// startup self-heal scan: rows that didn't sync-roundtrip (because
  /// the union runner committed but CKSyncEngine state never
  /// persisted, or because a registry mutation fired its hook before
  /// the engine was ready) get re-queued on the next launch.
  ///
  /// Returns an empty list when no `instrumentRepository` is wired —
  /// no shared registry to scan.
  func queueUnsyncedSharedInstrumentRecords() -> [CKRecord.ID] {
    guard let instrumentRepository else { return [] }
    do {
      let ids = try instrumentRepository.unsyncedNonFiatRowIdsSync()
      return ids.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
    } catch {
      logger.error(
        "queueUnsyncedSharedInstrumentRecords: failed: \(error, privacy: .public)"
      )
      return []
    }
  }

  /// Applies the spam-wins conflict merge for `InstrumentRecord`
  /// when CKSyncEngine reports `.serverRecordChanged`. The merge
  /// rule is the same one the downlink path runs in
  /// `GRDBInstrumentRegistryRepository.applyRemoteChangesSync` —
  /// `PricingStatusMerge.merge(local:incoming:)` resolves
  /// `pricingStatus` to spam if either side has it; other fields
  /// follow plain newest-wins via the upsert.
  ///
  /// The retry upload (driven by the coordinator's existing
  /// `SyncErrorRecovery.requeueFailures` path) re-queues the local
  /// row, which now carries the merged `pricingStatus`.
  func applyInstrumentServerRecordChangedMerge(serverRecord: CKRecord) {
    guard let instrumentRepository else { return }
    guard var values = InstrumentRow.fieldValues(from: serverRecord) else {
      logger.error(
        "applyInstrumentServerRecordChangedMerge: malformed serverRecord '\(serverRecord.recordID.recordName)' — skipping"
      )
      return
    }
    values.encodedSystemFields = serverRecord.encodedSystemFields
    do {
      try instrumentRepository.applyRemoteChangesSync(
        saved: [values], deleted: [])
    } catch {
      logger.error(
        "applyInstrumentServerRecordChangedMerge: \(error, privacy: .public)")
    }
  }
}
