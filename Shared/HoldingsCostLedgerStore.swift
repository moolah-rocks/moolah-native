import Foundation

/// Profile-scoped provider for the profile-wide `HoldingsCostLedger`.
///
/// Builds the ledger **once per data load** from the SQL key-event query
/// (`fetchCostBasisEventLegs` — only non-fiat-touching transactions leave
/// SQLite) and caches it; concurrent callers during a build share the single
/// in-flight build. Returns `.empty` while `isMigratingCrossChainIdentity`
/// (lots may still be split across retired + canonical ids).
///
/// **`.empty` is ONLY the migration gate — never a swallowed failure.** A
/// genuine build failure (the query throws, or the conversion batch throws)
/// propagates out of `ledger()`; it is never degraded to `.empty` and never
/// cached. This matters because `.empty`'s `remainingInvested` returns 0 (its
/// `unavailableKeys` is empty), so degrading a real failure to `.empty` would
/// silently render "0 invested" instead of "unavailable" — a Rule 11
/// violation. Callers treat a thrown ledger as unavailable (the downstream
/// tile/baseline becomes nil), never as 0. The migration gate returns `.empty`
/// legitimately: no cost-basis data exists yet, so 0/empty is honest — and it
/// does so WITHOUT querying.
///
/// **Invalidation is a full rebuild on the import-inclusive dual seam.** Two
/// streams both drop the cache: (a) `transactionChanges` =
/// `repository.observeAll()` — the app's own GRDB connection, catching manual
/// creates/edits/deletes; and (b) `instrumentChanges` =
/// `instrumentChangeObserver.observeChanges()` — the **import/sync backstop**.
/// An in-app import holds its *own* `DatabaseQueue` over the same file, so its
/// writes never fire `observeAll()`; the importer always pings the
/// instrument-registry stream before its per-profile write, so wiring both
/// seams is the same belt-and-suspenders fix #1149 gave `AccountGroupStore`
/// (`Features/Accounts/AccountGroupStore.swift`). Not invalidated on rate
/// ticks — the value-line batch-conversion path is unchanged.
///
/// **Full rebuild, never incremental.** Any data change drops the whole
/// cached ledger and the next `ledger()` re-runs the SQL query + FIFO pass
/// from scratch — FIFO across accounts makes partial patching unsafe.
///
/// **Supersession, not stacking.** A monotonic `generation` (mirroring
/// `AccountStore.snapshotGeneration` / `ReportingStore.reportGeneration`) is
/// bumped on every `invalidate()`. EVERY `ledger()` caller — the build
/// originator and any joiner that awaits the same in-flight `buildTask` —
/// captures the generation before its await and rechecks it after, dropping
/// the result and retrying if a later invalidate superseded it. So a burst of
/// sync ticks coalesces to a single rebuild rather than stacking N, and a
/// joiner never publishes a pre-invalidate snapshot — the single-flight
/// discipline the analysis reload-storm fix (#1164) established.
@MainActor
final class HoldingsCostLedgerStore {
  nonisolated private let transactionRepository: any TransactionRepository
  nonisolated private let conversionService: any InstrumentConversionService
  nonisolated private let referenceCurrency: Instrument
  /// Migration gate. `@MainActor`-isolated (not `@Sendable`): only `ledger()`
  /// reads it, on the main actor, so it may call the `@MainActor`
  /// `UnifiedInstrumentIdentityMigration.isComplete(in:)` directly.
  private let isMigrating: () -> Bool

  private var cached: HoldingsCostLedger?
  private var buildTask: Task<HoldingsCostLedger, any Error>?
  private var observationTask: Task<Void, Never>?
  /// Bumped on every `invalidate()`; a build that started under an older
  /// value drops its (now-stale) result instead of caching it.
  private var generation: UInt64 = 0

  /// Internal (for tests): whether a successfully-built ledger is currently
  /// cached. A genuine build failure leaves this `false` (failures are never
  /// cached); an `invalidate()` clears it.
  var hasCachedLedger: Bool { cached != nil }

  init(
    transactionRepository: any TransactionRepository,
    conversionService: any InstrumentConversionService,
    referenceCurrency: Instrument,
    isMigrating: @escaping () -> Bool = { false },
    transactionChanges: AsyncStream<[Transaction]>? = nil,
    instrumentChanges: AsyncStream<Void>? = nil
  ) {
    self.transactionRepository = transactionRepository
    self.conversionService = conversionService
    self.referenceCurrency = referenceCurrency
    self.isMigrating = isMigrating
    guard transactionChanges != nil || instrumentChanges != nil else { return }
    // Strong `self` capture inside the task-group children: the store is
    // `@MainActor` and owned by `ProfileSession`, whose teardown cancels this
    // task via `stopObserving()` / `deinit`. A `weak self` avoids retaining
    // the store past that point.
    self.observationTask = Task { [weak self] in
      await withTaskGroup(of: Void.self) { group in
        if let transactionChanges {
          group.addTask { for await _ in transactionChanges { await self?.invalidate() } }
        }
        if let instrumentChanges {
          group.addTask { for await _ in instrumentChanges { await self?.invalidate() } }
        }
      }
    }
  }

