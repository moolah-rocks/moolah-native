import Foundation

/// Y-axis domain for `PositionsChart`. Hugs the plotted data (value line
/// plus the invested/cost baseline when shown) instead of anchoring at 0,
/// so a portfolio worth $60–80k doesn't waste two-thirds of the chart on
/// empty space below the line. Pure and unit-tested; the view applies the
/// result via `.chartYScale(domain:)`.
enum PositionsChartYDomain {
  static func domain(
    values: [Decimal], baselines: [Decimal], paddingFraction: Double = 0.06
  ) -> ClosedRange<Double> {
    let all = (values + baselines).map { Double(truncating: $0 as NSNumber) }
    guard let lower = all.min(), let upper = all.max() else { return 0...1 }
    let span = upper - lower
    let pad = span > 0 ? span * paddingFraction : max(abs(upper) * paddingFraction, 1)
    return (lower - pad)...(upper + pad)
  }
}
