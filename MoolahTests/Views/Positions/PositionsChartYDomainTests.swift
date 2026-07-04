import Testing

@testable import Moolah

@Suite
struct PositionsChartYDomainTests {
  @Test
  func hugsHighBandInsteadOfAnchoringAtZero() {
    let dom = PositionsChartYDomain.domain(values: [60_000, 72_000, 80_000], baselines: [])
    #expect(dom.lowerBound > 50_000)  // NOT anchored at 0
    #expect(dom.upperBound > 80_000)  // padded above the max
    #expect(dom.lowerBound < 60_000)  // padded below the min
  }

  @Test
  func includesBaselineWhenPresent() {
    let dom = PositionsChartYDomain.domain(values: [80_000], baselines: [10_000])
    #expect(dom.lowerBound < 10_000)  // baseline pulls the floor down
    #expect(dom.upperBound > 80_000)
  }

  @Test
  func flatSeriesStillGetsNonZeroSpan() {
    let dom = PositionsChartYDomain.domain(values: [500, 500, 500], baselines: [])
    #expect(dom.lowerBound < 500)
    #expect(dom.upperBound > 500)
    #expect(dom.upperBound - dom.lowerBound >= 2)
  }

  @Test
  func emptyInputsAreSafe() {
    #expect(PositionsChartYDomain.domain(values: [], baselines: []) == 0.0...1.0)
  }
}
