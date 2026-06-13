import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class InvestmentStore {
  private(set) var values: [InvestmentValue] = []
  private(set) var dailyBalances: [AccountDailyBalance] = []
  private(set) var isLoading = false
  private(set) var error: Error?
  private(set) var positions: [Position] = []
  private(set) var valuedPositions: [ValuedPosition] = []
  /// Total portfolio value in the profile currency. `nil` when any
  /// individual position's conversion failed — per Rule 11 in
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` we must not display a
  /// partial sum as the portfolio total.
  private(set) var totalPortfolioValue: Decimal?
  /// Lifetime account-level performance numbers in profile currency.
  /// `nil` until `loadAllData(...)` runs, or when conversion failure
  /// during cash-flow extraction marks it unavailable. A failure here
  /// does not invalidate other store state — `valuedPositions` and
  /// `totalPortfolioValue` continue to render normally; only the
  /// header tile reverts to "Unavailable".
  private(set) var accountPerformance: AccountPerformance?

  var selectedPeriod: TimePeriod = .all
  private(set) var loadedAccountId: UUID?
  private(set) var loadedHostCurrency: Instrument?

  // internal (was private) so the `+Observation`, `+Loading`, `+Positions`,
  // and `+PositionsInput` extension files can reach the repository for
  // fetches and pass-through writes.
  let repository: InvestmentRepository
  // internal (was private) so the `+PositionsInput` extension file can fetch
  // transactions and classify trades using the same injected dependencies.
  let transactionRepository: TransactionRepository?
  let conversionService: any InstrumentConversionService
  let logger = Logger(subsystem: "com.moolah.app", category: "InvestmentStore")

  /// Page size for the per-account values subscription. Matches the
  /// legacy `loadValues` batch size so the subscription returns the
  /// same prefix on the first emission.
  let pagedValuesPageSize = 200

  /// The single observation `Task` that runs the always-on `withTaskGroup`
  /// of child tasks subscribing to `repository.observeErrors()`,
  /// `conversionService.observeRates()`, and `conversionService.observeErrors()`.
  /// Spawned from `init`, torn down by `stopObserving()` (called from
  /// `ProfileSession.cleanupSync`) or by `deinit` as a safety net.
  private var observationTask: Task<Void, Never>?

  /// Per-account observation task that subscribes to
  /// `repository.observeValues(accountId:page:pageSize:)`. Replaced
  /// (with cancellation of the prior handle) on every
  /// `setActiveAccount(...)` call. internal so the `+Observation`
  /// extension can manage the lifecycle.
  var perAccountObservationTask: Task<Void, Never>?

  /// Narrow seam onto the shared instrument registry's change stream.
  /// The per-account values observation does not track the
  /// `instrument` table (identity / valuation resolved via the shared
  /// registry), so a metadata edit there does not re-fire
  /// `observeValues(...)`. When wired,
  /// `instrumentChangeObservationTask` re-runs the conversion-sensitive
  /// recompute on each registry tick so an open investment account
  /// live-refreshes its valuation across the DB boundary. Nil in
  /// previews / legacy tests.
  private let instrumentChanges: (any InstrumentChangeObserving)?

  /// Read-only seam onto the shared instrument registry, used to build the
  /// cross-chain asset-key map. `nil` in previews / legacy tests, in which
  /// case the holdings surface degrades to per-chain rows.
  private let instrumentRegistry: (any InstrumentRegistryRepository)?

  /// `[instrumentId: assetKey]` for the holdings cross-chain rollup, refreshed
  /// by `loadAllData`. Empty until first load, or if the registry is absent or
  /// errors — the surface then shows per-chain rows (a safe degradation).
  private(set) var assetKeysByInstrumentId: [String: String] = [:]

  /// Observes `instrumentChanges.observeChanges()` and re-runs the
  /// valuation recompute on each tick. Spawned from `init` only when a
  /// registry seam is wired; torn down by `stopObserving()` / `deinit`
  /// alongside `observationTask`.
  private var instrumentChangeObservationTask: Task<Void, Never>?

  /// Test-only emission tick stream. Yields `()` after every state
  /// assignment in the apply pipeline. Tests use the
  /// `TestableStoreObservation` helpers in
  /// `MoolahTests/Support/TestableStoreObservation.swift` to await
  /// emissions deterministically. `internal` access is intentional;
  /// `@testable import Moolah` exposes it to the test target.
  let testObservationTickStream: AsyncStream<Void>
  private let testObservationTickContinuation: AsyncStream<Void>.Continuation

  init(
    repository: InvestmentRepository,
    transactionRepository: TransactionRepository? = nil,
    conversionService: any InstrumentConversionService,
    instrumentChanges: (any InstrumentChangeObserving)? = nil,
    instrumentRegistry: (any InstrumentRegistryRepository)? = nil
  ) {
    self.repository = repository
    self.transactionRepository = transactionRepository
    self.conversionService = conversionService
    self.instrumentChanges = instrumentChanges
    self.instrumentRegistry = instrumentRegistry
    let pair = AsyncStream<Void>.makeStream()
    self.testObservationTickStream = pair.stream
    self.testObservationTickContinuation = pair.continuation

    // Strong `self` capture is intentional: the store is `@MainActor`,
    // the task already holds an implicit strong reference, and
    // `stopObserving()` (called from `cleanupSync`) is the sole lifetime
    // gate. A weak capture would just add a nil-check hazard without
    // preventing the retain — and `guard let self else { return }` would
    // mask cancellation-propagation bugs by silently exiting.
    observationTask = Task { await self.runAlwaysOnObservation() }
    if let instrumentChanges {
      let changes = instrumentChanges.observeChanges()
      instrumentChangeObservationTask = Task { [self] in
        await self.observeInstrumentRegistryChanges(changes)
      }
    }
  }

  /// Consumes the shared registry's change stream. Each tick re-runs
  /// the conversion-sensitive valuation recompute (`recomputeOnRateTick`)
  /// so an instrument-metadata edit applied to the shared registry
  /// (which does not re-fire the per-account `observeValues(...)`
  /// stream) live-refreshes the open account's valued positions.
  /// `recomputeOnRateTick` is a no-op until an account is loaded and
  /// yields the test observation tick itself. `Task.isCancelled` is
  /// re-checked after the stream suspension so a teardown that races a
  /// tick exits before recomputing. Strong `self` capture matches
  /// `runAlwaysOnObservation()` — the task's lifetime is gated by
  /// `stopObserving()` / `deinit`.
  private func observeInstrumentRegistryChanges(
    _ changes: AsyncStream<Void>
  ) async {
    for await _ in changes {
      if Task.isCancelled { return }
      await recomputeOnRateTick()
      if Task.isCancelled { return }
      await refreshAssetKeys()
      if Task.isCancelled { return }
    }
  }

  /// Refreshes the `[instrumentId: assetKey]` rollup map from the shared
  /// instrument registry. Mirrors the file's repository-error style: a
  /// `CancellationError` preserves the previous map and propagates no
  /// failure, any other error logs and disables the rollup (empty map →
  /// per-chain rows). A `nil` registry seam clears the map.
  ///
  /// Internal (not private): also invoked from
  /// `InvestmentStore+Loading.loadAllData`.
  func refreshAssetKeys() async {
    do {
      assetKeysByInstrumentId = try await CryptoRegistration.assetKeys(from: instrumentRegistry)
    } catch is CancellationError {
      // Preserve the previous map on cancellation.
    } catch {
      logger.warning(
        "allCryptoRegistrations failed, asset rollup disabled: \(error.localizedDescription, privacy: .public)"
      )
      assetKeysByInstrumentId = [:]
    }
  }

  deinit {
    // Safety net for the case where `cleanupSync` is missed (e.g. an
    // early-error tear-down path that drops the ProfileSession without
    // calling cleanupSync). Cancels the strongly-held observation Tasks
    // so they do not retain `self` and a stale GRDB connection forever.
    // Under normal lifecycle, `stopObserving()` runs first via
    // `cleanupSync` and this is a no-op. Swift 6 makes `deinit`
    // nonisolated; reading `@MainActor`-isolated state requires
    // `MainActor.assumeIsolated`. The store is owned by main-actor
    // code (`ProfileSession`), so the assumption holds in practice.
    MainActor.assumeIsolated {
      observationTask?.cancel()
      instrumentChangeObservationTask?.cancel()
      perAccountObservationTask?.cancel()
      testObservationTickContinuation.finish()
    }
  }

  /// Tears down all observation tasks. Idempotent. Called from
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
    perAccountObservationTask?.cancel()
  }

  /// Test-only. Awaits the observation tasks to fully terminate after
  /// `stopObserving()`, then nils the references.
  func awaitObservationTermination() async {
    await observationTask?.value
    observationTask = nil
    await instrumentChangeObservationTask?.value
    instrumentChangeObservationTask = nil
    await perAccountObservationTask?.value
    perAccountObservationTask = nil
  }

  // MARK: - Module-internal state setters

  // The `+Observation`, `+Loading`, and `+Positions` extensions live in
  // separate files in this module. Swift extensions in different files
  // cannot mutate `private(set)` properties on the main type — so the
  // setters below provide the privileged write access the extensions
  // need without leaking the writes outside the store.

  func setValues(_ newValues: [InvestmentValue]) { values = newValues }
  func setDailyBalances(_ newBalances: [AccountDailyBalance]) { dailyBalances = newBalances }
  func setPositions(_ newPositions: [Position]) { positions = newPositions }
  func setValuedPositions(_ newPositions: [ValuedPosition]) { valuedPositions = newPositions }
  func setTotalPortfolioValue(_ value: Decimal?) { totalPortfolioValue = value }
  func setAccountPerformance(_ performance: AccountPerformance?) {
    accountPerformance = performance
  }
  func setLoadedAccountId(_ id: UUID?) { loadedAccountId = id }
  func setLoadedHostCurrency(_ instrument: Instrument?) { loadedHostCurrency = instrument }
  func setError(_ error: (any Error)?) { self.error = error }
  func yieldTestObservationTick() { testObservationTickContinuation.yield(()) }
}

// `runAlwaysOnObservation`, `setActiveAccount`, `applyValuesPage`,
// `recomputeOnRateTick`, `surfaceObservationError` live in
// `InvestmentStore+Observation.swift`.
//
// `loadValues`, `loadDailyBalances`, `loadAllData`, `setValue`,
// `removeValue`, `refreshLegacyPerformance`, `reloadPositionsIfNeeded`
// live in `InvestmentStore+Loading.swift`.
//
// `loadPositions`, `valuatePositions`, `refreshPositionTrackedPerformance`,
// and `valuate` live in `InvestmentStore+Positions.swift`.
//
// `chartDataPoints` and the other pure-read computed properties live in
// `InvestmentStore+ComputedProperties.swift`. `InvestmentChartData` (merge +
// forward-fill helpers) lives in `InvestmentChartData.swift`.
