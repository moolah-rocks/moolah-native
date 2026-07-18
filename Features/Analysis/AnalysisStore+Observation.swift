import Foundation

// Reactive rate-tick observation for `AnalysisStore`.
//
// The conversion service's `observeRates()` emits one tick on subscribe
// (the contract) and then re-emits whenever a price-cache table changes
// — including the background `CryptoPriceWarmer`'s writes. We skip the
// initial tick so subscription doesn't double-load on top of the view's
// own initial `.task { loadAll() }`. Subsequent ticks force a coalesced
// reload while Analysis is active, or invalidate its cache while offscreen.
// See issue #1075.
extension AnalysisStore {

  func observe() async {
    let rateStream = conversionService.observeRates()
    let rateErrors = conversionService.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        var sawInitial = false
        for await _ in rateStream {
          if !sawInitial {
            sawInitial = true
            // Signal so tests can confirm the subscription is live before
            // emitting a real tick; production ignores the tick stream.
            await self.signalObservationTickForTesting()
            continue
          }
          await self.reloadForRateTick()
          await self.signalObservationTickForTesting()
        }
      }
      group.addTask { [self] in
        for await error in rateErrors { await self.surfaceObservationError(error) }
      }
      // Cancellation of `observationTask` cancels the group; the
      // `for await` loops exit; the group returns naturally.
    }
  }

  /// Tears down the observation task. Idempotent. Called from
  /// `ProfileSession.cleanupSync(coordinator:)`.
  func stopObserving() {
    observationTask?.cancel()
    cancelDeferredRateRefresh()
  }

  /// Handles a price-cache tick from a background warm. Active views route
  /// through the single-flight loader; offscreen views retain one deferred
  /// invalidation, and reconciliation-time bursts receive one debounced
  /// follow-up. See #1163, #1075.
  func reloadForRateTick() async {
    guard prepareForRateTick() else { return }
    await loadAll(force: true)
  }

  /// Test-only: yields after every consumed rate-stream emission, including
  /// offscreen emissions that only mark a deferred refresh. Invoked from the
  /// `observe()` loop.
  func signalObservationTickForTesting() {
    testObservationTickContinuation.yield(())
  }
}
