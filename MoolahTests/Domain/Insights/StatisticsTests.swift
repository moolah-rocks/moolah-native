import Foundation
import Testing

@testable import Moolah

@Suite("Insight statistics")
struct StatisticsTests {
  @Test
  func medianHandlesOddAndEven() {
    #expect(DescriptiveStatistics.median([3, 1, 2]) == 2)
    #expect(DescriptiveStatistics.median([4, 1, 2, 3]) == 2.5)
    #expect(DescriptiveStatistics.median([]) == 0)
  }

  @Test
  func robustZScoreFlagsOutlierAndPreservesSign() {
    let population = [10.0, 11, 9, 10, 12, 8, 10, 11]
    let high = DescriptiveStatistics.robustZScore(of: 40, in: population)
    let low = DescriptiveStatistics.robustZScore(of: -20, in: population)
    #expect(high > 3.5)
    #expect(low < -3.5)
  }

  @Test
  func robustZScoreFallsBackToStdDevWhenMadZero() {
    // >50% identical → MAD is zero; falls back to classic z-score.
    let population = [5.0, 5, 5, 5, 5, 100]
    let score = DescriptiveStatistics.robustZScore(of: 100, in: population)
    #expect(score > 0)
  }

  @Test
  func percentileInterpolates() {
    let values = [0.0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
    #expect(DescriptiveStatistics.percentile(values, 0.9) >= 89)
    #expect(DescriptiveStatistics.percentile(values, 0) == 0)
    #expect(DescriptiveStatistics.percentile(values, 1) == 100)
  }

  @Test
  func coefficientOfVariation() {
    #expect(DescriptiveStatistics.coefficientOfVariation([10, 10, 10]) == 0)
    #expect(DescriptiveStatistics.coefficientOfVariation([0, 0, 0]) == nil)
    let variation = DescriptiveStatistics.coefficientOfVariation([8, 12, 10, 9, 11])
    #expect((variation ?? 0) > 0)
  }

  @Test
  func mannKendallDetectsIncreasingTrend() throws {
    let rising = [1.0, 2, 3, 4, 5, 6, 7, 8]
    let result = try #require(MannKendall.test(rising))
    #expect(result.isIncreasing)
    #expect(result.sensSlope == 1)
    #expect(result.pValue < 0.05)
  }

  @Test
  func mannKendallDetectsDecreasingTrend() throws {
    let falling = [9.0, 7, 6, 5, 4, 2, 1]
    let result = try #require(MannKendall.test(falling))
    #expect(result.isDecreasing)
    #expect(result.sensSlope < 0)
  }

  @Test
  func mannKendallFlatSeriesIsNotSignificant() throws {
    let flat = [5.0, 5, 5, 5, 5, 5]
    let result = try #require(MannKendall.test(flat))
    #expect(result.statistic == 0)
    #expect(result.pValue >= 0.99)
  }

  @Test
  func mannKendallRejectsTooFewPoints() {
    #expect(MannKendall.test([1, 2, 3]) == nil)
  }

  @Test
  func benjaminiHochbergControlsDiscoveries() {
    let hypotheses = [
      PValue(tag: "a", pValue: 0.001),
      PValue(tag: "b", pValue: 0.008),
      PValue(tag: "c", pValue: 0.04),
      PValue(tag: "d", pValue: 0.6),
      PValue(tag: "e", pValue: 0.9),
    ]
    let significant = BenjaminiHochberg.significant(hypotheses, fdr: 0.05)
    let tags = Set(significant.map(\.tag))
    #expect(tags.contains("a"))
    #expect(!tags.contains("d"))
    #expect(!tags.contains("e"))
  }

  @Test
  func benjaminiHochbergEmptyInput() {
    #expect(BenjaminiHochberg.significant([PValue<String>]()).isEmpty)
  }

  @Test
  func normalSurpriseMonotonic() {
    #expect(NormalDistribution.surprise(fromZScore: 0) < 0.1)
    #expect(NormalDistribution.surprise(fromZScore: 2) > 0.9)
    #expect(NormalDistribution.surprise(fromZScore: 5) <= 1)
  }

  @Test
  func seasonalDecompositionRecoversConstantPlusSeason() {
    // Two years of a clean period-4 seasonal pattern on a flat trend.
    let pattern = [10.0, 20, 30, 20]
    let series = pattern + pattern
    let decomposition = SeasonalDecomposition.decompose(series, period: 4)
    #expect(decomposition.remainder.count == series.count)
    // Remainder should be small relative to the seasonal swing.
    let maxRemainder = decomposition.remainder.map(abs).max() ?? 0
    #expect(maxRemainder < 5)
  }

  @Test
  func seasonalDecompositionSkipsSeasonalForShortSeries() {
    let series = [1.0, 2, 3]
    let decomposition = SeasonalDecomposition.decompose(series, period: 12)
    #expect(decomposition.seasonal.allSatisfy { $0 == 0 })
  }
}
