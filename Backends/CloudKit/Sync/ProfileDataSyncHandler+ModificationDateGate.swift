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
    warnOnExistingRowsWithNilCache(
      recordType: recordType, ids: cleanIds, cachedDates: cachedDates, in: database)
    return Self.applicableAfterDateGate(deduped, cachedDates: cachedDates)
  }

  /// Regression tripwire (issue #1090). Logs loudly when a CLEAN incoming
  /// record's local row EXISTS but caches no `modificationDate` — i.e. some
  /// write nulled the row's `encoded_system_fields`. That is the exact state
  /// in which the gate's deliberate nil-cache fail-open lets a stale self-echo
  /// clobber the row. The record still applies (fail-open is preserved — it is
  /// required so a genuine first-time peer record inserts); this only surfaces
  /// the condition so any future cache-nulling write path is caught at runtime.
  ///
  /// The explicit row-exists guard (`currentCKRecord` returning non-nil) is
  /// what keeps it from firing on a normal new-record insert, whose row does
  /// not yet exist locally. A read failure is logged and the check is skipped
  /// rather than propagated, so a database error never interrupts the apply.
  nonisolated func warnOnExistingRowsWithNilCache(
    recordType: String, ids: [UUID], cachedDates: [UUID: Date], in database: Database
  ) {
    let suspect: [UUID]
    do {
      suspect = try existingRowsWithNilCache(
        recordType: recordType, ids: ids, cachedDates: cachedDates, in: database)
    } catch {
      logger.error(
        """
        clean-apply tripwire: existence check failed for \
        \(recordType, privacy: .public): \(error.localizedDescription, privacy: .public)
        """)
      return
    }
    for id in suspect {
      logger.error(
        """
        clean-apply tripwire: existing \(recordType, privacy: .public) row \
        \(id.uuidString, privacy: .public) has a nil cached system-fields blob — \
        a write nulled the cache; a stale echo could clobber it (issue #1090)
        """)
    }
  }

  /// The `ids` whose local row EXISTS yet carries no cached `modificationDate`
  /// (the nil-cache regression). An id with no local row — a genuine new
  /// record — is excluded. Pure (no logging) so it can be asserted directly.
  ///
  /// Existence is tested via `currentCKRecord` rather than `cachedSystemFields`:
  /// the latter is built with optional chaining (`fetchRowSync(...)?.encoded…`),
  /// which collapses "row absent" and "row present with a nil blob" into the
  /// same value — so its outer optional cannot tell them apart.
  /// `currentCKRecord` returns `nil` only for a genuinely missing row.
  nonisolated func existingRowsWithNilCache(
    recordType: String, ids: [UUID], cachedDates: [UUID: Date], in database: Database
  ) throws -> [UUID] {
    var suspect: [UUID] = []
    for id in ids where cachedDates[id] == nil {
      if try currentCKRecord(recordType: recordType, id: id, in: database) != nil {
        suspect.append(id)
      }
    }
    return suspect
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
