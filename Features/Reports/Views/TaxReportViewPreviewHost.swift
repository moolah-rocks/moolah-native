import SwiftUI

private struct TaxReportViewPreviewHost: View {
  var summary: CapitalGainsSummary? = TaxReportPreviewData.summary
  var events: [CapitalGainEvent] = TaxReportPreviewData.events
  var capitalGainsHasUnavailableData = false
  var capitalGainsUnavailableInstruments: [Instrument] = []
  var taxIncomeExpenseSummaries: [TaxIncomeExpenseSummary] = TaxReportPreviewData.taxIncomeExpense
  var taxIncomeExpenseError: Error?
  var taxOwnerNames: [UUID: String] = TaxReportPreviewData.taxOwnerNames
  var profitLoss: [InstrumentProfitLoss] = TaxReportPreviewData.holdings
  var profitLossHasUnavailableData = false
  var profitLossUnavailableInstruments: [Instrument] = []
  var isLoading = false
  var error: Error?
  var isMigratingCrossChainIdentity = false

  var body: some View {
    TaxReportView(
      financialYear: 2026,
      holdingsDate: TaxReportPreviewData.date(2026, 6, 30),
      profileInstrument: .AUD,
      summary: summary,
      events: events,
      capitalGainsHasUnavailableData: capitalGainsHasUnavailableData,
      capitalGainsUnavailableInstruments: capitalGainsUnavailableInstruments,
      taxIncomeExpenseSummaries: taxIncomeExpenseSummaries,
      taxIncomeExpenseRollup: TaxReportPreviewData.taxIncomeExpenseRollup(
        from: taxIncomeExpenseSummaries),
      defaultTaxOwnerId: TaxReportPreviewData.ownerA,
      taxIncomeExpenseDateInterval: TaxReportPresentation.financialYearInterval(2026),
      taxIncomeExpenseError: taxIncomeExpenseError,
      taxOwnerNames: taxOwnerNames,
      profitLoss: profitLoss,
      profitLossHasUnavailableData: profitLossHasUnavailableData,
      profitLossUnavailableInstruments: profitLossUnavailableInstruments,
      isLoading: isLoading,
      error: error,
      isMigratingCrossChainIdentity: isMigratingCrossChainIdentity,
      reload: {})
  }
}

private struct PreviewReportError: LocalizedError {
  var errorDescription: String? {
    "Preview price data is unavailable."
  }
}

enum TaxReportPreviewData {
  static let bhp = Instrument.stock(
    ticker: "BHP.AX",
    exchange: "ASX",
    name: "BHP Group Limited")
  static let longNameStock = Instrument.stock(
    ticker: "VERY-LONG-HOLDING-NAME.AX",
    exchange: "ASX",
    name: "Very Long Australian Index Holding Name Limited")
  static let optimism = Instrument.crypto(
    chainId: 10,
    contractAddress: "0x4200000000000000000000000000000000000042",
    symbol: "OP",
    name: "Optimism",
    decimals: 18)
  static let ownerA = UUID()
  static let ownerB = UUID()

  static let taxOwnerNames = [
    ownerA: "Alex",
    ownerB: "Jordan",
  ]

  static let events = [
    event(
      instrument: bhp,
      sellDate: date(2026, 3, 1),
      acquiredDate: date(2024, 2, 20),
      value: PreviewCapitalGainValue(quantity: 120, costBasis: 4_800, proceeds: 6_150)),
    event(
      instrument: bhp,
      sellDate: date(2026, 3, 1),
      acquiredDate: date(2025, 11, 18),
      value: PreviewCapitalGainValue(quantity: 30, costBasis: 1_800, proceeds: 1_537.50)),
    event(
      instrument: optimism,
      sellDate: date(2026, 5, 6),
      acquiredDate: date(2025, 12, 1),
      value: PreviewCapitalGainValue(quantity: 20_167, costBasis: 9_871.08, proceeds: 3_497.35)),
  ]

  static let summary = CapitalGainsSummary(
    shortTermGain: -6_636.23,
    longTermGain: 1_350,
    totalGain: -5_286.23,
    eventCount: 2,
    shortTermCapitalGains: 0,
    longTermCapitalGains: 1_350,
    capitalLosses: 6_636.23)

  static let taxIncomeExpense = [
    TaxIncomeExpenseSummary(
      ownerId: ownerA,
      taxableIncome: InstrumentAmount(quantity: 18_400, instrument: .AUD),
      deductibleExpenses: InstrumentAmount(quantity: 2_150, instrument: .AUD)),
    TaxIncomeExpenseSummary(
      ownerId: ownerB,
      taxableIncome: InstrumentAmount(quantity: 12_250, instrument: .AUD),
      deductibleExpenses: InstrumentAmount(quantity: 1_780, instrument: .AUD)),
  ]

