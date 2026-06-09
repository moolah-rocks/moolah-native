import Foundation

// Reactive rate-tick observation for `AnalysisStore`.
//
// The conversion service's `observeRates()` emits one tick on subscribe
// (the contract) and then re-emits whenever a price-cache table changes
// — including the background `CryptoPriceWarmer`'s writes. We skip the
// initial tick so subscription doesn't double-load on top of the view's
// own initial `.task { loadAll() }`; every subsequent tick forces a
// coalesced reload. See issue #1075.
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
  }

  /// Force a reload in response to a price-cache rate tick (a background
  /// warm landed new crypto prices). Coalesces bursts: if a reload is
  /// already running, run exactly one more when it finishes. See #1075.
  func reloadForRateTick() async {
    if rateTickReloadInFlight {
      rateTickReloadPending = true
      return
    }
    rateTickReloadInFlight = true
    defer { rateTickReloadInFlight = false }
    repeat {
      rateTickReloadPending = false
      await loadAll(force: true)
    } while rateTickReloadPending
  }

  /// Test-only: yields a tick after every consumed rate-stream emission
  /// (the initial on-subscribe tick and each subsequent reload). Invoked
  /// from the `observe()` loop.
  func signalObservationTickForTesting() {
    testObservationTickContinuation.yield(())
  }
}
