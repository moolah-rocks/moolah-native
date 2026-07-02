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
final class GRDBInstrumentRegistryRepository: @unchecked Sendable {
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
  /// Redirects an incoming retired cross-chain instrument id onto its
  /// canonical id so the apply path can mark the retired row `alias_of`.
  /// `nil` for repos that never apply instrument records
  /// (per-profile bundles, previews, tests that don't exercise aliasing).
  let canonicalResolver: CanonicalInstrumentResolver?

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
    onRecordDeleted: @escaping @Sendable (String) -> Void = { _ in },
    canonicalResolver: CanonicalInstrumentResolver? = nil
  ) {
    self.database = database
    self.canonicalResolver = canonicalResolver
    self.hooks = OSAllocatedUnfairLock(
      initialState: HookState(
        onRecordChanged: onRecordChanged,
        onRecordDeleted: onRecordDeleted))
  }

  // MARK: - Cross-extension internals
  //
  // `attachSyncHooks` and the `fireOnRecord*` helpers live in
  // `GRDBInstrumentRegistryRepository+SyncHooks.swift`; the row-level
  // upsert helpers (`upsertCrypto`, `upsertStock`) and the
  // `clearDeletionIntent(for:in:)` deletion-journal helper live in
  // `GRDBInstrumentRegistryRepository+Upsert.swift`; and the remote-apply
  // entry point (`applyRemoteChangesSync`, which calls
  // `Self.clearDeletionIntent`) lives in
  // `GRDBInstrumentRegistryRepository+SyncEntryPoints.swift`. They access
  // `hooks` / are called as `Self.upsert…` / `Self.clearDeletionIntent`
  // via the `internal` visibility implied by Swift's same-module-extension
  // scope.

  // MARK: - InstrumentRegistryRepository conformance

  func all() async throws -> [Instrument] {
    let stored = try await database.read { database in
      // Hide aliased (retired) rows — a unified asset (e.g. ETH) must
      // appear once. `alias_of` is not in `CodingKeys` so we reference it
      // via `Column("alias_of")` per GRDB's untyped-column API. The
      // `instrument_by_alias` partial index covers `WHERE alias_of IS NOT NULL`
      // (the FK-resolver path); this predicate (`IS NULL`) is the opposite, so
      // SQLite does a full scan — intentional and correct for this small table.
      try InstrumentRow
        .filter(Column("alias_of") == nil)
        .fetchAll(database).map { try $0.toDomain() }
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
      // Compose the alias filter (hide retired rows) with the existing
      // kind filter. `alias_of` is not in `CodingKeys` so we reference it via
      // `Column("alias_of")`. The `instrument_by_alias` partial index covers
      // `WHERE alias_of IS NOT NULL` (the FK-resolver path); this predicate
      // (`IS NULL`) is the opposite, so SQLite does a full scan — intentional
      // and correct for this small table (same scan as the unfiltered form).
      let rows =
        try InstrumentRow
        .filter(InstrumentRow.Columns.kind == cryptoKind)
        .filter(Column("alias_of") == nil)
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
      let didDelete = try InstrumentRow.deleteOne(database, key: id)
      if didDelete {
        // Durable deletion intent (issue #1097) written in the SAME
        // transaction as the row delete, so an engine-down window or a
        // sync-state reset can't lose it before the `.deleteRecord`
        // propagates — otherwise a token-less refetch (zone purge,
        // encrypted-data reset, or #1090/#12 bloated-state recovery) would
        // resurrect the instrument. Instruments live in the profile-index DB
        // and sync in the `profile-index` zone (like `ProfileRow`, NOT the
        // per-profile `@profile-data` sentinel), so the real index zone name
        // is stored — the start-time replay then re-enqueues it as a
        // `.deleteRecord` and the recovery shield snapshots it for free.
        try DeletionJournal.record(
          zoneName: DeletionJournal.profileIndexZoneName,
          recordName: InstrumentRow.recordName(for: id),
          recordType: InstrumentRow.recordType,
          at: Date(),
          in: database)
      }
      return didDelete
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
  // `applyRemoteChangesSync` (the CKSyncEngine remote-apply path) and its
  // `mergedPricingStatus` / `isStaleInstrumentEcho` helpers live in the
  // sibling `+SyncEntryPoints` extension file, alongside the other
  // synchronous sync entry points, so this file stays under SwiftLint's
  // `file_length` budget.

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

// MARK: - InstrumentRegistryRepository

extension GRDBInstrumentRegistryRepository: InstrumentRegistryRepository {}
