import Foundation
import OSLog
import Observation

/// Reactive store for sidebar expand / collapse state on `AccountGroup`
/// rows. Local-only (per-device) — never synced via CloudKit.
///
/// Mirrors `AccountGroupStore`: subscribes to
/// `repository.observeExpandedGroupIds()` in `init`, exposes a
/// `@MainActor` snapshot (`expandedGroupIds`), and surfaces errors
/// out-of-band on `error`. The toggle / setExpanded methods are
/// pass-through to the repository; the reactive observation delivers
/// the authoritative state. This is the same shape as `EarmarkStore`'s
/// observation-driven update path.
@Observable
@MainActor
final class GroupUIStateStore {
  private(set) var expandedGroupIds: Set<UUID> = []
  private(set) var error: Error?

  private let repository: any GroupUIStateRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "GroupUIStateStore")

  /// The observation task driving `expandedGroupIds` from
  /// `repository.observeExpandedGroupIds()`. Spawned from `init`; torn
  /// down by `stopObserving()` (called from
  /// `ProfileSession.cleanupSync`) or `deinit` as a safety net.
  private var observationTask: Task<Void, Never>?

  /// Test-only emission tick stream. Yields `()` after every state
  /// assignment in `apply(ids:)`. Tests use the
  /// `TestableStoreObservation` helpers in
  /// `MoolahTests/Support/TestableStoreObservation.swift` to await
  /// emissions deterministically. `internal` access is intentional;
  /// `@testable import Moolah` exposes it to the test target.
  let testObservationTickStream: AsyncStream<Void>
  private let testObservationTickContinuation: AsyncStream<Void>.Continuation

  init(repository: any GroupUIStateRepository) {
    self.repository = repository
    let pair = AsyncStream<Void>.makeStream()
    self.testObservationTickStream = pair.stream
    self.testObservationTickContinuation = pair.continuation
    // Strong `self` capture is intentional: the store is `@MainActor`,
    // the task already holds an implicit strong reference, and
    // `stopObserving()` is the sole lifetime gate. Same pattern as
    // `AccountGroupStore.init`.
    observationTask = Task { await self.observe() }
  }

  deinit {
    // Safety net for the case where `cleanupSync` is missed. Swift 6
    // makes `deinit` nonisolated; reading `@MainActor`-isolated state
    // requires `MainActor.assumeIsolated`.
    MainActor.assumeIsolated {
      observationTask?.cancel()
      testObservationTickContinuation.finish()
    }
  }

  /// Subscribes to `repository.observeExpandedGroupIds()` and forwards
  /// every emission to `apply(ids:)`. Errors are surfaced out-of-band
  /// via `repository.observeErrors()`.
  private func observe() async {
    let idsStream = repository.observeExpandedGroupIds()
    let errorsStream = repository.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await fresh in idsStream {
          await self.apply(ids: fresh)
        }
      }
      group.addTask { [self] in
        for await error in errorsStream {
          await self.surface(error: error)
        }
      }
    }
  }

  /// Applies a fresh snapshot from `observeExpandedGroupIds()`. Yields
  /// the test tick so deterministic emission-aware tests can await
  /// observed state.
  private func apply(ids fresh: Set<UUID>) async {
    self.expandedGroupIds = fresh
    testObservationTickContinuation.yield(())
  }

  private func surface(error: any Error) {
    logger.error("GroupUIStateStore observation error: \(error.localizedDescription)")
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

  // MARK: - Mutations

  /// Persists the expand state for a single group. Pass-through to the
  /// repository; the observation stream delivers the authoritative
  /// `expandedGroupIds` update.
  func setExpanded(_ expanded: Bool, for groupId: UUID) async {
    do {
      try await repository.setExpanded(expanded, for: groupId)
    } catch {
      logger.error("setExpanded failed: \(error.localizedDescription)")
      self.error = error
    }
  }

  /// Convenience: flips the current expand state for `groupId`. Reads
  /// the local snapshot to decide the target value, then routes through
  /// `setExpanded(_:for:)`. Race-tolerant: the observation stream
  /// re-syncs the snapshot whether or not the toggle wrote.
  func toggle(_ groupId: UUID) async {
    let target = !expandedGroupIds.contains(groupId)
    await setExpanded(target, for: groupId)
  }
}
