import Foundation
import Testing

@testable import Moolah

struct ReadSummaryHorizonTests {
  @Test
  func aTenYearSummaryDoesNotRelaxTransactionSearchLimits() throws {
    let range = try ReadDateRange(
      from: "2020-01-01",
      through: "2029-12-31",
      timeZone: .utc,
      horizon: .summary
    )
    #expect(throws: ReadQueryError.invalidFilter) { try ReadTransactionSearch(range: range) }
    #expect(throws: ReadQueryError.invalidFilter) {
      try ReadDateRange(
        from: "2020-01-01",
        through: "2030-01-01",
        timeZone: .utc,
        horizon: .summary
      )
    }
  }

  @Test
  func leapDaySummariesUseTheCalendarAnniversaryAsTheirExclusiveBoundary() throws {
    _ = try ReadDateRange(
      from: "2020-02-29",
      through: "2030-02-27",
      timeZone: .utc,
      horizon: .summary
    )
    #expect(throws: ReadQueryError.invalidFilter) {
      try ReadDateRange(
        from: "2020-02-29",
        through: "2030-02-28",
        timeZone: .utc,
        horizon: .summary
      )
    }
  }

  @Test
  func summaryDaysFollowLocalDSTBoundaries() throws {
    let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let range = try ReadDateRange(
      from: "2026-03-08",
      through: "2026-03-08",
      timeZone: zone,
      horizon: .summary
    )
    #expect(range.interval.upperBound.timeIntervalSince(range.interval.lowerBound) == 23 * 3600)
  }
}