  static func taxIncomeExpenseRollup(
    from summaries: [TaxIncomeExpenseSummary]
  ) -> TaxIncomeExpenseSummary? {
    guard let ownerId = summaries.first?.ownerId else { return nil }
    let zero = InstrumentAmount.zero(instrument: .AUD)
    let income = summaries.reduce(zero) { $0 + $1.taxableIncome }
    let deductions = summaries.reduce(zero) { $0 + $1.deductibleExpenses }
    return TaxIncomeExpenseSummary(
      ownerId: ownerId,
      taxableIncome: income,
      deductibleExpenses: deductions)
  }

  static let holdings = [
    InstrumentProfitLoss(
      instrument: longNameStock,
      currentQuantity: 17_726,
      totalInvested: 596_675.72,
      currentValue: 637_062.94,
      realizedGain: 0,
      unrealizedGain: 40_387.22),
    InstrumentProfitLoss(
      instrument: bhp,
      currentQuantity: 295,
      totalInvested: 30_528.59,
      currentValue: 30_569.16,
      realizedGain: 0,
      unrealizedGain: 40.57),
    InstrumentProfitLoss(
      instrument: optimism,
      currentQuantity: 47_046.61,
      totalInvested: 109_625.66,
      currentValue: 49_917.46,
      realizedGain: 0,
      unrealizedGain: -59_708.19),
  ]

  static func event(
    instrument: Instrument,
    sellDate: Date,
    acquiredDate: Date,
    value: PreviewCapitalGainValue
  ) -> CapitalGainEvent {
    CapitalGainEvent(
      sourceTransactionId: UUID(),
      instrument: instrument,
      sellDate: sellDate,
      acquiredDate: acquiredDate,
      quantity: value.quantity,
      costBasis: value.costBasis,
      proceeds: value.proceeds,
      holdingDays: AustralianTaxCalendar.calendar.dateComponents(
        [.day],
        from: acquiredDate,
        to: sellDate
      ).day ?? 0)
  }

  static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    guard
      let date = AustralianTaxCalendar.calendar.date(
        from: DateComponents(year: year, month: month, day: day))
    else {
      fatalError("Could not build preview date")
    }
    return date
  }
}

struct PreviewCapitalGainValue {
  let quantity: Decimal
  let costBasis: Decimal
  let proceeds: Decimal
}

#Preview("Capital Gains Report") {
  TaxReportViewPreviewHost()
    .frame(width: 1180, height: 760)
}

#Preview("Capital Gains Report - Narrow") {
  TaxReportViewPreviewHost()
    .frame(width: 720, height: 760)
}

#Preview("Capital Gains Report - Unavailable Data") {
  TaxReportViewPreviewHost(
    capitalGainsHasUnavailableData: true,
    capitalGainsUnavailableInstruments: [TaxReportPreviewData.optimism],
    profitLossHasUnavailableData: true,
    profitLossUnavailableInstruments: [TaxReportPreviewData.longNameStock]
  )
  .frame(width: 1180, height: 760)
}

#Preview("Capital Gains Report - Loading") {
  TaxReportViewPreviewHost(
    summary: nil,
    events: [],
    profitLoss: [],
    isLoading: true
  )
  .frame(width: 1180, height: 760)
}

#Preview("Capital Gains Report - Empty") {
  TaxReportViewPreviewHost(
    summary: CapitalGainsSummary(shortTermGain: 0, longTermGain: 0, totalGain: 0, eventCount: 0),
    events: [],
    profitLoss: []
  )
  .frame(width: 1180, height: 760)
}

#Preview("Capital Gains Report - Migration") {
  TaxReportViewPreviewHost(
    summary: nil,
    events: [],
    profitLoss: [],
    isMigratingCrossChainIdentity: true
  )
  .frame(width: 1180, height: 760)
}

#Preview("Capital Gains Report - Error") {
  TaxReportViewPreviewHost(
    summary: nil,
    events: [],
    profitLoss: [],
    error: PreviewReportError()
  )
  .frame(width: 1180, height: 760)
}

#Preview("Capital Gains Report - Tax Income Error") {
  TaxReportViewPreviewHost(
    taxIncomeExpenseSummaries: [],
    taxIncomeExpenseError: PreviewReportError()
  )
  .frame(width: 1180, height: 760)
}
