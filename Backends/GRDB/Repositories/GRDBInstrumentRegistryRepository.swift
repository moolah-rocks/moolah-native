// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository.swift

import Foundation
import GRDB
import OSLog
import os

/// GRDB-backed implementation of `InstrumentRegistryRepository`. Replaces
/// the SwiftData-backed `CloudKitInstrumentRegistryRepository` for the
/// `instrument` table.
///
/// `Instrument` is the only synced row that uses an arbitrary string ID
/// (e.g. `"AUD"`, `"ASX:BHP"`, `"1:0xa0b8…"`) instead of a UUID, so the
/// hook closures and sync entry points are string-keyed rather than
/// UUID-keyed. The repo also exposes a `MainActor`-isolated
/// `observeChanges()` AsyncStream so picker UIs can refresh after local
/// mutations, and a non-protocol `notifyExternalChange()` method that the
/// sync layer calls when remote pulls touch instrument rows.
///
/// **`@unchecked Sendable` justification.** Has three mutable stored
/// properties: `subscribers` (the `@MainActor`-confined
/// AsyncStream-continuation map driving `observeChanges()`),
/// `hooks` (the lock-guarded `HookState` swapped in by
/// `attachSyncHooks`), and `mapCache` (the lock-guarded
/// `MapCacheState` memoising the instrument-map snapshot; see
/// `GRDBInstrumentRegistryRepository+InstrumentMapResolving.swift`).
/// All three are race-free at runtime — see
/// `guides/CONCURRENCY_GUIDE.md` §2 "False Positives to Avoid",
/// Carve-out 3 (GRDB repositories).
final class GRDBInstrumentRegistryRepository:
  InstrumentRegistryRepository, @unchecked Sendable
{
  // `database` is `internal` rather than `private` so the sibling
  // extension file `GRDBInstrumentRegistryRepository+Lookup.swift`
  // (which hosts `cryptoRegistration(byId:)`) can read from it. The
  // other stored properties remain private — only the database handle
  // is shared across files.
  /// Holds the post-init hook closures so they can be swapped in
  /// atomically by `attachSyncHooks`. Mirrors the pattern used by
  /// `GRDBProfileIndexRepository` — the shared registry is constructed
  /// at app boot before the `SyncCoordinator` exists, so the hooks
  /// arrive later via the lock-guarded swap.
  ///
  /// `internal` (default) so the sibling `+SyncHooks` extension file
  /// can declare `attachSyncHooks` over it.
  struct HookState {
    var onRecordChanged: @Sendable (String) -> Void
    var onRecordDeleted: @Sendable (String) -> Void
  }

  let database: any DatabaseWriter
  // `internal` (default) so the sibling `+SyncHooks` extension file
  // can read / mutate the lock-guarded hook closures. The lock itself
  // is the threading primitive; the property's visibility is module-
  // scoped because Swift extensions in separate files don't share
  // `private` access.
  let hooks: OSAllocatedUnfairLock<HookState>

  /// Lock-guarded memoised instrument-map snapshot. The
  /// `MapCacheState` type and the invalidation / test-accessor helpers
  /// live in the sibling `+SyncHooks` extension file; only the stored
  /// property itself must be declared in the class body. Guarded by
  /// the same `OSAllocatedUnfairLock` primitive the
  /// type already uses for `hooks` — deliberately not a second,
  /// divergent synchronisation mechanism. `internal` (default) so the
  /// sibling `+InstrumentMapResolving` / `+SyncEntryPoints` extensions
  /// can read and invalidate it.
  let mapCache = OSAllocatedUnfairLock(
    initialState: MapCacheState(
      snapshot: [:], isValid: false, generation: 0, dbReadCount: 0))
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "InstrumentRegistry")

  @MainActor private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

  /// - Parameters:
  ///   - onRecordChanged: Invoked from whatever task context completes
  ///     the GRDB write — do not assume `@MainActor`. Typically used to
  ///     queue CKSyncEngine saves, which are themselves thread-safe.
  ///   - onRecordDeleted: Invoked from whatever task context completes
  ///     the GRDB write — do not assume `@MainActor`. Typically used to
  ///     queue CKSyncEngine deletes, which are themselves thread-safe.
  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (String) -> Void = { _ in },
    onRecordDeleted: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.database = database
    self.hooks = OSAllocatedUnfairLock(
      initialState: HookState(
        onRecordChanged: onRecordChanged,
        onRecordDeleted: onRecordDeleted))
  }

  // MARK: - Cross-extension internals
  //
  // `attachSyncHooks` and the `fireOnRecord*` helpers live in
  // `GRDBInstrumentRegistryRepository+SyncHooks.swift`, and the row-level
  // upsert helpers (`upsertCrypto`, `upsertStock`) live in
  // `GRDBInstrumentRegistryRepository+Upsert.swift`. They access `hooks`
  // / are called as `Self.upsert…` via the `internal` visibility implied
  // by Swift's same-module-extension scope.

  // MARK: - InstrumentRegistryRepository conformance

  func all() async throws -> [Instrument] {
    let stored = try await database.read { database in
      try InstrumentRow.fetchAll(database).map { try $0.toDomain() }
    }
    let storedIds = Set(stored.map(\.id))
    let ambient =
      Locale.Currency.isoCurrencies
      .map(\.identifier)
      .map { Instrument.fiat(code: $0) }
      .filter { !storedIds.contains($0.id) }
    return stored + ambient
  }

  func allCryptoRegistrations() async throws -> [CryptoRegistration] {
    try await database.read { database in
      let cryptoKind = Instrument.Kind.cryptoToken.rawValue
      let rows =
        try InstrumentRow
        .filter(InstrumentRow.Columns.kind == cryptoKind)
        .fetchAll(database)
      return try rows.compactMap { row in try Self.project(row: row) }
    }
  }

  // `cryptoRegistration(byId:)` lives in
  // `GRDBInstrumentRegistryRepository+Lookup.swift`.

  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws {
    precondition(instrument.kind == .cryptoToken)
    try await database.write { database in
      try Self.upsertCrypto(
        database: database, instrument: instrument, mapping: mapping)
    }
    invalidateInstrumentMapCache()
    fireOnRecordChanged(instrument.id)
    await notifySubscribers()
  }

  /// Single-write overload. See
  /// `InstrumentRegistryRepository.registerCrypto(_:mapping:forcingStatus:)`
  /// for the contract (one transaction, one `onRecordChanged`, issue #895).
  func registerCrypto(
    _ instrument: Instrument,
    mapping: CryptoProviderMapping,
    forcingStatus status: TokenPricingStatus
  ) async throws {
    precondition(instrument.kind == .cryptoToken)
    try await database.write { database in
      try Self.upsertCrypto(
        database: database,
        instrument: instrument,
        mapping: mapping,
        forcingStatus: status)
    }
    invalidateInstrumentMapCache()
    fireOnRecordChanged(instrument.id)
    await notifySubscribers()
  }

  func registerStock(_ instrument: Instrument) async throws {
    precondition(instrument.kind == .stock)
    try await database.write { database in
      try Self.upsertStock(database: database, instrument: instrument)
    }
    invalidateInstrumentMapCache()
    fireOnRecordChanged(instrument.id)
    await notifySubscribers()
  }

  func remove(id: String) async throws {
    let didDelete = try await database.write { database -> Bool in
      let fiatKind = Instrument.Kind.fiatCurrency.rawValue
      guard
        let existing =
          try InstrumentRow
          .filter(InstrumentRow.Columns.id == id)
          .fetchOne(database)
      else { return false }
      guard existing.kind != fiatKind else { return false }
      return try InstrumentRow.deleteOne(database, key: id)
    }
    guard didDelete else { return }
    invalidateInstrumentMapCache()
    fireOnRecordDeleted(id)
    await notifySubscribers()
  }

  // MARK: - Upsert helpers (see GRDBInstrumentRegistryRepository+Upsert.swift)
  //
  // The row-level upsert helpers (`upsertCrypto`, `mergeResolvedFields`,
  // `upsertStock`) live in the sibling
  // `GRDBInstrumentRegistryRepository+Upsert.swift` extension file so this
  // file stays under SwiftLint's `file_length` budget. They are `static`
  // and module-scoped so the `register…` methods above can call
  // `Self.upsertCrypto` / `Self.upsertStock` across the extension
  // boundary — same split rationale as `+SyncHooks` / `+Lookup`.

  // MARK: - Change fan-out

  @MainActor
  func observeChanges() -> AsyncStream<Void> {
    let key = UUID()
    // `.bufferingNewest(1)`: the payload is a signal, not a diff —
    // consumers re-fetch + recompute after a tick. A burst of local
    // instrument writes (bulk seed / CSV import registering N
    // instruments) therefore collapses to ≤1 pending wake-up instead of
    // N redundant `fetchAll` + recompute round-trips on the consuming
    // store.
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      self.subscribers[key] = continuation
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { @MainActor [weak self] in
          self?.subscribers.removeValue(forKey: key)
        }
      }
    }
  }

  @MainActor
  private func notifySubscribers() {
    for continuation in subscribers.values {
      continuation.yield()
    }
  }

  /// Yields a `Void` to every active `observeChanges()` subscriber
  /// without performing a local write. The sync layer calls this when a
  /// remote pull touches `InstrumentRow`s so picker UIs refresh without
  /// waiting for an app relaunch. Concrete-only — not part of the
  /// `InstrumentRegistryRepository` protocol because it is implementation
  /// plumbing, not a domain contract.
  @MainActor
  func notifyExternalChange() {
    notifySubscribers()
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from the CKSyncEngine delegate executor on a non-MainActor
  // context. `DatabaseWriter.write { db in … }` has both async and sync
  // overloads; the sync form blocks the calling thread until the queue's
  // serial executor admits the closure. Never call these from
  // `@MainActor`.

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
          continue
        }

        row.pricingStatus = mergedStatus
        try row.upsert(database)
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
  /// row caches (reject-on-tie, design §4). Fail-open: if either date is
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

  /// Persists a new `pricingStatus` for the row identified by
  /// `registration.instrument.id`, leaving every other column unchanged.
  /// Used by `CryptoTokenStore.setStatus(_:for:)` to record a user-driven
  /// classification (`.spam` / `.priced` / `.unpriced`). Throws when no
  /// row is registered for the supplied instrument id — callers should
  /// have an existing registration in hand before calling.
  ///
  /// **Field coverage.** Only the `pricing_status` column is rewritten;
  /// `instrument` / `mapping` are read from `registration` purely to
  /// locate the row. To rewrite the provider mapping, call
  /// `registerCrypto(_:mapping:)` instead. Splitting the two surfaces
  /// keeps the cross-device merge rule (which only governs
  /// `pricing_status`) from having to reason about partial updates of
  /// other server-authoritative columns.
  ///
  /// Fires `onRecordChanged` and the `observeChanges()` fan-out on
  /// success so CKSyncEngine queues the record for upload and any picker
  /// UI refreshes.
  func update(_ registration: CryptoRegistration) async throws {
    let updated = try await database.write { database -> Bool in
      guard
        var existing =
          try InstrumentRow
          .filter(InstrumentRow.Columns.id == registration.instrument.id)
          .fetchOne(database)
      else { return false }
      existing.pricingStatus = registration.pricingStatus.rawValue
      try existing.update(database)
      return true
    }
    guard updated else {
      throw BackendError.notFound(
        "InstrumentRegistry: no row registered for id '\(registration.instrument.id)'"
      )
    }
    invalidateInstrumentMapCache()
    fireOnRecordChanged(registration.instrument.id)
    await notifySubscribers()
  }

  // The synchronous entry points used by `ProfileIndexSyncHandler`
  // (`setEncodedSystemFieldsSync`, `clearAllSystemFieldsSync`,
  // `unsyncedRowIdsSync`, `allRowIdsSync`, `fetchRowSync`,
  // `fetchRowsSync`, `deleteAllSync`) live in the sibling
  // `+SyncEntryPoints` extension file.
  // `unsyncedNonFiatRowIdsSync` similarly lives in `+Lookup`.
}
