import Foundation
import Testing

@testable import Moolah

@Suite("Tax income expense Rule 11")
struct TaxIncomeExpenseRule11Tests {
  @Test("tax detail assembly rejects summary rows without transaction IDs")
  func taxDetailAssemblyRejectsRowsWithoutTransactionIds() async {
    let ownerId = UUID()
    let aggregation = GRDBAnalysisRepository.TaxIncomeExpenseAggregation(
      rows: [
        GRDBAnalysisRepository.TaxIncomeExpenseRow(
          transactionId: nil,
          day: "2026-07-01",
          categoryId: UUID(),
          instrumentId: Instrument.AUD.id,
          type: .income,
          ownerIds: [ownerId],
          qty: 100)
      ],
      instrumentMap: [Instrument.AUD.id: .AUD])
    let handlers = GRDBAnalysisRepository.TaxIncomeExpenseHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in })

    await #expect(throws: (any Error).self) {
      _ = try await GRDBAnalysisRepository.assembleTaxIncomeExpenseDetails(
        aggregation: aggregation,
        targetInstrument: .AUD,
        conversionService: FakeConversionService.passthrough,
        selection: GRDBAnalysisRepository.TaxIncomeExpenseDetailSelection(
          ownerId: ownerId,
          type: .income),
        handlers: handlers)
    }
  }

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

  @Test("an unavailable deduction preserves independently computable income")
  func unavailableDeductionPreservesIncome() async throws {
    let usd = Instrument.fiat(code: "USD")
    let fixture = try await makeTaxIncomeFixture(
      conversionService: FakeConversionService.failingInstruments([usd.id]))
    let ownerId = UUID()
    var account = fixture.account
    account.taxOwnerIds = [ownerId]
    let category = try await fixture.categories.create(
      Moolah.Category(name: "Tax items", isTaxReportable: true))
    _ = try await fixture.accounts.create(account)
    try await insertTaxTransaction(
      fixture.database,
      accountId: account.id,
      legs: [
        TaxTestLeg(100, .income, category.id),
        TaxTestLeg(-25, .expense, category.id, instrument: usd),
      ])

    let summaries = try await fixture.analysis.fetchTaxIncomeExpenseSummaries(
      dateInterval: fixture.date..<fixture.date.addingTimeInterval(1),
      targetInstrument: .AUD,
      defaultTaxOwnerId: fixture.defaultOwner)
    let incomeRows = try await fixture.analysis.fetchTaxIncomeExpenseDetails(
      dateInterval: fixture.date..<fixture.date.addingTimeInterval(1),
      targetInstrument: .AUD,
      defaultTaxOwnerId: fixture.defaultOwner,
      ownerId: ownerId,
      type: .income)

    let summary = try #require(summaries.first { $0.ownerId == ownerId })
    #expect(summary.taxableIncome.quantity == 100)
    #expect(summary.deductibleExpenses.quantity == 0)
    #expect(summary.incomeHasUnavailableData == false)
    #expect(summary.deductionsHasUnavailableData)
    #expect(summary.netHasUnavailableData)
    #expect(incomeRows.compactMap(\.amount).reduce(.zero(instrument: .AUD), +).quantity == 100)
    #expect(incomeRows.allSatisfy { !$0.hasUnavailableData })
  }
}
