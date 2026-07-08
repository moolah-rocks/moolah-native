import Foundation
import Testing

@testable import Moolah

@Suite("Tax income expense Rule 11")
struct TaxIncomeExpenseRule11Tests {
  @Test("tax income summaries preserve unaffected owners when conversion fails")
  func taxIncomeSummariesPreserveUnaffectedOwnersWhenConversionFails() async throws {
    let usd = Instrument.fiat(code: "USD")
    let fixture = try await makeTaxIncomeFixture(
      conversionService: FakeConversionService.failingInstruments([usd.id]))
    let ownerA = UUID()
    let ownerB = UUID()
    let usdAccount = Account(
      id: UUID(),
      name: "USD cash",
      type: .bank,
      instrument: usd,
      taxOwnerIds: [ownerB])
    var audAccount = fixture.account
    audAccount.taxOwnerIds = [ownerA]
    let category = try await fixture.categories.create(
      Moolah.Category(name: "Interest", isTaxReportable: true))
    _ = try await fixture.accounts.create(audAccount)
    _ = try await fixture.accounts.create(usdAccount)
    try await insertTaxTransaction(
      fixture.database,
      accountId: audAccount.id,
      legs: [TaxTestLeg(100, .income, category.id)])
    try await insertTaxTransaction(
      fixture.database,
      accountId: usdAccount.id,
      legs: [TaxTestLeg(200, .income, category.id, instrument: usd)])

    let summaries = try await fixture.analysis.fetchTaxIncomeExpenseSummaries(
      dateInterval: fixture.date..<fixture.date.addingTimeInterval(1),
      targetInstrument: .AUD,
      defaultTaxOwnerId: fixture.defaultOwner)

    let ownerASummary = try #require(summaries.first { $0.ownerId == ownerA })
    let ownerBSummary = try #require(summaries.first { $0.ownerId == ownerB })
    #expect(ownerASummary.taxableIncome.quantity == 100)
    #expect(!ownerASummary.hasUnavailableData)
    #expect(ownerBSummary.taxableIncome.quantity == 0)
    #expect(ownerBSummary.hasUnavailableData)
  }
}
