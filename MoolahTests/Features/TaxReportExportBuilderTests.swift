// CSV tests stay in one file so row-order, escaping, owner, and unavailable-data fixtures remain comparable.
// swiftlint:disable file_length

import Foundation
import Testing

@testable import Moolah

@Suite("TaxReportExportBuilder")
struct TaxReportExportBuilderTests {
  @Test
  func csvIncludesAllOwnerRollupAndPerOwnerResults() {
    let csv = TaxReportExportBuilder.csv(for: completeReportInput())

    assertCompleteReport(csv)
  }

  @Test
  func csvMarksUnavailableOwnerAndInstrumentRows() {
    let csv = TaxReportExportBuilder.csv(for: unavailableReportInput())

    #expect(csv.contains("All owners,All owners,Taxable income,,AUD,true"))
    #expect(csv.contains("Owner,Alex,Taxable income,,AUD,true"))
    #expect(csv.contains("Holdings,All owners,BHP.AX,3,90,150,12,60,72,AUD"))
    #expect(csv.contains("Sales,All owners,ETH,Missing price"))
    #expect(csv.contains("Holdings,All owners,ETH,Missing price"))
  }

  @Test
  func csvIncludesCapitalGainOwnerWithoutIncomeExpenseRows() {
    let csv = TaxReportExportBuilder.csv(for: capitalGainOnlyReportInput())

    #expect(csv.contains("Owner,Casey,Taxable income,,AUD,false"))
    #expect(csv.contains("Owner,Casey,Net capital gain,50,AUD,false"))
  }

  @Test
  func csvMarksOwnerCapitalGainsUnavailableWhenOnlyGlobalUnavailableStateExists() {
    let csv = TaxReportExportBuilder.csv(for: unavailableOwnerCapitalGainInput())

    #expect(csv.contains("Owner,Casey,Net capital gain,,AUD,true"))
    #expect(!csv.contains("Owner,Casey,Net capital gain,50,AUD,false"))
  }

  @Test
  func csvIncludesUnavailableCapitalGainOwnerWithoutActivityRows() {
    let csv = TaxReportExportBuilder.csv(for: ownerUnavailableCapitalGainOnlyInput())

    #expect(csv.contains("Owner,Casey,Taxable income,,AUD,false"))
    #expect(csv.contains("Owner,Casey,Net capital gain,,AUD,true"))
    #expect(csv.contains("Sales,Casey,ETH,Missing price"))
  }

  @Test
  func csvExportsTrustCapitalGainSupportFiguresInsteadOfIndividualNetCapitalGain() {
    let csv = TaxReportExportBuilder.csv(for: trustOwnerCapitalGainInput())

    #expect(!csv.contains("Owner,Family Trust,Net capital gain"))
    #expect(csv.contains("Owner,Family Trust,Short-term capital gains,150,AUD,false"))
    #expect(csv.contains("Owner,Family Trust,Long-term capital gains,300,AUD,false"))
    #expect(csv.contains("Owner,Family Trust,Capital losses,40,AUD,false"))
  }

  @Test
  func csvAllOwnerTrustTreatmentIgnoresInactiveTrustOwners() {
    let csv = TaxReportExportBuilder.csv(for: inactiveTrustReportInput())

    #expect(csv.contains("All owners,All owners,Net capital gain,160,AUD,false"))
    #expect(!csv.contains("All owners,All owners,Short-term capital gains"))
  }

  @Test
  func csvUsesDeterministicRowOrder() {
    let lines = TaxReportExportBuilder.csv(for: sortingReportInput()).split(separator: "\n").map(
      String.init)

    assertLineOrder(
      lines,
      [
        "Owner,Alex,Taxable income,200,AUD,false",
        "Owner,Sam,Taxable income,100,AUD,false",
      ])
    assertLineOrder(
      lines,
      [
        "Alex,2026-08-01,2025-07-01,BHP.AX,4,250,100,150,Held over 12 months,51000000-0000-0000-0000-000000000001",
        "Sam,2027-03-03,2027-01-10,BHP.AX,2,150,20,130,Held 12 months or less,51000000-0000-0000-0000-000000000002",
      ])
    assertLineOrder(
      lines,
      [
        "Sales,All owners,BHP.AX,Missing price",
        "Sales,All owners,ETH,Missing price",
      ])
    assertLineOrder(
      lines,
      [
        "Holdings,All owners,BHP.AX,3,90,150,12,60,72,AUD",
        "Holdings,All owners,ETH,2,10,16,4,6,10,AUD",
      ])
    assertLineOrder(
      lines,
      [
        "Holdings,All owners,BHP.AX,Missing price",
        "Holdings,All owners,ETH,Missing price",
      ])
  }

