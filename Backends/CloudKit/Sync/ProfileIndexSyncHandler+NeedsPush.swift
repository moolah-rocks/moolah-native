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
  /// `freshSaved` is the original `[CKRecord]` batch after the #1079
  /// pending-echo partition; the dirty echoes' system-fields blob is
  /// sourced from it so the cached change tag advances.
  func applyProfilesGuarded(
    profileRows: [ProfileRow],
    deletedProfileIds: [UUID],
    freshSaved: [CKRecord]
  ) throws {
    try repository.database.write { database in
      let profileIds = profileRows.map(\.id)
      let dirty = try repository.dirtyIdsSync(from: profileIds, in: database)
      let clean = profileRows.filter { !dirty.contains($0.id) }
      try repository.applyRemoteChangesSync(
        saved: clean, deleted: deletedProfileIds, in: database)
      let echoes = freshSaved.compactMap { record -> (id: UUID, data: Data?)? in
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
}
