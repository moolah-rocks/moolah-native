import Foundation

// Reactive observation pipeline for `EarmarkStore`. `observe()` owns the
// always-on streams (`repository.observeAll()` +
// `conversionService.observeRates()`); the shared-registry change
// stream is owned by `instrumentChangeObservationTask` and drained by
// `observeInstrumentRegistryChanges` below (see the property docs on
// `EarmarkStore` for why each surface exists).
extension EarmarkStore {

  /// Subscribes to the four reactive streams in parallel via a
  /// `TaskGroup`. The child tasks run nonisolated; each per-emission
  /// body awaits a `@MainActor`-isolated method on `self` so state
  /// assignments happen on the main actor. Capturing the streams
  /// locally (instead of `self.repository.observeAll()` inside the
  /// `addTask` closure) lets the region-based isolation checker reason
  /// about Sendable-ness.
  func observe() async {
    let earmarksStream = repository.observeAll()
    let earmarkErrors = repository.observeErrors()
    let rateStream = conversionService.observeRates()
    let rateErrors = conversionService.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await fresh in earmarksStream {
          await self.applyEarmarksSnapshot(fresh)
        }
      }
      group.addTask { [self] in
        for await error in earmarkErrors {
          await self.surface(error: error)
        }
      }
      group.addTask { [self] in
        for await _ in rateStream {
          await self.recomputeConvertedTotals()
        }
      }
      group.addTask { [self] in
        for await error in rateErrors {
          await self.surface(error: error)
        }
      }
      // Cancellation of `observationTask` cancels the group; the
      // `for await` loops exit; the group returns naturally.
    }
  }

  /// Consumes the shared instrument registry's change stream. Each tick
  /// re-fetches the earmarks list and re-applies it so an instrument-
  /// metadata edit applied to the shared registry (which does not
  /// re-fire `repository.observeAll()`) live-refreshes an open earmark
  /// list. `Task.isCancelled` is re-checked after the stream suspension
  /// so a teardown that races a tick exits before issuing a fetch. The
  /// task's lifetime is gated by `stopObserving()` / `deinit`, matching
  /// `observe()`.
  ///
  /// `snapshotGeneration` is captured *before* the `fetchAll()` so the
  /// apply can be dropped if a fresher authoritative snapshot lands
  /// while the fetch is in flight — see `applyInstrumentRegistryRefresh`.
  func observeInstrumentRegistryChanges(_ changes: AsyncStream<Void>) async {
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

  /// **Authoritative** snapshot entry point driven by `observeAll()`. Bumps
  /// `snapshotGeneration` so a concurrent instrument-registry refetch can
  /// detect that it raced a fresher snapshot, then applies.
  private func applyEarmarksSnapshot(_ fresh: [Earmark]) async {
    bumpSnapshotGeneration()
    await apply(earmarks: fresh)
  }

  /// Applies an instrument-registry-triggered refetch, but only if no
  /// authoritative `observeAll()` snapshot has landed since the fetch was
  /// issued. The `fetchAll()` runs unordered with respect to
  /// `observeAll()`; if it read the database before a concurrent write
  /// committed, its row set is stale and applying it after a fresher
  /// authoritative snapshot would clobber `earmarks` back to a pre-write
  /// state. The generation check and the assignment inside
  /// `apply(earmarks:)` run with no intervening suspension on the main
  /// actor, so an authoritative snapshot cannot interleave between the
  /// guard and the write. See `AccountStore`'s twin for the full rationale.
  func applyInstrumentRegistryRefresh(
    _ fresh: [Earmark], observedGeneration: UInt64
  ) async {
    guard snapshotGeneration == observedGeneration else { return }
    await apply(earmarks: fresh)
  }
}
