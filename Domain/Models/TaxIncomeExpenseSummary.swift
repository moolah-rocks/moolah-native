import Foundation

/// Tax-reportable income and deductible expenses allocated to one tax owner.
///
/// `deductibleExpenses` is a positive deduction amount: normal negative
/// expense legs increase it, while positive expense refunds reduce it.
struct TaxIncomeExpenseSummary: Sendable, Identifiable, Hashable {
  var id: UUID { ownerId }

  let ownerId: UUID
  let taxableIncome: InstrumentAmount
  let deductibleExpenses: InstrumentAmount
  var hasUnavailableData = false

  var netTaxableIncome: InstrumentAmount {
    taxableIncome - deductibleExpenses
  }
}
