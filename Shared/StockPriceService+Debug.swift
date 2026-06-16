// Shared/StockPriceService+Debug.swift

#if DEBUG
  import Foundation

  extension StockPriceService {
    /// Returns the largest gap (in calendar days) between consecutive price
    /// entries in the in-memory cache for `ticker`. A gap of N means there
    /// are N − 1 un-fetched interior days between two adjacent data points.
    /// Used by contiguity tests to assert the bounded-window invariant.
    func debugMaxInteriorGapDays(ticker: String) -> Int {
      guard let cache = caches[ticker] else { return 0 }
      let keys = cache.prices.sortedKeys
      guard keys.count > 1 else { return 0 }
      let fmt = ISO8601DateFormatter()
      fmt.formatOptions = [.withFullDate]
      fmt.timeZone = TimeZone.utc
      var maxGap = 0
      for idx in 1..<keys.count {
        let prev = DateKey.isoString(keys[idx - 1])
        let curr = DateKey.isoString(keys[idx])
        if let prevDate = fmt.date(from: prev), let currDate = fmt.date(from: curr) {
          let gap = Calendar.utc.dateComponents([.day], from: prevDate, to: currDate).day ?? 0
          if gap - 1 > maxGap { maxGap = gap - 1 }
        }
      }
      return maxGap
    }
  }
#endif
