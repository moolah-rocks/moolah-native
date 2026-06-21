import Foundation
import Testing

@testable import Moolah

/// Tests the label shown for a Monthly Income & Expense row. A financial
/// month with a non-month-end cutoff spans two calendar months, so when the
/// row's transactions straddle a month boundary the label names both.
@Suite("MonthlyIncomeExpense month label")
struct MonthlyIncomeExpenseMonthLabelTests {
  private func month(start: Date, end: Date) -> MonthlyIncomeExpense {
    MonthlyIncomeExpense(
      month: "202605",
      start: start,
      end: end,
      income: .zero(instrument: .AUD),
      expense: .zero(instrument: .AUD),
      profit: .zero(instrument: .AUD),
      investmentIncome: .zero(instrument: .AUD),
      investmentExpense: .zero(instrument: .AUD),
      investmentProfit: .zero(instrument: .AUD))
  }

  /// UTC-pinned abbreviated month name — the same anchoring the label must
  /// use, so assertions stay locale-agnostic (no hard-coded "Apr"/"May").
  private func utcMonthAbbrev(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.setLocalizedDateFormatFromTemplate("MMM")
    return formatter.string(from: date)
  }

  private func utcDate(_ year: Int, _ monthValue: Int, _ day: Int) throws -> Date {
    try #require(
      Calendar.utc.date(from: DateComponents(year: year, month: monthValue, day: day)))
  }

  @Test("single calendar month shows one name and no range separator")
  func singleMonth() throws {
    let start = try utcDate(2026, 5, 3)
    let end = try utcDate(2026, 5, 20)

    let label = month(start: start, end: end).monthLabel

    #expect(!label.contains("–"))
    #expect(label.contains(utcMonthAbbrev(start)))
    #expect(label.contains("2026"))
  }

  @Test("transactions spanning two months in the same year name both months once")
  func twoMonthsSameYear() throws {
    let start = try utcDate(2026, 4, 22)
    let end = try utcDate(2026, 5, 10)

    let label = month(start: start, end: end).monthLabel

    #expect(label.contains("–"), "range label should join the two month names")
    #expect(label.contains(utcMonthAbbrev(start)))  // April
    #expect(label.contains(utcMonthAbbrev(end)))  // May
    // Same year → year appears once.
    #expect(label.components(separatedBy: "2026").count - 1 == 1)
  }

  @Test("transactions spanning a year boundary name both months and both years")
  func twoMonthsAcrossYears() throws {
    let start = try utcDate(2025, 12, 25)
    let end = try utcDate(2026, 1, 10)

    let label = month(start: start, end: end).monthLabel

    #expect(label.contains("–"))
    #expect(label.contains("2025"))
    #expect(label.contains("2026"))
  }

  @Test("label uses UTC: a day-1 boundary date does not drift to the previous month")
  func dayOneBoundaryDoesNotDrift() throws {
    // Midnight-UTC May 1 must read as May, not April (which a local-zone
    // formatter would show in a negative-UTC zone).
    let mayFirst = try utcDate(2026, 5, 1)

    let label = month(start: mayFirst, end: mayFirst).monthLabel

    #expect(label.contains(utcMonthAbbrev(mayFirst)))
    #expect(!label.contains("–"))
  }
}
