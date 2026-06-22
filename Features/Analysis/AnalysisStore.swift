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

  /// True while a `loadAll(...)` pass is running. A single gate over ALL
  /// loads — the view's initial load, filter-change reloads, and rate-tick
  /// reloads alike — so a load requested while another is in flight never
  /// runs concurrently; it coalesces into exactly one trailing reconcile
  /// pass. This bounds the reload storm: the initial load's own price
  /// fetches write the cache `observeRates()` watches, firing ticks
  /// mid-load; without the gate each such tick spawns a fresh full
  /// recompute (a populated profile cascades ~4–5 times). See #1163, #1075.
  private var loadInFlight = false
  private var pendingReload = false
  /// Whether the coalesced trailing pass must bypass the cache guard
  /// (a rate tick was among the coalesced requests). See `loadAll(force:)`.
  private var pendingReloadForce = false

  /// The single observation `Task` draining `conversionService.observeRates()`
  /// / `observeErrors()`. Spawned from `init`, torn down by `stopObserving()`
  /// (called from `ProfileSession.cleanupSync`) or `deinit` as a safety net.
  /// Non-private so the `+Observation.swift` extension's `stopObserving()`
  /// can cancel it.
  var observationTask: Task<Void, Never>?

  /// Test-only emission tick stream. Yields `()` after every
  /// rate-tick-driven reload completes (see `+Observation`). Tests await
  /// it to deterministically observe the post-tick reload without sleeps.
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
    monthEnd: Int = Calendar.current.component(.day, from: Date())
  ) {
    self.repository = repository
    self.conversionService = conversionService
    self.defaults = defaults
    self.monthEnd = monthEnd
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
      testObservationTickContinuation.finish()
    }
  }

  // MARK: - Data Loading

  /// Single-flight entry point for every load. A load requested while
  /// another is running does not start concurrently — it coalesces into
  /// exactly one trailing reconcile pass that re-reads the current filters.
  /// A rate tick (`force`) makes that pass bypass the cache guard. This is
  /// what tames the reload storm; see the `loadInFlight` doc and #1163.
  func loadAll(force: Bool = false) async {
    if loadInFlight {
      pendingReload = true
      if force { pendingReloadForce = true }
      return
    }
    loadInFlight = true
    defer { loadInFlight = false }
    var passForce = force
    repeat {
      // If the owning task (e.g. the view's `.task`) was cancelled while a
      // pass ran, stop here rather than running the coalesced reconcile on
      // a torn-down view — `performLoad` swallows `CancellationError`, so it
      // would otherwise issue a wasted fetch and restamp `lastLoadedAt`.
      guard !Task.isCancelled else { break }
      pendingReload = false
      pendingReloadForce = false
      await performLoad(force: passForce)
      // Any load requested during `performLoad` above set `pendingReload`
      // (and `pendingReloadForce` if it was a rate tick); carry that force
      // into the single trailing reconcile pass.
      passForce = pendingReloadForce
    } while pendingReload
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

  /// Reloads analysis data only if it has been at least `minimumInterval` seconds since
  /// the last successful `loadAll()`. Called on scene phase transitions from background
  /// to active — the app briefly going inactive (share sheet, Command-Tab, notification
  /// banner) should not trigger a disruptive reload.
  ///
  /// Always loads if no data has been loaded yet.
  func refreshIfStale(minimumInterval: TimeInterval) async {
    if let last = lastLoadedAt,
      Date().timeIntervalSince(last) < minimumInterval
    {
      return
    }
    await loadAll()
  }

  /// Test hook: allows tests to rewind `lastLoadedAt` to simulate staleness without
  /// waiting real time. Not intended for production use.
  func overrideLastLoadedAtForTesting(_ date: Date?) {
    lastLoadedAt = date
  }

  // MARK: - Aggregation

  /// Extends balance data to fill gaps, matching the web app's extrapolateBalances logic:
  /// 1. Extend actual balances forward to today (so the step chart reaches the present).
  /// 2. Extend forecast balances back to today (so forecast connects to actual data).
  /// 3. Extend forecast balances forward to the forecast end date.
  nonisolated static func extrapolateBalances(
    _ balances: [DailyBalance], today: Date, forecastUntil: Date?
  ) -> [DailyBalance] {
    let todayStart = Calendar.current.startOfDay(for: today)
    var actual = balances.filter { !$0.isForecast }
    var forecast = balances.filter { $0.isForecast }

    // Extend actual balances to today
    if let last = actual.last, Calendar.current.startOfDay(for: last.date) < todayStart {
      actual.append(last.withDate(todayStart))
    }

    // Extend forecast back to today (so forecast line starts where actual ends)
    if !forecast.isEmpty, let lastActual = actual.last {
      let firstForecastDay = Calendar.current.startOfDay(for: forecast[0].date)
      if firstForecastDay > todayStart {
        forecast.insert(lastActual.withDate(todayStart, isForecast: true), at: 0)
      }
    }

    // Extend forecast to the forecast end date
    if let forecastUntil, let last = forecast.last {
      let untilStart = Calendar.current.startOfDay(for: forecastUntil)
      if Calendar.current.startOfDay(for: last.date) < untilStart {
        forecast.append(last.withDate(untilStart))
      }
    }

    return (actual + forecast).sorted { $0.date < $1.date }
  }

  // The category-rollup aggregation statics
  // (`categoriesOverTime`/`buildCategoriesOverTime`/`buildExpenseBreakdown`
  // and their helpers) live in `AnalysisStore+Aggregation.swift`.

  // MARK: - Date Utilities

  private func afterDate(monthsAgo: Int) -> Date? {
    guard monthsAgo > 0 else { return nil }  // 0 = "All"
    return Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date())
  }

  private func forecastDate(monthsAhead: Int) -> Date? {
    guard monthsAhead > 0 else { return nil }  // 0 = "None"
    return Calendar.current.date(byAdding: .month, value: monthsAhead, to: Date())
  }
}
