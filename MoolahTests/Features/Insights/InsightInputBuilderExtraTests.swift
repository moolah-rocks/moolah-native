import Foundation
import Testing

@testable import Moolah

/// Additional tests for `InsightInputBuilder` covering:
/// - `budgetedCategoryIds` cross-earmark union
/// - `scheduledBills` conversion date correctness
@Suite("InsightInputBuilder — budget and conversion")
struct InsightInputBuilderExtraTests {
  private let aud = Instrument.defaultTestInstrument

  private func context(now: Date) -> InsightContext {
    InsightContext(now: now, reportingCurrency: aud)
  }

  private func leg(
    _ quantity: Decimal,
    type: TransactionType,
    instrument: Instrument
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: nil, instrument: instrument, quantity: quantity,
      type: type, categoryId: nil)
  }

  // MARK: - budgetedCategoryIds

  @Test("budgetedCategoryIds unions budget items across multiple earmarks")
  func budgetedCategoryIdsMultiEarmark() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let groceries = Category(name: "Groceries")
    let travel = Category(name: "Travel")
    // Two separate earmarks, each budgeting a distinct category.
    let groceriesEarmark = try await backend.earmarks.create(
      Earmark(name: "Grocery Budget", instrument: aud))
    let travelEarmark = try await backend.earmarks.create(
      Earmark(name: "Travel Fund", instrument: aud))
    try await backend.earmarks.setBudget(
      earmarkId: groceriesEarmark.id, categoryId: groceries.id,
      amount: InstrumentAmount(quantity: 300, instrument: aud))
    try await backend.earmarks.setBudget(
      earmarkId: travelEarmark.id, categoryId: travel.id,
      amount: InstrumentAmount(quantity: 500, instrument: aud))

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(), context: context(now: now))

    // Both categories must appear — cross-earmark union is required.
    #expect(input.budgetedCategoryIds.contains(groceries.id))
    #expect(input.budgetedCategoryIds.contains(travel.id))
    #expect(input.budgetedCategoryIds.count == 2)
  }

  // MARK: - scheduledBills conversion date

  @Test("scheduledBills convert at current rate, not future transaction date's rate")
  func scheduledBillsConversionUsesCurrentRate() async throws {
    // The conversion service has two rate entries:
    // - distantPast (effective "today"): 1 USD → 1.5 AUD
    // - far-future (effective at transaction date): 1 USD → 3.0 AUD
    //
    // scheduledBills must use Date() for conversion (Rule 6 — current rate for
    // a future obligation), so the result should reflect 1.5, not 3.0.
    // FakeConversionService.dateRates picks the most-recent date <= requested,
    // so conversion on Date() resolves the distantPast entry (1.5), while
    // conversion on the future transaction date would resolve the far-future
    // entry (3.0). The distinction proves the gate uses context.now and the
    // conversion uses Date().
    let usd = Instrument.fiat(code: "USD")
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let futureTransactionDate = try AnalysisTestHelpers.utcDate(year: 2027, month: 1, day: 1)
    let pastTransactionDate = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 14)
    // Rate effective from distantPast (< Date()) = 1.5; far-future = 3.0.
    let conversionService = FakeConversionService.dateRates([
      Date.distantPast: ["USD": 1.5],
      futureTransactionDate: ["USD": 3.0],
    ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversionService)

    // Future-dated bill: must appear, converted at current rate (1.5).
    let futureBill = try await backend.transactions.create(
      Transaction(
        date: futureTransactionDate, payee: "Foreign Sub", recurPeriod: .month, recurEvery: 1,
        legs: [leg(-100, type: .expense, instrument: usd)]))
    // Past-dated (before context.now): must be excluded by the gate.
    _ = try await backend.transactions.create(
      Transaction(
        date: pastTransactionDate, payee: "Old Bill", recurPeriod: .month, recurEvery: 1,
        legs: [leg(-50, type: .expense, instrument: usd)]))

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(), context: context(now: now))

    // Only the future bill should appear.
    #expect(input.scheduledBills.count == 1)
    let bill = try #require(input.scheduledBills.first { $0.id == futureBill.id })
    // Converted at current rate (1.5): -100 USD → -150 AUD.
    // If it used the future-date rate (3.0) it would be -300 AUD.
    #expect(bill.amount.quantity == -150)
    #expect(bill.amount.instrument == aud)
  }
}
