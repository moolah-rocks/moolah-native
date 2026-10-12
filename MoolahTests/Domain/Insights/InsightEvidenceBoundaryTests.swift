import Foundation
import Testing

@testable import Moolah

@Suite("Insight evidence excludes the following day")
struct InsightEvidenceBoundaryTests {
  private let category = Category(
    id: makeUUID("00100000-0000-0000-0000-000000000001"), name: "Electricity")

  @Test
  func categoryTrendQueryKeepsTheEntireCutoffDay() async throws {
    let context = InsightTestSupport.context(
      now: InsightTestSupport.date(2026, 10, 13), monthEnd: 13)
    let breakdown = (7...10).map { month in
      InsightTestSupport.breakdownRow(
        Decimal(month * 100), categoryId: category.id,
        month: String(format: "2026%02d", month))
    }
    let insight = try #require(
      CategoryTrendInsight.detect(
        breakdown: breakdown, categories: Categories(from: [category]), context: context
      ).first)
    let filter = try #require(insight.references.transactionFilter)
    try await checkQuery(filter, start: InsightTestSupport.date(2026, 6, 14))
  }

  @Test
  func singleTransactionQueryKeepsTheEntireEvidenceDay() async throws {
    let transaction = InsightTransaction(
      id: makeUUID("00100000-0000-0000-0000-000000000002"),
      date: InsightTestSupport.date(2026, 10, 13).addingTimeInterval(12 * 60 * 60),
      rawPayee: nil, normalizedPayee: "", amount: -100,
      categoryId: category.id, categoryPath: "Electricity", type: .expense, accountId: nil)
    let filter = try #require(transaction.evidenceFilter(calendar: .utc))
    try await checkQuery(filter, start: InsightTestSupport.date(2026, 10, 13))
  }
}

extension InsightEvidenceBoundaryTests {
  private func checkQuery(_ filter: TransactionFilter, start: Date) async throws {
    let (backend, _) = try TestBackend.create(instrument: InsightTestSupport.currency)
    _ = try await backend.categories.create(category)
    let nextDay = InsightTestSupport.date(2026, 10, 14)
    let dates = [
      start.addingTimeInterval(-0.001), start, nextDay.addingTimeInterval(-0.001), nextDay,
    ]
    let ids = [
      makeUUID("00200000-0000-0000-0000-000000000001"),
      makeUUID("00200000-0000-0000-0000-000000000002"),
      makeUUID("00200000-0000-0000-0000-000000000003"),
      makeUUID("00200000-0000-0000-0000-000000000004"),
    ]
    let transactions = zip(ids, dates).map { id, date in
      Transaction(
        id: id, date: date,
        legs: [
          TransactionLeg(
            accountId: nil, instrument: InsightTestSupport.currency, quantity: -100,
            type: .expense, categoryId: category.id)
        ])
    }
    _ = try await backend.transactions.createMany(transactions)
    let matches = try await backend.transactions.fetchAll(filter: filter)
    #expect(
      Set(matches.map(\.id)) == [ids[1], ids[2]],
      "Evidence must include the first instant and last stored millisecond, excluding adjacent days"
    )
  }
}
