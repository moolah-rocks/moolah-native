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
