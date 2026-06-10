@preconcurrency import CloudKit
import Foundation
import GRDB

// Clean-path modification-date gate (issue #1085). A clean row is fully
// round-tripped, so `needs_push` no longer protects it; the gate rejects any
// out-of-order echo whose server `modificationDate` is older-or-equal to the
// date the row already caches, closing the single-device revert window the
// dirty-path guard cannot reach.

/// Collapses same-id duplicates within one fetched batch to the
/// highest-`modificationDate` version (issue #1085). Cheap insurance for the
/// whole-row server-wins upsert sites, where keeping the newest version is
/// correct and a stray duplicate would otherwise land by array order. `id`
/// and `date` are closures because the batch element may be a `CKRecord`
/// (whose uuid is optional and not expressible as `Identifiable`) or a typed
/// row. Elements with no id and the common no-duplicate batch pass through
/// untouched. A nil date sorts as oldest, so a dated version always beats a
/// dateless one.
///
/// Assumption: one fetch event coalesces to at most one version per record,
/// so this only ever guards against a defensive edge case.
func dedupToMaxModificationDate<Element>(
  _ items: [Element], id: (Element) -> UUID?, date: (Element) -> Date?
) -> [Element] {
  var newestByID: [UUID: Element] = [:]
  var hasDuplicate = false
  for item in items {
    guard let key = id(item) else { continue }
    if let existing = newestByID[key] {
      hasDuplicate = true
      if (date(item) ?? .distantPast) > (date(existing) ?? .distantPast) {
        newestByID[key] = item
      }
    } else {
      newestByID[key] = item
    }
  }
  guard hasDuplicate else { return items }
  // Rebuild preserving first-seen order, substituting the chosen version.
  var seen: Set<UUID> = []
  var result: [Element] = []
  for item in items {
    guard let key = id(item) else {
      result.append(item)
      continue
    }
    guard seen.insert(key).inserted else { continue }
    result.append(newestByID[key] ?? item)
  }
  return result
}

extension ProfileDataSyncHandler {
  /// Applies the modification-date gate to the clean subset of one
  /// record-type group: dedups same-id duplicates to the newest version then
  /// drops any echo not strictly newer than the version the local row already
  /// caches. Reads each clean row's cached `modificationDate` inside the
  /// active write `database`, so the gate decision and the upsert share one
  /// transaction. Fail-open: a row with no cached date (first sync) or an
  /// echo with no date applies.
  nonisolated func applicableCleanSaves(
    recordType: String, clean: [CKRecord], in database: Database
  ) throws -> [CKRecord] {
    guard !clean.isEmpty else { return clean }
    let deduped = dedupToMaxModificationDate(
      clean, id: { $0.recordID.uuid }, date: { $0.modificationDate })
    let cleanIds = deduped.compactMap { $0.recordID.uuid }
    let cachedDates = try cachedModificationDates(
      recordType: recordType, ids: cleanIds, in: database)
    return Self.applicableAfterDateGate(deduped, cachedDates: cachedDates)
  }

  /// Filters the clean records by the modification-date gate, returning only
  /// the applicable ones. A record is applied when the row has no cached
  /// date (`nil` → fail-open, first sync), the incoming record has no date
  /// (`nil` → fail-open, unreachable in production), or the incoming date is
  /// strictly newer than the cached date. An older-or-equal date is a
  /// superseded stale echo and is rejected (reject-on-tie).
  nonisolated static func applicableAfterDateGate(
    _ clean: [CKRecord], cachedDates: [UUID: Date]
  ) -> [CKRecord] {
    clean.filter { record in
      guard
        let uuid = record.recordID.uuid,
        let cached = cachedDates[uuid],
        let incoming = record.modificationDate
      else { return true }
      return incoming > cached
    }
  }
}
