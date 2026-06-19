import Foundation
import Testing

@testable import Moolah

@Suite("PositionsTimeRange")
struct PositionsTimeRangeTests {
  @Test("all has a nil cutoff (caller treats as: from earliest holding)")
  func allRangeUnbounded() {
    #expect(PositionsTimeRange.all.cutoff(from: Date()) == nil)
  }

  @Test("YTD cutoff is start-of-year for the given reference date")
  func ytdCutoff() throws {
    var components = DateComponents()
    components.year = 2026
    components.month = 4
    components.day = 20
    components.hour = 12
    let calendar = Calendar(identifier: .gregorian)
    let now = try #require(calendar.date(from: components))
    let cutoff = try #require(PositionsTimeRange.ytd.cutoff(from: now))

    let cutoffComponents = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: cutoff)
    #expect(cutoffComponents.year == 2026)
    #expect(cutoffComponents.month == 1)
    #expect(cutoffComponents.day == 1)
    #expect(cutoffComponents.hour == 0)
    #expect(cutoffComponents.minute == 0)
    #expect(cutoffComponents.second == 0)
  }

  @Test(
    "month-based ranges subtract the correct amount",
    arguments: [
      (PositionsTimeRange.oneMonth, -1, Calendar.Component.month),
      (PositionsTimeRange.threeMonths, -3, Calendar.Component.month),
      (PositionsTimeRange.sixMonths, -6, Calendar.Component.month),
      (PositionsTimeRange.oneYear, -1, Calendar.Component.year),
    ]
  )
  func monthRangeCutoff(range: PositionsTimeRange, value: Int, component: Calendar.Component)
    throws
  {
    let now = Date(timeIntervalSince1970: 1_775_000_000)  // 2026-04-29 UTC
    let calendar = Calendar(identifier: .gregorian)
    let cutoff = try #require(range.cutoff(from: now))
    let expected = try #require(calendar.date(byAdding: component, value: value, to: now))
    #expect(abs(cutoff.timeIntervalSince(expected)) < 1)
  }

  // `PositionsTimeRange.cutoff` uses the LOCAL Gregorian calendar (no explicit
  // timezone — system local). This test asserts that the YTD cutoff is exactly
  // local midnight on January 1 of the reference year. It deliberately does NOT
  // equal UTC midnight Jan 1 unless the runner's local timezone happens to be
  // UTC. Both the `now` construction and the component extraction use the same
  // local calendar, which is the same calendar `cutoff(from:)` uses internally.
  @Test("YTD cutoff is local midnight Jan 1, matching the local Gregorian calendar")
  func ytdCutoffIsLocalMidnightJan1() throws {
    let localCalendar = Calendar(identifier: .gregorian)  // system local timezone

    var components = DateComponents()
    components.year = 2026
    components.month = 6
    components.day = 15
    components.hour = 10
    let now = try #require(localCalendar.date(from: components))
    let cutoff = try #require(PositionsTimeRange.ytd.cutoff(from: now))

    // The cutoff must be exactly local midnight on 2026-01-01.
    // The same local calendar is used for both `now` and the assertion so
    // the test is zone-stable on any CI runner timezone.
    let cutoffComponents = localCalendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: cutoff)
    #expect(cutoffComponents.year == 2026)
    #expect(cutoffComponents.month == 1)
    #expect(cutoffComponents.day == 1)
    #expect(cutoffComponents.hour == 0)
    #expect(cutoffComponents.minute == 0)
    #expect(cutoffComponents.second == 0)
  }

  @Test("allCases includes all 6 picker entries in order")
  func allCasesOrder() {
    #expect(
      PositionsTimeRange.allCases == [
        .oneMonth, .threeMonths, .sixMonths, .ytd, .oneYear, .all,
      ]
    )
  }
}
