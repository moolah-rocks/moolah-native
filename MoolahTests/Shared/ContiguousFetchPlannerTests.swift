import Testing

@testable import Moolah

@Suite struct ContiguousFetchPlannerTests {
  // DateKeys are yyyymmdd ints; use real calendar days so +1 day math is exercised.
  static let jan01: Int32 = 20_240_101
  static let jan15: Int32 = 20_240_115
  static let jan31: Int32 = 20_240_131
  static let feb15: Int32 = 20_240_215

  @Test func requestedInsideBoundsReturnsNil() {
    let window = ContiguousFetchPlanner.nextWindow(
      earliest: Self.jan01, latest: Self.jan31,
      requested: Self.jan15, today: Self.feb15,
      windowDays: 30, forwardBuffer: 2)
    #expect(window == nil)
  }
}
