@preconcurrency import CloudKit
import Foundation

// MARK: - needs_push conditional clear (issue #1081)
//
// Split out of `ProfileIndexSyncHandler.swift` to keep the main file
// under the 400-line limit (it is already split into +Lifecycle and
// +Instruments). Mirrors the per-profile path's conditional clear in
// `ProfileDataSyncHandler+SystemFields.swift`.

extension ProfileIndexSyncHandler {
  /// Applies the profile leg of a fetched batch in ONE transaction: the
  /// dirty check, the clean-row upsert, and the dirty-row system-fields
  /// write all share a single `repository.database.write` so an in-flight
  /// profile rename can never be clobbered by a fetched echo (issue
  /// #1081 — no main-actor snapshot gap, no accepted residual). A dirty
  /// profile row skips its field-value upsert and takes its change tag
  /// only; a clean one upserts normally. The instrument leg is applied
  /// separately by the caller (separate shared-registry database).
  ///
  /// `saved` is the original fetched `[CKRecord]` batch; the dirty
  /// echoes' system-fields blob is sourced from it so the cached change
  /// tag advances even though their field values are not written.
  func applyProfilesGuarded(
    profileRows: [ProfileRow],
    deletedProfileIds: [UUID],
    saved: [CKRecord]
  ) throws {
    try repository.database.write { database in
      let profileIds = profileRows.map(\.id)
      let dirty = try repository.dirtyIdsSync(from: profileIds, in: database)
      let clean = profileRows.filter { !dirty.contains($0.id) }
      try repository.applyRemoteChangesSync(
        saved: clean, deleted: deletedProfileIds, in: database)
      let echoes = saved.compactMap { record -> (id: UUID, data: Data?)? in
        guard let uuid = record.recordID.uuid, dirty.contains(uuid),
          record.recordType == ProfileRow.recordType
        else { return nil }
        return (uuid, record.encodedSystemFields)
      }
      if !echoes.isEmpty {
        try repository.setEncodedSystemFieldsBatchSync(echoes, in: database)
      }
    }
  }

  /// Clears `needs_push` for each saved profile record whose current
  /// local row still matches the uploaded version. If the row changed
  /// since the send (a newer edit), the flag stays set — CKSyncEngine
  /// has already re-queued that edit, and its own later ack clears the
  /// flag. Instrument-typed saved records are ignored (shared registry).
  ///
  /// **Atomicity (issue #1081).** The current-row read, the user-field
  /// compare, and the conditional clear all share ONE
  /// `repository.database.write` transaction, so no concurrent profile
  /// rename can commit (and re-raise `needs_push`) between the compare and
  /// the clear — the prior read-then-separate-write shape had a TOCTOU
  /// window where such an interleaving could clear the flag over a newer
  /// rename, losing its protection.
  func clearNeedsPushForConfirmed(_ savedRecords: [CKRecord]) {
    do {
      try repository.database.write { database in
        var confirmed: [UUID] = []
        for saved in savedRecords where saved.recordType == ProfileRow.recordType {
          guard let profileId = saved.recordID.uuid else { continue }
          // Re-read the CURRENT row inside this transaction and compare.
          guard let current = try self.repository.fetchRowSync(id: profileId, in: database)
          else { continue }
          if self.buildCKRecord(for: current).hasSameUserFields(as: saved) {
            confirmed.append(profileId)
          }
        }
        // Clear in the SAME transaction so no rename interleaves between
        // the compare above and the clear below.
        _ = try self.repository.clearNeedsPushBatchSync(confirmed, in: database)
      }
    } catch {
      logger.error(
        "clearNeedsPushForConfirmed: failed: \(error, privacy: .public)")
    }
  }
}
