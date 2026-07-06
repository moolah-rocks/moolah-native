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
/// bumped on every `invalidate()`. A build captures the generation it started
/// under and refuses to publish its result if a later invalidate superseded
/// it, so a burst of sync ticks coalesces to a single rebuild rather than
/// stacking N — the single-flight discipline the analysis reload-storm fix
/// (#1164) established.
@MainActor
final class HoldingsCostLedgerStore {
  nonisolated private let transactionRepository: any TransactionRepository
  nonisolated private let conversionService: any InstrumentConversionService
  nonisolated private let referenceCurrency: Instrument
  nonisolated private let isMigrating: @Sendable () -> Bool

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
    isMigrating: @escaping @Sendable () -> Bool = { false },
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
  /// the same `buildTask`. If an `invalidate()` supersedes the build
  /// mid-flight, the stale result is dropped and a fresh build is issued —
  /// the cache is never written behind a newer generation. A genuine build
  /// failure propagates (it is NOT degraded to `.empty` and NOT cached).
  func ledger() async throws -> HoldingsCostLedger {
    if isMigrating() { return .empty }
    if let cached { return cached }
    if let inFlight = buildTask { return try await inFlight.value }
    let requested = generation
    let task = Task { try await self.build() }
    buildTask = task

    let built: HoldingsCostLedger
    do {
      built = try await task.value
    } catch {
      // An `invalidate()` may have cancelled this build (generation bumped) —
      // it already cleared `buildTask`. That is supersession, not a genuine
      // failure: rebuild under the new generation rather than surfacing the
      // cancellation.
      if requested != generation { return try await ledger() }
      // Genuine failure (query / conversion threw): clear our settled handle
      // so a later call retries, then propagate — never degrade to `.empty`,
      // never cache.
      buildTask = nil
      throw error
    }
    guard requested == generation else {
      // Superseded after a successful build (`invalidate()` already cleared
      // `buildTask`) — drop the stale result, rebuild.
      return try await ledger()
    }
    cached = built
    buildTask = nil
    return built
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
