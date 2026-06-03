import Foundation

// Reactive observation pipeline for `InsightStore`. `init` spawns the two
// observation Tasks; the stream-draining loop bodies live here so
// `InsightStore.swift` stays within the file-length budget. The per-emission
// state mutators (`applyPersistedDismissals`, `surface`) stay on the main type
// because they assign `private(set)` state. Mirrors
// `EarmarkStore+Observation.swift`.
extension InsightStore {

  /// Consumes the shared instrument registry's change stream. Each tick
  /// re-refreshes so conversion-dependent insights re-derive. `Task.isCancelled`
  /// is re-checked before and after each suspension so a teardown racing a tick
  /// exits before issuing a rebuild and promptly after a long in-flight refresh.
  /// Mirrors `EarmarkStore`.
  func observeInstrumentRegistryChanges(_ changes: AsyncStream<Void>) async {
    for await _ in changes {
      if Task.isCancelled { return }
      await refresh()
      if Task.isCancelled { return }
    }
  }

  /// Drains the persisted-dismissal repository's two streams in parallel
  /// (mirrors `EarmarkStore.observe()`): one child task applies each tally
  /// emission, the other surfaces stream errors. Both child bodies await a
  /// `@MainActor`-isolated method on `self`, so all state mutation happens on
  /// the main actor. Cancelling `dismissalObservationTask` cancels the group;
  /// the `for await` loops exit and the group returns.
  func observePersistedDismissals(
    _ stream: AsyncStream<[InsightDismissal]>,
    errors: AsyncStream<any Error>
  ) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await tallies in stream {
          if Task.isCancelled { return }
          await self.applyPersistedDismissals(tallies)
        }
      }
      group.addTask { [self] in
        for await error in errors {
          if Task.isCancelled { return }
          await self.surface(error: error)
        }
      }
    }
  }
}
