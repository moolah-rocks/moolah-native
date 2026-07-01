// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+SyncEntryPoints.swift

import Foundation
import GRDB

/// Synchronous entry points consumed by `ProfileIndexSyncHandler` and
/// the coordinator's startup self-heal scan.
///
/// These methods are called from the CKSyncEngine delegate executor
/// on a non-MainActor context. `DatabaseWriter.write { db in … }` has
/// both async and sync overloads; the sync form blocks the calling
/// thread until the queue's serial executor admits the closure. Never
/// call any of these from `@MainActor`.
extension GRDBInstrumentRegistryRepository {

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: String, data: Data?) throws -> Bool {
    let updated = try database.write { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == id)
        .updateAll(database, [InstrumentRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
    // System-fields-only writes don't change the domain `Instrument`,
    // but a blanket invalidate-on-any-write keeps the staleness
    // invariant simple and provably correct — the cost is one extra
    // rebuild, never stale data.
    invalidateInstrumentMapCache()
    return updated
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try InstrumentRow
        .updateAll(
          database,
          [InstrumentRow.Columns.encodedSystemFields.set(to: nil)])
    }
    invalidateInstrumentMapCache()
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [String] {
    try database.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.encodedSystemFields == nil)
        .select(InstrumentRow.Columns.id, as: String.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [String] {
    try database.read { database in
      try InstrumentRow
        .select(InstrumentRow.Columns.id, as: String.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path
  /// in the sync handler.
  func fetchRowSync(id: String) throws -> InstrumentRow? {
    try database.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [String]) throws -> [InstrumentRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try InstrumentRow
        .filter(idSet.contains(InstrumentRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after
  /// a remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try InstrumentRow.deleteAll(database)
    }
    invalidateInstrumentMapCache()
  }

  /// Applies a CKSyncEngine remote-change batch in one transaction: every saved
  /// row is upserted with the `PricingStatusMerge` CRDT applied (and the
  /// issue-#1085 stale-echo date gate) and any stale local deletion intent
  /// cleared (D1-b, issue #1097); every deleted id is removed WITHOUT journaling
  /// — server-originated deletes are already propagated by CKSyncEngine. Where
  /// a `canonicalResolver` is wired, incoming retired cross-chain ids (e.g.
  /// `10:native`) have `alias_of` set to the canonical id via raw SQL on BOTH
  /// the fresh-insert path (after upsert) and the stale-echo path
  /// (before the early `continue`) so a retired row is never left unaliased. If
  /// any statement throws, the whole batch rolls back so prior on-disk state
  /// survives byte-equal, per `guides/DATABASE_CODE_GUIDE.md` §5.
  func applyRemoteChangesSync(saved rows: [InstrumentRow], deleted ids: [String]) throws {
    try database.write { database in
      for var row in rows {
        let existing =
          try InstrumentRow
          .filter(InstrumentRow.Columns.id == row.id)
          .fetchOne(database)

        // Apply the field-level merge rule for `pricingStatus` before
        // upserting. CKSyncEngine's default "server wins" would let
        // the daily auto-resolver on one device clobber a `.spam`
        // classification a user made on another. The rule is
        // centralised in `PricingStatusMerge.merge` and unit-tested
        // against the full 3x3 truth table.
        //
        // Unrecognised raw values (only possible from a future-version
        // device sending an enum case this build doesn't compile against,
        // since legacy records that omit the field decode as `"priced"`
        // in `InstrumentRow+CloudKit.swift`) decode as `.priced`. That
        // matches the legacy fallback and keeps the merge defensive
        // rather than throwing.
        let mergedStatus = Self.mergedPricingStatus(local: existing, incoming: row)

        // Resolve the incoming id to its canonical id.
        // `nil` when no resolver is wired (most construction sites) or
        // when the id is already canonical — no alias write in either case.
        let aliasTarget = canonicalAlias(for: row.id)

        // Modification-date gate on identity / provider-mapping fields and
        // the cached system-fields blob (issue #1085). Instruments have no
        // `needs_push`; the date gate piggybacks on the `fetchOne` above.
        // A stale echo (incoming date older-or-equal to the existing row's
        // cached date) must NOT revert the identity/mapping fields — but
        // `pricingStatus` is EXEMPT: it always flows through
        // `PricingStatusMerge` regardless of date, because that merge is a
        // deliberately recency-independent CRDT (sticky `.spam`) and gating
        // it wholesale could leave two devices divergent. So a stale echo
        // writes only the merged `pricingStatus` (and only when it changed,
        // to skip a no-op write), leaving identity / mapping / blob put.
        if let existing, Self.isStaleInstrumentEcho(existing: existing, incoming: row) {
          if mergedStatus != existing.pricingStatus {
            _ =
              try InstrumentRow
              .filter(InstrumentRow.Columns.id == row.id)
              .updateAll(
                database, [InstrumentRow.Columns.pricingStatus.set(to: mergedStatus)])
          }
          // Alias even on the stale-echo path: the row already exists but
          // may have arrived before the alias feature shipped, leaving
          // `alias_of` NULL. Write it here — BEFORE the `continue` — so a
          // retired row is never left unaliased and visible. Idempotent.
          if let aliasTarget {
            try Self.setAliasOf(row.id, to: aliasTarget, in: database)
          }
          continue
        }

        row.pricingStatus = mergedStatus
        try row.upsert(database)
        // D1-b (issue #1097): a peer re-creating this instrument clears our
        // stale deletion intent too, so we don't re-delete a record the server
        // now holds. Apply-path deletions below are NOT journaled —
        // server-originated deletions are already propagated.
        try Self.clearDeletionIntent(for: row.id, in: database)
        // Alias AFTER the upsert so the row exists on a fresh insert.
        // On the update path (existing row) ordering relative to upsert
        // is immaterial — the row already exists and the UPDATE is idempotent.
        if let aliasTarget {
          try Self.setAliasOf(row.id, to: aliasTarget, in: database)
        }
      }
      for id in ids {
        _ = try InstrumentRow.deleteOne(database, key: id)
      }
    }
    // Remote pulls mutate rows just like local writes; the memoised
    // map must be rebuilt before the next reader (e.g. a price-cache
    // resolution) observes it.
    invalidateInstrumentMapCache()
  }

  /// Returns the canonical alias target for `id` when `canonicalResolver`
  /// is wired and `id` is a retired cross-chain instrument, or `nil`
  /// otherwise (no resolver, or `id` is already canonical). Used to keep
  /// the `applyRemoteChangesSync` write closure under the SwiftLint
  /// `closure_body_length` budget.
  private func canonicalAlias(for id: String) -> String? {
    guard let resolver = canonicalResolver else { return nil }
    let canonical = resolver.canonicalId(for: id)
    return canonical == id ? nil : canonical
  }

  /// Marks a retired instrument row as an alias of its canonical id.
  /// `alias_of` is a local-only column (not in `InstrumentRow.CodingKeys`),
  /// written exclusively via raw SQL so no Codable upsert can clobber it.
  /// The `id`/`recordName` and `encodedSystemFields` are never touched.
  /// Idempotent — writing the same `alias_of` value twice is a no-op.
  /// Uses `cachedStatement` per `DATABASE_CODE_GUIDE.md` §8: the statement
  /// is prepared once per `Database` connection and reused across loop iterations.
  private static func setAliasOf(
    _ id: String, to canonical: String, in database: Database
  ) throws {
    let statement = try database.cachedStatement(
      sql: "UPDATE instrument SET alias_of = ? WHERE id = ?")
    try statement.execute(arguments: [canonical, id])
  }

  /// Resolves the `pricingStatus` raw value to persist for an incoming
  /// instrument row, applying `PricingStatusMerge` against the existing
  /// local row's status (issue #1085 keeps this recency-independent, so it
  /// runs whether or not the date gate rejects the rest of the record).
  /// With no existing row the incoming status is taken as-is.
  private static func mergedPricingStatus(
    local existing: InstrumentRow?, incoming row: InstrumentRow
  ) -> String {
    guard let existing else { return row.pricingStatus }
    let local = TokenPricingStatus(rawValue: existing.pricingStatus) ?? .priced
    let incoming = TokenPricingStatus(rawValue: row.pricingStatus) ?? .priced
    return PricingStatusMerge.merge(local: local, incoming: incoming).rawValue
  }

  /// True when `row` is a superseded stale echo relative to `existing` —
  /// its server `modificationDate` is older-or-equal to the date the local
  /// row caches (reject-on-tie). Fail-open: if either date is
  /// absent (no cached blob, or a dateless incoming record) returns `false`
  /// so the incoming record applies, matching the gate's behaviour at the
  /// UUID-keyed sites.
  private static func isStaleInstrumentEcho(
    existing: InstrumentRow, incoming row: InstrumentRow
  ) -> Bool {
    guard
      let cached = existing.serverModificationDate,
      let incoming = row.serverModificationDate
    else { return false }
    return incoming <= cached
  }
}