  @Test
  func csvEscapesOwnerFields() {
    let csv = TaxReportExportBuilder.csv(for: escapedReportInput())

    #expect(csv.contains("Owner,\"Alex \"\"Tax\"\", Pty\nOwner\",Taxable income,1,AUD,false"))
  }

  @Test
  func exportCompletionMapsFailureMessage() {
    let exportURL = URL(fileURLWithPath: "/tmp/moolah-tax-report.csv")

    #expect(TaxReportView.exportFailureMessage(for: .failure(TestExportError())) == "Export failed")
    #expect(TaxReportView.exportFailureMessage(for: .success(exportURL)) == nil)
  }
}

extension TaxReportExportBuilderTests {

  private var ownerAlex: UUID { makeUUID("00000000-0000-0000-0000-0000000000A1") }
  private var ownerSam: UUID { makeUUID("00000000-0000-0000-0000-0000000000B2") }
  private var ownerCasey: UUID { makeUUID("00000000-0000-0000-0000-0000000000C3") }
  private var ownerFamilyTrust: UUID { makeUUID("00000000-0000-0000-0000-0000000000F4") }
  private var defaultOwner: UUID { makeUUID("00000000-0000-0000-0000-0000000000D0") }
  private var saleOne: UUID { makeUUID("51000000-0000-0000-0000-000000000001") }
  private var saleTwo: UUID { makeUUID("51000000-0000-0000-0000-000000000002") }
  private var saleThree: UUID { makeUUID("51000000-0000-0000-0000-000000000003") }
  private var bhp: Instrument { Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP") }
  private var eth: Instrument {
    Instrument.crypto(
      chainId: 1,
      contractAddress: nil,
      symbol: "ETH",
      name: "Ethereum",
      decimals: 18)
  }

  private func completeReportInput() -> TaxReportExportInput {
    TaxReportExportInput(
      financialYear: 2027,
      holdingsDate: date(year: 2027, month: 6, day: 30),
      profileInstrument: .AUD,
      summary: completeReportSummary,
      events: completeReportEvents,
      capitalGainsHasUnavailableData: false,
      capitalGainsUnavailableInstruments: [],
      taxIncomeExpenseSummaries: completeReportIncomeExpense,
      taxIncomeExpenseRollup: TaxIncomeExpenseSummary(
        ownerId: defaultOwner,
        taxableIncome: amount(300),
        deductibleExpenses: amount(80)),
      taxOwnerNames: ownerNames,
      taxOwnerKinds: ownerKinds,
      profitLoss: [],
      profitLossHasUnavailableData: false,
      profitLossUnavailableInstruments: [],
      defaultTaxOwnerId: defaultOwner)
  }

  private func inactiveTrustReportInput() -> TaxReportExportInput {
    TaxReportExportInput(
      financialYear: 2027,
      holdingsDate: date(year: 2027, month: 6, day: 30),
      profileInstrument: .AUD,
      summary: completeReportSummary,
      events: completeReportEvents,
      capitalGainsHasUnavailableData: false,
      capitalGainsUnavailableInstruments: [],
      taxIncomeExpenseSummaries: completeReportIncomeExpense,
      taxIncomeExpenseRollup: TaxIncomeExpenseSummary(
        ownerId: defaultOwner,
        taxableIncome: amount(300),
        deductibleExpenses: amount(80)),
      taxOwnerNames: ownerNames.merging([ownerFamilyTrust: "Family Trust"]) { current, _ in
        current
      },
      taxOwnerKinds: ownerKinds.merging([ownerFamilyTrust: .trust]) { current, _ in current },
      profitLoss: [],
      profitLossHasUnavailableData: false,
      profitLossUnavailableInstruments: [],
      defaultTaxOwnerId: defaultOwner)
  }

  private func unavailableReportInput() -> TaxReportExportInput {
    TaxReportExportInput(
      financialYear: 2027,
      holdingsDate: date(year: 2027, month: 6, day: 30),
      profileInstrument: .AUD,
      summary: nil,
      events: [],
      capitalGainsHasUnavailableData: true,
      capitalGainsUnavailableInstruments: [eth],
      taxIncomeExpenseSummaries: [unavailableIncomeExpenseSummary],
      taxIncomeExpenseRollup: TaxIncomeExpenseSummary(
        ownerId: defaultOwner,
        taxableIncome: amount(0),
        deductibleExpenses: amount(0),
        hasUnavailableData: true),
      taxOwnerNames: [ownerAlex: "Alex"],
      taxOwnerKinds: [ownerAlex: .individual],
      profitLoss: [holdingProfitLoss],
      profitLossHasUnavailableData: true,
      profitLossUnavailableInstruments: [eth],
      defaultTaxOwnerId: defaultOwner)
  }

  private func capitalGainOnlyReportInput() -> TaxReportExportInput {
    TaxReportExportInput(
      financialYear: 2027,
      holdingsDate: date(year: 2027, month: 6, day: 30),
      profileInstrument: .AUD,
      summary: nil,
      events: [
        capitalGainEvent(
          CapitalGainFixture(
            ownerId: ownerCasey,
            sourceTransactionId: saleThree,
            sellDate: date(year: 2027, month: 2, day: 1),
            acquiredDate: date(year: 2027, month: 1, day: 1),
            quantity: 1,
            costBasis: 50,
            proceeds: 100))
      ],
      capitalGainsHasUnavailableData: false,
      capitalGainsUnavailableInstruments: [],
      taxIncomeExpenseSummaries: [],
      taxIncomeExpenseRollup: nil,
      taxOwnerNames: [ownerCasey: "Casey"],
      taxOwnerKinds: [ownerCasey: .individual],
      profitLoss: [],
      profitLossHasUnavailableData: false,
      profitLossUnavailableInstruments: [],
      defaultTaxOwnerId: defaultOwner)
  }

  private func sortingReportInput() -> TaxReportExportInput {
    TaxReportExportInput(
      financialYear: 2027,
      holdingsDate: date(year: 2027, month: 6, day: 30),
      profileInstrument: .AUD,
      summary: completeReportSummary,
      events: Array(completeReportEvents.reversed()),
      capitalGainsHasUnavailableData: true,
      capitalGainsUnavailableInstruments: [eth, bhp],
      taxIncomeExpenseSummaries: completeReportIncomeExpense,
      taxIncomeExpenseRollup: TaxIncomeExpenseSummary(
        ownerId: defaultOwner,
        taxableIncome: amount(300),
        deductibleExpenses: amount(80)),
      taxOwnerNames: ownerNames,
      taxOwnerKinds: ownerKinds,
      profitLoss: [ethProfitLoss, holdingProfitLoss],
      profitLossHasUnavailableData: true,
      profitLossUnavailableInstruments: [eth, bhp],
      defaultTaxOwnerId: defaultOwner)
  }

  private func escapedReportInput() -> TaxReportExportInput {
    TaxReportExportInput(
      financialYear: 2027,
      holdingsDate: date(year: 2027, month: 6, day: 30),
      profileInstrument: .AUD,
      summary: nil,
      events: [],
      capitalGainsHasUnavailableData: false,
      capitalGainsUnavailableInstruments: [],
      taxIncomeExpenseSummaries: [
        TaxIncomeExpenseSummary(
          ownerId: ownerAlex,
          taxableIncome: amount(1),
          deductibleExpenses: amount(0))
      ],
      taxIncomeExpenseRollup: nil,
      taxOwnerNames: [ownerAlex: "Alex \"Tax\", Pty\nOwner"],
      taxOwnerKinds: [ownerAlex: .individual],
      profitLoss: [],
      profitLossHasUnavailableData: false,
      profitLossUnavailableInstruments: [],
      defaultTaxOwnerId: defaultOwner)
  }

  private func unavailableOwnerCapitalGainInput() -> TaxReportExportInput {
    TaxReportExportInput(
      financialYear: 2027,
      holdingsDate: date(year: 2027, month: 6, day: 30),
      profileInstrument: .AUD,
      summary: nil,
      events: [
        capitalGainEvent(
          CapitalGainFixture(
            ownerId: ownerCasey,
            sourceTransactionId: saleThree,
            sellDate: date(year: 2027, month: 2, day: 1),
            acquiredDate: date(year: 2027, month: 1, day: 1),
            quantity: 1,
            costBasis: 50,
            proceeds: 100))
      ],
      capitalGainsHasUnavailableData: true,
      capitalGainsUnavailableInstruments: [eth],
      taxIncomeExpenseSummaries: [],
      taxIncomeExpenseRollup: nil,
      taxOwnerNames: [ownerCasey: "Casey"],
      taxOwnerKinds: [ownerCasey: .individual],
      profitLoss: [],
      profitLossHasUnavailableData: false,
      profitLossUnavailableInstruments: [],
      defaultTaxOwnerId: defaultOwner)
  }

  private func ownerUnavailableCapitalGainOnlyInput() -> TaxReportExportInput {
    TaxReportExportInput(
      financialYear: 2027,
      holdingsDate: date(year: 2027, month: 6, day: 30),
      profileInstrument: .AUD,
      summary: nil,
      events: [],
      capitalGainsHasUnavailableData: false,
      capitalGainsUnavailableInstruments: [],
      capitalGainsHasUnavailableDataByOwner: [ownerCasey: true],
      ownerUnavailableCapitalGainsInstruments: [ownerCasey: [eth]],
      taxIncomeExpenseSummaries: [],
      taxIncomeExpenseRollup: nil,
      taxOwnerNames: [ownerCasey: "Casey"],
      taxOwnerKinds: [ownerCasey: .individual],
      profitLoss: [],
      profitLossHasUnavailableData: false,
      profitLossUnavailableInstruments: [],
      defaultTaxOwnerId: defaultOwner)
  }

  private func trustOwnerCapitalGainInput() -> TaxReportExportInput {
    TaxReportExportInput(
      financialYear: 2027,
      holdingsDate: date(year: 2027, month: 6, day: 30),
      profileInstrument: .AUD,
      summary: nil,
      events: [
        capitalGainEvent(
          CapitalGainFixture(
            ownerId: ownerFamilyTrust,
            sourceTransactionId: saleOne,
            sellDate: date(year: 2027, month: 2, day: 1),
            acquiredDate: date(year: 2027, month: 1, day: 1),
            quantity: 1,
            costBasis: 50,
            proceeds: 200)),
        capitalGainEvent(
          CapitalGainFixture(
            ownerId: ownerFamilyTrust,
            sourceTransactionId: saleTwo,
            sellDate: date(year: 2027, month: 2, day: 2),
            acquiredDate: date(year: 2025, month: 1, day: 1),
            quantity: 1,
            costBasis: 100,
            proceeds: 400)),
        capitalGainEvent(
          CapitalGainFixture(
            ownerId: ownerFamilyTrust,
            sourceTransactionId: saleThree,
            sellDate: date(year: 2027, month: 2, day: 3),
            acquiredDate: date(year: 2027, month: 1, day: 1),
            quantity: 1,
            costBasis: 40,
            proceeds: 0)),
      ],
      capitalGainsHasUnavailableData: false,
      capitalGainsUnavailableInstruments: [],
      taxIncomeExpenseSummaries: [],
      taxIncomeExpenseRollup: nil,
      taxOwnerNames: [ownerFamilyTrust: "Family Trust"],
      taxOwnerKinds: [ownerFamilyTrust: .trust],
      profitLoss: [],
      profitLossHasUnavailableData: false,
      profitLossUnavailableInstruments: [],
      defaultTaxOwnerId: defaultOwner)
  }

  private var completeReportSummary: CapitalGainsSummary {
    CapitalGainsSummary(
      shortTermGain: 40,
      longTermGain: 240,
      totalGain: 280,
      eventCount: 2,
      shortTermCapitalGains: 40,
      longTermCapitalGains: 240,
      capitalLosses: 0)
  }

  private var completeReportEvents: [CapitalGainEvent] {
    [
      capitalGainEvent(
        CapitalGainFixture(
          ownerId: ownerAlex,
          sourceTransactionId: saleOne,
          sellDate: date(year: 2026, month: 8, day: 1),
          acquiredDate: date(year: 2025, month: 7, day: 1),
          quantity: 4,
          costBasis: 100,
          proceeds: 250)),
      capitalGainEvent(
        CapitalGainFixture(
          ownerId: ownerSam,
          sourceTransactionId: saleTwo,
          sellDate: date(year: 2027, month: 3, day: 3),
          acquiredDate: date(year: 2027, month: 1, day: 10),
          quantity: 2,
          costBasis: 20,
          proceeds: 150)),
    ]
  }

  private var completeReportIncomeExpense: [TaxIncomeExpenseSummary] {
    [
      TaxIncomeExpenseSummary(
        ownerId: ownerSam,
        taxableIncome: amount(100),
        deductibleExpenses: amount(25)),
      TaxIncomeExpenseSummary(
        ownerId: ownerAlex,
        taxableIncome: amount(200),
        deductibleExpenses: amount(55)),
    ]
  }

  private var unavailableIncomeExpenseSummary: TaxIncomeExpenseSummary {
    TaxIncomeExpenseSummary(
      ownerId: ownerAlex,
      taxableIncome: amount(0),
      deductibleExpenses: amount(0),
      hasUnavailableData: true)
  }

  private var holdingProfitLoss: InstrumentProfitLoss {
    InstrumentProfitLoss(
      instrument: bhp,
      currentQuantity: 3,
      totalInvested: 90,
      currentValue: 150,
      realizedGain: 12,
      unrealizedGain: 60)
  }

  private var ethProfitLoss: InstrumentProfitLoss {
    InstrumentProfitLoss(
      instrument: eth,
      currentQuantity: 2,
      totalInvested: 10,
      currentValue: 16,
      realizedGain: 4,
      unrealizedGain: 6)
  }

  private var ownerNames: [UUID: String] {
    [ownerAlex: "Alex", ownerSam: "Sam", defaultOwner: "Default owner"]
  }
  private var ownerKinds: [UUID: TaxOwnerKind] {
    [ownerAlex: .individual, ownerSam: .individual, defaultOwner: .individual]
  }

  private func assertCompleteReport(_ csv: String) {
    #expect(csv.contains("Financial year,2026/27 financial year"))
    #expect(csv.contains("Holdings date,2027-06-30"))
    #expect(csv.contains("All owners,All owners,Taxable income,300,AUD,false"))
    #expect(csv.contains("All owners,All owners,Net capital gain,160,AUD,false"))
    #expect(csv.contains("Owner,Alex,Taxable income,200,AUD,false"))
    #expect(csv.contains("Owner,Alex,Net capital gain,75,AUD,false"))
    #expect(csv.contains("Owner,Sam,Taxable income,100,AUD,false"))
    #expect(csv.contains("Owner,Sam,Net capital gain,130,AUD,false"))
    #expect(
      csv.contains(
        "Alex,2026-08-01,2025-07-01,BHP.AX,4,250,100,150,Held over 12 months,51000000-0000-0000-0000-000000000001"
      ))
    #expect(
      csv.contains(
        "Sam,2027-03-03,2027-01-10,BHP.AX,2,150,20,130,Held 12 months or less,51000000-0000-0000-0000-000000000002"
      ))
  }

  private func assertLineOrder(_ lines: [String], _ expected: [String]) {
    var searchStart = lines.startIndex
    for expectedLine in expected {
      guard
        let matchIndex = lines[searchStart...].firstIndex(of: expectedLine)
      else {
        Issue.record("Missing CSV line: \(expectedLine)")
        return
      }
      searchStart = lines.index(after: matchIndex)
    }
  }

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: .AUD)
  }

  private func capitalGainEvent(_ fixture: CapitalGainFixture) -> CapitalGainEvent {
    CapitalGainEvent(
      sourceTransactionId: fixture.sourceTransactionId,
      instrument: bhp,
      sellDate: fixture.sellDate,
      acquiredDate: fixture.acquiredDate,
      quantity: fixture.quantity,
      costBasis: fixture.costBasis,
      proceeds: fixture.proceeds,
      holdingDays: AustralianTaxCalendar.calendar.dateComponents(
        [.day], from: fixture.acquiredDate, to: fixture.sellDate
      ).day ?? 0,
      taxOwnerId: fixture.ownerId)
  }

  private func date(year: Int, month: Int, day: Int) -> Date {
    guard
      let result = AustralianTaxCalendar.calendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: 12))
    else {
      fatalError("Could not construct date \(year)-\(month)-\(day)")
    }
    return result
  }

}

private struct CapitalGainFixture {
  let ownerId: UUID
  let sourceTransactionId: UUID
  let sellDate: Date
  let acquiredDate: Date
  let quantity: Decimal
  let costBasis: Decimal
  let proceeds: Decimal
}

private struct TestExportError: LocalizedError {
  var errorDescription: String? { "Export failed" }
}
