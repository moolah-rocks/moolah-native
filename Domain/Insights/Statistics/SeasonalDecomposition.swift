import Foundation

/// Additive decomposition of an evenly-spaced series into trend, seasonal,
/// and remainder components: `y = trend + seasonal + remainder`.
struct SeriesDecomposition: Sendable {
  let trend: [Double]
  let seasonal: [Double]
  let remainder: [Double]
}

/// A pragmatic, dependency-free stand-in for STL (design §B-6). Full STL is
/// overkill and numerically unstable for the handful-to-a-few-dozen monthly
/// points a personal-finance series carries. This computes:
///
/// - **trend** — a centred moving average (window = seasonal `period`, edges
///   clipped to the available span);
/// - **seasonal** — mean-centred per-phase means of the detrended series,
///   but only when there are at least two full cycles; otherwise zero;
/// - **remainder** — what's left, which the anomaly detector scores with a
///   robust z.
///
/// Documented as a deliberate simplification so a future swap to a real STL
/// implementation is a drop-in for `decompose`.
enum SeasonalDecomposition {
  /// Decompose `values` (time order) with the given seasonal `period`
  /// (e.g. 12 for month-of-year on a monthly series). A `period` ≤ 1 or a
  /// series shorter than `2·period` skips the seasonal step.
  static func decompose(_ values: [Double], period: Int) -> SeriesDecomposition {
    let count = values.count
    guard count > 0 else {
      return SeriesDecomposition(trend: [], seasonal: [], remainder: [])
    }

    let trend = movingAverageTrend(values, window: max(period, 2))

    let useSeasonal = period > 1 && count >= 2 * period
    let seasonal =
      useSeasonal
      ? seasonalComponent(values, trend: trend, period: period)
      : [Double](repeating: 0, count: count)

    var remainder = [Double](repeating: 0, count: count)
    for index in 0..<count {
      remainder[index] = values[index] - trend[index] - seasonal[index]
    }
    return SeriesDecomposition(trend: trend, seasonal: seasonal, remainder: remainder)
  }

  /// Centred moving average. At the edges the window is clipped to whatever
  /// neighbours exist, so every index gets a defined trend value.
  private static func movingAverageTrend(_ values: [Double], window: Int) -> [Double] {
    let count = values.count
    let half = window / 2
    var trend = [Double](repeating: 0, count: count)
    for index in 0..<count {
      let lower = max(0, index - half)
      let upper = min(count - 1, index + half)
      var sum = 0.0
      for position in lower...upper {
        sum += values[position]
      }
      trend[index] = sum / Double(upper - lower + 1)
    }
    return trend
  }

  /// Mean-centred per-phase seasonal indices, expanded back to a full
  /// series. Phase = `index % period`.
  private static func seasonalComponent(
    _ values: [Double], trend: [Double], period: Int
  ) -> [Double] {
    let count = values.count
    var phaseSums = [Double](repeating: 0, count: period)
    var phaseCounts = [Int](repeating: 0, count: period)
    for index in 0..<count {
      let phase = index % period
      phaseSums[phase] += values[index] - trend[index]
      phaseCounts[phase] += 1
    }
    var phaseMeans = [Double](repeating: 0, count: period)
    for phase in 0..<period where phaseCounts[phase] > 0 {
      phaseMeans[phase] = phaseSums[phase] / Double(phaseCounts[phase])
    }
    let overall = DescriptiveStatistics.mean(phaseMeans)
    var seasonal = [Double](repeating: 0, count: count)
    for index in 0..<count {
      seasonal[index] = phaseMeans[index % period] - overall
    }
    return seasonal
  }
}
