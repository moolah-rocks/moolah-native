import Foundation

/// Standard-normal helpers used to turn test statistics into p-values and
/// to squash unbounded z-scores into a `0...1` surprise signal.
enum NormalDistribution {
  /// Cumulative distribution function Φ(z) via the C library `erf`.
  static func cdf(_ value: Double) -> Double {
    0.5 * (1 + erf(value / 2.0.squareRoot()))
  }

  /// Two-sided p-value for a standard-normal test statistic.
  static func twoSidedPValue(_ statistic: Double) -> Double {
    2 * (1 - cdf(abs(statistic)))
  }

  /// Map an unbounded statistic onto `0...1` via the half-normal CDF:
  /// `2·Φ(|z|) − 1`. `0` at `z = 0`, ~`0.95` at `z ≈ 2`, →`1` as `z → ∞`.
  /// Used to normalise detector strengths into the ranker's `surprise`.
  static func surprise(fromZScore statistic: Double) -> Double {
    min(max(2 * cdf(abs(statistic)) - 1, 0), 1)
  }
}
