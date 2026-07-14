import SwiftUI

extension ReportsView {
  @ViewBuilder
  func taxIncomeExpenseDrillDownDestination(
    _ drillDown: TaxIncomeExpenseDrillDown
  ) -> some View {
    TaxIncomeExpenseDetailView(
      drillDown: drillDown,
      profileInstrument: reportingStore.profileCurrency,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore
    ) {
      try await reportingStore.fetchTaxIncomeExpenseDetails(
        dateInterval: drillDown.dateInterval,
        ownerId: drillDown.ownerId,
        type: drillDown.kind.transactionType)
    }
  }
}
