import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the central promise of the SQL-backed `InsightDataSource`: summary
/// size scales with the number of distinct dimensions (days, payees,
/// categories) and the bounded windows — **never** with the total
/// transaction count. A profile with years of data must pay no more than a
/// small one. Exit criterion of issue #1031.
@Suite("GRDBInsightDataSource scaling")
struct GRDBInsightDataSourceScalingTests {
  private let aud = Instrument.defaultTestInstrument

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
    return calendar
  }

  @Test("summaries stay bounded as the transaction count grows")
  func summariesDoNotScaleWithTransactionCount() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let calendar = utcCalendar
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 30)
    let context = InsightContext(now: now, reportingCurrency: aud)
    let dining = Category(name: "Dining")

    // 40 distinct days × 6 legs/day = 240 transactions, one payee, one
    // category — deliberately many rows over few dimensions.
    let days = 40
    let perDay = 6
    for dayOffset in 0..<days {
      let date = try #require(calendar.date(byAdding: .day, value: -dayOffset, to: now))
      for _ in 0..<perDay {
        _ = try await backend.transactions.create(
          Transaction(
            date: date, payee: "Netflix",
            legs: [
              TransactionLeg(
                accountId: nil, instrument: aud, quantity: -15, type: .expense,
                categoryId: dining.id)
            ]))
      }
    }
    let total = days * perDay

    let dailyTotals = try await backend.insightDataSource.dailyTotals(context: context)
    let payees = try await backend.insightDataSource.payeeSummaries(
      windowDays: 395, context: context)
    let samples = try await backend.insightDataSource.categorySamples(
      windowDays: 365, maxPerCategory: 100, context: context)
    let recent = try await backend.insightDataSource.recentCandidates(
      windowDays: 30, categories: Categories(from: [dining]), context: context)

    // O(days), not O(transactions).
    #expect(dailyTotals.count == days)
    // O(payees) — one normalized payee regardless of the 240 legs.
    #expect(payees.count == 1)
    // O(cap) — the MAD baseline never materialises more than the cap.
    let diningSamples = try #require(samples.first { $0.categoryId == dining.id })
    #expect(diningSamples.magnitudes.count == 100)
    #expect(diningSamples.magnitudes.count < total)
    // O(window) — the recent projection covers only the trailing window,
    // never the full history.
    let cutoff = try #require(calendar.date(byAdding: .day, value: -30, to: now))
    #expect(recent.count < total)
    #expect(recent.allSatisfy { $0.date >= cutoff })
  }
}
