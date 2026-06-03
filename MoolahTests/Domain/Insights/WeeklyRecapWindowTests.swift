import Foundation
import Testing

@testable import Moolah

/// Tests for the pure ISO-week gate that determines whether the weekly
/// recap should be shown (issue #1042). All dates are fixed
/// `Date(timeIntervalSince1970:)` values — no `Date()` calls — so results
/// are deterministic regardless of when tests run.
///
/// The calendar is pinned to UTC so ISO week boundaries are consistent
/// regardless of the machine's local timezone.
@Suite("WeeklyRecapWindow")
struct WeeklyRecapWindowTests {

  // UTC calendar anchors ISO week boundaries at UTC midnight, making
  // epoch-based fixed dates unambiguous across all test-runner timezones.
  private let cal: Calendar = {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(abbreviation: "UTC") ?? .current
    return calendar
  }()

  // ISO week reference dates (UTC noon, away from midnight boundary):
  //   2024-W01-Wed = 2024-01-03T12:00Z → epoch 1_704_283_200
  //   2024-W01-Mon = 2024-01-01T12:00Z → epoch 1_704_110_400
  //   2024-W02-Mon = 2024-01-08T12:00Z → epoch 1_704_715_200
  //   2023-W52-Mon = 2023-12-25T12:00Z → epoch 1_703_505_600
  //   2023-W52-Wed = 2023-12-27T12:00Z → epoch 1_703_678_400

  private let w01mon = Date(timeIntervalSince1970: 1_704_110_400)  // 2024-01-01 12:00 UTC
  private let w01wed = Date(timeIntervalSince1970: 1_704_283_200)  // 2024-01-03 12:00 UTC
  private let w02mon = Date(timeIntervalSince1970: 1_704_715_200)  // 2024-01-08 12:00 UTC
  private let w52mon = Date(timeIntervalSince1970: 1_703_505_600)  // 2023-12-25 12:00 UTC
  private let w52wed = Date(timeIntervalSince1970: 1_703_678_400)  // 2023-12-27 12:00 UTC

  // MARK: - Never shown

  @Test("shows when never shown (lastShown == nil)")
  func showsWhenNeverShown() {
    #expect(WeeklyRecapWindow.shouldShow(now: w01mon, lastShown: nil, calendar: cal))
  }

  // MARK: - Same week

  @Test("hides when shown earlier in the same ISO week")
  func hidesInSameWeek() {
    // lastShown = Monday of week 1, now = Wednesday of week 1 — same ISO week
    #expect(!WeeklyRecapWindow.shouldShow(now: w01wed, lastShown: w01mon, calendar: cal))
  }

  @Test("hides when shown on the same day")
  func hidesOnSameDay() {
    #expect(!WeeklyRecapWindow.shouldShow(now: w01mon, lastShown: w01mon, calendar: cal))
  }

  // MARK: - Different week

  @Test("shows when now is in a later ISO week than lastShown")
  func showsNextWeek() {
    // lastShown = week 1, now = week 2
    #expect(WeeklyRecapWindow.shouldShow(now: w02mon, lastShown: w01mon, calendar: cal))
  }

  // MARK: - Year boundary (ISO week 52 → week 1)

  @Test("shows across ISO year boundary (week 52 → week 1)")
  func showsAcrossYearBoundary() {
    // lastShown = 2023-W52-Mon, now = 2024-W01-Mon
    // ISO year 2023 week 52 → ISO year 2024 week 1: different (year, week) tuple
    #expect(WeeklyRecapWindow.shouldShow(now: w01mon, lastShown: w52mon, calendar: cal))
  }

  @Test("hides within the same ISO year-boundary week")
  func hidesWithinYearBoundaryWeek() {
    // Both dates land in ISO 2023-W52 (2023-12-25 through 2023-12-31).
    // w52mon = Monday, w52wed = Wednesday — same week.
    #expect(!WeeklyRecapWindow.shouldShow(now: w52wed, lastShown: w52mon, calendar: cal))
  }
}
