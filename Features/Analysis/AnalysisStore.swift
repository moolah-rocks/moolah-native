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
  private let defaults: UserDefaults
  private let logger = Logger(subsystem: "com.moolah.app", category: "AnalysisStore")

  // MARK: - Lifecycle

  init(
    repository: AnalysisRepository,
    defaults: UserDefaults = .moolahShared,
    monthEnd: Int = Calendar.current.component(.day, from: Date())
  ) {
    self.repository = repository
    self.defaults = defaults
    self.monthEnd = monthEnd

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
  }

  // MARK: - Data Loading

  func loadAll() async {
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
    guard needsLoad else { return }

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

  /// Transforms expense breakdown into chart-ready data grouped by root-level category and month.
  func categoriesOverTime(categories: Categories) -> [CategoryOverTimeEntry] {
    Self.buildCategoriesOverTime(from: displayedExpenseBreakdown, categories: categories)
  }

  /// Pure function for testability: transforms expense breakdown into chart-ready grouped data.
  /// Each category's expenses are rolled up to the root level, then sorted by total descending.
  static func buildCategoriesOverTime(
    from breakdown: [ExpenseBreakdown], categories: Categories
  ) -> [CategoryOverTimeEntry] {
    var rootTotals: [UUID?: [String: Decimal]] = [:]
    var allMonths: Set<String> = []

    // Negate totalExpenses (server returns negative for expenses) and clamp to zero,
    // matching the web app's categoryOverTimeData.js approach.
    for item in breakdown {
      let rootId = rootCategoryId(for: item.categoryId, categories: categories)
      allMonths.insert(item.month)
      rootTotals[rootId, default: [:]][item.month, default: 0] += -item.totalExpenses.quantity
    }

    let orderedMonths = allMonths.sorted()

    var monthTotals: [String: Decimal] = [:]
    for (_, months) in rootTotals {
      for (month, amount) in months {
        monthTotals[month, default: 0] += max(0, amount)
      }
    }

    return rootTotals.map { categoryId, months in
      let points = orderedMonths.map { month -> CategoryOverTimePoint in
        let amount = max(0, months[month] ?? 0)
        let total = monthTotals[month] ?? 1
        let percentage =
          total > 0 ? Double(truncating: (amount / total * 100) as NSDecimalNumber) : 0
        return CategoryOverTimePoint(
          month: month,
          monthDate: parseMonth(month),
          actualAmount: amount,
          percentage: percentage
        )
      }
      let totalAmount = months.values.reduce(Decimal(0), +)
      return CategoryOverTimeEntry(
        categoryId: categoryId,
        points: points,
        totalAmount: totalAmount
      )
    }
    .sorted { $0.totalAmount > $1.totalAmount }
  }

  private static func rootCategoryId(for categoryId: UUID?, categories: Categories) -> UUID? {
    guard var id = categoryId else { return nil }
    while let category = categories.by(id: id), let parentId = category.parentId {
      id = parentId
    }
    return id
  }

  /// Builds the pie-chart breakdown shown in `ExpenseBreakdownCard`.
  ///
  /// At the top level (`selectedCategoryId == nil`), each root category's total rolls up all
  /// descendants' expenses. When drilled into a parent, each direct child's total rolls up its
  /// own subtree; transactions directly on the drilled-into parent, or outside its subtree, are
  /// excluded.
  static func buildExpenseBreakdown(
    from breakdown: [ExpenseBreakdown],
    categories: Categories,
    selectedCategoryId: UUID?
  ) -> [ExpenseBreakdownWithPercentage] {
    guard let instrument = breakdown.first?.totalExpenses.instrument else { return [] }

    var totals: [UUID?: Decimal] = [:]
    for item in breakdown {
      let targetId: UUID?
      if let selected = selectedCategoryId {
        guard
          let child = childOfAncestor(
            for: item.categoryId, ancestor: selected, categories: categories)
        else { continue }
        targetId = child
      } else {
        targetId = rootCategoryId(for: item.categoryId, categories: categories)
      }
      totals[targetId, default: 0] += -item.totalExpenses.quantity
    }

    let grandTotal = totals.values.reduce(Decimal(0)) { $0 + max(0, $1) }

    return
      totals
      .map { id, amount -> ExpenseBreakdownWithPercentage in
        let clamped = max(0, amount)
        let percentage =
          grandTotal > 0
          ? Double(truncating: (clamped / grandTotal * 100) as NSDecimalNumber) : 0
        return ExpenseBreakdownWithPercentage(
          categoryId: id,
          totalExpenses: InstrumentAmount(quantity: clamped, instrument: instrument),
          percentage: percentage
        )
      }
      .sorted { $0.totalExpenses.quantity > $1.totalExpenses.quantity }
  }

  /// Returns the id of the node in `ancestor`'s direct children that is an ancestor of (or equal
  /// to) `categoryId`, or nil if `categoryId` is outside `ancestor`'s subtree or is `ancestor`
  /// itself.
  private static func childOfAncestor(
    for categoryId: UUID?, ancestor: UUID, categories: Categories
  ) -> UUID? {
    guard var id = categoryId else { return nil }
    while let category = categories.by(id: id) {
      if category.parentId == ancestor {
        return id
      }
      guard let parentId = category.parentId else { return nil }
      id = parentId
    }
    return nil
  }

  // MARK: - Date Utilities

  private static func parseMonth(_ month: String) -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMM"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: month) ?? Date.distantPast
  }

  private func afterDate(monthsAgo: Int) -> Date? {
    guard monthsAgo > 0 else { return nil }  // 0 = "All"
    return Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date())
  }

  private func forecastDate(monthsAhead: Int) -> Date? {
    guard monthsAhead > 0 else { return nil }  // 0 = "None"
    return Calendar.current.date(byAdding: .month, value: monthsAhead, to: Date())
  }
}

struct CategoryOverTimePoint: Sendable, Identifiable {
  let month: String
  let monthDate: Date
  let actualAmount: Decimal
  let percentage: Double

  var id: String { month }
}

struct CategoryOverTimeEntry: Sendable, Identifiable {
  let categoryId: UUID?
  let points: [CategoryOverTimePoint]
  let totalAmount: Decimal

  var id: String { categoryId?.uuidString ?? "uncategorized" }
}
