import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class AnalysisStore {

  // MARK: - State

  private(set) var dailyBalances: [DailyBalance] = []
  private(set) var expenseBreakdown: [ExpenseBreakdown] = []
  private(set) var incomeAndExpense: [MonthlyIncomeExpense] = []
  private(set) var isLoading = false
  private(set) var error: Error?

  /// The effective *load* window (months) of the currently cached data —
  /// `max(historyMonths, insightHistoryFloorMonths)`, or `Int.max` for "All".
  /// Keyed on the load window (not the display filter) so narrowing the UI
  /// window re-clips from cache instead of refetching; only a request that
  /// reaches further back than the cache triggers a new load.
  private var cachedLoadMonths: Int?
  private var cachedForecastMonths: Int?
  private var hasCachedData: Bool {
    cachedLoadMonths != nil && !dailyBalances.isEmpty
  }

  /// Timestamp of the last successful `loadAll()`. Used by `refreshIfStale` to
  /// avoid reloading when data was recently fetched (e.g. the app briefly
  /// becomes inactive returning from a share sheet or system dialog).
  private(set) var lastLoadedAt: Date?

  /// Today's day-of-month, used as the financial month boundary (matching
  /// the web app). Stored so SwiftUI can observe changes (e.g. date
  /// rollover triggers reload). Initialised in `init` (via the
  /// defaulted parameter) and refreshed at the start of each `loadAll()`.
  /// Tests can inject a fixed value through the init parameter so the
  /// store doesn't depend on wall-clock at construction time.
  private(set) var monthEnd: Int

  // MARK: - Filters (persisted across launches)

  var historyMonths: Int {
    didSet { defaults.set(historyMonths, forKey: "analysisHistoryMonths") }
  }
  var forecastMonths: Int {
    didSet { defaults.set(forecastMonths, forKey: "analysisForecastMonths") }
  }
  var showActualValues: Bool = false  // false = percentage, true = actual amounts

  // MARK: - Dependencies

  let repository: AnalysisRepository
  // `conversionService` is deliberately not `private` so the sibling
  // `AnalysisStore+Observation.swift` extension can subscribe to its
  // `observeRates()` / `observeErrors()` streams (mirroring
  // `AccountStore`). Treat it as private-by-convention from elsewhere.
  let conversionService: any InstrumentConversionService
  private let defaults: UserDefaults
  private let logger = Logger(subsystem: "com.moolah.app", category: "AnalysisStore")

  // MARK: - Load coalescing

  /// A single phase gate over every load source. Requests during the initial
  /// pass coalesce into one reconciliation pass; rate ticks generated during
  /// reconciliation receive at most one debounced follow-up cycle. This caps
  /// a rate-driven burst at four reads. See #1163, #1075.
  private enum LoadPhase {
    case idle
    case initial
    case reconciliation
  }

  private var loadPhase: LoadPhase = .idle
  private var loadIdleContinuations: [CheckedContinuation<Void, Never>] = []
  private var pendingReload = false
  /// Whether the coalesced trailing pass must bypass the cache guard
  /// (a rate tick was among the coalesced requests). See `loadAll(force:)`.
  private var pendingReloadForce = false

  /// Rate ticks are only useful while Analysis is visible. Offscreen ticks
  /// mark the cache dirty; the next view-initiated load consumes the marker
  /// and performs one forced refresh.
  private var isViewActive = false
  private var deferredRateRefresh = false
  private let rateRefreshDebounce: Duration
  private var isPerformingDeferredRateRefresh = false
  private var deferredRateRefreshGeneration = 0
  // Non-private so the observation extension can cancel it during profile
  // teardown alongside `observationTask`.
  var deferredRateRefreshTask: Task<Void, Never>?

  /// The single observation `Task` draining `conversionService.observeRates()`
  /// / `observeErrors()`. Spawned from `init`, torn down by `stopObserving()`
  /// (called from `ProfileSession.cleanupSync`) or `deinit` as a safety net.
  /// Non-private so the `+Observation.swift` extension's `stopObserving()`
  /// can cancel it.
  var observationTask: Task<Void, Never>?

  /// Test-only emission tick stream. Yields `()` after every rate-stream
  /// emission is handled (see `+Observation`), whether it reloads immediately
  /// or records an offscreen invalidation.
  /// `internal` so `@testable import Moolah` exposes it; the production
  /// app never reads it.
  let testObservationTickStream: AsyncStream<Void>
  // Non-private so the sibling `+Observation.swift` extension can yield
  // ticks from the observation loop (see `signalObservationTickForTesting`).
  let testObservationTickContinuation: AsyncStream<Void>.Continuation

  // MARK: - Lifecycle

  init(
    repository: AnalysisRepository,
    conversionService: any InstrumentConversionService,
    defaults: UserDefaults = .moolahShared,
    monthEnd: Int = Calendar.current.component(.day, from: Date()),
    rateRefreshDebounce: Duration = .milliseconds(500)
  ) {
    self.repository = repository
    self.conversionService = conversionService
    self.defaults = defaults
    self.monthEnd = monthEnd
    self.rateRefreshDebounce = rateRefreshDebounce
    let pair = AsyncStream<Void>.makeStream()
    self.testObservationTickStream = pair.stream
    self.testObservationTickContinuation = pair.continuation

    // Restore last-used values (UserDefaults returns 0 for missing keys)
    let savedHistory = defaults.integer(forKey: "analysisHistoryMonths")
    self.historyMonths = savedHistory > 0 ? savedHistory : 12

    let savedForecast = defaults.integer(forKey: "analysisForecastMonths")
    // forecastMonths=0 means "None" which is valid, so only default if key is absent
    if defaults.object(forKey: "analysisForecastMonths") != nil {
      self.forecastMonths = savedForecast
    } else {
      self.forecastMonths = 1
    }

    // Strong `self` capture is intentional (mirrors `AccountStore`): the
    // store is `@MainActor`, the task already holds an implicit strong
    // reference, and `stopObserving()` (via `cleanupSync`) is the sole
    // lifetime gate.
    observationTask = Task { await self.observe() }
  }

  deinit {
    // Safety net for the case where `cleanupSync` is missed. Swift 6
    // makes `deinit` nonisolated; the store is owned by main-actor code
    // (`ProfileSession`), so the assumption holds.
    MainActor.assumeIsolated {
      observationTask?.cancel()
      deferredRateRefreshTask?.cancel()
      testObservationTickContinuation.finish()
    }
  }

  // MARK: - Data Loading

  /// Single-flight entry point for every load. A request during the initial
  /// pass coalesces into one reconciliation pass. A rate tick (`force`) makes
  /// that pass bypass the cache guard, while self-generated ticks during the
  /// reconciliation pass are suppressed.
  func loadAll(force: Bool = false) async {
    let waitsForCurrentCycle = !force
    var requestedForce = force
    if isViewActive, deferredRateRefresh {
      requestedForce = true
      deferredRateRefresh = false
    }

    if await handleInFlightLoad(
      requestedForce: requestedForce, waitsForCurrentCycle: waitsForCurrentCycle)
    {
      return
    }

    defer { finishLoadCycle() }
    repeat {
      guard !Task.isCancelled else {
        if pendingReloadForce { deferredRateRefresh = true }
        break
      }

      loadPhase = .initial
      pendingReload = false
      pendingReloadForce = false
      await performLoad(force: requestedForce)

      if Task.isCancelled {
        if pendingReloadForce { deferredRateRefresh = true }
        break
      }
      guard pendingReload else { break }

      let reconciliationForce = pendingReloadForce
      pendingReload = false
      pendingReloadForce = false
      loadPhase = .reconciliation
      await performLoad(force: reconciliationForce)

      // Forced requests are ignored during reconciliation. A non-forced
      // request can still arrive there when the user changes a filter; treat
      // that as a new cycle so user intent is never dropped.
      requestedForce = pendingReloadForce
    } while pendingReload
  }

  private func handleInFlightLoad(
    requestedForce: Bool,
    waitsForCurrentCycle: Bool
  ) async -> Bool {
    guard loadPhase != .idle else { return false }
    if waitsForCurrentCycle {
      pendingReload = true
      if requestedForce { pendingReloadForce = true }
      await waitUntilLoadIdle()
      guard !Task.isCancelled else { return true }
      await loadAll()
      return true
    }
    // Most ticks here are writes made by the reconciliation itself, but
    // the shared rate stream can also carry an unrelated warmer update.
    // Preserve that signal as one debounced follow-up instead of either
    // recursing immediately or dropping it.
    if loadPhase == .reconciliation, requestedForce {
      scheduleDeferredRateRefresh()
      return true
    }
    pendingReload = true
    if requestedForce { pendingReloadForce = true }
    return true
  }

  /// Mirrors the Analysis view lifecycle. Rate observation itself remains
  /// alive for the profile, but expensive recomputation is deferred while
  /// the view is not mounted.
  func setViewActive(_ active: Bool) {
    isViewActive = active
    if !active { cancelDeferredRateRefresh() }
  }

  /// Returns whether a rate tick should reload immediately, recording a
  /// deferred refresh when Analysis is offscreen.
  func prepareForRateTick() -> Bool {
    guard isViewActive else {
      deferredRateRefresh = true
      return false
    }
    return true
  }

  /// Coalesces rate writes that arrive during reconciliation and reloads
  /// after the burst has gone quiet. The delay prevents cache writes caused
  /// by analysis itself from forming an immediate main-actor reload loop.
  private func scheduleDeferredRateRefresh() {
    deferredRateRefresh = true
    // A deferred cycle is the one allowed follow-up for this burst. Ticks it
    // produces stay as a dirty marker for the next view/scene-driven load;
    // they never recursively schedule another autonomous cycle.
    guard !isPerformingDeferredRateRefresh else { return }

    deferredRateRefreshGeneration += 1
    let generation = deferredRateRefreshGeneration
    deferredRateRefreshTask?.cancel()
    deferredRateRefreshTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if deferredRateRefreshGeneration == generation {
          deferredRateRefreshTask = nil
        }
      }
      do {
        try await Task.sleep(for: rateRefreshDebounce)
      } catch {
        return
      }
      await waitUntilLoadIdle()
      guard !Task.isCancelled else { return }
      guard isViewActive else { return }
      isPerformingDeferredRateRefresh = true
      defer { isPerformingDeferredRateRefresh = false }
      await loadAll(force: true)
    }
  }

  /// Cancels the current debounced follow-up without losing its dirty marker.
  /// Incrementing the generation prevents the cancelled task's cleanup from
  /// clearing a replacement created after the view becomes active again.
  func cancelDeferredRateRefresh() {
    if deferredRateRefreshTask != nil { deferredRateRefresh = true }
    deferredRateRefreshGeneration += 1
    deferredRateRefreshTask?.cancel()
    deferredRateRefreshTask = nil
  }

  /// Deterministic test seam for awaiting the bounded follow-up cycle.
  func waitForDeferredRateRefreshForTesting() async {
    await deferredRateRefreshTask?.value
  }

  private func waitUntilLoadIdle() async {
    guard loadPhase != .idle else { return }
    await withCheckedContinuation { continuation in
      if loadPhase == .idle {
        continuation.resume()
      } else {
        loadIdleContinuations.append(continuation)
      }
    }
  }

  private func finishLoadCycle() {
    loadPhase = .idle
    let continuations = loadIdleContinuations
    loadIdleContinuations.removeAll()
    for continuation in continuations { continuation.resume() }
  }

  private func performLoad(force: Bool) async {
    monthEnd = Calendar.current.component(.day, from: Date())
    error = nil

    // Load the larger of the user's display window and the insight floor.
    let requestedLoadMonths = Self.effectiveLoadMonths(
      historyMonths: historyMonths, floorMonths: Self.insightHistoryFloorMonths)
    // Capture the forecast window before any suspension so the cache stamp agrees
    // with the data we actually fetch, even if the user changes it mid-load.
    let requestedForecastMonths = forecastMonths

    // Refetch only when the request reaches further back than the cache, the
    // forecast window changed, or nothing is loaded yet. Narrowing the display
    // filter needs no fetch — `displayed*` re-clips the cached data.
    let needsLoad =
      !hasCachedData
      || requestedForecastMonths != cachedForecastMonths
      || requestedLoadMonths > (cachedLoadMonths ?? 0)
    // A rate tick (`force == true`) bypasses the cache guard: a background
    // warm landed new crypto prices, so even an unchanged window must
    // recompute. On a forced same-window reload `requestedLoadMonths ==
    // cachedLoadMonths`, so the `growing` branch below stays false and the
    // chart is not cleared. See #1075.
    guard force || needsLoad else { return }

    isLoading = true
    defer { isLoading = false }

    let growing = requestedLoadMonths > (cachedLoadMonths ?? 0)
    if growing {
      // Dropping stale narrower data so the spinner shows while we widen.
      dailyBalances = []
      expenseBreakdown = []
      incomeAndExpense = []
    }

    do {
      let after: Date? =
        historyMonths == 0 ? nil : afterDate(monthsAgo: requestedLoadMonths)
      let forecastUntil = forecastDate(monthsAhead: requestedForecastMonths)

      let data = try await repository.loadAll(
        historyAfter: after,
        forecastUntil: forecastUntil,
        monthEnd: monthEnd
      )
      try Task.checkCancellation()

      dailyBalances = Self.extrapolateBalances(
        data.dailyBalances, today: Date(), forecastUntil: forecastUntil
      )
      expenseBreakdown = data.expenseBreakdown
      incomeAndExpense = data.incomeAndExpense.sorted { $0.month > $1.month }

      cachedLoadMonths = requestedLoadMonths
      cachedForecastMonths = requestedForecastMonths
      lastLoadedAt = Date()
    } catch is CancellationError {
      // View teardown / supersession — see AnalysisView's `.task`. A re-mount
      // issues its own `loadAll()`. `defer` resets `isLoading`.
      return
    } catch {
      logger.error("Failed to load analysis data: \(error)")
      self.error = error
    }
  }

  /// Surfaces a rate-observation error. Non-fatal to the chart: log,
  /// don't blank. Defined in the main file (mirroring `AccountStore`) so
  /// the `+Observation.swift` extension never touches the `private`
  /// `logger` directly.
  func surfaceObservationError(_ error: any Error) {
    logger.error(
      "AnalysisStore rate observation error: \(error.localizedDescription, privacy: .public)")
  }

  /// Test hook for simulating staleness without waiting real time.
  func overrideLastLoadedAtForTesting(_ date: Date?) {
    lastLoadedAt = date
  }
}
