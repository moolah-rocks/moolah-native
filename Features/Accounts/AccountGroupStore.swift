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

  /// Test-only emission tick stream. Yields `()` after every state
  /// assignment in `apply(groups:)`. Tests use the
  /// `TestableStoreObservation` helpers in
  /// `MoolahTests/Support/TestableStoreObservation.swift` to await
  /// emissions deterministically. `internal` access is intentional;
  /// `@testable import Moolah` exposes it to the test target.
  let testObservationTickStream: AsyncStream<Void>
  private let testObservationTickContinuation: AsyncStream<Void>.Continuation

  init(repository: any AccountGroupRepository) {
    self.repository = repository
    let pair = AsyncStream<Void>.makeStream()
    self.testObservationTickStream = pair.stream
    self.testObservationTickContinuation = pair.continuation

    // Strong `self` capture is intentional: the store is `@MainActor`,
    // the task already holds an implicit strong reference, and
    // `stopObserving()` is the sole lifetime gate. A weak capture would
    // just add a nil-check hazard without preventing the retain.
    observationTask = Task { await self.observe() }
  }

  deinit {
    // Safety net for the case where `cleanupSync` is missed (e.g. an
    // early-error tear-down path that drops the ProfileSession without
    // calling cleanupSync). Swift 6 makes `deinit` nonisolated; reading
    // `@MainActor`-isolated state requires `MainActor.assumeIsolated`.
    MainActor.assumeIsolated {
      observationTask?.cancel()
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
          await self.apply(groups: fresh)
        }
      }
      group.addTask { [self] in
        for await error in errorsStream {
          await self.surface(error: error)
        }
      }
    }
  }

  /// Applies a fresh snapshot from `observeAll()`. Yields the test tick
  /// so deterministic emission-aware tests can await observed state.
  /// Internal (not private) so a hypothetical future `+Observation`
  /// split mirrors `AccountStore` / `EarmarkStore`.
  func apply(groups fresh: [AccountGroup]) async {
    self.groups = fresh
    testObservationTickContinuation.yield(())
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

  /// Tears down the observation task. Idempotent.
  func stopObserving() {
    observationTask?.cancel()
  }

  /// Test-only. Awaits the observation task chain to fully terminate
  /// after `stopObserving()`, then nils the reference.
  func awaitObservationTermination() async {
    await observationTask?.value
    observationTask = nil
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
