import Foundation

extension ReportingStore {
  static func taxIncomeExpenseDateRange(
    financialYear: Int,
    dates: TaxReportLoadDates
  ) -> Range<Date>? {
    guard let interval = TaxReportPresentation.financialYearInterval(financialYear) else {
      return nil
    }
    let upper = dates.ledgerBeforeDate ?? interval.upperBound
    return interval.lowerBound..<upper
  }

  static func taxReportLoadDates(financialYear: Int, today: Date) -> TaxReportLoadDates {
    let valuationDate = TaxReportPresentation.holdingsObservationDate(
      financialYear: financialYear,
      today: today)
    let ledgerBeforeDate = TaxReportPresentation.holdingsLedgerCutoffDate(
      financialYear: financialYear,
      observationDate: valuationDate)
    let sellDateInterval =
      TaxReportPresentation.financialYearInterval(financialYear).flatMap { financialYearInterval in
        ledgerBeforeDate.map { financialYearInterval.lowerBound..<$0 }
      }
    return TaxReportLoadDates(
      valuationDate: valuationDate,
      ledgerBeforeDate: ledgerBeforeDate,
      sellDateInterval: sellDateInterval)
  }

  static func taxIncomeExpenseRollup(
    from summaries: [TaxIncomeExpenseSummary],
    instrument: Instrument
  ) -> TaxIncomeExpenseSummary? {
    guard let ownerId = summaries.first?.ownerId else { return nil }
    let zero = InstrumentAmount.zero(instrument: instrument)
    let income = summaries.reduce(zero) { $0 + $1.taxableIncome }
    let deductions = summaries.reduce(zero) { $0 + $1.deductibleExpenses }
    return TaxIncomeExpenseSummary(
      ownerId: ownerId,
      taxableIncome: income,
      deductibleExpenses: deductions,
      hasUnavailableData: summaries.contains { $0.hasUnavailableData })
  }
}
