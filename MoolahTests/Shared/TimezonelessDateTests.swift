import Foundation
import Testing

@testable import Moolah

/// Zone-invariance tests for *timezoneless* calendar-unit carriers — values
/// like a `YYYYMM` financial-month label that are mapped onto a `Date` purely
/// to position them on a chart axis or order them. These `Date`s must report
/// the same calendar month/day when read back in *any* timezone.
///
/// The zones are injected in-process (a calendar per `TimeZone`) rather than
/// relying on the ambient process `TZ`, so the invariant is checked on every
/// CI run regardless of the runner's local zone. See
/// `guides/DATE_TIME_GUIDE.md`.
@Suite("Timezoneless date carriers")
struct TimezonelessDateTests {
  /// A spread of zones either side of UTC: one strongly negative (the case
  /// that drifts a midnight-UTC instant into the prior day), UTC itself, and
  /// one strongly positive.
  private static let zones: [String] = [
    "America/Los_Angeles",  // UTC-8 / -7
    "UTC",
    "Australia/Brisbane",  // UTC+10, no DST
    "Pacific/Kiritimati",  // UTC+14, the extreme positive case
  ]

  private func calendar(_ identifier: String) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: identifier))
    return calendar
  }

  @Test("ExpenseBreakdown.monthDate reads as April in every timezone")
  func expenseBreakdownMonthDateIsZoneInvariant() throws {
    let breakdown = ExpenseBreakdown(
      categoryId: nil,
      month: "202604",
      totalExpenses: .zero(instrument: .defaultTestInstrument)
    )
    let monthDate = try #require(breakdown.monthDate)

    for zone in Self.zones {
      let components = try calendar(zone).dateComponents([.year, .month], from: monthDate)
      #expect(components.year == 2026, "year drifted in \(zone)")
      #expect(components.month == 4, "month drifted in \(zone)")
    }
  }

  @Test("CategorySpendSeries.monthDate reads as April in every timezone")
  func categorySpendSeriesMonthDateIsZoneInvariant() throws {
    let monthDate = try #require(CategorySpendSeries.monthDate("202604"))

    for zone in Self.zones {
      let components = try calendar(zone).dateComponents([.year, .month], from: monthDate)
      #expect(components.year == 2026, "year drifted in \(zone)")
      #expect(components.month == 4, "month drifted in \(zone)")
    }
  }

  @Test("CategoryOverTimePoint.monthDate reads as April in every timezone")
  @MainActor
  func categoryOverTimeMonthDateIsZoneInvariant() throws {
    // Drives `AnalysisStore.parseMonth` (private) through its public surface so
    // the third financial-month producer is covered by the same invariant.
    let categoryId = UUID()
    let entries = AnalysisStore.buildCategoriesOverTime(
      from: [
        ExpenseBreakdown(
          categoryId: categoryId,
          month: "202604",
          totalExpenses: .zero(instrument: .defaultTestInstrument)
        )
      ],
      categories: Categories(from: [Category(id: categoryId, name: "Groceries")])
    )
    let monthDate = try #require(entries.first?.points.first?.monthDate)

    for zone in Self.zones {
      let components = try calendar(zone).dateComponents([.year, .month], from: monthDate)
      #expect(components.year == 2026, "year drifted in \(zone)")
      #expect(components.month == 4, "month drifted in \(zone)")
    }
  }
}