  /// The profile-wide ledger: `.empty` while migrating, the cached instance
  /// if valid, otherwise built once. Concurrent callers during a build await
  /// the same `buildTask` (single-flight). If an `invalidate()` supersedes the
  /// build mid-flight, the stale result is dropped and a fresh build is issued
  /// — for the originator AND every joiner, since both capture and recheck the
  /// generation around the await. The cache is never written behind a newer
  /// generation. A genuine build failure propagates (it is NOT degraded to
  /// `.empty` and NOT cached).
  func ledger() async throws -> HoldingsCostLedger {
    if isMigrating() { return .empty }
    if let cached { return cached }
    // Capture the generation and resolve the in-flight (or freshly created)
    // build in ONE synchronous, non-suspending region so single-flight holds
    // and EVERY caller — the originator AND a joiner — rechecks the captured
    // generation after the await. Otherwise a joiner awaiting a build that an
    // `invalidate()` supersedes mid-flight would return that build's stale
    // (pre-edit) ledger or its `CancellationError` (the #1209 clobber class).
    let requested = generation
    let task: Task<HoldingsCostLedger, any Error>
    if let inFlight = buildTask {
      task = inFlight
    } else {
      task = Task { try await self.build() }
      buildTask = task
    }

    let built: HoldingsCostLedger
    do {
      built = try await task.value
    } catch {
      // Superseded by an `invalidate()` (which bumped the generation and may
      // have cancelled the build): rebuild under the new generation rather
      // than surfacing a stale result or the cancellation. Applies to
      // originator and joiner alike.
      guard requested == generation else { return try await ledger() }
      // Genuine failure (query / conversion threw): clear the settled handle
      // so a later call retries, then propagate — never degrade to `.empty`,
      // never cache. Only the originator holds `buildTask`; a joiner's clear
      // is a harmless no-op (the originator already cleared it).
      buildTask = nil
      throw error
    }
    guard requested == generation else {
      // Superseded after a successful build — drop the stale result, rebuild.
      // Both originator and joiner take this path when their captured
      // generation is stale, so neither publishes a pre-invalidate snapshot.
      return try await ledger()
    }
    cached = built
    buildTask = nil
    return built
  }

  /// Builds an uncached profile-wide ledger containing only cost-basis rows
  /// whose parent transaction date is on or before `date`. Used by historical
  /// tax projections where both open quantity and market value must reflect a
  /// past point in time rather than today's open lots.
  func ledger(through date: Date) async throws -> HoldingsCostLedger {
    if isMigrating() { return .empty }
    let legRows = try await transactionRepository.fetchCostBasisEventLegs()
    let filteredRows = legRows.filter { $0.date <= date }
    return try await HoldingsCostLedger.build(
      legRows: filteredRows,
      referenceCurrency: referenceCurrency,
      conversionService: conversionService)
  }

  /// Builds an uncached profile-wide ledger containing only cost-basis rows
  /// whose parent transaction date is before `date`. Prefer this for financial
  /// year ranges, which are modelled as half-open intervals.
  func ledger(before date: Date) async throws -> HoldingsCostLedger {
    if isMigrating() { return .empty }
    let legRows = try await transactionRepository.fetchCostBasisEventLegs()
    let filteredRows = legRows.filter { $0.date < date }
    return try await HoldingsCostLedger.build(
      legRows: filteredRows,
      referenceCurrency: referenceCurrency,
      conversionService: conversionService)
  }

  /// Full-rebuild invalidation: bumps the generation, drops the cached
  /// ledger, and cancels any in-flight build. The next `ledger()` re-runs the
  /// SQL query + FIFO pass from scratch. Called from both change-stream
  /// drains (edit seam + import backstop).
  func invalidate() {
    generation &+= 1
    cached = nil
    buildTask?.cancel()
    buildTask = nil
  }

  /// Tears down the change-stream observation. Idempotent. Called from
  /// `ProfileSession.cleanupSync(coordinator:)` on teardown.
  func stopObserving() {
    observationTask?.cancel()
  }

  /// Runs off the main actor (`nonisolated`): the FIFO fold is pure and only
  /// hops the conversion actor for conversions.
  nonisolated private func build() async throws -> HoldingsCostLedger {
    let legRows = try await transactionRepository.fetchCostBasisEventLegs()
    return try await HoldingsCostLedger.build(
      legRows: legRows,
      referenceCurrency: referenceCurrency,
      conversionService: conversionService)
  }

  deinit {
    // Same reasoning as `CryptoTokenStore`: the only deallocation path is
    // `ProfileSession` (`@MainActor`) releasing its last strong reference on
    // the main actor, so the isolation assumption holds.
    MainActor.assumeIsolated { observationTask?.cancel() }
  }
}
