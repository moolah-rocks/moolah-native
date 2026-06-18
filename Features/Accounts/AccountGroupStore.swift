import Foundation
import OSLog
import Observation

/// Reactive store for the `AccountGroup` collection.
///
/// Mirrors `EarmarkStore` / `AccountStore`: subscribes to
/// `repository.observeAll()` in `init`, exposes a `@MainActor` snapshot
/// (`groups`), and surfaces errors out-of-band on `error`. Mutations
/// (extension in `AccountGroupStore+Mutations.swift`) are pass-through
/// to the repository; the reactive observation delivers the
/// authoritative state.
///
/// Group membership lives on `Account.groupId` (back-reference). Methods
/// that need to mutate membership take an `AccountStore` directly rather
/// than holding a reference — keeps the dependency direction explicit
/// and avoids cycles.
@Observable
@MainActor
final class AccountGroupStore {
  private(set) var groups: [AccountGroup] = []
  private(set) var error: Error?

  // Internal access (not private) so the `+Mutations` extension file can
  // reach the repository and the logger across the file split.
  let repository: any AccountGroupRepository
  let logger = Logger(subsystem: "com.moolah.app", category: "AccountGroupStore")

  /// The observation task driving `groups` from `repository.observeAll()`.
  /// Spawned from `init`; torn down by `stopObserving()` (called from
  /// `ProfileSession.cleanupSync`) or `deinit` as a safety net.
  private var observationTask: Task<Void, Never>?

  /// Shared instrument-registry change seam + the child task draining it.
  /// `observeAll()` tracks only the `account_group` table, so a write that
  /// lands through a *different* GRDB connection — an in-app profile import
  /// holds its own `DatabaseQueue` over the same file — never fires it, and
  /// the sidebar's groups stay stale until a restart re-reads the file. An
  /// import always pings this registry stream (it registers every non-fiat
  /// denomination before the per-profile write), so re-fetching on each
  /// tick live-refreshes the open list across the DB boundary — mirroring
  /// `AccountStore` / `EarmarkStore` / `TransactionStore`. Nil in
  /// previews / legacy tests.
  private let instrumentChanges: (any InstrumentChangeObserving)?
  private var instrumentChangeObservationTask: Task<Void, Never>?

  /// Monotonic counter over authoritative `observeAll()` snapshots. The
  /// instrument-registry refresh path captures it before its `fetchAll()`
  /// and drops a stale refetch that raced a fresher snapshot — see
  /// `applyInstrumentRegistryRefresh`. `private(set)` (only
  /// `bumpSnapshotGeneration()` writes it) + `@ObservationIgnored` (a pure
  /// guard counter no view reads). Mirrors `AccountStore`.
  @ObservationIgnored private(set) var snapshotGeneration: UInt64 = 0

  /// The single increment path for `snapshotGeneration`.
  private func bumpSnapshotGeneration() {
    snapshotGeneration &+= 1
  }

  /// Test-only emission tick stream. Yields `()` after every state
  /// assignment in `apply(groups:)`. Tests use the
  /// `TestableStoreObservation` helpers in
  /// `MoolahTests/Support/TestableStoreObservation.swift` to await
  /// emissions deterministically. `internal` access is intentional;
  /// `@testable import Moolah` exposes it to the test target.
  let testObservationTickStream: AsyncStream<Void>
  private let testObservationTickContinuation: AsyncStream<Void>.Continuation

  init(
    repository: any AccountGroupRepository,
    instrumentChanges: (any InstrumentChangeObserving)? = nil
  ) {
    self.repository = repository
    self.instrumentChanges = instrumentChanges
    let pair = AsyncStream<Void>.makeStream()
    self.testObservationTickStream = pair.stream
    self.testObservationTickContinuation = pair.continuation

    // Strong `self` capture is intentional: the store is `@MainActor`,
    // the task already holds an implicit strong reference, and
    // `stopObserving()` is the sole lifetime gate. A weak capture would
    // just add a nil-check hazard without preventing the retain.
    observationTask = Task { await self.observe() }
    if let instrumentChanges {
      let changes = instrumentChanges.observeChanges()
      instrumentChangeObservationTask = Task { [self] in
        await self.observeInstrumentRegistryChanges(changes)
      }
    }
  }

  deinit {
    // Safety net for the case where `cleanupSync` is missed (e.g. an
    // early-error tear-down path that drops the ProfileSession without
    // calling cleanupSync). Swift 6 makes `deinit` nonisolated; reading
    // `@MainActor`-isolated state requires `MainActor.assumeIsolated`.
    MainActor.assumeIsolated {
      observationTask?.cancel()
      instrumentChangeObservationTask?.cancel()
      testObservationTickContinuation.finish()
    }
  }

