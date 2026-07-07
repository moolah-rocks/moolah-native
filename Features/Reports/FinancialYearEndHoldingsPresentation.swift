import Foundation

struct FinancialYearEndHoldingsPresentation: Hashable {
  let rows: [InstrumentProfitLoss]
  let unrealizedTotal: InstrumentAmount
}
