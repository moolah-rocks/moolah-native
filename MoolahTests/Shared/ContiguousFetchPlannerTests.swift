import Foundation
import Testing

@testable import Moolah

@Suite
struct ContiguousFetchPlannerTests {
  // DateKeys are yyyymmdd ints; use real calendar days so +1 day math is exercised.
  static let jan01: Int32 = 20_240_101
  static let jan15: Int32 = 20_240_115
  static let jan31: Int32 = 20_240_131
  static let feb15: Int32 = 20_240_215

  static let defaultConfig = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)

  @Test
  func requestedInsideBoundsReturnsNil() {
    let window = ContiguousFetchPlanner.nextWindow(
      earliest: Self.jan01,
      latest: Self.jan31,
      requested: Self.jan15,
      today: Self.feb15,
      config: Self.defaultConfig)
    #expect(window == nil)
  }

  @Test
  func addingDaysCrossesMonthBoundary() {
    #expect(ContiguousFetchPlanner.addingDays(1, to: 20_240_131) == 20_240_201)
    #expect(ContiguousFetchPlanner.addingDays(-1, to: 20_240_301) == 20_240_229)  // leap year
    #expect(ContiguousFetchPlanner.addingDays(30, to: 20_240_101) == 20_240_131)
  }

  @Test
  func forwardWindowIsBoundedAndAnchoredAtLatest() {
    // latest=Jan15, requested far ahead → window [Jan15 … Jan15+30], not [Jan15 … requested].
    let win = ContiguousFetchPlanner.nextWindow(
      earliest: 20_240_101,
      latest: 20_240_115,
      requested: 20_240_601,
      today: 20_240_601,
      config: Self.defaultConfig)
    #expect(win == 20_240_115...20_240_214)  // includes latest (re-query to overwrite stale), spans 30 days
  }

  @Test
  func forwardWindowStopsAtRequestedWhenNearer() {
    let win = ContiguousFetchPlanner.nextWindow(
      earliest: 20_240_101,
      latest: 20_240_115,
      requested: 20_240_120,
      today: 20_240_601,
      config: Self.defaultConfig)
    #expect(win == 20_240_115...20_240_120)
  }

  @Test
  func forwardWindowCappedAtTodayPlusBuffer() {
    // requested beyond today → cap at today+buffer, never an arbitrary future date.
    let win = ContiguousFetchPlanner.nextWindow(
      earliest: 20_240_101,
      latest: 20_240_115,
      requested: 20_240_601,
      today: 20_240_118,
      config: Self.defaultConfig)
    #expect(win == 20_240_115...20_240_120)  // today(18)+buffer(2)=20
  }

  @Test
  func backwardWindowIsBoundedAndAnchoredAtEarliest() {
    // requested far before earliest → window [earliest-30 … earliest-1], not [requested … earliest-1].
    let win = ContiguousFetchPlanner.nextWindow(
      earliest: 20_240_201,
      latest: 20_240_301,
      requested: 20_230_101,
      today: 20_240_601,
      config: Self.defaultConfig)
    #expect(win == 20_240_102...20_240_131)  // earliest-1 = Jan31, back 30 days = Jan02
  }

  @Test
  func backwardWindowStopsAtRequestedWhenNearer() {
    let win = ContiguousFetchPlanner.nextWindow(
      earliest: 20_240_201,
      latest: 20_240_301,
      requested: 20_240_120,
      today: 20_240_601,
      config: Self.defaultConfig)
    #expect(win == 20_240_120...20_240_131)
  }

  @Test
  func coldCacheWindowEndsAtRequestedWithPriorContext() {
    // empty cache: window ends at min(requested, today+buffer), reaches back windowDays for fallback context.
    let win = ContiguousFetchPlanner.nextWindow(
      earliest: nil,
      latest: nil,
      requested: 20_240_215,
      today: 20_240_601,
      config: Self.defaultConfig)
    #expect(win == 20_240_116...20_240_215)
  }

  @Test
  func coldCacheWindowCapsFutureRequestAtToday() {
    let win = ContiguousFetchPlanner.nextWindow(
      earliest: nil,
      latest: nil,
      requested: 20_240_601,
      today: 20_240_215,
      config: Self.defaultConfig)
    #expect(win == 20_240_118...20_240_217)  // end=today+buffer=Feb17, back 30 = Jan18
  }

  // MARK: - chunked

  /// Midnight-UTC anchor for `YYYY-MM-DD`.
  private func day(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = .utc
    return formatter.date(from: string) ?? Date(timeIntervalSince1970: 0)
  }

  @Test
  func chunkedSplitsLongRangeIntoBoundedWindows() {
    // 2024-01-01 … 2024-03-31 (91 days) at ≤30-day windows. Each window spans
    // 30 day-components ([Jan1…Jan31], [Feb1…Mar2], [Mar3…Mar31]) → 3
    // sub-ranges, consecutive and non-overlapping.
    let chunks = ContiguousFetchPlanner.chunked(
      day("2024-01-01")...day("2024-03-31"), days: 30)
    #expect(chunks.count == 3)
    #expect(chunks.first?.lowerBound == day("2024-01-01"))
    #expect(chunks.last?.upperBound == day("2024-03-31"))
    let cal = Calendar.utc
    for chunk in chunks {
      let span = cal.dateComponents([.day], from: chunk.lowerBound, to: chunk.upperBound).day ?? 0
      #expect(span <= 30)
    }
    // Each chunk starts the day after the previous one ends (contiguous, no gap).
    for idx in 1..<chunks.count {
      let prevEnd = chunks[idx - 1].upperBound
      let expectedStart = cal.date(byAdding: .day, value: 1, to: prevEnd)
      #expect(chunks[idx].lowerBound == expectedStart)
    }
  }

  @Test
  func chunkedShortRangeIsSingleWindow() {
    let chunks = ContiguousFetchPlanner.chunked(
      day("2024-01-01")...day("2024-01-10"), days: 30)
    #expect(chunks == [day("2024-01-01")...day("2024-01-10")])
  }

  @Test
  func chunkedSingleDayRangeIsSingleWindow() {
    let chunks = ContiguousFetchPlanner.chunked(
      day("2024-01-01")...day("2024-01-01"), days: 30)
    #expect(chunks == [day("2024-01-01")...day("2024-01-01")])
  }
}