  /// Subscribes to `repository.observeAll()` and forwards every
  /// emission to `apply(groups:)`. Errors are surfaced out-of-band via
  /// `repository.observeErrors()`. Modelled on `EarmarkStore.observe()`
  /// — same `TaskGroup` shape kept small here because the group store
  /// has no companion conversion / rates stream.
  private func observe() async {
    let groupsStream = repository.observeAll()
    let errorsStream = repository.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await fresh in groupsStream {
          await self.applyGroupsSnapshot(fresh)
        }
      }
      group.addTask { [self] in
        for await error in errorsStream {
          await self.surface(error: error)
        }
      }
    }
  }

  /// The **authoritative** per-emission entry point for the `observeAll()`
  /// subscription. Bumps `snapshotGeneration` so a concurrent
  /// instrument-registry refetch can detect that it raced a fresher
  /// snapshot, then applies it. Mirrors `AccountStore.applyAccountsSnapshot`.
  private func applyGroupsSnapshot(_ fresh: [AccountGroup]) async {
    bumpSnapshotGeneration()
    await apply(groups: fresh)
  }

  /// Assigns a fresh snapshot and yields the test tick so deterministic
  /// emission-aware tests can await observed state. Does NOT bump the
  /// generation — only authoritative `observeAll()` snapshots do, so the
  /// registry-refresh guard stays meaningful.
  private func apply(groups fresh: [AccountGroup]) async {
    self.groups = fresh
    testObservationTickContinuation.yield(())
  }

  /// Consumes the shared instrument registry's change stream. Each tick
  /// re-fetches the groups and re-applies them so a write that landed
  /// through a connection `observeAll()` doesn't track (an in-app import's
  /// own `DatabaseQueue`) still reaches the open sidebar. `Task.isCancelled`
  /// is re-checked after the stream suspension so a teardown that races a
  /// tick exits before issuing a fetch. `snapshotGeneration` is captured
  /// *before* the `fetchAll()` so a stale refetch can be dropped — see
  /// `applyInstrumentRegistryRefresh`. Mirrors
  /// `AccountStore.observeInstrumentRegistryChanges`.
  private func observeInstrumentRegistryChanges(_ changes: AsyncStream<Void>) async {
    for await _ in changes {
      guard !Task.isCancelled else { return }
      let observedGeneration = snapshotGeneration
      do {
        let fresh = try await repository.fetchAll()
        guard !Task.isCancelled else { return }
        await applyInstrumentRegistryRefresh(fresh, observedGeneration: observedGeneration)
      } catch {
        surface(error: error)
      }
    }
  }

  /// Applies an instrument-registry-triggered refetch, but only if no
  /// authoritative `observeAll()` snapshot has landed since the fetch was
  /// issued. The `fetchAll()` runs unordered with respect to `observeAll()`;
  /// a fetch that read the database before a concurrent write committed
  /// returns a stale row set, and applying it after a fresher authoritative
  /// snapshot would clobber `groups` back to the pre-write state. The
  /// generation check and the assignment inside `apply(groups:)` run with no
  /// intervening suspension on the main actor, so the only harmful ordering
  /// (a stale refresh applied *after* a fresh snapshot) is exactly what the
  /// guard drops. Internal so the store's refresh tests can drive the guard
  /// path directly with a captured generation. Mirrors `AccountStore`.
  func applyInstrumentRegistryRefresh(
    _ fresh: [AccountGroup], observedGeneration: UInt64
  ) async {
    guard snapshotGeneration == observedGeneration else { return }
    await apply(groups: fresh)
  }

  /// Surfaces an observation error onto `self.error`. Internal so the
  /// `+Mutations` extension can route mutation errors here too.
  func surface(error: any Error) {
    logger.error("AccountGroupStore observation error: \(error.localizedDescription)")
    self.error = error
  }

  /// Module-internal so `+Mutations` can clear / set `error` directly.
  /// Necessary because `error` is `private(set)`.
  func setError(_ error: (any Error)?) {
    self.error = error
  }

  /// Tears down the observation tasks. Idempotent.
  func stopObserving() {
    observationTask?.cancel()
    instrumentChangeObservationTask?.cancel()
  }

  /// Test-only. Awaits the observation task chain to fully terminate
  /// after `stopObserving()`, then nils the references.
  func awaitObservationTermination() async {
    await observationTask?.value
    observationTask = nil
    await instrumentChangeObservationTask?.value
    instrumentChangeObservationTask = nil
  }

  // MARK: - Lookups

  /// Looks up a group by id. Returns `nil` for unknown ids.
  func by(id: UUID) -> AccountGroup? {
    groups.first { $0.id == id }
  }

  /// Returns the members of `groupId`, sorted by `Account.position`
  /// ascending. Visibility / hidden filtering is the caller's
  /// responsibility — the store doesn't track hidden state for
  /// accounts.
  func members(of groupId: UUID, in accounts: Accounts) -> [Account] {
    accounts.ordered
      .filter { $0.groupId == groupId }
      .sorted { $0.position < $1.position }
  }
}
