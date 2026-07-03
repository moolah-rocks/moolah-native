import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class CategoryStore {
  private(set) var categories = Categories(from: [])
  private(set) var error: Error?

  private let repository: any CategoryRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "CategoryStore")

  /// The single observation `Task` that runs the `withTaskGroup` of
  /// child tasks subscribing to `repository.observeAll()` and
  /// `repository.observeErrors()`. Spawned from `init`, torn down by
  /// `stopObserving()` (called from `ProfileSession.cleanupSync`) or by
  /// `deinit` as a safety net. Categories carry no converted balances,
  /// so the group only has the two repository streams — there is no
  /// conversion-service subscription as in `AccountStore` /
  /// `EarmarkStore`.
  private var observationTask: Task<Void, Never>?

  /// The shared instrument-registry change seam + the child task draining it.
  /// An in-app profile import writes `category` rows through its own
  /// `DatabaseQueue`, which the open session's `observeAll()` never sees;
  /// re-fetching on each registry tick live-refreshes the open list across the
  /// DB boundary — same backstop as `AccountGroupStore` (#1149). Nil in
  /// previews / legacy tests.
  private let instrumentChanges: (any InstrumentChangeObserving)?
  private var instrumentChangeObservationTask: Task<Void, Never>?

  /// Monotonic counter over authoritative `observeAll()` snapshots. The
  /// instrument-registry refresh path captures it before its `fetchAll()`
  /// and drops a stale refetch that raced a fresher snapshot — see
  /// `applyInstrumentRegistryRefresh`. `private(set)` (only
  /// `bumpSnapshotGeneration()` writes it) + `@ObservationIgnored` (a pure
  /// guard counter no view reads). Mirrors `AccountGroupStore`.
  @ObservationIgnored private(set) var snapshotGeneration: UInt64 = 0

  /// The single increment path for `snapshotGeneration`.
  private func bumpSnapshotGeneration() {
    snapshotGeneration &+= 1
  }

  /// Test-only emission tick stream. Yields `()` after every state
  /// assignment in `apply(categories:)`. Tests use the
  /// `TestableStoreObservation` helpers in
  /// `MoolahTests/Support/TestableStoreObservation.swift` to await
  /// emissions deterministically. `internal` access is intentional;
  /// `@testable import Moolah` exposes it to the test target.
  let testObservationTickStream: AsyncStream<Void>
  private let testObservationTickContinuation: AsyncStream<Void>.Continuation

  init(
    repository: any CategoryRepository,
    instrumentChanges: (any InstrumentChangeObserving)? = nil
  ) {
    self.repository = repository
    self.instrumentChanges = instrumentChanges
    let pair = AsyncStream<Void>.makeStream()
    self.testObservationTickStream = pair.stream
    self.testObservationTickContinuation = pair.continuation

    // Strong `self` capture is intentional: the store is `@MainActor`,
    // the task already holds an implicit strong reference, and
    // `stopObserving()` (called from `cleanupSync`) is the sole lifetime
    // gate. A weak capture would just add a nil-check hazard without
    // preventing the retain — and `guard let self else { return }` would
    // mask cancellation-propagation bugs by silently exiting.
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
    // calling cleanupSync). Cancels the strongly-held observation Task
    // so it does not retain `self` and a stale GRDB connection forever.
    // Under normal lifecycle, `stopObserving()` runs first via
    // `cleanupSync` and this is a no-op. Swift 6 makes `deinit`
    // nonisolated; reading `@MainActor`-isolated state requires
    // `MainActor.assumeIsolated`. The store is owned by main-actor
    // code (`ProfileSession`), so the assumption holds in practice.
    MainActor.assumeIsolated {
      observationTask?.cancel()
      instrumentChangeObservationTask?.cancel()
      testObservationTickContinuation.finish()
    }
  }

  /// Subscribes to the two reactive streams in parallel via a
  /// `TaskGroup`. The child tasks run nonisolated; each per-emission
  /// body awaits a `@MainActor`-isolated method on `self` so state
  /// assignments happen on the main actor. Capturing the streams
  /// locally (instead of `self.repository.observeAll()` inside the
  /// `addTask` closure) lets the region-based isolation checker reason
  /// about Sendable-ness.
  private func observe() async {
    let categoriesStream = repository.observeAll()
    let categoryErrors = repository.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await fresh in categoriesStream {
          await self.applyCategoriesSnapshot(fresh)
        }
      }
      group.addTask { [self] in
        for await error in categoryErrors {
          await self.surface(error: error)
        }
      }
      // Cancellation of `observationTask` cancels the group; the
      // `for await` loops exit; the group returns naturally.
    }
  }

  /// The **authoritative** per-emission entry point for the `observeAll()`
  /// subscription. Bumps `snapshotGeneration` so a concurrent
  /// instrument-registry refetch can detect that it raced a fresher snapshot,
  /// then applies it. Mirrors `AccountGroupStore.applyGroupsSnapshot`.
  private func applyCategoriesSnapshot(_ fresh: [Moolah.Category]) async {
    bumpSnapshotGeneration()
    await apply(categories: fresh)
  }

  /// Applies a fresh categories snapshot. Wrapped in the reactive-store
  /// signpost interval so benchmarks and Instruments traces can attribute
  /// `mainThreadMs` to this method. Does NOT bump the generation — only
  /// authoritative `observeAll()` snapshots do, so the registry-refresh guard
  /// stays meaningful.
  private func apply(categories fresh: [Moolah.Category]) async {
    await withReactiveStoreSignpost("category-store-apply") {
      self.categories = Categories(from: fresh)
      testObservationTickContinuation.yield(())
    }
  }

  /// Consumes the shared instrument registry's change stream. Each tick
  /// re-fetches the categories and re-applies them so a write that landed
  /// through a connection `observeAll()` doesn't track (an in-app import's own
  /// `DatabaseQueue`) still reaches the open list. `Task.isCancelled` is
  /// re-checked after the stream suspension so a teardown that races a tick
  /// exits before issuing a fetch. `snapshotGeneration` is captured *before*
  /// the `fetchAll()` so a stale refetch can be dropped. Mirrors
  /// `AccountGroupStore`.
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
  /// issued. The `fetchAll()` runs unordered with respect to `observeAll()`; a
  /// fetch that read the database before a concurrent write committed returns a
  /// stale row set, and applying it after a fresher snapshot would clobber
  /// `categories` back to the pre-write state (#1209). The generation check and
  /// the assignment run with no intervening suspension on the main actor.
  /// Internal so the store's refresh tests can drive the guard path directly.
  func applyInstrumentRegistryRefresh(
    _ fresh: [Moolah.Category], observedGeneration: UInt64
  ) async {
    guard snapshotGeneration == observedGeneration else { return }
    await apply(categories: fresh)
  }

  private func surface(error: any Error) {
    logger.error("CategoryStore observation error: \(error.localizedDescription)")
    self.error = error
  }

  /// Tears down the observation task. Idempotent. Called from
  /// `ProfileSession.cleanupSync(coordinator:)` AFTER any
  /// `deleteAllLocalData()` call so the empty-state transition is
  /// emitted to subscribed views before cancellation.
  ///
  /// Returns the moment `Task.cancel()` is issued — the underlying
  /// `for await` loops only notice cancellation on the next stream
  /// check. Tests asserting "no emission after stop" must call
  /// `awaitObservationTermination()` before the assertion.
  func stopObserving() {
    observationTask?.cancel()
    instrumentChangeObservationTask?.cancel()
  }

  /// Test-only. Awaits the observation tasks to fully terminate after
  /// `stopObserving()`, then nils the references.
  func awaitObservationTermination() async {
    await observationTask?.value
    observationTask = nil
    await instrumentChangeObservationTask?.value
    instrumentChangeObservationTask = nil
  }

  // MARK: - Mutations
  //
  // Mutations are pass-through under the reactive design: every method
  // calls the repository, the GRDB write commits, and
  // `repository.observeAll()` delivers the authoritative state via the
  // observation task spawned in `init`. There is no optimistic insert /
  // rollback path — the reactive emission IS the state update.
  //
  // Return shapes (`Category?` for create/update, `Bool` for delete) are
  // preserved from the pre-reactive store so existing call sites
  // (`if await categoryStore.update(updated) != nil { … }`,
  // `if await categoryStore.delete(id:withReplacement:) { … }`) compile
  // unchanged.

  /// Pass-through create. The reactive observation delivers the new
  /// category via `observeAll()` shortly after the GRDB write commits;
  /// no optimistic insert is needed and there is nothing to roll back
  /// because no local state was mutated. Errors surface on `self.error`
  /// and the method returns `nil` for the caller.
  func create(_ category: Moolah.Category) async -> Moolah.Category? {
    error = nil
    do {
      let created = try await repository.create(category)
      logger.debug("Created category: \(created.name)")
      return created
    } catch {
      logger.error("Failed to create category: \(error.localizedDescription)")
      self.error = error
      return nil
    }
  }

  /// Pass-through update. See `create(_:)` for the rationale; the
  /// reactive observation delivers the updated category.
  func update(_ category: Moolah.Category) async -> Moolah.Category? {
    error = nil
    do {
      let updated = try await repository.update(category)
      logger.debug("Updated category: \(updated.name)")
      return updated
    } catch {
      logger.error("Failed to update category: \(error.localizedDescription)")
      self.error = error
      return nil
    }
  }

  /// Pass-through re-categorisation delete. `withReplacement:` reassigns
  /// transaction legs / budget items from the deleted category to
  /// `replacementId` (or sets them `nil` when `replacementId == nil`)
  /// inside a single GRDB transaction; orphaned child categories are
  /// re-parented to `nil`. The reactive observation delivers the
  /// post-delete category list once the write commits.
  func delete(id: UUID, withReplacement replacementId: UUID?) async -> Bool {
    error = nil
    do {
      try await repository.delete(id: id, withReplacement: replacementId)
      logger.debug("Deleted category \(id)")
      return true
    } catch {
      logger.error("Failed to delete category: \(error.localizedDescription)")
      self.error = error
      return false
    }
  }
}
