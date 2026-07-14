import Foundation

/// Tax-reportable income and deductible expenses allocated to one tax owner.
///
/// `deductibleExpenses` is a positive deduction amount: normal negative
/// expense legs increase it, while positive expense refunds reduce it.
struct TaxIncomeExpenseSummary {
  let ownerId: UUID
  let taxableIncome: InstrumentAmount
  let deductibleExpenses: InstrumentAmount
  let incomeHasUnavailableData: Bool
  let deductionsHasUnavailableData: Bool

  init(
    ownerId: UUID,
    taxableIncome: InstrumentAmount,
    deductibleExpenses: InstrumentAmount,
    incomeHasUnavailableData: Bool = false,
    deductionsHasUnavailableData: Bool = false
  ) {
    self.ownerId = ownerId
    self.taxableIncome = taxableIncome
    self.deductibleExpenses = deductibleExpenses
    self.incomeHasUnavailableData = incomeHasUnavailableData
    self.deductionsHasUnavailableData = deductionsHasUnavailableData
  }

  var hasUnavailableData: Bool {
    incomeHasUnavailableData || deductionsHasUnavailableData
  }

  var netHasUnavailableData: Bool { hasUnavailableData }

  var netTaxableIncome: InstrumentAmount {
    taxableIncome - deductibleExpenses
  }
}

extension TaxIncomeExpenseSummary: Sendable {}

extension TaxIncomeExpenseSummary: Identifiable {
  var id: UUID { ownerId }
}

extension TaxIncomeExpenseSummary: Hashable {}
