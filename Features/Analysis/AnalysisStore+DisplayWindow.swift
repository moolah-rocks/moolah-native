import Foundation

// MARK: - Load window + display clipping

extension AnalysisStore {
  /// Minimum history (months) loaded for the insight engine, regardless of the
  /// Analysis screen's display filter. Three years gives the category-anomaly
  /// detector enough same-month samples to recognise an annual pattern instead
  /// of mis-flagging it as an overspend. A *minimum*, never a cap.
  nonisolated static let insightHistoryFloorMonths = 36

  /// The effective load window in months: the larger of the user's display
  /// filter and the insight floor. `historyMonths == 0` ("All") loads
  /// everything, represented as `Int.max`.
  nonisolated static func effectiveLoadMonths(historyMonths: Int, floorMonths: Int) -> Int {
    historyMonths == 0 ? Int.max : max(historyMonths, floorMonths)
  }

  // MARK: - Display clipping (pure)

  /// First `YYYYMM` bucket visible for a display window, or `nil` for "All".
  nonisolated static func displayStartMonth(historyMonths: Int, now: Date) -> String? {
    guard historyMonths > 0,
      let start = Calendar.current.date(byAdding: .month, value: -historyMonths, to: now)
    else { return nil }
    let components = Calendar.current.dateComponents([.year, .month], from: start)
    return String(format: "%04d%02d", components.year ?? 0, components.month ?? 0)
  }

  /// Clips breakdown rows to the display window (string compare on `YYYYMM`).
  nonisolated static func clipBreakdown(
    _ rows: [ExpenseBreakdown], historyMonths: Int, now: Date
  ) -> [ExpenseBreakdown] {
    guard let startMonth = displayStartMonth(historyMonths: historyMonths, now: now)
    else { return rows }
    return rows.filter { $0.month >= startMonth }
  }

  /// Clips income/expense rows to the display window (string compare on `YYYYMM`,
  /// mirrors `clipBreakdown`).
  nonisolated static func clipIncomeExpense(
    _ rows: [MonthlyIncomeExpense], historyMonths: Int, now: Date
  ) -> [MonthlyIncomeExpense] {
    guard let startMonth = displayStartMonth(historyMonths: historyMonths, now: now)
    else { return rows }
    return rows.filter { $0.month >= startMonth }
  }

  /// Clips daily balances to the display window. Forecast rows (future-dated)
  /// are always kept so the net-worth chart still draws its forecast tail.
  ///
  /// Deliberate asymmetry with `clipBreakdown` / `clipIncomeExpense`: those clip
  /// on a whole-month `YYYYMM` boundary, whereas balances clip on the exact day.
  /// At a window edge the dense daily chart starts mid-month while the monthly
  /// aggregates show the whole boundary month — acceptable, since the two
  /// surfaces have different visual granularity.
  nonisolated static func clipBalances(
    _ balances: [DailyBalance], historyMonths: Int, now: Date
  ) -> [DailyBalance] {
    guard historyMonths > 0,
      let start = Calendar.current.date(byAdding: .month, value: -historyMonths, to: now)
    else { return balances }
    let startDay = Calendar.current.startOfDay(for: start)
    return balances.filter { $0.isForecast || $0.date >= startDay }
  }

  // MARK: - Display projections (consumed by AnalysisView)

  /// Daily balances clipped to the current display window.
  var displayedDailyBalances: [DailyBalance] {
    Self.clipBalances(dailyBalances, historyMonths: historyMonths, now: Date())
  }

  /// Expense breakdown clipped to the current display window.
  var displayedExpenseBreakdown: [ExpenseBreakdown] {
    Self.clipBreakdown(expenseBreakdown, historyMonths: historyMonths, now: Date())
  }

  /// Income/expense rows clipped to the current display window.
  var displayedIncomeAndExpense: [MonthlyIncomeExpense] {
    Self.clipIncomeExpense(incomeAndExpense, historyMonths: historyMonths, now: Date())
  }
}
