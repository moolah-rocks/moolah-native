import Foundation

// Pure loading transforms and date-window helpers for `AnalysisStore`.
extension AnalysisStore {
  /// Extends actual balances to today and forecast balances across their
  /// requested window so the two step-chart series join cleanly.
  nonisolated static func extrapolateBalances(
    _ balances: [DailyBalance], today: Date, forecastUntil: Date?
  ) -> [DailyBalance] {
    let todayStart = Calendar.current.startOfDay(for: today)
    var actual = balances.filter { !$0.isForecast }
    var forecast = balances.filter { $0.isForecast }

    if let last = actual.last, Calendar.current.startOfDay(for: last.date) < todayStart {
      actual.append(last.withDate(todayStart))
    }

    if !forecast.isEmpty, let lastActual = actual.last {
      let firstForecastDay = Calendar.current.startOfDay(for: forecast[0].date)
      if firstForecastDay > todayStart {
        forecast.insert(lastActual.withDate(todayStart, isForecast: true), at: 0)
      }
    }

    if let forecastUntil, let last = forecast.last {
      let untilStart = Calendar.current.startOfDay(for: forecastUntil)
      if Calendar.current.startOfDay(for: last.date) < untilStart {
        forecast.append(last.withDate(untilStart))
      }
    }

    return (actual + forecast).sorted { $0.date < $1.date }
  }

  /// Reloads after a background interval, while ignoring brief scene changes.
  func refreshIfStale(minimumInterval: TimeInterval) async {
    if let last = lastLoadedAt,
      Date().timeIntervalSince(last) < minimumInterval
    {
      return
    }
    await loadAll()
  }

  func afterDate(monthsAgo: Int) -> Date? {
    guard monthsAgo > 0 else { return nil }  // 0 = "All"
    return Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date())
  }

  func forecastDate(monthsAhead: Int) -> Date? {
    guard monthsAhead > 0 else { return nil }  // 0 = "None"
    return Calendar.current.date(byAdding: .month, value: monthsAhead, to: Date())
  }
}
