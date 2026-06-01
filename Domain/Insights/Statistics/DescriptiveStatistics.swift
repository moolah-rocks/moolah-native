import Foundation

/// Pure descriptive-statistics helpers shared by the insight detectors.
///
/// Everything operates on `[Double]`; callers convert `Decimal` amounts at
/// the boundary (`Double(truncating:)`) because the robust estimators here
/// (median, MAD) need ordering and division that `Decimal` makes clumsy and
/// the inputs are already lossy aggregates. Monetary *results* are converted
/// back to `Decimal` / `InstrumentAmount` by the detector.
enum DescriptiveStatistics {
  /// Arithmetic mean, or `0` for an empty input.
  static func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
  }

  /// Median (lower-of-two-middle averaged). `0` for an empty input.
  static func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let count = sorted.count
    if count.isMultiple(of: 2) {
      return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }
    return sorted[count / 2]
  }

  /// Population standard deviation. `0` for fewer than two values.
  static func standardDeviation(_ values: [Double]) -> Double {
    guard values.count > 1 else { return 0 }
    let average = mean(values)
    let variance =
      values.reduce(0) { $0 + ($1 - average) * ($1 - average) }
      / Double(values.count)
    return variance.squareRoot()
  }

  /// Median Absolute Deviation. Robust scale estimate: `median(|xᵢ −
  /// median(x)|)`. `0` for an empty input.
  static func medianAbsoluteDeviation(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let center = median(values)
    let deviations = values.map { abs($0 - center) }
    return median(deviations)
  }

  /// Robust z-score of `value` against the distribution `population`, using
  /// the MAD with the `0.6745` normal-consistency constant
  /// (`0.6745 · (x − median) / MAD`). Falls back to the classic z-score when
  /// the MAD is zero but the standard deviation is not (e.g. a tight cluster
  /// with one outlier where >50% of points are identical). Returns `0` when
  /// both scale estimates vanish.
  ///
  /// Sign is preserved: a value far *below* the centre yields a negative
  /// score, distinguishing an unusually large refund from an unusually large
  /// charge.
  static func robustZScore(of value: Double, in population: [Double]) -> Double {
    guard population.count > 1 else { return 0 }
    let center = median(population)
    let mad = medianAbsoluteDeviation(population)
    if mad > 0 {
      return 0.6745 * (value - center) / mad
    }
    let deviation = standardDeviation(population)
    guard deviation > 0 else { return 0 }
    return (value - mean(population)) / deviation
  }

  /// The value below which `fraction` (0...1) of the sorted data falls, via
  /// linear interpolation between order statistics. `0` for an empty input.
  static func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    guard sorted.count > 1 else { return sorted[0] }
    let clamped = min(max(fraction, 0), 1)
    let position = clamped * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    let weight = position - Double(lower)
    return sorted[lower] * (1 - weight) + sorted[upper] * weight
  }

  /// Coefficient of variation: `stddev / |mean|`. `nil` when the mean is
  /// zero (the ratio is undefined). Used for the income-stability score.
  static func coefficientOfVariation(_ values: [Double]) -> Double? {
    let average = mean(values)
    guard average != 0 else { return nil }
    return standardDeviation(values) / abs(average)
  }
}
