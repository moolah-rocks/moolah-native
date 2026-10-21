import Foundation
import Testing

@testable import Moolah

struct ReadDateRangeTests {
  @Test
  func springDSTDayUsesTwentyThreeHours() throws {
    let range = try ReadDateRange(
      from: "2026-03-08",
      through: "2026-03-08",
      timeZone: zone("America/New_York"))
    #expect(range.interval.upperBound.timeIntervalSince(range.interval.lowerBound) == 23 * 3600)
  }

  @Test
  func autumnDSTDayUsesTwentyFiveHours() throws {
    let range = try ReadDateRange(
      from: "2026-11-01",
      through: "2026-11-01",
      timeZone: zone("America/New_York"))
    #expect(range.interval.upperBound.timeIntervalSince(range.interval.lowerBound) == 25 * 3600)
  }

  @Test
  func rejectsNormalizedInvalidDatesAndReversedBounds() throws {
    let utc = try zone("UTC")
    #expect(throws: ReadQueryError.invalidFilter) {
      try ReadDateRange(from: "2026-02-30", through: "2026-03-01", timeZone: utc)
    }
    #expect(throws: ReadQueryError.invalidFilter) {
      try ReadDateRange(from: "2026-03-02", through: "2026-03-01", timeZone: utc)
    }
  }

  @Test
  func enforcesOneCalendarYearIncludingLeapYears() throws {
    let utc = try zone("UTC")
    _ = try ReadDateRange(from: "2024-01-01", through: "2024-12-31", timeZone: utc)
    #expect(throws: ReadQueryError.invalidFilter) {
      try ReadDateRange(from: "2024-01-01", through: "2025-01-01", timeZone: utc)
    }
  }

  private func zone(_ identifier: String) throws -> TimeZone {
    try #require(TimeZone(identifier: identifier))
  }
}

extension ReadDateRangeTests {
  @Test
  func instantIntervalsAlsoEnforceACalendarYear() throws {
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let year = try ReadDateRange(from: "2024-03-10", through: "2025-03-09", timeZone: zone)
    let search = try ReadTransactionSearch(range: year)
    #expect(search.range.timeZone == zone)
    #expect(throws: ReadQueryError.invalidFilter) {
      try ReadDateRange(
        interval: year.interval.lowerBound..<year.interval.upperBound.addingTimeInterval(86400),
        timeZone: zone)
    }
    #expect(throws: ReadQueryError.invalidFilter) {
      try ReadDateRange(from: "2025-01-01", through: "2026-01-02", timeZone: .utc)
    }
  }
}
