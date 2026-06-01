import Foundation

/// Result of a Mann-Kendall monotonic-trend test plus the Sen's-slope point
/// estimate, over an evenly-spaced time series.
struct MannKendallResult: Sendable, Hashable {
  /// The Mann-Kendall S statistic (sum of pairwise sign comparisons).
  let statistic: Int
  /// Normal-approximation z (continuity-corrected, tie-adjusted variance).
  let zScore: Double
  /// Two-sided p-value from the normal approximation.
  let pValue: Double
  /// Sen's slope: median of all pairwise slopes, in series units per step.
  let sensSlope: Double

  var isIncreasing: Bool { statistic > 0 }
  var isDecreasing: Bool { statistic < 0 }
}

/// Non-parametric monotonic-trend detection. Chosen over linear regression
/// (design §C-10) because it assumes no distribution and tolerates small N.
///
/// Apply `BenjaminiHochberg` across the per-category family of tests before
/// surfacing any result — testing dozens of categories without FDR control
/// manufactures false trends and floods the user (design §"alert spam").
enum MannKendall {
  /// Run the test over `values` in time order (index = time step). Returns
  /// `nil` for fewer than four points — the normal approximation is
  /// meaningless below that and the slope is too noisy to act on.
  static func test(_ values: [Double]) -> MannKendallResult? {
    let count = values.count
    guard count >= 4 else { return nil }

    var statistic = 0
    for i in 0..<(count - 1) {
      for j in (i + 1)..<count {
        statistic += signum(values[j] - values[i])
      }
    }

    let variance = tieAdjustedVariance(values)
    let zScore = continuityCorrectedZ(statistic: statistic, variance: variance)
    let pValue = NormalDistribution.twoSidedPValue(zScore)
    let slope = sensSlope(values)

    return MannKendallResult(
      statistic: statistic, zScore: zScore, pValue: pValue, sensSlope: slope)
  }

  /// Variance of S under H₀, corrected for ties:
  /// `[n(n−1)(2n+5) − Σ tₚ(tₚ−1)(2tₚ+5)] / 18`.
  private static func tieAdjustedVariance(_ values: [Double]) -> Double {
    let count = Double(values.count)
    let base = count * (count - 1) * (2 * count + 5)
    var tieCorrection = 0.0
    let groups = Dictionary(grouping: values, by: { $0 })
    for group in groups.values where group.count > 1 {
      let tied = Double(group.count)
      tieCorrection += tied * (tied - 1) * (2 * tied + 5)
    }
    return (base - tieCorrection) / 18
  }

  /// Continuity-corrected normal statistic. `0` when S is zero or the
  /// variance collapses (all points tied).
  private static func continuityCorrectedZ(statistic: Int, variance: Double) -> Double {
    guard variance > 0 else { return 0 }
    let deviation = variance.squareRoot()
    if statistic > 0 {
      return Double(statistic - 1) / deviation
    } else if statistic < 0 {
      return Double(statistic + 1) / deviation
    }
    return 0
  }

  /// Sen's slope: median of `(xⱼ − xᵢ) / (j − i)` over all `i < j`.
  private static func sensSlope(_ values: [Double]) -> Double {
    var slopes: [Double] = []
    let count = values.count
    slopes.reserveCapacity(count * (count - 1) / 2)
    for i in 0..<(count - 1) {
      for j in (i + 1)..<count {
        slopes.append((values[j] - values[i]) / Double(j - i))
      }
    }
    return DescriptiveStatistics.median(slopes)
  }

  private static func signum(_ value: Double) -> Int {
    if value > 0 { return 1 }
    if value < 0 { return -1 }
    return 0
  }
}
